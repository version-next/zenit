#include "d3d12_resources.h"
#include <windows.h>
#include <d3d12.h>
#include <dxgi1_4.h>
#include <dcomp.h>
#include <dwmapi.h>
#include <stdlib.h>
#include <float.h>
#include <string.h>
#include <stdio.h>
#include "dxgi_driver_info.h"
#include "d3d12_atomic_probe.h"
#include "d3d12_ledger.h"

// Per-frame command objects whose GPU use has ended, kept for reuse: creating
// a command allocator, list, timestamp query heap, readback buffer and
// shader-visible descriptor pages for every frame cost hundreds of
// microseconds. Entries hold raw COM objects only (no ZenitD12Device refs).
struct D12CommandPoolEntry { ID3D12CommandAllocator *allocator; ID3D12GraphicsCommandList *list; ID3D12QueryHeap *timestamps; ID3D12Resource *readback; void *mapping; };
static constexpr uint32_t COMMAND_POOL_CAPACITY=8, PAGE_POOL_CAPACITY=16;
struct ZenitD12Device { ID3D12Device *raw; LONG refs; int software; bool vertex_viewport_index; ZenitD12DriverInfo driver_info; SRWLOCK atomic_lock; volatile LONG atomic_state; ZenitAtomicProbe *pending_probe;
    SRWLOCK pool_lock; D12CommandPoolEntry command_pool[COMMAND_POOL_CAPACITY]; uint32_t command_pool_count;
    ID3D12DescriptorHeap *page_pool[2][PAGE_POOL_CAPACITY]; uint32_t page_pool_count[2]; };
static void release_pool_entry(D12CommandPoolEntry &e) {
    if (e.list) e.list->Release(); if (e.allocator) e.allocator->Release();
    if (e.timestamps) e.timestamps->Release();
    if (e.readback) { if (e.mapping) e.readback->Unmap(0,nullptr); e.readback->Release(); }
    e={};
}
struct ZenitD12Texture {
    ID3D12Resource *raw; ZenitD12Device *owner; LONG refs;
    uint32_t dimension, width, height, depth, mips, usage, samples;
    DXGI_FORMAT format;
    // Full-range SRVs by view dimension (1..6), created on first use and
    // shared: a texture's views are immutable. Each holder of a cached view
    // also holds one texture reference, so these outlive every holder.
    ZenitD12View *cached_views[7];
    // SHADER_SAMPLE support of the SRV format: 0 unknown, 1 yes, 2 no.
    uint8_t sample_support;
    // Render-target view of mip 0 / layer 0, for single-attachment passes.
    ID3D12DescriptorHeap *rtv_heap;
    // ZENIT_GPU_LEDGER accounting (LK_NONE when the ledger is off).
    uint64_t ledger_bytes; D12LedgerKind ledger_kind;
};
// A cached view (owned by its texture) or a private view (owns a texture ref).
struct ZenitD12View { ID3D12DescriptorHeap *heap; ZenitD12Texture *texture; LONG refs; uint32_t dimension; bool storage, cached; };
struct ZenitD12Buffer { ID3D12Resource *raw; ZenitD12Device *owner; void *mapping; LONG refs; uint64_t size; uint32_t usage; uint64_t ledger_bytes; D12LedgerKind ledger_kind; };
static constexpr uint32_t MAP_READ=1, MAP_WRITE=2, COPY_DST=8, UNIFORM=64, STORAGE=128;
// ZENIT_D3D12_DEBUG=1: the D3D12 debug layer, its messages printed at each
// present (zenit_d12_debug_drain). Diagnostics only (slow).
static bool d12_debug_requested() {
    static LONG state = 0;
    LONG v = InterlockedCompareExchange(&state, 0, 0);
    if (!v) {
        char buf[4] = {};
        v = GetEnvironmentVariableA("ZENIT_D3D12_DEBUG", buf, sizeof(buf)) && buf[0] == '1' ? 2 : 1;
        InterlockedExchange(&state, v);
    }
    return v == 2;
}
extern "C" void zenit_d12_debug_drain(ID3D12Device *device) {
    if (!d12_debug_requested() || !device) return;
    ID3D12InfoQueue *info = nullptr;
    if (FAILED(device->QueryInterface(IID_ID3D12InfoQueue, (void **)&info))) return;
    const UINT64 count = info->GetNumStoredMessagesAllowedByRetrievalFilter();
    for (UINT64 i = 0; i < count; ++i) {
        SIZE_T size = 0;
        if (FAILED(info->GetMessage(i, nullptr, &size))) continue;
        auto message = (D3D12_MESSAGE *)malloc(size);
        if (!message) break;
        if (SUCCEEDED(info->GetMessage(i, message, &size)) && message->Severity <= D3D12_MESSAGE_SEVERITY_WARNING)
            fprintf(stderr, "[d3d12-debug] sev=%d id=%u %s\n", (int)message->Severity, unsigned(message->ID), message->pDescription);
        free(message);
    }
    info->ClearStoredMessages();
    info->Release();
    fflush(stderr);
}

extern "C" int zenit_d12_device_create(int force_warp, ZenitD12Device **out) {
    if (!out) return 1;
    *out = nullptr;
    if (d12_debug_requested()) {
        ID3D12Debug *debug = nullptr;
        if (SUCCEEDED(D3D12GetDebugInterface(IID_ID3D12Debug, (void **)&debug))) {
            debug->EnableDebugLayer();
            debug->Release();
            fprintf(stderr, "[d3d12-debug] debug layer enabled\n");
        } else fprintf(stderr, "[d3d12-debug] debug layer unavailable\n");
    }
    ID3D12Device *raw = nullptr;
    HRESULT hr = E_FAIL;
    int software = 0;
    ZenitD12DriverInfo driver_info={};
    IDXGIFactory4 *factory = nullptr;
    hr = CreateDXGIFactory1(IID_IDXGIFactory4, (void **)&factory);
    if (FAILED(hr)) return 2;
    // The default adapter need not support D3D12. Try every hardware adapter
    // in DXGI order before selecting WARP; never classify a software adapter
    // as hardware just because device creation succeeded.
    if (!force_warp) {
        for (UINT index = 0; ; ++index) {
            IDXGIAdapter1 *adapter = nullptr;
            hr = factory->EnumAdapters1(index, &adapter);
            if (FAILED(hr)) break;
            DXGI_ADAPTER_DESC1 desc = {};
            hr = adapter->GetDesc1(&desc);
            if (SUCCEEDED(hr) && !(desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE)) {
                hr = D3D12CreateDevice(adapter, D3D_FEATURE_LEVEL_11_0,
                    IID_ID3D12Device, (void **)&raw);
                char name[512] = {};
                if (!WideCharToMultiByte(CP_UTF8, 0, desc.Description, -1,
                        name, sizeof(name), nullptr, nullptr)) strcpy(name, "unknown");
                fprintf(stderr, "[d3d12-adapter] index=%u name=%s vendor=%04x device=%04x result=0x%08lx\n",
                    index, name, desc.VendorId, desc.DeviceId, (unsigned long)hr);
            }
            if (raw) driver_info=zenit_dxgi_driver_info(adapter);
            adapter->Release();
            if (raw) break;
        }
    }
    if (!raw && !force_warp && GetEnvironmentVariableW(L"ZENIT_D3D12_REQUIRE_HARDWARE",nullptr,0)) {
        fprintf(stderr,"[d3d12-adapter] required hardware unavailable; refusing WARP fallback\n");
        factory->Release(); return 2;
    }
    if (!raw) {
        IDXGIAdapter *adapter = nullptr;
        hr = factory->EnumWarpAdapter(IID_IDXGIAdapter, (void **)&adapter);
        if (SUCCEEDED(hr)) hr = D3D12CreateDevice(adapter, D3D_FEATURE_LEVEL_11_0, IID_ID3D12Device, (void **)&raw);
        if (adapter) { if (raw) driver_info=zenit_dxgi_driver_info(adapter); adapter->Release(); }
        software = 1;
        fprintf(stderr, "[d3d12-adapter] selected=WARP forced=%d result=0x%08lx\n", force_warp != 0, (unsigned long)hr);
    }
    factory->Release();
    if (FAILED(hr)) return 2;
    auto device = (ZenitD12Device *)calloc(1, sizeof(ZenitD12Device));
    if (!device) { raw->Release(); return 2; }
    device->raw = raw; device->refs = 1; device->software = software; device->driver_info=driver_info;
    d12_ledger_start(raw);
    D3D12_FEATURE_DATA_D3D12_OPTIONS options = {};
    HRESULT options_hr = raw->CheckFeatureSupport(D3D12_FEATURE_D3D12_OPTIONS, &options, sizeof(options));
    device->vertex_viewport_index = SUCCEEDED(options_hr) && options.VPAndRTArrayIndexFromAnyShaderFeedingRasterizerSupportedWithoutGSEmulation;
#ifdef ZENIT_D12_TEST
    fprintf(stderr, "[d3d12-capability] options=0x%08lx vertex_viewport_array_index=%d\n",
        (unsigned long)options_hr,
        SUCCEEDED(options_hr) && options.VPAndRTArrayIndexFromAnyShaderFeedingRasterizerSupportedWithoutGSEmulation);
#endif
    *out = device;
    return 0;
}
extern "C" void zenit_d12_device_release(ZenitD12Device *device) {
    if (device && InterlockedDecrement(&device->refs) == 0) { if (device->pending_probe) {
            auto p=device->pending_probe;
            if (!p->submitted || (p->fence && p->fence->GetCompletedValue()>=1) || FAILED(device->raw->GetDeviceRemovedReason())) delete p;
            else fprintf(stderr,"[d3d12-atomic-probe] retaining pending GPU resources after timeout\n");
        }
        for (uint32_t i=0;i<device->command_pool_count;++i) release_pool_entry(device->command_pool[i]);
        for (uint32_t t=0;t<2;++t) for (uint32_t i=0;i<device->page_pool_count[t];++i) device->page_pool[t][i]->Release();
        device->raw->Release(); free(device); }
}
extern "C" void zenit_d12_device_driver_info(ZenitD12Device *device, ZenitD12DriverInfo *out) { *out=device->driver_info; }
// State: 0 untested, 1 original path, 2 switch, 3 operational failure.
// Decided states are published once and read without the probe lock, so a
// slow or hung probe never blocks capability queries or later pipelines.
// Failures before submission (allocation, compilation, resource creation)
// leave the device untested and are retried by the next pipeline; a probe
// that was submitted and timed out, a removed device or an invalid override
// is final.
extern "C" int zenit_d12_device_atomic_workaround(ZenitD12Device *device, int test) {
    LONG state=InterlockedCompareExchange(&device->atomic_state,0,0);
    if (state || !test) return (int)state;
    AcquireSRWLockExclusive(&device->atomic_lock);
    state=device->atomic_state;
    if (!state) {
        LARGE_INTEGER started, ended, frequency;
        QueryPerformanceFrequency(&frequency); QueryPerformanceCounter(&started);
        char override_value[16]={};
        DWORD length=GetEnvironmentVariableA("ZENIT_D3D12_UAV_ATOMIC_SWITCH",override_value,sizeof(override_value));
        if (length>=sizeof(override_value) || (length && strcmp(override_value,"0") && strcmp(override_value,"1"))) {
            fprintf(stderr,"[d3d12-atomic-probe] invalid ZENIT_D3D12_UAV_ATOMIC_SWITCH; expected 0 or 1\n");
            state=3;
        } else if (length) {
            state=override_value[0]=='1'?2:1;
            fprintf(stderr,"[d3d12-atomic-probe] forced switch=%d\n",state==2);
        } else if (device->software) state=1;
        else {
            bool correct=true, transient=false;
            for (unsigned raw=0;raw<2;++raw) {
                auto p=new(std::nothrow) ZenitAtomicProbe;
                if (!p) { fprintf(stderr,"[d3d12-atomic-probe] allocation failed: 0x%08lx\n",(unsigned long)E_OUTOFMEMORY); transient=true; break; }
                bool result=false;
                HRESULT hr=zenit_atomic_probe(device->raw,raw,p,&result);
                fprintf(stderr,"[d3d12-atomic-probe] raw=%d result=0x%08lx correct=%d\n",raw,(unsigned long)hr,result);
                if (FAILED(hr)) {
                    bool removed=FAILED(device->raw->GetDeviceRemovedReason());
                    bool in_flight=p->submitted && !(p->fence && p->fence->GetCompletedValue()>=1);
                    if (in_flight && !removed) {
                        // The GPU may still write these resources: keep them
                        // alive until the device is released.
                        device->pending_probe=p; state=3;
                    } else {
                        delete p;
                        if (removed) state=3; else transient=true;
                    }
                    break;
                }
                delete p; correct &= result;
            }
            if (!state && !transient) state=correct?1:2;
            if (transient) fprintf(stderr,"[d3d12-atomic-probe] transient failure; will retry on the next pipeline\n");
            if (transient) {
                QueryPerformanceCounter(&ended);
                ReleaseSRWLockExclusive(&device->atomic_lock);
                return 3;
            }
        }
        QueryPerformanceCounter(&ended);
        fprintf(stderr,"[d3d12-atomic-probe] cached-state=%ld elapsed-ms=%.3f\n",state,
            1000.0*double(ended.QuadPart-started.QuadPart)/double(frequency.QuadPart));
        InterlockedExchange(&device->atomic_state,state);
    }
    ReleaseSRWLockExclusive(&device->atomic_lock);
    return (int)state;
}
#ifdef ZENIT_D12_TEST
extern "C" int zenit_d12_test_atomic_probe_device_loss() {
    ZenitD12Device *device=nullptr;
    if (zenit_d12_device_create(0,&device)) return 1;
    if (device->software) { zenit_d12_device_release(device); return 4; }
    ID3D12Device5 *control=nullptr;
    HRESULT hr=device->raw->QueryInterface(IID_ID3D12Device5,(void**)&control);
    if (FAILED(hr)) { zenit_d12_device_release(device); return 2; }
    control->RemoveDevice(); control->Release();
    int first=zenit_d12_device_atomic_workaround(device,1);
    int cached=zenit_d12_device_atomic_workaround(device,1);
    zenit_d12_device_release(device);
    return first==3 && cached==3 ? 0 : 3;
}
#endif
extern "C" int zenit_d12_device_vertex_viewport_index(ZenitD12Device *device) { return device && device->vertex_viewport_index; }
extern "C" int zenit_d12_device_is_software(ZenitD12Device *device) { return device->software; }
extern "C" void *zenit_d12_device_native(ZenitD12Device *device) { return device->raw; }
extern "C" void *zenit_d12_buffer_native(ZenitD12Buffer *buffer) { return buffer->raw; }
extern "C" void *zenit_d12_buffer_mapping(ZenitD12Buffer *buffer) { return buffer->mapping; }
extern "C" int zenit_d12_buffer_create(ZenitD12Device *device, uint64_t size, uint32_t usage, ZenitD12Buffer **out) {
    if (!out) return 1;
    *out = nullptr;
    // Readback heaps can only be copy destinations. Upload heaps permit the
    // existing renderers' persistent mapped vertex/uniform/index allocations.
    // Storage in upload heaps is shader-readable, never a writable UAV.
    if (!device || !size || !usage || (usage & ~1023u) ||
        ((usage & MAP_READ) && (usage & ~(MAP_READ | COPY_DST))) ||
        ((usage & MAP_WRITE) && (usage & (MAP_READ | COPY_DST | 512u)))) return 1;
    uint64_t allocation_size = size;
    if (usage & UNIFORM) {
        if (size > UINT64_MAX - 255) return 1;
        allocation_size = (size + 255) & ~uint64_t(255);
    }
    D3D12_HEAP_PROPERTIES heap = {};
    heap.Type = (usage & MAP_WRITE) ? D3D12_HEAP_TYPE_UPLOAD :
                (usage & MAP_READ) ? D3D12_HEAP_TYPE_READBACK : D3D12_HEAP_TYPE_DEFAULT;
    heap.CreationNodeMask = heap.VisibleNodeMask = 1;
    D3D12_RESOURCE_DESC desc = {};
    desc.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
    desc.Width = allocation_size; desc.Height = 1; desc.DepthOrArraySize = 1;
    desc.MipLevels = 1; desc.SampleDesc.Count = 1; desc.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    if ((usage & STORAGE) && heap.Type == D3D12_HEAP_TYPE_DEFAULT) desc.Flags = D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;
    D3D12_RESOURCE_STATES state = heap.Type == D3D12_HEAP_TYPE_UPLOAD ? D3D12_RESOURCE_STATE_GENERIC_READ :
        heap.Type == D3D12_HEAP_TYPE_READBACK ? D3D12_RESOURCE_STATE_COPY_DEST : D3D12_RESOURCE_STATE_COMMON;
    auto buffer = (ZenitD12Buffer *)calloc(1, sizeof(ZenitD12Buffer));
    if (!buffer) return 2;
    HRESULT hr = device->raw->CreateCommittedResource(&heap, D3D12_HEAP_FLAG_NONE, &desc, state,
        nullptr, IID_ID3D12Resource, (void **)&buffer->raw);
    if (SUCCEEDED(hr) && heap.Type != D3D12_HEAP_TYPE_DEFAULT) {
        const D3D12_RANGE read_range = {0, heap.Type == D3D12_HEAP_TYPE_READBACK ? (SIZE_T)size : 0};
        hr = buffer->raw->Map(0, &read_range, &buffer->mapping);
    }
    if (FAILED(hr)) { if (buffer->raw) buffer->raw->Release(); free(buffer); return 2; }
    InterlockedIncrement(&device->refs);
    buffer->owner = device; buffer->refs = 1; buffer->size = size; buffer->usage = usage;
    if (d12_ledger_enabled()) {
        buffer->ledger_kind = heap.Type == D3D12_HEAP_TYPE_UPLOAD ? LK_BUF_UPLOAD : heap.Type == D3D12_HEAP_TYPE_READBACK ? LK_BUF_READBACK : LK_BUF_DEFAULT;
        buffer->ledger_bytes = d12_ledger_allocation_bytes(device->raw, desc);
        d12_ledger_add(buffer, buffer->ledger_kind, buffer->ledger_bytes, (uint32_t)size, 1, 0);
    }
    *out = buffer;
    return 0;
}
extern "C" void zenit_d12_buffer_retain(ZenitD12Buffer *buffer) { if (buffer) InterlockedIncrement(&buffer->refs); }
extern "C" void zenit_d12_buffer_release(ZenitD12Buffer *buffer) {
    if (!buffer || InterlockedDecrement(&buffer->refs) != 0) return;
    // Recorded and submitted commands retain buffers until their GPU use ends.
    d12_ledger_remove(buffer, buffer->ledger_kind, buffer->ledger_bytes);
    if (buffer->mapping) buffer->raw->Unmap(0, nullptr);
    buffer->raw->Release(); zenit_d12_device_release(buffer->owner); free(buffer);
}

struct D12RenderRefs;
struct D12DrawRefs;
static void release_render(D12RenderRefs *);
static void release_draw(D12DrawRefs *);
struct D12DispatchRefs;
static void release_dispatch(D12DispatchRefs *);
struct D12CopyRefs { D12RenderRefs *render; D12DrawRefs *draw; D12DispatchRefs *dispatch; ZenitD12Buffer *source, *destination; ZenitD12Texture *texture, *other_texture; D12CopyRefs *next; };
// Append-only shader-visible pages belong to the command list. Draw tables
// retain their page; no descriptor range is rewritten while GPU work is live.
struct D12DescriptorPage {
    ID3D12DescriptorHeap *heap; uint32_t used, capacity;
    D12DescriptorPage *next;
};
static constexpr uint32_t MAX_PROFILE_DRAWS = 512;
#ifdef ZENIT_D12_TEST
static bool test_draw_profile;
extern "C" void zenit_d12_test_draw_profile(int enabled) { test_draw_profile = enabled != 0; }
#endif
struct D12DrawTiming { char shader[96]; uint32_t width, height, vertices, instances; };
struct ZenitD12Commands {
    ID3D12CommandAllocator *allocator;
    ID3D12GraphicsCommandList *list;
    ZenitD12Device *owner;
    D12CopyRefs *resources;
    D12DescriptorPage *descriptor_pages[2];
    ID3D12QueryHeap *timestamp_heap;
    ZenitD12Buffer *timestamp_readback;
    ID3D12Fence *timestamp_fence;
    uint64_t timestamp_serial, timestamp_frequency;
    uint64_t calibration_gpu, calibration_cpu, submit_cpu, cpu_frequency;
    D12DrawTiming *draw_timings;
    uint32_t timed_draws, dropped_draws;
    bool timings_reported;
    LONG refs;
    bool closed, submitted;
    ZenitD12RenderPass *pass;
    // Objects direct draws reference, released with the command (after its
    // fence): one growing array instead of per-draw bind groups and nodes.
    void **retained; uint8_t *retained_kinds; uint32_t retained_count, retained_capacity;
    // Frame-pair timestamp objects handed over from the device pool, used by
    // enable_timestamps (released with the command if it never takes them).
    ID3D12QueryHeap *pooled_timestamps; ID3D12Resource *pooled_readback; void *pooled_mapping;
};
enum : uint8_t { RETAIN_BUFFER, RETAIN_VIEW, RETAIN_SAMPLER, RETAIN_PIPELINE };
struct D12Pending { ZenitD12Commands *commands; uint64_t serial; D12Pending *next; };
struct ZenitD12Queue {
    ID3D12CommandQueue *raw;
    ID3D12Fence *fence;
    HANDLE event;
    ZenitD12Device *owner;
    D12Pending *head, *tail;
    uint64_t last_serial;
    uint64_t timestamp_frequency;
    bool signal_failed;
#ifdef ZENIT_D12_TEST
    bool fail_next_signal;
#endif
};
static void release_retained(ZenitD12Commands *commands);
extern "C" void zenit_d12_commands_release(ZenitD12Commands *commands) {
    if (!commands || InterlockedDecrement(&commands->refs) != 0) return;
    // The last reference ends with the command's GPU use (the queue holds one
    // until its fence), so its allocator, list and readback may be reused.
    auto device=commands->owner;
    D12CommandPoolEntry entry={commands->allocator,commands->list};
    bool reusable=!FAILED(device->raw->GetDeviceRemovedReason()) && (commands->closed || SUCCEEDED(commands->list->Close()));
    // Only the frame pair (no per-draw profile) has the standard query layout.
    if (reusable && commands->timestamp_heap && !commands->draw_timings && commands->timestamp_readback->refs==1) {
        entry.timestamps=commands->timestamp_heap; commands->timestamp_heap=nullptr;
        entry.readback=commands->timestamp_readback->raw; entry.mapping=commands->timestamp_readback->mapping;
        // The raw readback moves to the command pool (bounded by its capacity);
        // its ledger entry ends with this wrapper.
        d12_ledger_remove(commands->timestamp_readback, commands->timestamp_readback->ledger_kind, commands->timestamp_readback->ledger_bytes);
        free(commands->timestamp_readback); commands->timestamp_readback=nullptr; zenit_d12_device_release(device);
    }
    if (reusable) {
        AcquireSRWLockExclusive(&device->pool_lock);
        if (device->command_pool_count<COMMAND_POOL_CAPACITY) { device->command_pool[device->command_pool_count++]=entry; entry={}; }
        ReleaseSRWLockExclusive(&device->pool_lock);
    }
    release_pool_entry(entry);
    if (commands->pooled_timestamps || commands->pooled_readback) {
        D12CommandPoolEntry unused={nullptr,nullptr,commands->pooled_timestamps,commands->pooled_readback,commands->pooled_mapping};
        release_pool_entry(unused);
    }
    if (commands->timestamp_heap) commands->timestamp_heap->Release();
    if (commands->timestamp_fence) commands->timestamp_fence->Release();
    zenit_d12_buffer_release(commands->timestamp_readback);
    free(commands->draw_timings);
    while (commands->resources) {
        auto node = commands->resources; commands->resources = node->next;
        zenit_d12_buffer_release(node->source); zenit_d12_buffer_release(node->destination);
        zenit_d12_texture_release(node->texture); zenit_d12_texture_release(node->other_texture); release_dispatch(node->dispatch); release_render(node->render); release_draw(node->draw); free(node);
    }
    for (uint32_t type=0;type<2;++type) for (auto page=commands->descriptor_pages[type];page;) {
        auto next=page->next; bool pooled=false;
        if (page->capacity==(type?256u:1024u) && !FAILED(device->raw->GetDeviceRemovedReason())) {
            AcquireSRWLockExclusive(&device->pool_lock);
            if (device->page_pool_count[type]<PAGE_POOL_CAPACITY) { device->page_pool[type][device->page_pool_count[type]++]=page->heap; pooled=true; }
            ReleaseSRWLockExclusive(&device->pool_lock);
        }
        if (!pooled) page->heap->Release();
        free(page); page=next;
    }
    release_retained(commands);
    zenit_d12_device_release(commands->owner); free(commands);
}
extern "C" int zenit_d12_commands_create(ZenitD12Device *device, ZenitD12Commands **out) {
    if (!out) return 1;
    *out = nullptr;
    if (!device) return 1;
    auto commands = (ZenitD12Commands *)calloc(1, sizeof(ZenitD12Commands));
    if (!commands) return 2;
    D12CommandPoolEntry pooled={};
    AcquireSRWLockExclusive(&device->pool_lock);
    if (device->command_pool_count) pooled=device->command_pool[--device->command_pool_count];
    ReleaseSRWLockExclusive(&device->pool_lock);
    if (pooled.allocator) {
        if (SUCCEEDED(pooled.allocator->Reset()) && SUCCEEDED(pooled.list->Reset(pooled.allocator,nullptr))) {
            commands->allocator=pooled.allocator; commands->list=pooled.list;
            commands->pooled_timestamps=pooled.timestamps; commands->pooled_readback=pooled.readback; commands->pooled_mapping=pooled.mapping;
            commands->owner = device; commands->refs = 1;
            InterlockedIncrement(&device->refs); *out = commands; return 0;
        }
        release_pool_entry(pooled);
    }
    HRESULT hr = device->raw->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT,
        IID_ID3D12CommandAllocator, (void **)&commands->allocator);
    if (SUCCEEDED(hr)) hr = device->raw->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT,
        commands->allocator, nullptr, IID_ID3D12GraphicsCommandList, (void **)&commands->list);
    if (FAILED(hr)) {
        if (commands->list) commands->list->Release();
        if (commands->allocator) commands->allocator->Release();
        free(commands); return 2;
    }
    commands->owner = device; commands->refs = 1;
    InterlockedIncrement(&device->refs); *out = commands; return 0;
}
static void transition_buffer(ID3D12GraphicsCommandList *list, ZenitD12Buffer *buffer,
                              D3D12_RESOURCE_STATES before, D3D12_RESOURCE_STATES after) {
    // Upload/readback heap states are fixed for their lifetime.
    if (buffer->usage & (MAP_READ | MAP_WRITE)) return;
    D3D12_RESOURCE_BARRIER barrier = {};
    barrier.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    barrier.Transition.pResource = buffer->raw;
    barrier.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    barrier.Transition.StateBefore = before; barrier.Transition.StateAfter = after;
    list->ResourceBarrier(1, &barrier);
}
extern "C" int zenit_d12_commands_copy(ZenitD12Commands *commands, ZenitD12Buffer *source,
    uint64_t source_offset, ZenitD12Buffer *destination, uint64_t destination_offset, uint64_t bytes) {
    if (!commands || commands->closed || commands->submitted || commands->pass || !source || !destination || source == destination ||
        commands->owner != source->owner || commands->owner != destination->owner ||
        !(source->usage & 4u) || !(destination->usage & COPY_DST) || !bytes ||
        source_offset > source->size || bytes > source->size - source_offset ||
        destination_offset > destination->size || bytes > destination->size - destination_offset) return 1;
    auto refs = (D12CopyRefs *)calloc(1, sizeof(D12CopyRefs));
    if (!refs) return 2;
    refs->source = source; refs->destination = destination;
    InterlockedIncrement(&source->refs); InterlockedIncrement(&destination->refs);
    refs->next = commands->resources; commands->resources = refs;
    // Keep default buffers at COMMON between operations. This makes recorded
    // copy command lists independent of record/submit order, without guessed
    // global state. Render/compute state tracking will extend this later.
    transition_buffer(commands->list, source, D3D12_RESOURCE_STATE_COMMON, D3D12_RESOURCE_STATE_COPY_SOURCE);
    transition_buffer(commands->list, destination, D3D12_RESOURCE_STATE_COMMON, D3D12_RESOURCE_STATE_COPY_DEST);
    commands->list->CopyBufferRegion(destination->raw, destination_offset, source->raw, source_offset, bytes);
    transition_buffer(commands->list, source, D3D12_RESOURCE_STATE_COPY_SOURCE, D3D12_RESOURCE_STATE_COMMON);
    transition_buffer(commands->list, destination, D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_COMMON);
    return 0;
}
extern "C" int zenit_d12_commands_enable_timestamps(ZenitD12Commands *commands) {
    if (!commands || commands->closed || commands->submitted || commands->pass || commands->timestamp_heap) return 1;
    D3D12_QUERY_HEAP_DESC desc = {};
    desc.Type = D3D12_QUERY_HEAP_TYPE_TIMESTAMP; desc.Count = 2;
    // Explicit diagnostic mode only. Per-draw queries serialize pipeline work
    // and can perturb throughput; normal builds retain only the frame pair.
    char enabled[8] = {};
    bool profile = GetEnvironmentVariableA("ZENIT_WINDOWS_FRAME_TIMING", enabled, sizeof(enabled)) && enabled[0]=='1';
#ifdef ZENIT_D12_TEST
    profile = profile || test_draw_profile;
#endif
    if (profile) {
        commands->draw_timings = (D12DrawTiming *)calloc(MAX_PROFILE_DRAWS, sizeof(D12DrawTiming));
        if (commands->draw_timings) desc.Count += MAX_PROFILE_DRAWS * 2;
    }
    if (!commands->draw_timings && commands->pooled_timestamps && commands->pooled_readback) {
        auto readback=(ZenitD12Buffer *)calloc(1,sizeof(ZenitD12Buffer));
        if (readback) {
            readback->raw=commands->pooled_readback; readback->mapping=commands->pooled_mapping; readback->owner=commands->owner;
            readback->refs=1; readback->size=uint64_t(desc.Count)*8; readback->usage=MAP_READ | COPY_DST;
            InterlockedIncrement(&commands->owner->refs);
            commands->timestamp_heap=commands->pooled_timestamps; commands->timestamp_readback=readback;
            commands->pooled_timestamps=nullptr; commands->pooled_readback=nullptr; commands->pooled_mapping=nullptr;
            commands->list->EndQuery(commands->timestamp_heap, D3D12_QUERY_TYPE_TIMESTAMP, 0);
            return 0;
        }
    }
    ID3D12QueryHeap *heap = nullptr;
    if (FAILED(commands->owner->raw->CreateQueryHeap(&desc, IID_ID3D12QueryHeap, (void **)&heap))) {
        free(commands->draw_timings); commands->draw_timings=nullptr; return 2;
    }
    ZenitD12Buffer *readback = nullptr;
    int status = zenit_d12_buffer_create(commands->owner, uint64_t(desc.Count)*8, MAP_READ | COPY_DST, &readback);
    if (status) { heap->Release(); free(commands->draw_timings); commands->draw_timings=nullptr; return status; }
    commands->timestamp_heap = heap; commands->timestamp_readback = readback;
    commands->list->EndQuery(heap, D3D12_QUERY_TYPE_TIMESTAMP, 0);
    return 0;
}
// Never wait, submit a transfer, or touch an uncompleted readback. The command
// owns its fence reference, so results remain readable after queue destruction.
extern "C" int zenit_d12_commands_elapsed_micros(ZenitD12Commands *commands, uint64_t *micros) {
    if (!micros) return 1;
    *micros = 0;
    if (!commands || !commands->submitted || !commands->timestamp_fence || !commands->timestamp_frequency) return 3;
    uint64_t completed = commands->timestamp_fence->GetCompletedValue();
    if (completed == UINT64_MAX || FAILED(commands->owner->raw->GetDeviceRemovedReason())) return 4;
    if (completed < commands->timestamp_serial) return 3;
    uint64_t ticks[2];
    memcpy(ticks, commands->timestamp_readback->mapping, sizeof(ticks));
    if (ticks[1] < ticks[0]) return 2;
    double elapsed = double(ticks[1] - ticks[0]) * 1000000.0 / double(commands->timestamp_frequency);
    if (elapsed >= double(UINT64_MAX)) return 2;
    *micros = uint64_t(elapsed);
    if (commands->draw_timings && !commands->timings_reported) {
        commands->timings_reported = true;
        if (commands->cpu_frequency && commands->timestamp_frequency) {
            // GetClockCalibration pairs GPU ticks with QPC ticks. Only the
            // signed relative differences are converted; absolute counters
            // need not share an epoch or frequency.
            double start_after_submit=(double(int64_t(ticks[0]-commands->calibration_gpu))/double(commands->timestamp_frequency)
                +double(int64_t(commands->calibration_cpu-commands->submit_cpu))/double(commands->cpu_frequency))*1e6;
            fprintf(stderr,"[d3d12-submit-timing] serial=%llu gpu_start_after_submit_us=%.3f\n",(unsigned long long)commands->timestamp_serial,start_after_submit);
        }
        fprintf(stderr,"[d3d12-frame-timing] serial=%llu us=%llu draws=%u dropped=%u\n",
            (unsigned long long)commands->timestamp_serial,(unsigned long long)*micros,commands->timed_draws,commands->dropped_draws);
        for (uint32_t i=0;i<commands->timed_draws;++i) {
            memcpy(ticks, (const uint8_t *)commands->timestamp_readback->mapping+(2+i*2)*8, sizeof(ticks));
            auto &d=commands->draw_timings[i];
            // Invalid samples are explicit, never represented as successful 0.
            double us=ticks[1]>=ticks[0]?double(ticks[1]-ticks[0])*1000000.0/double(commands->timestamp_frequency):-1.0;
            fprintf(stderr,"[d3d12-draw-timing] serial=%llu draw=%u shader=%s target=%ux%u vertices=%u instances=%u us=%.3f\n",
                (unsigned long long)commands->timestamp_serial,i,d.shader,d.width,d.height,d.vertices,d.instances,us);
        }
    }
    return 0;
}
#ifdef ZENIT_D12_TEST
extern "C" int zenit_d12_test_check_draw_profile(ZenitD12Commands *commands) {
    uint64_t elapsed;
    if (zenit_d12_commands_elapsed_micros(commands,&elapsed) || commands->timed_draws!=512 || commands->dropped_draws!=2) return 1;
    auto ticks=(const uint64_t *)commands->timestamp_readback->mapping;
    for (uint32_t i=0;i<commands->timed_draws;++i) {
        auto &d=commands->draw_timings[i];
        if (strcmp(d.shader,"fragment") || d.width!=8 || d.height!=4 || d.vertices!=6 || d.instances!=(i==0?2u:1u)) return 2;
        if (ticks[2+i*2]<ticks[0] || ticks[3+i*2]<ticks[2+i*2] || ticks[3+i*2]>ticks[1]) return 3;
    }
    return 0;
}
#endif
extern "C" int zenit_d12_commands_finish(ZenitD12Commands *commands) {
    if (!commands || commands->closed || commands->submitted || commands->pass) return 1;
    if (commands->timestamp_heap) {
        commands->list->EndQuery(commands->timestamp_heap, D3D12_QUERY_TYPE_TIMESTAMP, 1);
        commands->list->ResolveQueryData(commands->timestamp_heap, D3D12_QUERY_TYPE_TIMESTAMP, 0, 2+commands->timed_draws*2, commands->timestamp_readback->raw, 0);
    }
    if (FAILED(commands->list->Close())) return 2;
    commands->closed = true; return 0;
}
extern "C" int zenit_d12_queue_create(ZenitD12Device *device, ZenitD12Queue **out) {
    if (!out) return 1;
    *out = nullptr;
    if (!device) return 1;
    auto queue = (ZenitD12Queue *)calloc(1, sizeof(ZenitD12Queue));
    if (!queue) return 2;
    D3D12_COMMAND_QUEUE_DESC desc = {};
    HRESULT hr = device->raw->CreateCommandQueue(&desc, IID_ID3D12CommandQueue, (void **)&queue->raw);
    if (SUCCEEDED(hr)) hr = device->raw->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_ID3D12Fence, (void **)&queue->fence);
    if (SUCCEEDED(hr)) queue->event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    if (FAILED(hr) || !queue->event) {
        if (queue->raw) queue->raw->Release();
        if (queue->fence) queue->fence->Release();
        free(queue); return 2;
    }
    // Unsupported timing must not prevent rendering.
    if (FAILED(queue->raw->GetTimestampFrequency(&queue->timestamp_frequency))) queue->timestamp_frequency = 0;
    queue->owner = device; InterlockedIncrement(&device->refs); *out = queue; return 0;
}
extern "C" int zenit_d12_queue_collect(ZenitD12Queue *queue) {
    if (!queue) return 1;
    uint64_t completed = queue->fence->GetCompletedValue();
    bool removed = completed == UINT64_MAX || FAILED(queue->owner->raw->GetDeviceRemovedReason());
    while (queue->head && (removed || queue->head->serial <= completed)) {
        auto node = queue->head; queue->head = node->next;
        zenit_d12_commands_release(node->commands); free(node);
    }
    if (!queue->head) queue->tail = nullptr;
    return removed ? 4 : 0;
}
extern "C" int zenit_d12_queue_submit(ZenitD12Queue *queue, ZenitD12Commands *commands, uint64_t *serial) {
    if (!serial) return 1;
    *serial = 0;
    if (!queue || !commands || commands->owner != queue->owner || !commands->closed || commands->submitted || commands->pass ||
        queue->signal_failed || queue->last_serial >= UINT64_MAX - 1) return 1;
    int status = zenit_d12_queue_collect(queue);
    if (status) return status;
    auto node = (D12Pending *)calloc(1, sizeof(D12Pending));
    if (!node) return 2;
    node->commands = commands; node->serial = ++queue->last_serial;
    InterlockedIncrement(&commands->refs); commands->submitted = true;
    if (queue->tail) queue->tail->next = node; else queue->head = node;
    queue->tail = node;
    if (commands->timestamp_heap) {
        commands->timestamp_fence = queue->fence; queue->fence->AddRef();
        commands->timestamp_serial = node->serial;
        commands->timestamp_frequency = queue->timestamp_frequency;
    }
    if (commands->draw_timings) {
        LARGE_INTEGER frequency, now;
        if (SUCCEEDED(queue->raw->GetClockCalibration(&commands->calibration_gpu,&commands->calibration_cpu)) && QueryPerformanceFrequency(&frequency)) {
            commands->cpu_frequency=frequency.QuadPart;
            QueryPerformanceCounter(&now); commands->submit_cpu=now.QuadPart;
        }
    }
    ID3D12CommandList *lists[] = { commands->list };
    queue->raw->ExecuteCommandLists(1, lists);
    // Even a failed Signal leaves GPU work and owned references in-flight.
#ifdef ZENIT_D12_TEST
    if (queue->fail_next_signal) {
        queue->fail_next_signal = false; queue->signal_failed = true;
    } else
#endif
    queue->signal_failed = FAILED(queue->raw->Signal(queue->fence, node->serial));
    *serial = node->serial;
    return queue->signal_failed ? 2 : 0;
}
// Diagnostic-only wall-clock attribution; never used as a GPU timestamp sample.
struct D12WaitProfile {
    ZenitD12Queue *queue; uint64_t serial, completed_before=0;
    bool enabled=false; LARGE_INTEGER started={}, frequency={};
    double collect_us=0, event_us=0;
    D12WaitProfile(ZenitD12Queue *q,uint64_t target,uint32_t timeout):queue(q),serial(target) {
        char value[8]={};
        enabled=q && timeout && GetEnvironmentVariableA("ZENIT_WINDOWS_FRAME_TIMING",value,sizeof(value)) && value[0]=='1';
        if (enabled) { QueryPerformanceFrequency(&frequency); QueryPerformanceCounter(&started); completed_before=q->fence->GetCompletedValue(); }
    }
    double now() { LARGE_INTEGER t; QueryPerformanceCounter(&t); return double(t.QuadPart-started.QuadPart)*1e6/double(frequency.QuadPart); }
    ~D12WaitProfile() {
        if (!enabled) return;
        double total=now();
        if (total>=1000) fprintf(stderr,"[d3d12-wait-timing] serial=%llu completed_before=%llu last_serial=%llu total_us=%.3f collect_us=%.3f event_us=%.3f\n",
            (unsigned long long)serial,(unsigned long long)completed_before,(unsigned long long)queue->last_serial,total,collect_us,event_us);
    }
};
extern "C" int zenit_d12_queue_wait(ZenitD12Queue *queue, uint64_t serial, uint32_t timeout_ms) {
    D12WaitProfile profile(queue,serial,timeout_ms);
    if (!queue || serial > queue->last_serial || timeout_ms == INFINITE) return 1;
    double phase=profile.enabled?profile.now():0;
    int status = zenit_d12_queue_collect(queue);
    if (profile.enabled) profile.collect_us+=profile.now()-phase;
    if (status) return status;
    if (queue->signal_failed) {
        if (FAILED(queue->raw->Signal(queue->fence, queue->last_serial))) return 2;
        queue->signal_failed = false;
    }
    ULONGLONG deadline = GetTickCount64() + timeout_ms;
    for (;;) {
        uint64_t completed = queue->fence->GetCompletedValue();
        if (completed == UINT64_MAX || FAILED(queue->owner->raw->GetDeviceRemovedReason())) {
            zenit_d12_queue_collect(queue); return 4;
        }
        if (completed >= serial) {
            phase=profile.enabled?profile.now():0;
            int collected=zenit_d12_queue_collect(queue);
            if (profile.enabled) profile.collect_us+=profile.now()-phase;
            return collected;
        }
        ULONGLONG now = GetTickCount64();
        if (now >= deadline) return 3;
        if (FAILED(queue->fence->SetEventOnCompletion(serial, queue->event))) return 2;
        phase=profile.enabled?profile.now():0;
        DWORD result = WaitForSingleObject(queue->event, (DWORD)(deadline - now));
        if (profile.enabled) profile.event_us+=profile.now()-phase;
        if (result == WAIT_TIMEOUT) return 3;
        if (result != WAIT_OBJECT_0) return 2;
        // A previous timed-out wait may wake this event for an earlier serial.
        // Always inspect the fence before releasing retained resources.
    }
}
extern "C" int zenit_d12_queue_destroy(ZenitD12Queue *queue, uint32_t timeout_ms) {
    if (!queue) return 1;
    int status = zenit_d12_queue_wait(queue, queue->last_serial, timeout_ms);
    if (status && status != 4) return status; // Keep ownership and pending resources for retry.
    CloseHandle(queue->event); queue->fence->Release(); queue->raw->Release();
    zenit_d12_device_release(queue->owner); free(queue); return 0;
}

extern "C" void *zenit_d12_queue_native(ZenitD12Queue *queue) { return queue->raw; }

#ifdef ZENIT_D12_TEST
// Test-only fault: execute real commands but make the next fence Signal fail.
extern "C" void zenit_d12_test_fail_next_signal(ZenitD12Queue *queue) { queue->fail_next_signal = true; }
#endif

static bool depth_format(DXGI_FORMAT f) {
    return f==DXGI_FORMAT_D16_UNORM || f==DXGI_FORMAT_D32_FLOAT || f==DXGI_FORMAT_D24_UNORM_S8_UINT || f==DXGI_FORMAT_D32_FLOAT_S8X24_UINT;
}
static uint32_t depth_planes(DXGI_FORMAT f) { return f==DXGI_FORMAT_D24_UNORM_S8_UINT || f==DXGI_FORMAT_D32_FLOAT_S8X24_UINT?2:1; }
static DXGI_FORMAT depth_resource_format(DXGI_FORMAT f) {
    switch (f) { case DXGI_FORMAT_D16_UNORM:return DXGI_FORMAT_R16_TYPELESS; case DXGI_FORMAT_D32_FLOAT:return DXGI_FORMAT_R32_TYPELESS;
        case DXGI_FORMAT_D24_UNORM_S8_UINT:return DXGI_FORMAT_R24G8_TYPELESS; case DXGI_FORMAT_D32_FLOAT_S8X24_UINT:return DXGI_FORMAT_R32G8X24_TYPELESS; default:return f; }
}
static DXGI_FORMAT depth_srv_format(DXGI_FORMAT f) {
    switch (f) { case DXGI_FORMAT_D16_UNORM:return DXGI_FORMAT_R16_UNORM; case DXGI_FORMAT_D32_FLOAT:return DXGI_FORMAT_R32_FLOAT;
        case DXGI_FORMAT_D24_UNORM_S8_UINT:return DXGI_FORMAT_R24_UNORM_X8_TYPELESS; case DXGI_FORMAT_D32_FLOAT_S8X24_UINT:return DXGI_FORMAT_R32_FLOAT_X8X24_TYPELESS; default:return f; }
}
static uint32_t color_pixel_bytes(DXGI_FORMAT format) {
    switch (format) {
    case DXGI_FORMAT_R8_UNORM: case DXGI_FORMAT_R8_SNORM: case DXGI_FORMAT_R8_UINT: case DXGI_FORMAT_R8_SINT: return 1;
    case DXGI_FORMAT_R16_UINT: case DXGI_FORMAT_R16_SINT: case DXGI_FORMAT_R16_FLOAT:
    case DXGI_FORMAT_R8G8_UNORM: case DXGI_FORMAT_R8G8_SNORM: case DXGI_FORMAT_R8G8_UINT: case DXGI_FORMAT_R8G8_SINT: return 2;
    case DXGI_FORMAT_R32_UINT: case DXGI_FORMAT_R32_SINT: case DXGI_FORMAT_R32_FLOAT:
    case DXGI_FORMAT_R16G16_UINT: case DXGI_FORMAT_R16G16_SINT: case DXGI_FORMAT_R16G16_FLOAT:
    case DXGI_FORMAT_R8G8B8A8_UNORM: case DXGI_FORMAT_R8G8B8A8_UNORM_SRGB: case DXGI_FORMAT_R8G8B8A8_SNORM:
    case DXGI_FORMAT_R8G8B8A8_UINT: case DXGI_FORMAT_R8G8B8A8_SINT:
    case DXGI_FORMAT_B8G8R8A8_UNORM: case DXGI_FORMAT_B8G8R8A8_UNORM_SRGB: case DXGI_FORMAT_R10G10B10A2_UNORM: return 4;
    case DXGI_FORMAT_R32G32_UINT: case DXGI_FORMAT_R32G32_SINT: case DXGI_FORMAT_R32G32_FLOAT:
    case DXGI_FORMAT_R16G16B16A16_UINT: case DXGI_FORMAT_R16G16B16A16_SINT: case DXGI_FORMAT_R16G16B16A16_FLOAT: return 8;
    case DXGI_FORMAT_R32G32B32A32_UINT: case DXGI_FORMAT_R32G32B32A32_SINT: case DXGI_FORMAT_R32G32B32A32_FLOAT: return 16;
    default: return 0;
    }
}
extern "C" int zenit_d12_sample_supported(ZenitD12Device *device,uint32_t format,uint32_t samples) {
    if (!device || !samples || samples>32 || (samples & (samples-1))) return 0;
    D3D12_FEATURE_DATA_MULTISAMPLE_QUALITY_LEVELS q={}; q.Format=(DXGI_FORMAT)format; q.SampleCount=samples;
    return SUCCEEDED(device->raw->CheckFeatureSupport(D3D12_FEATURE_MULTISAMPLE_QUALITY_LEVELS,&q,sizeof(q))) && q.NumQualityLevels;
}
extern "C" int zenit_d12_texture_create(ZenitD12Device *device, uint32_t dimension, uint32_t width,
    uint32_t height, uint32_t depth, uint32_t mips, uint32_t format, uint32_t usage, uint32_t samples, ZenitD12Texture **out) {
    if (!out) return 1;
    *out = nullptr;
    if (!device || dimension < 1 || dimension > 3 || !width || !height || !depth || !mips ||
        (!color_pixel_bytes((DXGI_FORMAT)format) && !depth_format((DXGI_FORMAT)format)) || !usage || (usage & ~31u) ||
        width > 16384 || height > 16384 || depth > 2048 || (dimension == 1 && height != 1) ||
        (dimension == 3 && (width > 2048 || height > 2048))) return 1;
    if (samples!=1 && !zenit_d12_sample_supported(device,format,samples)) return 1;
    if (samples>1 && (dimension!=2 || mips!=1 || !(usage & 16u) || (usage & 14u))) return 1;
    const bool ds=depth_format((DXGI_FORMAT)format);
    if (ds && (dimension!=2 || !(usage & 16u) || (usage & ~20u))) return 1; // Depth copy/storage and MSAA sampling remain unsupported.
    if (usage & 8u) {
        D3D12_FEATURE_DATA_FORMAT_SUPPORT support={}; support.Format=(DXGI_FORMAT)format;
        if (FAILED(device->raw->CheckFeatureSupport(D3D12_FEATURE_FORMAT_SUPPORT,&support,sizeof(support))) ||
            !(support.Support1 & D3D12_FORMAT_SUPPORT1_TYPED_UNORDERED_ACCESS_VIEW) ||
            !(support.Support2 & D3D12_FORMAT_SUPPORT2_UAV_TYPED_STORE)) return 1;
    }
    if (usage & 16u) {
        D3D12_FEATURE_DATA_FORMAT_SUPPORT support={}; support.Format=(DXGI_FORMAT)format;
        if (FAILED(device->raw->CheckFeatureSupport(D3D12_FEATURE_FORMAT_SUPPORT,&support,sizeof(support))) ||
            !(support.Support1 & (ds?D3D12_FORMAT_SUPPORT1_DEPTH_STENCIL:D3D12_FORMAT_SUPPORT1_RENDER_TARGET))) return 1;
    }
    uint32_t largest = width > height ? width : height;
    if (dimension == 3 && depth > largest) largest = depth;
    uint32_t max_mips = 1;
    while (largest >>= 1) ++max_mips;
    if (mips > max_mips) return 1;
    D3D12_HEAP_PROPERTIES heap = {}; heap.Type = D3D12_HEAP_TYPE_DEFAULT;
    heap.CreationNodeMask = heap.VisibleNodeMask = 1;
    D3D12_RESOURCE_DESC desc = {};
    desc.Dimension = dimension == 1 ? D3D12_RESOURCE_DIMENSION_TEXTURE1D :
        dimension == 2 ? D3D12_RESOURCE_DIMENSION_TEXTURE2D : D3D12_RESOURCE_DIMENSION_TEXTURE3D;
    desc.Width = width; desc.Height = height; desc.DepthOrArraySize = (UINT16)depth;
    desc.MipLevels = (UINT16)mips; desc.Format = ds && (usage & 4u)?depth_resource_format((DXGI_FORMAT)format):(DXGI_FORMAT)format; desc.SampleDesc.Count = samples;
    if (usage & 8u) desc.Flags |= D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;
    if (usage & 16u) desc.Flags |= ds?D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL:D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
    if (ds && !(usage & 4u)) desc.Flags |= D3D12_RESOURCE_FLAG_DENY_SHADER_RESOURCE;
    auto texture = (ZenitD12Texture *)calloc(1, sizeof(ZenitD12Texture));
    if (!texture) return 2;
    HRESULT hr = device->raw->CreateCommittedResource(&heap, D3D12_HEAP_FLAG_NONE, &desc,
        D3D12_RESOURCE_STATE_COMMON, nullptr, IID_ID3D12Resource, (void **)&texture->raw);
    if (FAILED(hr)) { free(texture); return 2; }
    texture->owner = device; texture->refs = 1; texture->dimension = dimension;
    texture->width = width; texture->height = height; texture->depth = depth;
    texture->mips = mips; texture->samples = samples; texture->format = (DXGI_FORMAT)format; texture->usage = usage;
    if (d12_ledger_enabled()) {
        texture->ledger_kind = ds ? LK_TEX_DEPTH : (usage & 16u) ? LK_TEX_TARGET : LK_TEX_SAMPLED;
        texture->ledger_bytes = d12_ledger_allocation_bytes(device->raw, desc);
        d12_ledger_add(texture, texture->ledger_kind, texture->ledger_bytes, width, height, format);
    }
    InterlockedIncrement(&device->refs); *out = texture; return 0;
}
extern "C" void zenit_d12_texture_ledger_label(ZenitD12Texture *texture, const char *label, size_t len) { d12_ledger_label(texture, label, len); }
extern "C" void zenit_d12_buffer_ledger_label(ZenitD12Buffer *buffer, const char *label, size_t len) { d12_ledger_label(buffer, label, len); }
extern "C" void zenit_d12_texture_retain(ZenitD12Texture *texture) { if (texture) InterlockedIncrement(&texture->refs); }
extern "C" void zenit_d12_texture_release(ZenitD12Texture *texture) {
    if (!texture || InterlockedDecrement(&texture->refs) != 0) return;
    // No holder remains: each would still hold a texture reference.
    d12_ledger_remove(texture, texture->ledger_kind, texture->ledger_bytes);
    for (auto view:texture->cached_views) if (view) { view->heap->Release(); free(view); }
    if (texture->rtv_heap) texture->rtv_heap->Release();
    texture->raw->Release(); zenit_d12_device_release(texture->owner); free(texture);
}
#include "d3d12_surface_impl.h"
static bool texture_region_valid(ZenitD12Texture *texture, const ZenitD12TextureRegion *region) {
    if (!texture || !region || region->mip >= texture->mips || !region->width || !region->height || !region->depth) return false;
    uint32_t width = texture->width >> region->mip; if (!width) width = 1;
    uint32_t height = texture->height >> region->mip; if (!height) height = 1;
    uint32_t depth = texture->dimension == 3 ? texture->depth >> region->mip : 1; if (!depth) depth = 1;
    if (texture->dimension == 3 ? region->layer != 0 : region->layer >= texture->depth) return false;
    return region->x <= width && region->width <= width - region->x &&
        region->y <= height && region->height <= height - region->y &&
        region->z <= depth && region->depth <= depth - region->z;
}
extern "C" int zenit_d12_texture_layout(ZenitD12Texture *texture, const ZenitD12TextureRegion *region,
    uint64_t offset, ZenitD12TextureLayout *out) {
    if (!out) return 1;
    *out = {};
    if (!texture_region_valid(texture, region) || depth_format(texture->format) || texture->samples!=1 || offset % D3D12_TEXTURE_DATA_PLACEMENT_ALIGNMENT) return 1;
    D3D12_RESOURCE_DESC desc = {};
    desc.Dimension = texture->dimension == 3 ? D3D12_RESOURCE_DIMENSION_TEXTURE3D : D3D12_RESOURCE_DIMENSION_TEXTURE2D;
    desc.Width = region->width; desc.Height = region->height; desc.DepthOrArraySize = (UINT16)region->depth;
    desc.MipLevels = 1; desc.Format = texture->format; desc.SampleDesc.Count = 1;
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint = {};
    UINT rows = 0; UINT64 row_bytes = 0, total = 0;
    texture->owner->raw->GetCopyableFootprints(&desc, 0, 1, 0, &footprint, &rows, &row_bytes, &total);
    if (!row_bytes || total == UINT64_MAX || footprint.Footprint.RowPitch == 0 || rows != region->height) return 2;
    uint64_t span = uint64_t(footprint.Footprint.RowPitch) * (uint64_t(rows) * region->depth - 1) + row_bytes;
    if (offset > UINT64_MAX - span) return 1;
    out->offset = offset; out->row_bytes = row_bytes; out->required_bytes = offset + span;
    out->row_pitch = footprint.Footprint.RowPitch;
    out->width = region->width; out->height = region->height; out->depth = region->depth;
    return 0;
}
static void transition_texture(ID3D12GraphicsCommandList *list, ZenitD12Texture *texture,
    uint32_t subresource, D3D12_RESOURCE_STATES before, D3D12_RESOURCE_STATES after) {
    D3D12_RESOURCE_BARRIER barrier = {};
    barrier.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    barrier.Transition.pResource = texture->raw; barrier.Transition.Subresource = subresource;
    barrier.Transition.StateBefore = before; barrier.Transition.StateAfter = after;
    list->ResourceBarrier(1, &barrier);
}
extern "C" int zenit_d12_commands_texture_copy(ZenitD12Commands *commands, ZenitD12Buffer *buffer,
    uint64_t offset, uint32_t row_pitch, ZenitD12Texture *texture, const ZenitD12TextureRegion *region, int to_texture) {
    if (!commands || commands->closed || commands->submitted || commands->pass || !buffer || !texture ||
        commands->owner != buffer->owner || commands->owner != texture->owner ||
        (to_texture != 0 && to_texture != 1) || !(buffer->usage & (to_texture ? 4u : COPY_DST)) ||
        !(texture->usage & (to_texture ? 2u : 1u))) return 1;
    ZenitD12TextureLayout layout = {};
    int status = zenit_d12_texture_layout(texture, region, offset, &layout);
    if (status) return status;
    if (row_pitch < layout.row_bytes || row_pitch % D3D12_TEXTURE_DATA_PITCH_ALIGNMENT) return 1;
    uint64_t span = uint64_t(row_pitch) * (uint64_t(region->height) * region->depth - 1) + layout.row_bytes;
    if (offset > buffer->size || span > buffer->size - offset) return 1;
    auto refs = (D12CopyRefs *)calloc(1, sizeof(D12CopyRefs));
    if (!refs) return 2;
    if (to_texture) refs->source = buffer; else refs->destination = buffer;
    refs->texture = texture; refs->next = commands->resources; commands->resources = refs;
    InterlockedIncrement(&buffer->refs); InterlockedIncrement(&texture->refs);
    uint32_t subresource = region->mip + region->layer * texture->mips;
    D3D12_TEXTURE_COPY_LOCATION location = {}, pitched = {};
    location.pResource = texture->raw; location.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX; location.SubresourceIndex = subresource;
    pitched.pResource = buffer->raw; pitched.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
    pitched.PlacedFootprint.Offset = offset; pitched.PlacedFootprint.Footprint.Format = texture->format;
    pitched.PlacedFootprint.Footprint.Width = region->width; pitched.PlacedFootprint.Footprint.Height = region->height;
    pitched.PlacedFootprint.Footprint.Depth = region->depth; pitched.PlacedFootprint.Footprint.RowPitch = row_pitch;
    D3D12_RESOURCE_STATES texture_state = to_texture ? D3D12_RESOURCE_STATE_COPY_DEST : D3D12_RESOURCE_STATE_COPY_SOURCE;
    D3D12_RESOURCE_STATES buffer_state = to_texture ? D3D12_RESOURCE_STATE_COPY_SOURCE : D3D12_RESOURCE_STATE_COPY_DEST;
    transition_texture(commands->list, texture, subresource, D3D12_RESOURCE_STATE_COMMON, texture_state);
    transition_buffer(commands->list, buffer, D3D12_RESOURCE_STATE_COMMON, buffer_state);
    if (to_texture) {
        commands->list->CopyTextureRegion(&location, region->x, region->y, region->z, &pitched, nullptr);
    } else {
        D3D12_BOX box = {region->x, region->y, region->z, region->x + region->width, region->y + region->height, region->z + region->depth};
        commands->list->CopyTextureRegion(&pitched, 0, 0, 0, &location, &box);
    }
    transition_buffer(commands->list, buffer, buffer_state, D3D12_RESOURCE_STATE_COMMON);
    transition_texture(commands->list, texture, subresource, texture_state, D3D12_RESOURCE_STATE_COMMON);
    return 0;
}

// CopyTextureRegion preserves bytes between formats in the same DXGI type
// group. Render-target sRGB views and UNORM screenshot storage share a group.
static DXGI_FORMAT copy_format_group(DXGI_FORMAT format) {
    switch (format) {
    case DXGI_FORMAT_B8G8R8A8_UNORM_SRGB: return DXGI_FORMAT_B8G8R8A8_UNORM;
    case DXGI_FORMAT_R8G8B8A8_UNORM_SRGB: return DXGI_FORMAT_R8G8B8A8_UNORM;
    default: return format;
    }
}
extern "C" int zenit_d12_commands_texture_region_copy(ZenitD12Commands *commands,
    ZenitD12Texture *source, const ZenitD12TextureRegion *src,
    ZenitD12Texture *destination, const ZenitD12TextureRegion *dst) {
    if (!commands || commands->closed || commands->submitted || commands->pass ||
        !texture_region_valid(source,src) || !texture_region_valid(destination,dst) ||
        source->owner!=commands->owner || destination->owner!=commands->owner ||
        !(source->usage & 1u) || !(destination->usage & 2u) ||
        copy_format_group(source->format)!=copy_format_group(destination->format) || source->dimension!=destination->dimension ||
        source->samples!=1 || destination->samples!=1 || depth_format(source->format) ||
        src->width!=dst->width || src->height!=dst->height || src->depth!=dst->depth) return 1;
    uint32_t source_sub=src->mip+src->layer*source->mips;
    uint32_t destination_sub=dst->mip+dst->layer*destination->mips;
    if (source==destination && source_sub==destination_sub) return 1;
    auto refs=(D12CopyRefs *)calloc(1,sizeof(D12CopyRefs));
    if (!refs) return 2;
    refs->texture=source; refs->other_texture=destination;
    InterlockedIncrement(&source->refs); InterlockedIncrement(&destination->refs);
    refs->next=commands->resources; commands->resources=refs;
    D3D12_TEXTURE_COPY_LOCATION from={},to={};
    from.pResource=source->raw; from.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX; from.SubresourceIndex=source_sub;
    to.pResource=destination->raw; to.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX; to.SubresourceIndex=destination_sub;
    D3D12_BOX box={src->x,src->y,src->z,src->x+src->width,src->y+src->height,src->z+src->depth};
    transition_texture(commands->list,source,source_sub,D3D12_RESOURCE_STATE_COMMON,D3D12_RESOURCE_STATE_COPY_SOURCE);
    transition_texture(commands->list,destination,destination_sub,D3D12_RESOURCE_STATE_COMMON,D3D12_RESOURCE_STATE_COPY_DEST);
    commands->list->CopyTextureRegion(&to,dst->x,dst->y,dst->z,&from,&box);
    transition_texture(commands->list,source,source_sub,D3D12_RESOURCE_STATE_COPY_SOURCE,D3D12_RESOURCE_STATE_COMMON);
    transition_texture(commands->list,destination,destination_sub,D3D12_RESOURCE_STATE_COPY_DEST,D3D12_RESOURCE_STATE_COMMON);
    return 0;
}

struct ZenitD12Sampler { ID3D12DescriptorHeap *heap; ZenitD12Device *owner; LONG refs; uint32_t filter; };
extern "C" int zenit_d12_view_create(ZenitD12Texture *texture, uint32_t dimension, uint32_t base_mip,
    uint32_t mips, uint32_t base_layer, uint32_t layers, ZenitD12View **out) {
    if (!out) return 1;
    *out = nullptr;
    if (!texture || texture->samples!=1 || !(texture->usage & 4u) || !mips || base_mip >= texture->mips || mips > texture->mips - base_mip ||
        !layers || base_layer >= texture->depth || layers > texture->depth - base_layer) return 1;
    D3D12_SHADER_RESOURCE_VIEW_DESC desc = {};
    desc.Format = depth_srv_format(texture->format); desc.Shader4ComponentMapping = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
    switch (dimension) {
    case 1:
        if (texture->dimension != 1 || texture->depth != 1 || base_layer || layers != 1) return 1;
        desc.ViewDimension = D3D12_SRV_DIMENSION_TEXTURE1D;
        desc.Texture1D.MostDetailedMip = base_mip; desc.Texture1D.MipLevels = mips; break;
    case 2:
        if (texture->dimension != 2 || texture->depth != 1 || base_layer || layers != 1) return 1;
        desc.ViewDimension = D3D12_SRV_DIMENSION_TEXTURE2D;
        desc.Texture2D.MostDetailedMip = base_mip; desc.Texture2D.MipLevels = mips; break;
    case 3:
        if (texture->dimension != 2) return 1;
        desc.ViewDimension = D3D12_SRV_DIMENSION_TEXTURE2DARRAY;
        desc.Texture2DArray.MostDetailedMip = base_mip; desc.Texture2DArray.MipLevels = mips;
        desc.Texture2DArray.FirstArraySlice = base_layer; desc.Texture2DArray.ArraySize = layers; break;
    case 4:
        if (texture->dimension != 2 || texture->width != texture->height || base_layer || layers != 6) return 1;
        desc.ViewDimension = D3D12_SRV_DIMENSION_TEXTURECUBE;
        desc.TextureCube.MostDetailedMip = base_mip; desc.TextureCube.MipLevels = mips; break;
    case 5:
        if (texture->dimension != 2 || texture->width != texture->height || base_layer % 6 || layers % 6) return 1;
        desc.ViewDimension = D3D12_SRV_DIMENSION_TEXTURECUBEARRAY;
        desc.TextureCubeArray.MostDetailedMip = base_mip; desc.TextureCubeArray.MipLevels = mips;
        desc.TextureCubeArray.First2DArrayFace = base_layer; desc.TextureCubeArray.NumCubes = layers / 6; break;
    case 6:
        if (texture->dimension != 3 || base_layer || layers != 1) return 1;
        desc.ViewDimension = D3D12_SRV_DIMENSION_TEXTURE3D;
        desc.Texture3D.MostDetailedMip = base_mip; desc.Texture3D.MipLevels = mips; break;
    default: return 1;
    }
    // Renderers bind the same textures every frame; a full-range view of a
    // texture never changes, so it is created once instead of per draw.
    const bool full=base_mip==0 && mips==texture->mips && base_layer==0 && layers==texture->depth;
    if (full && texture->cached_views[dimension]) {
        auto view=texture->cached_views[dimension];
        InterlockedIncrement(&texture->refs); InterlockedIncrement(&view->refs); *out=view; return 0;
    }
    if (depth_format(texture->format)) {
        D3D12_FEATURE_DATA_FORMAT_SUPPORT cap={}; cap.Format=desc.Format;
        if (FAILED(texture->owner->raw->CheckFeatureSupport(D3D12_FEATURE_FORMAT_SUPPORT,&cap,sizeof(cap))) || !(cap.Support1 & D3D12_FORMAT_SUPPORT1_SHADER_LOAD)) return 1;
    }
    auto view = (ZenitD12View *)calloc(1, sizeof(ZenitD12View));
    if (!view) return 2;
    D3D12_DESCRIPTOR_HEAP_DESC heap = {}; heap.Type = D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV; heap.NumDescriptors = 1;
    HRESULT hr = texture->owner->raw->CreateDescriptorHeap(&heap, IID_ID3D12DescriptorHeap, (void **)&view->heap);
    if (FAILED(hr)) { free(view); return 2; }
    texture->owner->raw->CreateShaderResourceView(texture->raw, &desc, view->heap->GetCPUDescriptorHandleForHeapStart());
    view->refs = 1; view->dimension = dimension; view->texture = texture; InterlockedIncrement(&texture->refs);
    if (full) { view->cached=true; texture->cached_views[dimension]=view; }
    *out = view; return 0;
}
extern "C" int zenit_d12_storage_view_create(ZenitD12Texture *texture, uint32_t dimension,
    uint32_t mip, uint32_t layer, uint32_t layers, ZenitD12View **out) {
    if (!out) return 1; *out=nullptr;
    if (!texture || !(texture->usage & 8u) || mip>=texture->mips || !layers) return 1;
    D3D12_UNORDERED_ACCESS_VIEW_DESC d={}; d.Format=texture->format;
    switch (dimension) {
    case 1:
        if (texture->dimension!=1 || texture->depth!=1 || layer || layers!=1) return 1;
        d.ViewDimension=D3D12_UAV_DIMENSION_TEXTURE1D; d.Texture1D.MipSlice=mip; break;
    case 2:
        if (texture->dimension!=2 || texture->depth!=1 || layer || layers!=1) return 1;
        d.ViewDimension=D3D12_UAV_DIMENSION_TEXTURE2D; d.Texture2D.MipSlice=mip; break;
    case 3:
        if (texture->dimension!=2 || layer>=texture->depth || layers>texture->depth-layer) return 1;
        d.ViewDimension=D3D12_UAV_DIMENSION_TEXTURE2DARRAY; d.Texture2DArray.MipSlice=mip;
        d.Texture2DArray.FirstArraySlice=layer; d.Texture2DArray.ArraySize=layers; break;
    case 6:
        if (texture->dimension!=3 || layer || layers!=1) return 1;
        d.ViewDimension=D3D12_UAV_DIMENSION_TEXTURE3D; d.Texture3D.MipSlice=mip;
        d.Texture3D.WSize=texture->depth>>mip; if (!d.Texture3D.WSize) d.Texture3D.WSize=1; break;
    default: return 1;
    }
    auto v=(ZenitD12View *)calloc(1,sizeof(ZenitD12View)); if (!v) return 2;
    D3D12_DESCRIPTOR_HEAP_DESC h={}; h.Type=D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV; h.NumDescriptors=1;
    if (FAILED(texture->owner->raw->CreateDescriptorHeap(&h,IID_ID3D12DescriptorHeap,(void **)&v->heap))) { free(v); return 2; }
    texture->owner->raw->CreateUnorderedAccessView(texture->raw,nullptr,&d,v->heap->GetCPUDescriptorHandleForHeapStart());
    v->refs=1; v->texture=texture; v->dimension=dimension; v->storage=true;
    InterlockedIncrement(&texture->refs); *out=v; return 0;
}
extern "C" int zenit_d12_view_is_storage(ZenitD12View *v) { return v->storage; }
// Format support never changes for a device; query it once per texture.
static bool texture_samplable(ZenitD12Texture *t) {
    if (!t->sample_support) {
        D3D12_FEATURE_DATA_FORMAT_SUPPORT support={}; support.Format=depth_srv_format(t->format);
        t->sample_support=SUCCEEDED(t->owner->raw->CheckFeatureSupport(D3D12_FEATURE_FORMAT_SUPPORT,&support,sizeof(support))) &&
            (support.Support1 & D3D12_FORMAT_SUPPORT1_SHADER_SAMPLE)?1:2;
    }
    return t->sample_support==1;
}
static void view_retain(ZenitD12View *view) {
    InterlockedIncrement(&view->refs);
    if (view->cached) InterlockedIncrement(&view->texture->refs);
}
extern "C" void zenit_d12_view_release(ZenitD12View *view) {
    if (!view) return;
    // A cached view's holder releases its texture reference; the texture
    // frees the view with itself.
    if (view->cached) { InterlockedDecrement(&view->refs); zenit_d12_texture_release(view->texture); return; }
    if (InterlockedDecrement(&view->refs)!=0) return;
    view->heap->Release(); zenit_d12_texture_release(view->texture); free(view);
}
extern "C" int zenit_d12_sampler_create(ZenitD12Device *device, uint32_t filter, uint32_t address_u,
    uint32_t address_v, uint32_t address_w, float min_lod, float max_lod,
    uint32_t anisotropy, uint32_t comparison, ZenitD12Sampler **out) {
    if (!out) return 1;
    *out = nullptr;
    bool anisotropic = (filter & ~0x80u) == 0x55u;
    if (!device || (!anisotropic && (filter & ~0x95u)) ||
        address_u < 1 || address_u > 4 || address_v < 1 || address_v > 4 || address_w < 1 || address_w > 4 ||
        !(min_lod >= 0 && max_lod >= min_lod && max_lod <= FLT_MAX) ||
        !anisotropy || anisotropy > 16 || (!anisotropic && anisotropy != 1) || comparison < 1 || comparison > 8) return 1;
    auto sampler = (ZenitD12Sampler *)calloc(1, sizeof(ZenitD12Sampler));
    if (!sampler) return 2;
    D3D12_DESCRIPTOR_HEAP_DESC heap = {}; heap.Type = D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER; heap.NumDescriptors = 1;
    HRESULT hr = device->raw->CreateDescriptorHeap(&heap, IID_ID3D12DescriptorHeap, (void **)&sampler->heap);
    if (FAILED(hr)) { free(sampler); return 2; }
    D3D12_SAMPLER_DESC desc = {};
    desc.Filter = (D3D12_FILTER)filter; desc.AddressU = (D3D12_TEXTURE_ADDRESS_MODE)address_u;
    desc.AddressV = (D3D12_TEXTURE_ADDRESS_MODE)address_v; desc.AddressW = (D3D12_TEXTURE_ADDRESS_MODE)address_w;
    desc.MinLOD = min_lod; desc.MaxLOD = max_lod; desc.MaxAnisotropy = anisotropy; desc.ComparisonFunc = (D3D12_COMPARISON_FUNC)comparison;
    device->raw->CreateSampler(&desc, sampler->heap->GetCPUDescriptorHandleForHeapStart());
    sampler->refs = 1; sampler->filter = filter; sampler->owner = device; InterlockedIncrement(&device->refs); *out = sampler; return 0;
}
extern "C" void zenit_d12_sampler_retain(ZenitD12Sampler *sampler) { if (sampler) InterlockedIncrement(&sampler->refs); }
extern "C" void zenit_d12_sampler_release(ZenitD12Sampler *sampler) {
    if (!sampler || InterlockedDecrement(&sampler->refs)!=0) return;
    sampler->heap->Release(); zenit_d12_device_release(sampler->owner); free(sampler);
}
extern "C" void *zenit_d12_view_heap(ZenitD12View *view) { return view->heap; }
extern "C" void *zenit_d12_view_texture(ZenitD12View *view) { return view->texture->raw; }
extern "C" void *zenit_d12_sampler_heap(ZenitD12Sampler *sampler) { return sampler->heap; }

extern "C" void zenit_d12_device_retain(ZenitD12Device *device) { InterlockedIncrement(&device->refs); }

// Sample classes use the shared binding classes: float=1, sint=4, uint=5.
extern "C" uint32_t zenit_d12_view_dimension(ZenitD12View *v) { return v->dimension; }
extern "C" uint32_t zenit_d12_view_sample_type(ZenitD12View *v) {
    if (depth_format(v->texture->format)) return 3;
    switch (v->texture->format) {
    case DXGI_FORMAT_R8_UINT: case DXGI_FORMAT_R16_UINT: case DXGI_FORMAT_R32_UINT:
    case DXGI_FORMAT_R8G8_UINT: case DXGI_FORMAT_R16G16_UINT: case DXGI_FORMAT_R32G32_UINT:
    case DXGI_FORMAT_R8G8B8A8_UINT: case DXGI_FORMAT_R16G16B16A16_UINT: case DXGI_FORMAT_R32G32B32A32_UINT: return 5;
    case DXGI_FORMAT_R8_SINT: case DXGI_FORMAT_R16_SINT: case DXGI_FORMAT_R32_SINT:
    case DXGI_FORMAT_R8G8_SINT: case DXGI_FORMAT_R16G16_SINT: case DXGI_FORMAT_R32G32_SINT:
    case DXGI_FORMAT_R8G8B8A8_SINT: case DXGI_FORMAT_R16G16B16A16_SINT: case DXGI_FORMAT_R32G32B32A32_SINT: return 4;
    default: return 1;
    }
}
extern "C" int zenit_d12_sampler_comparison(ZenitD12Sampler *s) { return (s->filter & 0x80u)!=0; }

// Immutable CPU descriptors. Recorded dispatches and draws copy them into
// owned GPU heaps, so later binding changes cannot alter recorded operations.
struct ZenitD12BindGroup {
    ZenitD12PipelineLayout *layout; ID3D12DescriptorHeap *heaps[2];
    ZenitD12BindingEntry *entries; uint32_t *kinds; uint32_t count, group, descriptors[2]; LONG refs;
};
struct D12DispatchRefs {
    ZenitD12ComputePipeline *pipeline; ID3D12DescriptorHeap *heaps[2];
    ZenitD12BindGroup *groups[4]; uint32_t count;
};
extern "C" void zenit_d12_bind_group_release(ZenitD12BindGroup *g) {
    if (!g || InterlockedDecrement(&g->refs)!=0) return;
    for (uint32_t i=0;i<g->count;++i) {
        zenit_d12_buffer_release(g->entries[i].buffer);
        zenit_d12_view_release(g->entries[i].view);
        zenit_d12_sampler_release(g->entries[i].sampler);
    }
    for (auto heap:g->heaps) if (heap) heap->Release();
    zenit_d12_pipeline_layout_release(g->layout); free(g->entries); free(g->kinds); free(g);
}
static void release_dispatch(D12DispatchRefs *r) {
    if (!r) return;
    for (uint32_t i=0;i<r->count;++i) zenit_d12_bind_group_release(r->groups[i]);
    for (auto heap:r->heaps) if (heap) heap->Release();
    zenit_d12_compute_pipeline_release(r->pipeline); free(r);
}
extern "C" int zenit_d12_bind_group_create(ZenitD12Device *device, ZenitD12PipelineLayout *layout,
    uint32_t group, const ZenitD12BindingEntry *entries, uint32_t count, ZenitD12BindGroup **out) {
    if (!out) return 1; *out=nullptr;
    if (!device || !layout || zenit_d12_pipeline_layout_owner(layout)!=device || (count && !entries)) return 1;
    uint32_t nb=0,ng=0; auto bindings=zenit_d12_pipeline_layout_bindings(layout,&nb,&ng);
    if (group>=ng) return 1;
    uint32_t total=0, descriptors[2]={};
    for (uint32_t i=0;i<nb;++i) if (bindings[i].group==group) {
        total+=bindings[i].count; descriptors[bindings[i].kind==4]+=bindings[i].count;
    }
    if (count!=total) return 1;
    // Validate all entries before touching the device or taking references.
    for (uint32_t i=0;i<count;++i) {
        const auto &e=entries[i]; const ZenitD12LayoutBinding *b=nullptr;
        for (uint32_t j=0;j<nb;++j) if (bindings[j].group==group && bindings[j].binding==e.binding) b=&bindings[j];
        if (!b || e.array_index>=b->count || unsigned(e.buffer!=nullptr)+unsigned(e.view!=nullptr)+unsigned(e.sampler!=nullptr)!=1) return 1;
        for (uint32_t j=0;j<i;++j) if (entries[j].binding==e.binding && entries[j].array_index==e.array_index) return 1;
        if (b->kind==1 || b->kind==5) {
            if (!e.view || e.offset || e.size || e.stride || e.view->texture->owner!=device ||
                (b->view_dimension && b->view_dimension!=e.view->dimension) || e.view->storage!=(b->kind==5) ||
                (b->kind==5 && b->storage_format && (DXGI_FORMAT)b->storage_format!=e.view->texture->format)) return 1;
            uint32_t sample=zenit_d12_view_sample_type(e.view);
            if (b->sample_type && b->sample_type!=sample && !(b->sample_type==2 && sample==1)) return 1;
            if ((b->sample_type==1 || b->sample_type==3) && !texture_samplable(e.view->texture)) return 1;
            continue;
        }
        if (b->kind==4) {
            if (!e.sampler || e.offset || e.size || e.stride || e.sampler->owner!=device ||
                (b->sampler_type && (b->sampler_type==3)!=bool(zenit_d12_sampler_comparison(e.sampler))) ||
                (b->sampler_type==2 && (e.sampler->filter & 0x55u))) return 1;
            continue;
        }
        if (!e.buffer || e.buffer->owner!=device || !e.size || e.offset>e.buffer->size ||
            e.size>e.buffer->size-e.offset || e.size<b->min_size || (e.buffer->usage & MAP_READ)) return 1;
        if (b->kind==0) {
            uint64_t padded=(e.size+255)&~uint64_t(255);
            if (!(e.buffer->usage & UNIFORM) || e.stride || e.offset%256 || e.size>65536 ||
                padded>e.buffer->raw->GetDesc().Width-e.offset) return 1;
        } else {
            uint32_t unit=e.stride?e.stride:4;
            if (!(e.buffer->usage & STORAGE) || (b->kind==3 && (e.buffer->usage & MAP_WRITE)) ||
                e.stride>2048 || e.stride%4 || e.offset%unit || (!e.stride && e.offset%D3D12_RAW_UAV_SRV_BYTE_ALIGNMENT) || e.size%unit || e.size/unit>UINT32_MAX) return 1;
        }
    }
    auto g=(ZenitD12BindGroup *)calloc(1,sizeof(ZenitD12BindGroup)); if (!g) return 2;
    g->entries=(ZenitD12BindingEntry *)calloc(count?count:1,sizeof(ZenitD12BindingEntry));
    g->kinds=(uint32_t *)calloc(count?count:1,sizeof(uint32_t));
    if (!g->entries || !g->kinds) { free(g->entries); free(g->kinds); free(g); return 2; }
    g->layout=layout; zenit_d12_pipeline_layout_retain(layout); g->refs=1; g->group=group;
    uint32_t increments[2]={};
    for (uint32_t type=0;type<2;++type) {
        g->descriptors[type]=descriptors[type];
        auto heap_type=type?D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER:D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV;
        increments[type]=device->raw->GetDescriptorHandleIncrementSize(heap_type);
        if (!descriptors[type]) continue;
        D3D12_DESCRIPTOR_HEAP_DESC h={}; h.Type=heap_type; h.NumDescriptors=descriptors[type];
        HRESULT hr=device->raw->CreateDescriptorHeap(&h,IID_ID3D12DescriptorHeap,(void **)&g->heaps[type]);
        if (FAILED(hr)) { zenit_d12_bind_group_release(g); return 2; }
    }
    uint32_t slots[2]={};
    // Match root-table range order, independently of the supplied entry order.
    for (uint32_t i=0;i<nb;++i) if (bindings[i].group==group) for (uint32_t a=0;a<bindings[i].count;++a) {
        const auto &b=bindings[i]; const ZenitD12BindingEntry *e=nullptr;
        for (uint32_t j=0;j<count;++j) if (entries[j].binding==b.binding && entries[j].array_index==a) e=&entries[j];
        uint32_t slot=g->count++; g->entries[slot]=*e; g->kinds[slot]=b.kind;
        uint32_t type=b.kind==4;
        auto handle=g->heaps[type]->GetCPUDescriptorHandleForHeapStart(); handle.ptr+=SIZE_T(slots[type]++)*increments[type];
        if (e->view) {
            view_retain(e->view);
            device->raw->CopyDescriptorsSimple(1,handle,e->view->heap->GetCPUDescriptorHandleForHeapStart(),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
            continue;
        }
        if (e->sampler) {
            InterlockedIncrement(&e->sampler->refs);
            device->raw->CopyDescriptorsSimple(1,handle,e->sampler->heap->GetCPUDescriptorHandleForHeapStart(),D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER);
            continue;
        }
        InterlockedIncrement(&e->buffer->refs);
        uint32_t unit=e->stride?e->stride:4;
        if (b.kind==0) {
            D3D12_CONSTANT_BUFFER_VIEW_DESC d={}; d.BufferLocation=e->buffer->raw->GetGPUVirtualAddress()+e->offset;
            d.SizeInBytes=UINT((e->size+255)&~uint64_t(255)); device->raw->CreateConstantBufferView(&d,handle);
        } else if (b.kind==2) {
            D3D12_SHADER_RESOURCE_VIEW_DESC d={}; d.ViewDimension=D3D12_SRV_DIMENSION_BUFFER;
            d.Shader4ComponentMapping=D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
            d.Format=e->stride?DXGI_FORMAT_UNKNOWN:DXGI_FORMAT_R32_TYPELESS;
            d.Buffer.FirstElement=e->offset/unit; d.Buffer.NumElements=UINT(e->size/unit); d.Buffer.StructureByteStride=e->stride;
            d.Buffer.Flags=e->stride?D3D12_BUFFER_SRV_FLAG_NONE:D3D12_BUFFER_SRV_FLAG_RAW;
            device->raw->CreateShaderResourceView(e->buffer->raw,&d,handle);
        } else {
            D3D12_UNORDERED_ACCESS_VIEW_DESC d={}; d.ViewDimension=D3D12_UAV_DIMENSION_BUFFER;
            d.Format=e->stride?DXGI_FORMAT_UNKNOWN:DXGI_FORMAT_R32_TYPELESS;
            d.Buffer.FirstElement=e->offset/unit; d.Buffer.NumElements=UINT(e->size/unit); d.Buffer.StructureByteStride=e->stride;
            d.Buffer.Flags=e->stride?D3D12_BUFFER_UAV_FLAG_NONE:D3D12_BUFFER_UAV_FLAG_RAW;
            device->raw->CreateUnorderedAccessView(e->buffer->raw,nullptr,&d,handle);
        }
    }
    *out=g; return 0;
}
struct D12BoundState { ZenitD12Buffer *buffer; ZenitD12Texture *texture; D3D12_RESOURCE_STATES state; };
static void transition_bound(ID3D12GraphicsCommandList *list, const D12BoundState &s, bool restore) {
    auto before=restore?s.state:D3D12_RESOURCE_STATE_COMMON;
    auto after=restore?D3D12_RESOURCE_STATE_COMMON:s.state;
    if (s.buffer) transition_buffer(list,s.buffer,before,after);
    else transition_texture(list,s.texture,D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,before,after);
}
extern "C" int zenit_d12_commands_dispatch(ZenitD12Commands *commands, ZenitD12ComputePipeline *pipeline,
    ZenitD12BindGroup *const *groups, uint32_t count, uint32_t x, uint32_t y, uint32_t z) {
    if (!commands || commands->closed || commands->submitted || commands->pass || !pipeline || count>4 || (count && !groups) ||
        !x || !y || !z || x>65535 || y>65535 || z>65535) return 1;
    auto layout=zenit_d12_compute_pipeline_layout(pipeline);
    if (zenit_d12_pipeline_layout_owner(layout)!=commands->owner) return 1;
    uint32_t nb=0,ng=0; zenit_d12_pipeline_layout_bindings(layout,&nb,&ng);
    if (count!=ng) return 1;
    uint32_t total=0, descriptors[2]={};
    for (uint32_t i=0;i<count;++i) {
        auto g=groups[i];
        if (!g || g->layout!=layout || g->group!=i) return 1;
        int status=zenit_d12_compute_validate_bindings(pipeline,i,g->entries,g->count); if (status) return status;
        total+=g->count;
        for (uint32_t type=0;type<2;++type) descriptors[type]+=g->descriptors[type];
    }
    auto states=(D12BoundState *)calloc(total?total:1,sizeof(D12BoundState)); if (!states) return 2;
    uint32_t ns=0;
    for (uint32_t i=0;i<count;++i) for (uint32_t j=0;j<groups[i]->count;++j) {
        auto g=groups[i]; auto buffer=g->entries[j].buffer;
        auto texture=g->entries[j].view?g->entries[j].view->texture:nullptr;
        if (!buffer && !texture) continue;
        auto state=(g->kinds[j]==3 || g->kinds[j]==5)?D3D12_RESOURCE_STATE_UNORDERED_ACCESS:
            g->kinds[j]==0?D3D12_RESOURCE_STATE_VERTEX_AND_CONSTANT_BUFFER:D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE;
        uint32_t slot=0; while (slot<ns && (states[slot].buffer!=buffer || states[slot].texture!=texture)) ++slot;
        if (slot<ns && ((states[slot].state | state) & D3D12_RESOURCE_STATE_UNORDERED_ACCESS)) { free(states); return 1; }
        if (slot==ns) { states[ns].buffer=buffer; states[ns++].texture=texture; }
        states[slot].state=D3D12_RESOURCE_STATES(states[slot].state | state);
    }
    auto r=(D12DispatchRefs *)calloc(1,sizeof(D12DispatchRefs));
    auto node=(D12CopyRefs *)calloc(1,sizeof(D12CopyRefs));
    if (!r || !node) { free(r); free(node); free(states); return 2; }
    for (uint32_t type=0;type<2;++type) if (descriptors[type]) {
        D3D12_DESCRIPTOR_HEAP_DESC h={}; h.Type=type?D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER:D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV;
        h.NumDescriptors=descriptors[type]; h.Flags=D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
        if (FAILED(commands->owner->raw->CreateDescriptorHeap(&h,IID_ID3D12DescriptorHeap,(void **)&r->heaps[type]))) {
            release_dispatch(r); free(node); free(states); return 2;
        }
    }
    r->pipeline=pipeline; zenit_d12_compute_pipeline_retain(pipeline); r->count=count;
    for (uint32_t i=0;i<count;++i) { r->groups[i]=groups[i]; InterlockedIncrement(&groups[i]->refs); }
    node->dispatch=r; node->next=commands->resources; commands->resources=node;
    auto list=commands->list; list->SetPipelineState((ID3D12PipelineState *)zenit_d12_compute_pipeline_native(pipeline));
    list->SetComputeRootSignature((ID3D12RootSignature *)zenit_d12_compute_pipeline_root(pipeline));
    ID3D12DescriptorHeap *active[2]={}; uint32_t heap_count=0;
    for (auto heap:r->heaps) if (heap) active[heap_count++]=heap;
    if (heap_count) list->SetDescriptorHeaps(heap_count,active);
    for (uint32_t type=0;type<2;++type) {
        auto heap_type=type?D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER:D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV;
        uint32_t increment=commands->owner->raw->GetDescriptorHandleIncrementSize(heap_type), offset=0;
        for (uint32_t i=0;i<count;++i) if (groups[i]->descriptors[type]) {
            auto cpu=r->heaps[type]->GetCPUDescriptorHandleForHeapStart(); cpu.ptr+=SIZE_T(offset)*increment;
            commands->owner->raw->CopyDescriptorsSimple(groups[i]->descriptors[type],cpu,groups[i]->heaps[type]->GetCPUDescriptorHandleForHeapStart(),heap_type);
            auto gpu=r->heaps[type]->GetGPUDescriptorHandleForHeapStart(); gpu.ptr+=UINT64(offset)*increment;
            list->SetComputeRootDescriptorTable(zenit_d12_pipeline_layout_table(layout,i,type),gpu);
            offset+=groups[i]->descriptors[type];
        }
    }
    for (uint32_t i=0;i<ns;++i) transition_bound(list,states[i],false);
    list->Dispatch(x,y,z);
    for (uint32_t i=0;i<ns;++i) transition_bound(list,states[i],true);
    free(states); return 0;
}

struct D12RenderRefs {
    ID3D12DescriptorHeap *heap,*dsv; ZenitD12ColorAttachment attachments[8]; uint32_t count; ZenitD12DepthAttachment depth;
};
struct D12DrawRefs { ZenitD12RenderPipeline *pipeline; ZenitD12Buffer *buffers[33]; uint32_t count; D12DispatchRefs *bindings; };
struct ZenitD12RenderPass {
    ZenitD12Commands *commands; D12RenderRefs *resources; uint32_t width,height,samples;
    // Successful draws retain these textures through their bind groups. Keep
    // read-only textures in SRV state until pass end; never cache UAV-capable
    // textures, which may change access within a render pass.
    ZenitD12Texture *read_textures[32]; uint32_t read_count;
    D3D12_RECT draw_regions[4]; uint32_t draw_region_count;
    // Command-list state already set in this pass. Consecutive draws mostly
    // share pipeline, root signature, descriptor page and fixed state; setting
    // them again per draw was pure CPU cost. Zeroed (unknown) at pass begin.
    ID3D12PipelineState *bound_pso; ID3D12RootSignature *bound_root; ID3D12DescriptorHeap *bound_heaps[2];
    uint32_t bound_topology, bound_stencil, bound_viewport_count; bool bound_fixed;
    float bound_blend[4]; D3D12_VIEWPORT bound_viewports[4]; D3D12_RECT bound_scissors[4];
    D3D12_VERTEX_BUFFER_VIEW bound_vertex[32]; uint32_t bound_vertex_mask;
};
extern "C" int zenit_d12_render_pass_regions(ZenitD12RenderPass *pass,const uint32_t *bounds,uint32_t count) {
    if (!pass || pass->commands->pass!=pass || count>4 || (count && (!bounds || !pass->commands->owner->vertex_viewport_index))) return 1;
    for (uint32_t i=0;i<count;++i) {
        const uint32_t *b=bounds+i*4;
        uint64_t right=uint64_t(b[0])+b[2],bottom=uint64_t(b[1])+b[3];
        pass->draw_regions[i]={LONG(b[0]<pass->width?b[0]:pass->width),LONG(b[1]<pass->height?b[1]:pass->height),
            LONG(right<pass->width?right:pass->width),LONG(bottom<pass->height?bottom:pass->height)};
    }
    pass->draw_region_count=count;
    return 0;
}
#ifdef ZENIT_D12_TEST
static LONG read_texture_reuses;
extern "C" long zenit_d12_test_read_texture_reuses() { return InterlockedCompareExchange(&read_texture_reuses,0,0); }
#endif
static bool pass_has_read_texture(ZenitD12RenderPass *pass,ZenitD12Texture *texture) {
    for (uint32_t i=0;i<pass->read_count;++i) if (pass->read_textures[i]==texture) return true;
    return false;
}
static void prepare_draw_bound(ZenitD12RenderPass *pass,const D12BoundState &bound) {
    constexpr auto srv=D3D12_RESOURCE_STATES(D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE | D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
    if (bound.texture && !(bound.texture->usage & 8u) && bound.state==srv) {
        if (pass_has_read_texture(pass,bound.texture)) {
#ifdef ZENIT_D12_TEST
            InterlockedIncrement(&read_texture_reuses);
#endif
            return;
        }
        transition_bound(pass->commands->list,bound,false);
        if (pass->read_count<32) pass->read_textures[pass->read_count++]=bound.texture;
    } else transition_bound(pass->commands->list,bound,false);
}
static void release_render(D12RenderRefs *r) {
    if (!r) return;
    for (uint32_t i=0;i<r->count;++i) { zenit_d12_texture_release(r->attachments[i].texture); zenit_d12_texture_release(r->attachments[i].resolve); }
    if (r->heap) r->heap->Release(); if (r->dsv) r->dsv->Release(); zenit_d12_texture_release(r->depth.texture); free(r);
}
static void release_draw(D12DrawRefs *r) {
    if (!r) return;
    for (uint32_t i=0;i<r->count;++i) zenit_d12_buffer_release(r->buffers[i]);
    release_dispatch(r->bindings); zenit_d12_render_pipeline_release(r->pipeline); free(r);
}
static void discard_attachment(ID3D12GraphicsCommandList *list, const ZenitD12ColorAttachment &a) {
    D3D12_DISCARD_REGION d={}; d.FirstSubresource=a.mip+a.layer*a.texture->mips; d.NumSubresources=1;
    list->DiscardResource(a.texture->raw,&d);
}
static D3D12_RESOURCE_STATES depth_state(const ZenitD12DepthAttachment &d,uint32_t plane) {
    return (plane?d.stencil_read_only:d.depth_read_only)?D3D12_RESOURCE_STATE_DEPTH_READ:D3D12_RESOURCE_STATE_DEPTH_WRITE;
}
static uint32_t depth_subresource(const ZenitD12DepthAttachment &d,uint32_t plane) {
    return d.mip+d.layer*d.texture->mips+plane*d.texture->mips*d.texture->depth;
}
static void discard_depth(ID3D12GraphicsCommandList *list,const ZenitD12DepthAttachment &d,uint32_t plane) {
    D3D12_DISCARD_REGION r={}; r.FirstSubresource=depth_subresource(d,plane); r.NumSubresources=1; list->DiscardResource(d.texture->raw,&r);
}
extern "C" int zenit_d12_render_pass_begin(ZenitD12Commands *commands, const ZenitD12ColorAttachment *attachments,
    uint32_t count, const ZenitD12DepthAttachment *depth, ZenitD12RenderPass **out) {
    if (!out) return 1; *out=nullptr;
    if (!commands || commands->closed || commands->submitted || commands->pass || (!count && !depth) || count>8 || (count && !attachments)) return 1;
    uint32_t width=0,height=0,samples=0;
    for (uint32_t i=0;i<count;++i) {
        const auto &a=attachments[i]; auto t=a.texture;
        if (!t || t->owner!=commands->owner || t->dimension!=2 || !(t->usage & 16u) || a.mip>=t->mips ||
            a.layer>=t->depth || depth_format(t->format) || a.load_op>2 || a.store_op>1) return 1;
        for (auto v:a.clear) if (!(v>=-FLT_MAX && v<=FLT_MAX)) return 1;
        for (uint32_t j=0;j<i;++j) if (attachments[j].texture==t) return 1;
        uint32_t w=t->width>>a.mip,h=t->height>>a.mip; if (!w) w=1; if (!h) h=1;
        if (i && (w!=width || h!=height || t->samples!=samples)) return 1; width=w; height=h; samples=t->samples;
        if (a.resolve) {
            auto d=a.resolve;
            if (t->samples==1 || d->owner!=commands->owner || d->dimension!=2 || d->samples!=1 || d->format!=t->format || !(d->usage & 16u) ||
                a.resolve_mip>=d->mips || a.resolve_layer>=d->depth) return 1;
            uint32_t dw=d->width>>a.resolve_mip,dh=d->height>>a.resolve_mip; if (!dw) dw=1; if (!dh) dh=1;
            if (dw!=w || dh!=h) return 1;
            for (uint32_t j=0;j<count;++j) if (attachments[j].texture==d || (j!=i && attachments[j].resolve==d)) return 1;
            D3D12_FEATURE_DATA_FORMAT_SUPPORT cap={}; cap.Format=t->format;
            if (FAILED(commands->owner->raw->CheckFeatureSupport(D3D12_FEATURE_FORMAT_SUPPORT,&cap,sizeof(cap))) || !(cap.Support1 & D3D12_FORMAT_SUPPORT1_MULTISAMPLE_RESOLVE)) return 1;
        } else if (a.resolve_mip || a.resolve_layer) return 1;
    }
    if (depth) {
        auto t=depth->texture;
        if (!t || t->owner!=commands->owner || t->dimension!=2 || !depth_format(t->format) || !(t->usage & 16u) ||
            depth->mip>=t->mips || depth->layer>=t->depth || depth->depth_load>2 || depth->depth_store>1 || depth->stencil_load>2 || depth->stencil_store>1 ||
            !(depth->clear>=0 && depth->clear<=1) || depth->stencil_clear>255 || depth->depth_read_only>1 || depth->stencil_read_only>1 ||
            (depth->depth_read_only && (depth->depth_load!=0 || depth->depth_store!=0)) ||
            (depth->stencil_read_only && (depth->stencil_load!=0 || depth->stencil_store!=0)) ||
            (depth_planes(t->format)==1 && (depth->stencil_load!=0 || depth->stencil_store!=0 || depth->stencil_read_only))) return 1;
        uint32_t w=t->width>>depth->mip,h=t->height>>depth->mip; if (!w) w=1; if (!h) h=1;
        if (count && (w!=width || h!=height || t->samples!=samples)) return 1; width=w; height=h; samples=t->samples;
    }
    auto r=(D12RenderRefs *)calloc(1,sizeof(D12RenderRefs));
    auto node=(D12CopyRefs *)calloc(1,sizeof(D12CopyRefs));
    auto pass=(ZenitD12RenderPass *)calloc(1,sizeof(ZenitD12RenderPass));
    if (!r || !node || !pass) { free(r); free(node); free(pass); return 2; }
    D3D12_DESCRIPTOR_HEAP_DESC h={}; h.Type=D3D12_DESCRIPTOR_HEAP_TYPE_RTV; h.NumDescriptors=count;
    // Most passes render into mip 0 / layer 0 of one texture: reuse that
    // texture's RTV (descriptors are immutable once written) instead of a new
    // descriptor heap per pass. The pass holds a heap reference as before.
    auto first=count==1?attachments[0].texture:nullptr;
    const bool cached_rtv=first && attachments[0].mip==0 && attachments[0].layer==0 && first->depth==1;
    bool write_rtv=true;
    if (cached_rtv && first->rtv_heap) { r->heap=first->rtv_heap; r->heap->AddRef(); write_rtv=false; }
    else if (count && FAILED(commands->owner->raw->CreateDescriptorHeap(&h,IID_ID3D12DescriptorHeap,(void **)&r->heap))) {
        free(r); free(node); free(pass); return 2;
    }
    if (cached_rtv && !first->rtv_heap) { first->rtv_heap=r->heap; first->rtv_heap->AddRef(); }
    D3D12_CPU_DESCRIPTOR_HANDLE handles[8]={};
    uint32_t increment=commands->owner->raw->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
    for (uint32_t i=0;i<count;++i) {
        auto t=attachments[i].texture; r->attachments[i]=attachments[i]; InterlockedIncrement(&t->refs); if (attachments[i].resolve) InterlockedIncrement(&attachments[i].resolve->refs); ++r->count;
        handles[i]=r->heap->GetCPUDescriptorHandleForHeapStart(); handles[i].ptr+=SIZE_T(i)*increment;
        if (!write_rtv) continue;
        D3D12_RENDER_TARGET_VIEW_DESC d={}; d.Format=t->format;
        if (t->samples>1) {
            if (t->depth==1) d.ViewDimension=D3D12_RTV_DIMENSION_TEXTURE2DMS;
            else { d.ViewDimension=D3D12_RTV_DIMENSION_TEXTURE2DMSARRAY; d.Texture2DMSArray.FirstArraySlice=attachments[i].layer; d.Texture2DMSArray.ArraySize=1; }
        } else if (t->depth==1) { d.ViewDimension=D3D12_RTV_DIMENSION_TEXTURE2D; d.Texture2D.MipSlice=attachments[i].mip; }
        else { d.ViewDimension=D3D12_RTV_DIMENSION_TEXTURE2DARRAY; d.Texture2DArray.MipSlice=attachments[i].mip;
            d.Texture2DArray.FirstArraySlice=attachments[i].layer; d.Texture2DArray.ArraySize=1; }
        commands->owner->raw->CreateRenderTargetView(t->raw,&d,handles[i]);
    }
    D3D12_CPU_DESCRIPTOR_HANDLE dsv={};
    if (depth) {
        h.Type=D3D12_DESCRIPTOR_HEAP_TYPE_DSV; h.NumDescriptors=1;
        if (FAILED(commands->owner->raw->CreateDescriptorHeap(&h,IID_ID3D12DescriptorHeap,(void **)&r->dsv))) {
            release_render(r); free(node); free(pass); return 2;
        }
        r->depth=*depth; InterlockedIncrement(&depth->texture->refs);
        D3D12_DEPTH_STENCIL_VIEW_DESC d={}; d.Format=depth->texture->format;
        d.Flags=(D3D12_DSV_FLAGS)((depth->depth_read_only?D3D12_DSV_FLAG_READ_ONLY_DEPTH:0) | (depth->stencil_read_only?D3D12_DSV_FLAG_READ_ONLY_STENCIL:0));
        if (depth->texture->samples>1) {
            if (depth->texture->depth==1) d.ViewDimension=D3D12_DSV_DIMENSION_TEXTURE2DMS;
            else { d.ViewDimension=D3D12_DSV_DIMENSION_TEXTURE2DMSARRAY; d.Texture2DMSArray.FirstArraySlice=depth->layer; d.Texture2DMSArray.ArraySize=1; }
        } else if (depth->texture->depth==1) { d.ViewDimension=D3D12_DSV_DIMENSION_TEXTURE2D; d.Texture2D.MipSlice=depth->mip; }
        else { d.ViewDimension=D3D12_DSV_DIMENSION_TEXTURE2DARRAY; d.Texture2DArray.MipSlice=depth->mip; d.Texture2DArray.FirstArraySlice=depth->layer; d.Texture2DArray.ArraySize=1; }
        dsv=r->dsv->GetCPUDescriptorHandleForHeapStart(); commands->owner->raw->CreateDepthStencilView(depth->texture->raw,&d,dsv);
    }
    node->render=r; node->next=commands->resources; commands->resources=node;
    pass->commands=commands; pass->resources=r; pass->width=width; pass->height=height; pass->samples=samples;
    commands->pass=pass; InterlockedIncrement(&commands->refs);
    for (uint32_t i=0;i<count;++i) {
        auto &a=r->attachments[i];
        transition_texture(commands->list,a.texture,a.mip+a.layer*a.texture->mips,D3D12_RESOURCE_STATE_COMMON,D3D12_RESOURCE_STATE_RENDER_TARGET);
        if (a.load_op==1) commands->list->ClearRenderTargetView(handles[i],a.clear,0,nullptr);
        else if (a.load_op==2) discard_attachment(commands->list,a);
    }
    if (depth) {
        for (uint32_t plane=0;plane<depth_planes(depth->texture->format);++plane) {
            transition_texture(commands->list,depth->texture,depth_subresource(*depth,plane),D3D12_RESOURCE_STATE_COMMON,depth_state(*depth,plane));
            if ((plane?depth->stencil_load:depth->depth_load)==2) discard_depth(commands->list,*depth,plane);
        }
        uint32_t flags=(depth->depth_load==1?D3D12_CLEAR_FLAG_DEPTH:0) | (depth_planes(depth->texture->format)>1 && depth->stencil_load==1?D3D12_CLEAR_FLAG_STENCIL:0);
        if (flags) commands->list->ClearDepthStencilView(dsv,(D3D12_CLEAR_FLAGS)flags,depth->clear,(UINT8)depth->stencil_clear,0,nullptr);
    }
    commands->list->OMSetRenderTargets(count,handles,FALSE,depth?&dsv:nullptr);
    D3D12_VIEWPORT viewport={}; viewport.Width=float(width); viewport.Height=float(height); viewport.MaxDepth=1;
    commands->list->RSSetViewports(1,&viewport);
    *out=pass; return 0;
}
#ifdef ZENIT_D12_TEST
extern "C" uint32_t zenit_d12_test_descriptor_pages(ZenitD12Commands *commands,uint32_t type) {
    if (!commands || type>1) return 0;
    uint32_t count=0; for (auto page=commands->descriptor_pages[type];page;page=page->next) ++count;
    return count;
}
#endif
static int reserve_draw_descriptors(ZenitD12Commands *commands,uint32_t type,uint32_t count,
    ID3D12DescriptorHeap **out,uint32_t *base) {
    auto page=commands->descriptor_pages[type];
    if (!page || count>page->capacity-page->used) {
        auto next=(D12DescriptorPage *)calloc(1,sizeof(D12DescriptorPage));
        if (!next) return 2;
        next->capacity=count>(type?256u:1024u)?count:(type?256u:1024u);
        auto device=commands->owner;
        if (next->capacity==(type?256u:1024u)) {
            AcquireSRWLockExclusive(&device->pool_lock);
            if (device->page_pool_count[type]) next->heap=device->page_pool[type][--device->page_pool_count[type]];
            ReleaseSRWLockExclusive(&device->pool_lock);
        }
        if (!next->heap) {
            D3D12_DESCRIPTOR_HEAP_DESC h={};
            h.Type=type?D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER:D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV;
            h.NumDescriptors=next->capacity; h.Flags=D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
            if (FAILED(device->raw->CreateDescriptorHeap(&h,IID_ID3D12DescriptorHeap,(void **)&next->heap))) {
                free(next); return 2;
            }
        }
        next->next=page; commands->descriptor_pages[type]=next; page=next;
    }
    *base=page->used; page->used+=count; *out=page->heap; (*out)->AddRef(); return 0;
}
#ifdef ZENIT_D12_TEST
static LONG opaque_clear_count;
extern "C" long zenit_d12_test_opaque_clear_count() { return InterlockedCompareExchange(&opaque_clear_count,0,0); }
#endif
// One opaque replacement region, in the active render target's pixel space.
extern "C" int zenit_d12_render_pass_clear_opaque(ZenitD12RenderPass *pass, const float *color,
    uint32_t x, uint32_t y, uint32_t width, uint32_t height) {
    if (!pass || !color || pass->commands->pass!=pass || pass->resources->count!=1 ||
        color[3]!=1.0f || uint64_t(x)+width>pass->width || uint64_t(y)+height>pass->height) return 1;
    for (unsigned i=0;i<4;++i) if (!(color[i]>=-FLT_MAX && color[i]<=FLT_MAX)) return 1;
    if (!width || !height) return 0;
    D3D12_RECT rect={(LONG)x,(LONG)y,(LONG)(x+width),(LONG)(y+height)};
    pass->commands->list->ClearRenderTargetView(pass->resources->heap->GetCPUDescriptorHandleForHeapStart(),color,1,&rect);
#ifdef ZENIT_D12_TEST
    InterlockedIncrement(&opaque_clear_count);
#endif
    return 0;
}
static int retain_reserve(ZenitD12Commands *c, uint32_t more) {
    if (c->retained_count+more<=c->retained_capacity) return 0;
    uint32_t capacity=c->retained_capacity?c->retained_capacity:256;
    while (capacity<c->retained_count+more) capacity*=2;
    auto items=(void **)realloc(c->retained,capacity*sizeof(void *)); if (!items) return 2;
    c->retained=items;
    auto kinds=(uint8_t *)realloc(c->retained_kinds,capacity); if (!kinds) return 2;
    c->retained_kinds=kinds; c->retained_capacity=capacity; return 0;
}
static void retain_push(ZenitD12Commands *c, uint8_t kind, void *item) {
    c->retained[c->retained_count]=item; c->retained_kinds[c->retained_count++]=kind;
}
static void release_retained(ZenitD12Commands *c) {
    for (uint32_t i=0;i<c->retained_count;++i) switch (c->retained_kinds[i]) {
    case RETAIN_BUFFER: zenit_d12_buffer_release((ZenitD12Buffer *)c->retained[i]); break;
    case RETAIN_VIEW: zenit_d12_view_release((ZenitD12View *)c->retained[i]); break;
    case RETAIN_SAMPLER: zenit_d12_sampler_release((ZenitD12Sampler *)c->retained[i]); break;
    default: zenit_d12_render_pipeline_release((ZenitD12RenderPipeline *)c->retained[i]); break;
    }
    free(c->retained); free(c->retained_kinds);
    c->retained=nullptr; c->retained_kinds=nullptr; c->retained_count=c->retained_capacity=0;
}
// Pass/pipeline/vertex/index validation shared by both draw entry points.
struct D12DrawSetup {
    ZenitD12RenderInfo info; D3D12_VIEWPORT viewport; D3D12_RECT scissor; bool indexed;
    D3D12_INDEX_BUFFER_VIEW index_view; D3D12_VERTEX_BUFFER_VIEW views[32];
    ZenitD12Buffer *buffers[33]; D3D12_RESOURCE_STATES states[33]; uint32_t unique;
};
static int setup_draw(ZenitD12RenderPass *pass, ZenitD12RenderPipeline *pipeline, const ZenitD12Draw *draw, D12DrawSetup &d) {
    auto commands=pass->commands;
    zenit_d12_render_pipeline_info(pipeline,&d.info);
    const auto &info=d.info;
    if (info.samples!=pass->samples || info.target_count!=pass->resources->count || uint64_t(draw->first_vertex)+draw->vertices>UINT32_MAX ||
        uint64_t(draw->first_instance)+draw->instances>UINT32_MAX) return 1;
    for (uint32_t i=0;i<info.target_count;++i) if (info.formats[i]!=uint32_t(pass->resources->attachments[i].texture->format)) return 1;
    auto ds=pass->resources->depth.texture;
    if (info.depth_format!=(ds?uint32_t(ds->format):0) || draw->stencil_reference>255 ||
        (ds && ((info.depth_write && pass->resources->depth.depth_read_only) || (info.stencil_write && pass->resources->depth.stencil_read_only)))) return 1;
    uint32_t width=draw->width,height=draw->height;
    if (width==UINT32_MAX && height==UINT32_MAX) { width=pass->width; height=pass->height; }
    if (draw->x>pass->width || width>pass->width-draw->x || draw->y>pass->height || height>pass->height-draw->y) return 1;
    for (auto v:draw->blend) if (!(v>=-FLT_MAX && v<=FLT_MAX)) return 1;
    d.viewport={0,0,float(pass->width),float(pass->height),0,1};
    if (draw->has_viewport>1) return 1;
    if (draw->has_viewport) {
        for (auto v:draw->viewport) if (!(v>=-FLT_MAX && v<=FLT_MAX)) return 1;
        auto v=draw->viewport;
        if (v[0]<D3D12_VIEWPORT_BOUNDS_MIN || v[1]<D3D12_VIEWPORT_BOUNDS_MIN ||
            v[0]>D3D12_VIEWPORT_BOUNDS_MAX || v[1]>D3D12_VIEWPORT_BOUNDS_MAX ||
            v[2]<0 || v[3]<0 || v[0]+v[2]>D3D12_VIEWPORT_BOUNDS_MAX || v[1]+v[3]>D3D12_VIEWPORT_BOUNDS_MAX ||
            v[4]<0 || v[5]>1 || v[4]>v[5]) return 1;
        d.viewport={v[0],v[1],v[2],v[3],v[4],v[5]};
    }
    d.scissor={LONG(draw->x),LONG(draw->y),LONG(draw->x+width),LONG(draw->y+height)};
    d.indexed=draw->index_buffer!=nullptr;
    d.index_view={};
    if (d.indexed) {
        auto b=draw->index_buffer; uint32_t element=draw->index_format==1?2:4;
        if ((draw->index_format!=1 && draw->index_format!=2) || b->owner!=commands->owner ||
            !(b->usage & 16u) || (b->usage & MAP_READ) || draw->index_offset%element ||
            draw->index_offset>b->size || draw->index_size>b->size-draw->index_offset ||
            draw->index_size>UINT32_MAX || draw->index_size%element ||
            uint64_t(draw->first_index)+draw->vertices>UINT32_MAX ||
            (uint64_t(draw->first_index)+draw->vertices)*element>draw->index_size ||
            (info.strip_index && info.strip_index!=draw->index_format)) return 1;
        d.index_view.BufferLocation=b->raw->GetGPUVirtualAddress()+draw->index_offset;
        d.index_view.SizeInBytes=UINT(draw->index_size);
        d.index_view.Format=element==2?DXGI_FORMAT_R16_UINT:DXGI_FORMAT_R32_UINT;
    } else if (draw->index_format || draw->first_index || draw->base_vertex || draw->index_offset || draw->index_size) return 1;
    uint32_t slots=0; d.unique=0;
    for (uint32_t i=0;i<draw->buffer_count;++i) {
        const auto &b=draw->buffers[i]; auto buffer=b.buffer;
        if (!buffer || buffer->owner!=commands->owner || !(buffer->usage & 32u) || (buffer->usage & MAP_READ) ||
            b.slot>=32 || !(info.slots & (1u<<b.slot)) || (slots & (1u<<b.slot)) || b.offset%4 ||
            b.offset>buffer->size || b.size>buffer->size-b.offset || b.size>UINT32_MAX) return 1;
        uint64_t start=info.steps[b.slot]?draw->first_instance:draw->first_vertex;
        uint64_t count=info.steps[b.slot]?draw->instances:draw->vertices;
        if ((!d.indexed || info.steps[b.slot]) && draw->instances && draw->vertices && count && (start+count-1)*info.strides[b.slot]+info.ends[b.slot]>b.size) return 1;
        slots|=1u<<b.slot; d.views[i].BufferLocation=buffer->raw->GetGPUVirtualAddress()+b.offset;
        d.views[i].SizeInBytes=UINT(b.size); d.views[i].StrideInBytes=info.strides[b.slot];
        uint32_t j=0; while (j<d.unique && d.buffers[j]!=buffer) ++j; if (j==d.unique) d.buffers[d.unique++]=buffer; d.states[j]=D3D12_RESOURCE_STATE_VERTEX_AND_CONSTANT_BUFFER;
    }
    if (slots!=info.slots) return 1;
    if (d.indexed) {
        uint32_t j=0; while (j<d.unique && d.buffers[j]!=draw->index_buffer) ++j;
        if (j==d.unique) d.buffers[d.unique++]=draw->index_buffer;
        d.states[j]=(D3D12_RESOURCE_STATES)(d.states[j] | D3D12_RESOURCE_STATE_INDEX_BUFFER);
    }
    return 0;
}
// Merge one bound resource into the draw's transition set (attachment
// feedback and conflicting UAV access are rejected).
static int bind_state(ZenitD12RenderPass *pass, D12BoundState *bound, uint32_t &ns, ZenitD12Buffer *buffer, ZenitD12Texture *texture, uint32_t kind) {
    if (!buffer && !texture) return 0;
    if (texture && texture==pass->resources->depth.texture) return 1;
    for (uint32_t a=0;a<pass->resources->count;++a) if (texture==pass->resources->attachments[a].texture || (texture && texture==pass->resources->attachments[a].resolve)) return 1;
    auto state=(kind==3 || kind==5)?D3D12_RESOURCE_STATE_UNORDERED_ACCESS:
        kind==0?D3D12_RESOURCE_STATE_VERTEX_AND_CONSTANT_BUFFER:
        D3D12_RESOURCE_STATES(D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE | D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
    uint32_t slot=0; while (slot<ns && (bound[slot].buffer!=buffer || bound[slot].texture!=texture)) ++slot;
    if (slot<ns && ((bound[slot].state | state) & D3D12_RESOURCE_STATE_UNORDERED_ACCESS)) return 1;
    if (slot==ns) { bound[ns].buffer=buffer; bound[ns].texture=texture; bound[ns++].state=D3D12_RESOURCE_STATES(0); }
    bound[slot].state=D3D12_RESOURCE_STATES(bound[slot].state | state);
    return 0;
}
// Records the draw after its descriptor tables are in place. Skips state the
// pass already set; tables and draw constants are set every draw.
static void emit_draw(ZenitD12RenderPass *pass, ZenitD12RenderPipeline *pipeline, const ZenitD12Draw *draw, const D12DrawSetup &d,
    ID3D12DescriptorHeap *const heaps[2], const D3D12_GPU_DESCRIPTOR_HANDLE tables[4][2], uint32_t groups,
    const D12BoundState *bound, uint32_t ns) {
    auto commands=pass->commands; auto list=commands->list; auto layout=zenit_d12_render_pipeline_layout(pipeline);
    auto pso=(ID3D12PipelineState *)zenit_d12_render_pipeline_native(pipeline);
    auto root=(ID3D12RootSignature *)zenit_d12_render_pipeline_root(pipeline);
    if (pass->bound_pso!=pso) { list->SetPipelineState(pso); pass->bound_pso=pso; }
    if (pass->bound_root!=root) { list->SetGraphicsRootSignature(root); pass->bound_root=root; }
    ID3D12DescriptorHeap *active[2]={}; uint32_t heap_count=0;
    for (uint32_t t=0;t<2;++t) if (heaps[t]) active[heap_count++]=heaps[t];
    // SetDescriptorHeaps replaces both bindings; only a heap this draw uses
    // needs to match (descriptor tables are rebound below).
    bool heaps_match=true;
    for (uint32_t t=0;t<2;++t) if (heaps[t] && pass->bound_heaps[t]!=heaps[t]) heaps_match=false;
    if (heap_count && !heaps_match) {
        list->SetDescriptorHeaps(heap_count,active);
        pass->bound_heaps[0]=heaps[0]; pass->bound_heaps[1]=heaps[1];
    }
    for (uint32_t i=0;i<groups;++i) for (uint32_t t=0;t<2;++t) if (tables[i][t].ptr)
        list->SetGraphicsRootDescriptorTable(zenit_d12_pipeline_layout_table(layout,i,t),tables[i][t]);
    uint32_t draw_info[4]={d.indexed?uint32_t(draw->base_vertex):draw->first_vertex,draw->first_instance,0,0};
    list->SetGraphicsRoot32BitConstants(zenit_d12_pipeline_layout_draw_info(layout),4,draw_info,0);
    if (!pass->bound_fixed || pass->bound_topology!=d.info.topology) { list->IASetPrimitiveTopology((D3D12_PRIMITIVE_TOPOLOGY)d.info.topology); pass->bound_topology=d.info.topology; }
    if (!pass->bound_fixed || memcmp(pass->bound_blend,draw->blend,sizeof(pass->bound_blend))) { list->OMSetBlendFactor(draw->blend); memcpy(pass->bound_blend,draw->blend,sizeof(pass->bound_blend)); }
    if (!pass->bound_fixed || pass->bound_stencil!=draw->stencil_reference) { list->OMSetStencilRef(draw->stencil_reference); pass->bound_stencil=draw->stencil_reference; }
    pass->bound_fixed=true;
    D3D12_VIEWPORT viewports[4]; D3D12_RECT scissors[4]; uint32_t vp_count=1;
    if (pass->draw_region_count) {
        vp_count=pass->draw_region_count;
        for (uint32_t i=0;i<pass->draw_region_count;++i) {
            viewports[i]=d.viewport; auto r=pass->draw_regions[i];
            r.left=r.left>d.scissor.left?r.left:d.scissor.left;
            r.top=r.top>d.scissor.top?r.top:d.scissor.top;
            r.right=r.right<d.scissor.right?r.right:d.scissor.right;
            r.bottom=r.bottom<d.scissor.bottom?r.bottom:d.scissor.bottom;
            if (r.right<r.left) r.right=r.left;
            if (r.bottom<r.top) r.bottom=r.top;
            scissors[i]=r;
        }
    } else { viewports[0]=d.viewport; scissors[0]=d.scissor; }
    if (pass->bound_viewport_count!=vp_count || memcmp(pass->bound_viewports,viewports,vp_count*sizeof(D3D12_VIEWPORT))) {
        list->RSSetViewports(vp_count,viewports); memcpy(pass->bound_viewports,viewports,vp_count*sizeof(D3D12_VIEWPORT));
    }
    if (pass->bound_viewport_count!=vp_count || memcmp(pass->bound_scissors,scissors,vp_count*sizeof(D3D12_RECT))) {
        list->RSSetScissorRects(vp_count,scissors); memcpy(pass->bound_scissors,scissors,vp_count*sizeof(D3D12_RECT));
    }
    pass->bound_viewport_count=vp_count;
    for (uint32_t i=0;i<draw->buffer_count;++i) {
        uint32_t slot=draw->buffers[i].slot;
        if ((pass->bound_vertex_mask & (1u<<slot)) && !memcmp(&pass->bound_vertex[slot],&d.views[i],sizeof(d.views[i]))) continue;
        list->IASetVertexBuffers(slot,1,&d.views[i]); pass->bound_vertex[slot]=d.views[i]; pass->bound_vertex_mask|=1u<<slot;
    }
    for (uint32_t i=0;i<ns;++i) prepare_draw_bound(pass,bound[i]);
    bool timed=commands->draw_timings && commands->timed_draws<MAX_PROFILE_DRAWS;
    if (timed) {
        auto &sample=commands->draw_timings[commands->timed_draws];
        strncpy(sample.shader,zenit_d12_render_pipeline_entry(pipeline),sizeof(sample.shader)-1);
        sample.width=pass->width; sample.height=pass->height;
        sample.vertices=draw->vertices; sample.instances=draw->instances;
        list->EndQuery(commands->timestamp_heap,D3D12_QUERY_TYPE_TIMESTAMP,2+commands->timed_draws*2);
    } else if (commands->draw_timings) ++commands->dropped_draws;
    if (d.indexed) {
        list->IASetIndexBuffer(&d.index_view);
        list->DrawIndexedInstanced(draw->vertices,draw->instances,draw->first_index,draw->base_vertex,draw->first_instance);
    } else list->DrawInstanced(draw->vertices,draw->instances,draw->first_vertex,draw->first_instance);
    if (timed) {
        list->EndQuery(commands->timestamp_heap,D3D12_QUERY_TYPE_TIMESTAMP,3+commands->timed_draws*2);
        ++commands->timed_draws;
    }
    for (uint32_t i=0;i<ns;++i) if (!bound[i].texture || !pass_has_read_texture(pass,bound[i].texture)) transition_bound(list,bound[i],true);
}
extern "C" int zenit_d12_render_pass_draw(ZenitD12RenderPass *pass, ZenitD12RenderPipeline *pipeline, const ZenitD12Draw *draw) {
    if (!pass || !pipeline || !draw || pass->commands->pass!=pass || draw->buffer_count>32 || (draw->buffer_count && !draw->buffers)) return 1;
    auto commands=pass->commands; auto layout=zenit_d12_render_pipeline_layout(pipeline);
    if (zenit_d12_pipeline_layout_owner(layout)!=commands->owner) return 1;
    uint32_t bindings=0,groups=0; zenit_d12_pipeline_layout_bindings(layout,&bindings,&groups);
    if (draw->group_count!=groups || groups>4 || (groups && !draw->groups)) return 1;
    uint32_t total=0,descriptors[2]={};
    for (uint32_t i=0;i<groups;++i) {
        auto g=draw->groups[i];
        if (!g || g->layout!=layout || g->group!=i) return 1;
        int status=zenit_d12_render_validate_bindings(pipeline,i,g->entries,g->count); if (status) return status;
        total+=g->count;
        for (uint32_t type=0;type<2;++type) descriptors[type]+=g->descriptors[type];
    }
    D12DrawSetup d; int status=setup_draw(pass,pipeline,draw,d); if (status) return status;
    struct StateStorage { D12BoundState *values; ~StateStorage() { free(values); } } storage={
        (D12BoundState *)calloc(total+d.unique+1,sizeof(D12BoundState))};
    if (!storage.values) return 2;
    auto bound=storage.values; uint32_t ns=d.unique;
    for (uint32_t i=0;i<d.unique;++i) { bound[i].buffer=d.buffers[i]; bound[i].state=d.states[i]; }
    for (uint32_t i=0;i<groups;++i) for (uint32_t j=0;j<draw->groups[i]->count;++j) {
        auto g=draw->groups[i];
        if (bind_state(pass,bound,ns,g->entries[j].buffer,g->entries[j].view?g->entries[j].view->texture:nullptr,g->kinds[j])) return 1;
    }
    auto r=(D12DrawRefs *)calloc(1,sizeof(D12DrawRefs)); auto node=(D12CopyRefs *)calloc(1,sizeof(D12CopyRefs));
    if (!r || !node) { free(r); free(node); return 2; }
    auto tables=(D12DispatchRefs *)calloc(1,sizeof(D12DispatchRefs));
    if (!tables) { free(r); free(node); return 2; }
    r->bindings=tables;
    uint32_t descriptor_bases[2]={};
    for (uint32_t type=0;type<2;++type) if (descriptors[type]) {
        if (reserve_draw_descriptors(commands,type,descriptors[type],&tables->heaps[type],&descriptor_bases[type])) {
            release_draw(r); free(node); return 2;
        }
    }
    tables->count=groups;
    for (uint32_t i=0;i<groups;++i) { tables->groups[i]=draw->groups[i]; InterlockedIncrement(&draw->groups[i]->refs); }
    r->pipeline=pipeline; zenit_d12_render_pipeline_retain(pipeline); r->count=d.unique;
    for (uint32_t i=0;i<d.unique;++i) { r->buffers[i]=d.buffers[i]; InterlockedIncrement(&d.buffers[i]->refs); }
    node->draw=r; node->next=commands->resources; commands->resources=node;
    D3D12_GPU_DESCRIPTOR_HANDLE gpu_tables[4][2]={};
    for (uint32_t type=0;type<2;++type) {
        auto heap_type=type?D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER:D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV;
        uint32_t increment=commands->owner->raw->GetDescriptorHandleIncrementSize(heap_type),offset=descriptor_bases[type];
        for (uint32_t i=0;i<groups;++i) if (draw->groups[i]->descriptors[type]) {
            auto g=draw->groups[i]; auto cpu=tables->heaps[type]->GetCPUDescriptorHandleForHeapStart(); cpu.ptr+=SIZE_T(offset)*increment;
            commands->owner->raw->CopyDescriptorsSimple(g->descriptors[type],cpu,g->heaps[type]->GetCPUDescriptorHandleForHeapStart(),heap_type);
            auto gpu=tables->heaps[type]->GetGPUDescriptorHandleForHeapStart(); gpu.ptr+=UINT64(offset)*increment;
            gpu_tables[i][type]=gpu;
            offset+=g->descriptors[type];
        }
    }
    emit_draw(pass,pipeline,draw,d,tables->heaps,gpu_tables,groups,bound,ns);
    return 0;
}
#ifdef ZENIT_D12_TEST
static LONG direct_draws;
extern "C" long zenit_d12_test_direct_draws() { return InterlockedCompareExchange(&direct_draws,0,0); }
#endif
// Status of an entry that bind_group_create would reject (the Zig layer
// reports it as error.InvalidBindGroup, as group creation did).
static constexpr int BIND_INVALID=6;
// A draw whose bind groups are given as entries (group_counts[i] entries per
// group, in group order). Validation equals bind_group_create followed by
// zenit_d12_render_pass_draw; descriptors are written straight into the
// command's shader-visible page and the resources retained by the command,
// with no per-draw bind group objects, CPU descriptor heaps or allocations.
extern "C" int zenit_d12_render_pass_draw_entries(ZenitD12RenderPass *pass, ZenitD12RenderPipeline *pipeline, const ZenitD12Draw *draw,
    const ZenitD12BindingEntry *entries, const uint32_t *group_counts, uint32_t group_count) {
    if (!pass || !pipeline || !draw || pass->commands->pass!=pass || draw->buffer_count>32 || (draw->buffer_count && !draw->buffers) ||
        draw->group_count || (group_count && !group_counts)) return 1;
    auto commands=pass->commands; auto device=commands->owner; auto layout=zenit_d12_render_pipeline_layout(pipeline);
    if (zenit_d12_pipeline_layout_owner(layout)!=device) return 1;
    uint32_t nb=0,groups=0; auto layout_bindings=zenit_d12_pipeline_layout_bindings(layout,&nb,&groups);
    if (group_count!=groups || groups>4) return 1;
    // Per-group entry spans and descriptor counts (bind_group_create checks).
    const ZenitD12BindingEntry *group_entries[4]={}; uint32_t descriptors[4][2]={}, total=0;
    for (uint32_t g=0,at=0;g<groups;at+=group_counts[g],++g) {
        uint32_t count=group_counts[g]; if (count>128 || (count && !entries)) return BIND_INVALID;
        group_entries[g]=entries+at;
        uint32_t expected=0;
        for (uint32_t i=0;i<nb;++i) if (layout_bindings[i].group==g) { expected+=layout_bindings[i].count; descriptors[g][layout_bindings[i].kind==4]+=layout_bindings[i].count; }
        if (count!=expected) return BIND_INVALID;
        for (uint32_t i=0;i<count;++i) {
            const auto &e=group_entries[g][i]; const ZenitD12LayoutBinding *b=nullptr;
            for (uint32_t j=0;j<nb;++j) if (layout_bindings[j].group==g && layout_bindings[j].binding==e.binding) b=&layout_bindings[j];
            if (!b || e.array_index>=b->count || unsigned(e.buffer!=nullptr)+unsigned(e.view!=nullptr)+unsigned(e.sampler!=nullptr)!=1) return BIND_INVALID;
            for (uint32_t j=0;j<i;++j) if (group_entries[g][j].binding==e.binding && group_entries[g][j].array_index==e.array_index) return BIND_INVALID;
            if (b->kind==1 || b->kind==5) {
                if (!e.view || e.offset || e.size || e.stride || e.view->texture->owner!=device ||
                    (b->view_dimension && b->view_dimension!=e.view->dimension) || e.view->storage!=(b->kind==5) ||
                    (b->kind==5 && b->storage_format && (DXGI_FORMAT)b->storage_format!=e.view->texture->format)) return BIND_INVALID;
                uint32_t sample=zenit_d12_view_sample_type(e.view);
                if (b->sample_type && b->sample_type!=sample && !(b->sample_type==2 && sample==1)) return BIND_INVALID;
                if ((b->sample_type==1 || b->sample_type==3) && !texture_samplable(e.view->texture)) return BIND_INVALID;
                continue;
            }
            if (b->kind==4) {
                if (!e.sampler || e.offset || e.size || e.stride || e.sampler->owner!=device ||
                    (b->sampler_type && (b->sampler_type==3)!=bool(zenit_d12_sampler_comparison(e.sampler))) ||
                    (b->sampler_type==2 && (e.sampler->filter & 0x55u))) return BIND_INVALID;
                continue;
            }
            if (!e.buffer || e.buffer->owner!=device || !e.size || e.offset>e.buffer->size ||
                e.size>e.buffer->size-e.offset || e.size<b->min_size || (e.buffer->usage & MAP_READ)) return BIND_INVALID;
            if (b->kind==0) {
                uint64_t padded=(e.size+255)&~uint64_t(255);
                if (!(e.buffer->usage & UNIFORM) || e.stride || e.offset%256 || e.size>65536 ||
                    padded>e.buffer->raw->GetDesc().Width-e.offset) return BIND_INVALID;
            } else {
                uint32_t unit=e.stride?e.stride:4;
                if (!(e.buffer->usage & STORAGE) || (b->kind==3 && (e.buffer->usage & MAP_WRITE)) ||
                    e.stride>2048 || e.stride%4 || e.offset%unit || (!e.stride && e.offset%D3D12_RAW_UAV_SRV_BYTE_ALIGNMENT) || e.size%unit || e.size/unit>UINT32_MAX) return BIND_INVALID;
            }
        }
        total+=count;
    }
    // Pipeline checks follow all group checks, as when every group was created
    // before the draw.
    for (uint32_t g=0;g<groups;++g) {
        int status=zenit_d12_render_validate_bindings(pipeline,g,group_entries[g],group_counts[g]); if (status) return status;
    }
    D12DrawSetup d; int status=setup_draw(pass,pipeline,draw,d); if (status) return status;
    D12BoundState bound[4*128+33]; uint32_t ns=d.unique;
    for (uint32_t i=0;i<d.unique;++i) { bound[i].buffer=d.buffers[i]; bound[i].texture=nullptr; bound[i].state=d.states[i]; }
    for (uint32_t g=0;g<groups;++g) for (uint32_t i=0;i<group_counts[g];++i) {
        const auto &e=group_entries[g][i]; uint32_t kind=0;
        for (uint32_t j=0;j<nb;++j) if (layout_bindings[j].group==g && layout_bindings[j].binding==e.binding) kind=layout_bindings[j].kind;
        if (bind_state(pass,bound,ns,e.buffer,e.view?e.view->texture:nullptr,kind)) return 1;
    }
    if (retain_reserve(commands,total+d.unique+1)) return 2;
    ID3D12DescriptorHeap *heaps[2]={}; uint32_t bases[2]={};
    for (uint32_t t=0;t<2;++t) {
        uint32_t need=0; for (uint32_t g=0;g<groups;++g) need+=descriptors[g][t];
        if (!need) continue;
        if (reserve_draw_descriptors(commands,t,need,&heaps[t],&bases[t])) return 2;
        heaps[t]->Release(); // The command's page list owns the heap.
    }
    retain_push(commands,RETAIN_PIPELINE,pipeline); zenit_d12_render_pipeline_retain(pipeline);
    for (uint32_t i=0;i<d.unique;++i) { retain_push(commands,RETAIN_BUFFER,d.buffers[i]); InterlockedIncrement(&d.buffers[i]->refs); }
    D3D12_GPU_DESCRIPTOR_HANDLE tables[4][2]={};
    uint32_t increments[2]={device->raw->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV),
        device->raw->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER)};
    uint32_t offsets[2]={bases[0],bases[1]};
    for (uint32_t g=0;g<groups;++g) {
        for (uint32_t t=0;t<2;++t) if (descriptors[g][t]) {
            auto gpu=heaps[t]->GetGPUDescriptorHandleForHeapStart(); gpu.ptr+=UINT64(offsets[t])*increments[t]; tables[g][t]=gpu;
        }
        uint32_t slots[2]={};
        // Root-table range order, as bind_group_create lays its heap out.
        for (uint32_t i=0;i<nb;++i) if (layout_bindings[i].group==g) for (uint32_t a=0;a<layout_bindings[i].count;++a) {
            const auto &b=layout_bindings[i]; const ZenitD12BindingEntry *e=nullptr;
            for (uint32_t j=0;j<group_counts[g];++j) if (group_entries[g][j].binding==b.binding && group_entries[g][j].array_index==a) e=&group_entries[g][j];
            uint32_t t=b.kind==4;
            auto handle=heaps[t]->GetCPUDescriptorHandleForHeapStart(); handle.ptr+=SIZE_T(offsets[t]+slots[t]++)*increments[t];
            if (e->view) {
                view_retain(e->view); retain_push(commands,RETAIN_VIEW,e->view);
                device->raw->CopyDescriptorsSimple(1,handle,e->view->heap->GetCPUDescriptorHandleForHeapStart(),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
                continue;
            }
            if (e->sampler) {
                InterlockedIncrement(&e->sampler->refs); retain_push(commands,RETAIN_SAMPLER,e->sampler);
                device->raw->CopyDescriptorsSimple(1,handle,e->sampler->heap->GetCPUDescriptorHandleForHeapStart(),D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER);
                continue;
            }
            InterlockedIncrement(&e->buffer->refs); retain_push(commands,RETAIN_BUFFER,e->buffer);
            uint32_t unit=e->stride?e->stride:4;
            if (b.kind==0) {
                D3D12_CONSTANT_BUFFER_VIEW_DESC v={}; v.BufferLocation=e->buffer->raw->GetGPUVirtualAddress()+e->offset;
                v.SizeInBytes=UINT((e->size+255)&~uint64_t(255)); device->raw->CreateConstantBufferView(&v,handle);
            } else if (b.kind==2) {
                D3D12_SHADER_RESOURCE_VIEW_DESC v={}; v.ViewDimension=D3D12_SRV_DIMENSION_BUFFER;
                v.Shader4ComponentMapping=D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
                v.Format=e->stride?DXGI_FORMAT_UNKNOWN:DXGI_FORMAT_R32_TYPELESS;
                v.Buffer.FirstElement=e->offset/unit; v.Buffer.NumElements=UINT(e->size/unit); v.Buffer.StructureByteStride=e->stride;
                v.Buffer.Flags=e->stride?D3D12_BUFFER_SRV_FLAG_NONE:D3D12_BUFFER_SRV_FLAG_RAW;
                device->raw->CreateShaderResourceView(e->buffer->raw,&v,handle);
            } else {
                D3D12_UNORDERED_ACCESS_VIEW_DESC v={}; v.ViewDimension=D3D12_UAV_DIMENSION_BUFFER;
                v.Format=e->stride?DXGI_FORMAT_UNKNOWN:DXGI_FORMAT_R32_TYPELESS;
                v.Buffer.FirstElement=e->offset/unit; v.Buffer.NumElements=UINT(e->size/unit); v.Buffer.StructureByteStride=e->stride;
                v.Buffer.Flags=e->stride?D3D12_BUFFER_UAV_FLAG_NONE:D3D12_BUFFER_UAV_FLAG_RAW;
                device->raw->CreateUnorderedAccessView(e->buffer->raw,nullptr,&v,handle);
            }
        }
        offsets[0]+=descriptors[g][0]; offsets[1]+=descriptors[g][1];
    }
    emit_draw(pass,pipeline,draw,d,heaps,tables,groups,bound,ns);
#ifdef ZENIT_D12_TEST
    InterlockedIncrement(&direct_draws);
#endif
    return 0;
}
extern "C" int zenit_d12_render_pass_end(ZenitD12RenderPass *pass) {
    if (!pass || pass->commands->pass!=pass) return 1;
    auto commands=pass->commands;
    for (uint32_t i=0;i<pass->read_count;++i)
        transition_texture(commands->list,pass->read_textures[i],D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,
            D3D12_RESOURCE_STATES(D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE | D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE),D3D12_RESOURCE_STATE_COMMON);
    for (uint32_t i=0;i<pass->resources->count;++i) {
        auto &a=pass->resources->attachments[i];
        if (a.resolve) {
            uint32_t src=a.mip+a.layer*a.texture->mips,dst=a.resolve_mip+a.resolve_layer*a.resolve->mips;
            transition_texture(commands->list,a.texture,src,D3D12_RESOURCE_STATE_RENDER_TARGET,D3D12_RESOURCE_STATE_RESOLVE_SOURCE);
            transition_texture(commands->list,a.resolve,dst,D3D12_RESOURCE_STATE_COMMON,D3D12_RESOURCE_STATE_RESOLVE_DEST);
            commands->list->ResolveSubresource(a.resolve->raw,dst,a.texture->raw,src,a.texture->format);
            transition_texture(commands->list,a.resolve,dst,D3D12_RESOURCE_STATE_RESOLVE_DEST,D3D12_RESOURCE_STATE_COMMON);
            transition_texture(commands->list,a.texture,src,D3D12_RESOURCE_STATE_RESOLVE_SOURCE,D3D12_RESOURCE_STATE_RENDER_TARGET);
        }
        if (a.store_op==1) discard_attachment(commands->list,a);
        transition_texture(commands->list,a.texture,a.mip+a.layer*a.texture->mips,D3D12_RESOURCE_STATE_RENDER_TARGET,D3D12_RESOURCE_STATE_COMMON);
    }
    auto &depth=pass->resources->depth;
    if (depth.texture) for (uint32_t plane=0;plane<depth_planes(depth.texture->format);++plane) {
        if ((plane?depth.stencil_store:depth.depth_store)==1) discard_depth(commands->list,depth,plane);
        transition_texture(commands->list,depth.texture,depth_subresource(depth,plane),depth_state(depth,plane),D3D12_RESOURCE_STATE_COMMON);
    }
    commands->pass=nullptr; free(pass); zenit_d12_commands_release(commands); return 0;
}
