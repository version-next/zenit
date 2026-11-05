// ZENIT_GPU_LEDGER=1: live D3D12 resource bytes by kind plus process and DXGI
// memory counters, printed by a background thread every two seconds (idle
// windows present nothing, so a per-frame hook would go quiet exactly when the
// resident set matters). Sizes are the allocation sizes the driver reports.
// Disabled, every hook is one cached flag test.
#pragma once
#include <windows.h>
#include <d3d12.h>
#include <dxgi1_4.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>

enum D12LedgerKind : uint8_t {
    LK_NONE, LK_BUF_UPLOAD, LK_BUF_READBACK, LK_BUF_DEFAULT,
    LK_TEX_TARGET, LK_TEX_SAMPLED, LK_TEX_DEPTH, LK_SWAPCHAIN, LK_SPRITE_CHAIN,
    LK_POOL_READBACK, LK_COUNT
};
static const char *const d12_ledger_names[LK_COUNT] = {
    "none", "buf_upload", "buf_readback", "buf_default",
    "tex_target", "tex_sampled", "tex_depth", "swapchain", "sprite_chain", "pool_readback",
};
struct D12LedgerEntry { const void *key; uint64_t bytes; uint32_t width, height; uint32_t format; D12LedgerKind kind; char label[40]; };
static constexpr uint32_t D12_LEDGER_CAPACITY = 8192;
struct D12Ledger {
    volatile LONG64 bytes[LK_COUNT];
    volatile LONG count[LK_COUNT];
    SRWLOCK lock;
    D12LedgerEntry entries[D12_LEDGER_CAPACITY];
    uint32_t entry_count;
    ID3D12Device *device;
};
static D12Ledger g_d12_ledger;

static bool d12_ledger_enabled() {
    static LONG state = 0; // 0 unknown, 1 off, 2 on
    LONG s = InterlockedCompareExchange(&state, 0, 0);
    if (!s) {
        char v[8] = {};
        s = (GetEnvironmentVariableA("ZENIT_GPU_LEDGER", v, sizeof(v)) && (v[0] == '1' || v[0] == '2')) ? 2 : 1;
        InterlockedExchange(&state, s);
    }
    return s == 2;
}

static uint64_t d12_ledger_allocation_bytes(ID3D12Device *device, const D3D12_RESOURCE_DESC &desc) {
    if (!device) return 0;
    const D3D12_RESOURCE_ALLOCATION_INFO info = device->GetResourceAllocationInfo(0, 1, &desc);
    return info.SizeInBytes == UINT64_MAX ? 0 : info.SizeInBytes;
}

static void d12_ledger_add(const void *key, D12LedgerKind kind, uint64_t bytes, uint32_t w, uint32_t h, uint32_t format) {
    if (!kind || !bytes) return;
    InterlockedAdd64(&g_d12_ledger.bytes[kind], (LONG64)bytes);
    InterlockedIncrement(&g_d12_ledger.count[kind]);
    AcquireSRWLockExclusive(&g_d12_ledger.lock);
    if (g_d12_ledger.entry_count < D12_LEDGER_CAPACITY)
        g_d12_ledger.entries[g_d12_ledger.entry_count++] = {key, bytes, w, h, format, kind};
    ReleaseSRWLockExclusive(&g_d12_ledger.lock);
}

// Names a live entry after its creator's descriptor label (copied; labels may
// live in stack buffers).
static void d12_ledger_label(const void *key, const char *label, size_t len) {
    if (!label || !len || !d12_ledger_enabled()) return;
    AcquireSRWLockExclusive(&g_d12_ledger.lock);
    for (uint32_t i = 0; i < g_d12_ledger.entry_count; ++i) {
        D12LedgerEntry &e = g_d12_ledger.entries[i];
        if (e.key != key) continue;
        size_t n = len < sizeof(e.label) - 1 ? len : sizeof(e.label) - 1;
        // "Zenit.Image.Atlas[3]" groups with its siblings.
        for (size_t c = 0; c < n; ++c) if (label[c] == '[') { n = c; break; }
        memcpy(e.label, label, n); e.label[n] = 0;
        break;
    }
    ReleaseSRWLockExclusive(&g_d12_ledger.lock);
}

static void d12_ledger_remove(const void *key, D12LedgerKind kind, uint64_t bytes) {
    if (!kind || !bytes) return;
    InterlockedAdd64(&g_d12_ledger.bytes[kind], -(LONG64)bytes);
    InterlockedDecrement(&g_d12_ledger.count[kind]);
    AcquireSRWLockExclusive(&g_d12_ledger.lock);
    for (uint32_t i = 0; i < g_d12_ledger.entry_count; ++i) {
        if (g_d12_ledger.entries[i].key == key) {
            g_d12_ledger.entries[i] = g_d12_ledger.entries[--g_d12_ledger.entry_count];
            break;
        }
    }
    ReleaseSRWLockExclusive(&g_d12_ledger.lock);
}

// PROCESS_MEMORY_COUNTERS_EX2 (Windows 10 1809+), declared here because older
// MinGW headers lack it.
struct D12ProcessCounters {
    DWORD cb, PageFaultCount;
    SIZE_T PeakWorkingSetSize, WorkingSetSize, QuotaPeakPagedPoolUsage, QuotaPagedPoolUsage,
        QuotaPeakNonPagedPoolUsage, QuotaNonPagedPoolUsage, PagefileUsage, PeakPagefileUsage, PrivateUsage;
    ULONG64 PrivateWorkingSetSize, SharedCommitUsage;
};
extern "C" BOOL WINAPI K32GetProcessMemoryInfo(HANDLE, void *, DWORD);

static double d12_mib(uint64_t bytes) { return (double)bytes / (1024.0 * 1024.0); }

static void d12_ledger_dump(IDXGIAdapter3 *adapter) {
    D12ProcessCounters pc = {};
    pc.cb = sizeof(pc);
    if (!K32GetProcessMemoryInfo(GetCurrentProcess(), &pc, sizeof(pc))) {
        pc = {}; pc.cb = 88; // PROCESS_MEMORY_COUNTERS_EX: no private working set.
        K32GetProcessMemoryInfo(GetCurrentProcess(), &pc, 88);
    }
    DXGI_QUERY_VIDEO_MEMORY_INFO local = {}, nonlocal = {};
    if (adapter) {
        adapter->QueryVideoMemoryInfo(0, DXGI_MEMORY_SEGMENT_GROUP_LOCAL, &local);
        adapter->QueryVideoMemoryInfo(0, DXGI_MEMORY_SEGMENT_GROUP_NON_LOCAL, &nonlocal);
    }
    uint64_t total = 0;
    char kinds[512]; int at = 0;
    for (int k = 1; k < LK_COUNT; ++k) {
        const LONG64 b = InterlockedCompareExchange64(&g_d12_ledger.bytes[k], 0, 0);
        const LONG n = InterlockedCompareExchange(&g_d12_ledger.count[k], 0, 0);
        if (!n) continue;
        total += (uint64_t)b;
        at += snprintf(kinds + at, sizeof(kinds) - at, " %s=%ld/%.1f", d12_ledger_names[k], (long)n, d12_mib((uint64_t)b));
        if (at >= (int)sizeof(kinds)) break;
    }
    fprintf(stderr, "[gpu-ledger] private_ws=%.1f private=%.1f ws=%.1f dxgi_local=%.1f dxgi_nonlocal=%.1f resources=%.1f |%s\n",
        d12_mib(pc.PrivateWorkingSetSize), d12_mib(pc.PrivateUsage), d12_mib(pc.WorkingSetSize),
        d12_mib(local.CurrentUsage), d12_mib(nonlocal.CurrentUsage), d12_mib(total), kinds);
    // Live resources grouped by kind, extent and format, largest groups first,
    // so a per-window cost is named rather than inferred.
    struct Group { D12LedgerKind kind; uint32_t width, height, format, count; uint64_t bytes; const char *label; };
    static Group groups[256];
    uint32_t group_count = 0;
    AcquireSRWLockShared(&g_d12_ledger.lock);
    for (uint32_t i = 0; i < g_d12_ledger.entry_count; ++i) {
        const D12LedgerEntry &e = g_d12_ledger.entries[i];
        // Buffers group by kind only: their sizes vary per allocation.
        const bool buffer = e.kind <= LK_BUF_DEFAULT || e.kind == LK_POOL_READBACK;
        const uint32_t w = buffer ? 0 : e.width, h = buffer ? 0 : e.height, f = buffer ? 0 : e.format;
        uint32_t g = 0;
        while (g < group_count && !(groups[g].kind == e.kind && groups[g].width == w && groups[g].height == h && groups[g].format == f && strcmp(groups[g].label, e.label) == 0)) ++g;
        if (g == group_count) { if (group_count == 256) continue; groups[group_count++] = {e.kind, w, h, f, 0, 0, e.label}; }
        groups[g].count += 1; groups[g].bytes += e.bytes;
    }
    ReleaseSRWLockShared(&g_d12_ledger.lock);
    for (uint32_t a = 0; a < group_count; ++a)
        for (uint32_t b = a + 1; b < group_count; ++b)
            if (groups[b].bytes > groups[a].bytes) { Group t = groups[a]; groups[a] = groups[b]; groups[b] = t; }
    for (uint32_t j = 0; j < group_count && j < 16; ++j)
        fprintf(stderr, "[gpu-ledger]   %s %s %ux%u fmt=%u x%u = %.2f MiB\n", d12_ledger_names[groups[j].kind],
            groups[j].label[0] ? groups[j].label : "-", groups[j].width, groups[j].height, groups[j].format,
            groups[j].count, d12_mib(groups[j].bytes));
    fflush(stderr);
}

// ZENIT_GPU_LEDGER=2: where the private working set lives. Every private
// (unshared) resident page is attributed to its allocation region: an image
// (module), a mapped file/section, a process heap, or other private memory
// (VirtualAlloc: Zig page allocator, graphics driver, UMA GPU allocations).
struct D12WsBlock { ULONG_PTR flags_and_page; };
struct D12WsInfo { ULONG_PTR count; D12WsBlock blocks[1]; };
extern "C" BOOL WINAPI K32QueryWorkingSet(HANDLE, void *, DWORD);
extern "C" DWORD WINAPI K32GetMappedFileNameA(HANDLE, void *, char *, DWORD);
struct D12WsRegion { uintptr_t base; uint32_t type; uint64_t pages; };

static int d12_cmp_uptr(const void *a, const void *b) {
    const uintptr_t x = *(const uintptr_t *)a, y = *(const uintptr_t *)b;
    return x < y ? -1 : x > y ? 1 : 0;
}

static void d12_ledger_dump_working_set() {
    SIZE_T size = sizeof(ULONG_PTR) + sizeof(D12WsBlock) * 262144;
    D12WsInfo *info = nullptr;
    for (int attempt = 0; attempt < 4; ++attempt) {
        info = (D12WsInfo *)VirtualAlloc(nullptr, size, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
        if (!info) return;
        if (K32QueryWorkingSet(GetCurrentProcess(), info, (DWORD)size)) break;
        const ULONG_PTR need = info->count;
        VirtualFree(info, 0, MEM_RELEASE); info = nullptr;
        if (GetLastError() != ERROR_BAD_LENGTH) return;
        size = sizeof(ULONG_PTR) + sizeof(D12WsBlock) * (need + 65536);
    }
    if (!info) return;
    // Private pages (Shared bit 8 clear), as page addresses, sorted.
    uintptr_t *pages = (uintptr_t *)VirtualAlloc(nullptr, info->count * sizeof(uintptr_t) + 64, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    if (!pages) { VirtualFree(info, 0, MEM_RELEASE); return; }
    size_t n = 0;
    for (ULONG_PTR i = 0; i < info->count; ++i) {
        const ULONG_PTR v = info->blocks[i].flags_and_page;
        if (v & (1u << 8)) continue;
        pages[n++] = v & ~(uintptr_t)0xFFF;
    }
    qsort(pages, n, sizeof(uintptr_t), d12_cmp_uptr);
    static D12WsRegion regions[4096];
    uint32_t region_count = 0;
    uint64_t by_type[4] = {}; // image, mapped, heap, other private
    HANDLE heaps[64]; DWORD heap_count = GetProcessHeaps(64, heaps);
    MEMORY_BASIC_INFORMATION mbi = {}; uintptr_t region_end = 0; uintptr_t alloc_base = 0; uint32_t type = 3;
    for (size_t i = 0; i < n; ++i) {
        const uintptr_t page = pages[i];
        if (page >= region_end) {
            if (!VirtualQuery((void *)page, &mbi, sizeof(mbi))) continue;
            region_end = (uintptr_t)mbi.BaseAddress + mbi.RegionSize;
            alloc_base = (uintptr_t)mbi.AllocationBase;
            type = mbi.Type == MEM_IMAGE ? 0 : mbi.Type == MEM_MAPPED ? 1 : 3;
            if (type == 3) for (DWORD h = 0; h < heap_count && h < 64; ++h) if ((uintptr_t)heaps[h] == alloc_base) type = 2;
        }
        by_type[type] += 1;
        uint32_t r = 0;
        while (r < region_count && regions[r].base != alloc_base) ++r;
        if (r == region_count) { if (region_count == 4096) continue; regions[region_count++] = {alloc_base, type, 0}; }
        regions[r].pages += 1;
    }
    // Process heaps (CRT malloc, i.e. Zig's c_allocator, lives in one): bytes in
    // live blocks vs committed, the difference being fragmentation.
    struct D12HeapSummary { DWORD cb; SIZE_T allocated, committed, reserved, max_reserve; };
    typedef BOOL (WINAPI *HeapSummaryFn)(HANDLE, DWORD, D12HeapSummary *);
    static HeapSummaryFn heap_summary = (HeapSummaryFn)(void *)GetProcAddress(GetModuleHandleA("kernel32.dll"), "HeapSummary");
    for (DWORD h = 0; heap_summary && h < heap_count && h < 64; ++h) {
        D12HeapSummary hs = {}; hs.cb = sizeof(hs);
        if (!heap_summary(heaps[h], 0, &hs) || hs.committed < (1u << 20)) continue;
        fprintf(stderr, "[ws-ledger] heap %p allocated=%.1f committed=%.1f reserved=%.1f%s\n", (void *)heaps[h],
            d12_mib(hs.allocated), d12_mib(hs.committed), d12_mib(hs.reserved), heaps[h] == GetProcessHeap() ? " (process)" : "");
    }
    static const char *const type_names[4] = {"image", "mapped", "heap", "private"};
    fprintf(stderr, "[ws-ledger] private_resident=%.1f image=%.1f mapped=%.1f heap=%.1f other_private=%.1f regions=%u\n",
        d12_mib((uint64_t)n * 4096), d12_mib(by_type[0] * 4096), d12_mib(by_type[1] * 4096), d12_mib(by_type[2] * 4096), d12_mib(by_type[3] * 4096), region_count);
    // Largest regions first, named where Windows can name them.
    for (int shown = 0; shown < 40; ++shown) {
        uint32_t best = UINT32_MAX;
        for (uint32_t r = 0; r < region_count; ++r) if (regions[r].pages && (best == UINT32_MAX || regions[r].pages > regions[best].pages)) best = r;
        if (best == UINT32_MAX) break;
        char name[MAX_PATH] = "-";
        if (regions[best].type == 0) GetModuleFileNameA((HMODULE)regions[best].base, name, sizeof(name));
        else if (regions[best].type == 1) K32GetMappedFileNameA(GetCurrentProcess(), (void *)regions[best].base, name, sizeof(name));
        const char *leaf = strrchr(name, '\\'); leaf = leaf ? leaf + 1 : name;
        // The allocation's committed extent and protection: GPU resources on a
        // UMA adapter show their exact allocation sizes (see [gpu-ledger]).
        uint64_t committed = 0; DWORD protect = 0;
        for (uintptr_t at = regions[best].base;;) {
            MEMORY_BASIC_INFORMATION q = {};
            if (!VirtualQuery((void *)at, &q, sizeof(q)) || (uintptr_t)q.AllocationBase != regions[best].base) break;
            if (q.State == MEM_COMMIT) { committed += q.RegionSize; if (!protect) protect = q.Protect; }
            at = (uintptr_t)q.BaseAddress + q.RegionSize;
        }
        fprintf(stderr, "[ws-ledger]   %s %.1f/%.2f MiB prot=0x%lx base=%p %s\n", type_names[regions[best].type], d12_mib(regions[best].pages * 4096),
            d12_mib(committed), (unsigned long)protect, (void *)regions[best].base, leaf);
        regions[best].pages = 0;
    }
    fflush(stderr);
    VirtualFree(pages, 0, MEM_RELEASE);
    VirtualFree(info, 0, MEM_RELEASE);
}

static DWORD WINAPI d12_ledger_main(void *) {
    IDXGIAdapter3 *adapter = nullptr;
    if (g_d12_ledger.device) {
        IDXGIFactory4 *factory = nullptr;
        if (SUCCEEDED(CreateDXGIFactory1(IID_IDXGIFactory4, (void **)&factory))) {
            factory->EnumAdapterByLuid(g_d12_ledger.device->GetAdapterLuid(), IID_IDXGIAdapter3, (void **)&adapter);
            factory->Release();
        }
    }
    char level[4] = {};
    GetEnvironmentVariableA("ZENIT_GPU_LEDGER", level, sizeof(level));
    for (uint32_t tick = 1;; ++tick) {
        Sleep(2000);
        d12_ledger_dump(adapter);
        if (level[0] == '2' && tick % 5 == 0) d12_ledger_dump_working_set();
    }
}

static void d12_ledger_start(ID3D12Device *device) {
    if (!d12_ledger_enabled()) return;
    static volatile LONG started = 0;
    if (InterlockedExchange(&started, 1)) return;
    g_d12_ledger.device = device;
    device->AddRef();
    HANDLE thread = CreateThread(nullptr, 0, d12_ledger_main, nullptr, 0, nullptr);
    if (thread) CloseHandle(thread);
}
