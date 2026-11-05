#include "dual_source_validation.h"
// D3D11 implementation of the shared renderer ABI. The d12 prefix is an ABI
// name only: this translation unit uses D3D11 and DXGI exclusively.
#include "d3d12_resources.h"
#include <algorithm>
#include <cctype>
#include <climits>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <d3d11.h>
#include <d3d11_1.h>
#include <d3d11shader.h>
#include "dxbc_cache.h"
#include <d3dcompiler.h>
#include <dcomp.h>
#include <dwmapi.h>
#include <dxgi1_2.h>
#include "dxgi_driver_info.h"
#include <new>
#include <string>
#include <unordered_map>
#include <vector>
#include <windows.h>

template <class T> struct D11Com {
  T *p = nullptr;
  D11Com() = default;
  D11Com(T *v) : p(v) {}
  D11Com(const D11Com &v) : p(v.p) {
    if (p)
      p->AddRef();
  }
  D11Com(D11Com &&v) noexcept : p(v.p) { v.p = nullptr; }
  D11Com &operator=(D11Com v) {
    std::swap(p, v.p);
    return *this;
  }
  ~D11Com() {
    if (p)
      p->Release();
  }
  T *operator->() const { return p; }
  operator T *() const { return p; }
  T **put() {
    if (p)
      p->Release();
    p = nullptr;
    return &p;
  }
};
struct D11CachedUniform {
  std::vector<unsigned char> bytes;
  D11Com<ID3D11Buffer> buffer;
};
struct D11ExclusiveLock {
  SRWLOCK *lock;
  explicit D11ExclusiveLock(SRWLOCK *value) : lock(value) {
    if (lock) AcquireSRWLockExclusive(lock);
  }
  void release() { if (lock) { ReleaseSRWLockExclusive(lock); lock = nullptr; } }
  ~D11ExclusiveLock() { release(); }
};
struct ZenitD12Device {
  ZenitD12DriverInfo driver_info = {};
  LONG refs = 1;
  D11Com<ID3D11Device> raw;
  D11Com<ID3D11DeviceContext> immediate;
  int software = 0;
  bool failure_reported = false;
  LONG clear_diagnostic_reported = 0;
  // Immutable, bounded CPU-upload constants. Commands retain their own copies
  // of the COM references, so FIFO eviction cannot invalidate recorded draws.
  SRWLOCK uniform_lock = SRWLOCK_INIT;
  std::vector<D11CachedUniform> uniforms;
  // Immutable {first_vertex, first_instance} constants shared by every draw
  // with the same pair (almost always {0,0}); creating one per draw dominated
  // D3D11 recording on virtualized drivers. Guarded by uniform_lock.
  std::unordered_map<uint64_t, D11Com<ID3D11Buffer>> draw_info;
  uint64_t uniform_buffer_creations = 0;
};
struct ZenitD12Buffer {
  LONG refs = 1;
  ZenitD12Device *owner;
  D11Com<ID3D11Buffer> raw;
  std::vector<unsigned char> host;
  uint64_t size;
  uint32_t usage;
  ~ZenitD12Buffer() { zenit_d12_device_release(owner); }
};
struct ZenitD12Texture {
  LONG refs = 1;
  ZenitD12Device *owner;
  D11Com<ID3D11Resource> raw;
  uint32_t dimension, width, height, depth, mips, usage, samples;
  DXGI_FORMAT format;
  ~ZenitD12Texture() { zenit_d12_device_release(owner); }
};
struct ZenitD12View {
  LONG refs = 1;
  ZenitD12Texture *texture;
  D11Com<ID3D11ShaderResourceView> srv;
  D11Com<ID3D11UnorderedAccessView> uav;
  uint32_t dimension;
  bool storage = false;
  ~ZenitD12View() { zenit_d12_texture_release(texture); }
};
struct ZenitD12Sampler {
  LONG refs = 1;
  ZenitD12Device *owner;
  D11Com<ID3D11SamplerState> raw;
  uint32_t filter;
  ~ZenitD12Sampler() { zenit_d12_device_release(owner); }
};
struct ZenitD12Shader {
  LONG refs = 1;
  D11Com<ID3DBlob> blob;
  std::string entry;
  uint32_t stage;
  std::vector<ZenitD12ShaderBinding> bindings;
};
struct ZenitD12PipelineLayout {
  LONG refs = 1;
  ZenitD12Device *owner;
  uint32_t groups;
  std::vector<ZenitD12LayoutBinding> bindings;
  ~ZenitD12PipelineLayout() { zenit_d12_device_release(owner); }
};
struct ZenitD12RenderPipeline {
  LONG refs = 1;
  ZenitD12PipelineLayout *layout;
  D11Com<ID3D11VertexShader> vs;
  D11Com<ID3D11PixelShader> ps;
  D11Com<ID3D11InputLayout> input;
  D11Com<ID3D11BlendState> blend;
  D11Com<ID3D11RasterizerState> raster;
  D11Com<ID3D11DepthStencilState> depth;
  ZenitD12RenderInfo info = {};
  uint32_t sample_mask;
  std::string entry;
  std::vector<ZenitD12ShaderBinding> bindings;
  ~ZenitD12RenderPipeline() { zenit_d12_pipeline_layout_release(layout); }
};
struct ZenitD12ComputePipeline {
  LONG refs = 1;
  ZenitD12PipelineLayout *layout;
  D11Com<ID3D11ComputeShader> cs;
  std::vector<ZenitD12ShaderBinding> bindings;
  ~ZenitD12ComputePipeline() { zenit_d12_pipeline_layout_release(layout); }
};
struct ZenitD12BindGroup {
  LONG refs = 1;
  ZenitD12PipelineLayout *layout;
  uint32_t group;
  std::vector<ZenitD12BindingEntry> entries;
  ~ZenitD12BindGroup();
};
struct D11Readback {
  D11Com<ID3D11Resource> staging;
  ZenitD12Buffer *buffer = nullptr;
  uint64_t offset = 0;
  uint32_t pitch = 0, row_bytes = 0, height = 0, depth = 0;
  bool texture = false;
};
struct D11StorageSnapshot {
  // Retain the native identity so a released wrapper's address cannot make a
  // different buffer appear to be the same source during this command.
  const ZenitD12Buffer *source = nullptr;
  D11Com<ID3D11Buffer> source_native, buffer;
  uint64_t offset = 0, size = 0, source_version = 0;
  uint32_t stride = 0, kind = 0;
  std::vector<unsigned char> bytes;
};
// Mapped storage bindings (per-draw instance data) recorded into one buffer per
// stride per command: each draw's bytes are copied at record time (the same
// snapshot guarantee as a private buffer) and read through an offset view.
// One CreateBuffer per arena instead of one per draw; identical payloads from
// the same source range are found by hash instead of a linear memcmp scan.
struct D11ArenaSegment {
  const void *source;
  uint64_t offset, size, first;
};
struct D11StorageArena {
  uint32_t stride = 0;
  uint64_t capacity = 0;
  D11Com<ID3D11Buffer> buffer;
  std::vector<unsigned char> bytes;
  std::unordered_multimap<uint64_t, D11ArenaSegment> segments;
};
static void arena_upload(ZenitD12Commands *c, ID3D11DeviceContext *immediate);
struct D11BufferWriteVersion {
  D11Com<ID3D11Buffer> source;
  uint64_t version = 0;
};
struct ZenitD12Commands {
  LONG refs = 1;
  ZenitD12Device *owner;
  D11Com<ID3D11DeviceContext> context;
  D11Com<ID3D11DeviceContext1> context1;
  D11Com<ID3D11CommandList> list;
  // Each command owns its query trio independently of the submitting queue.
  D11Com<ID3D11Query> timestamp_disjoint, timestamp_start, timestamp_end;
  std::vector<D11Readback> readbacks;
  std::vector<D11StorageSnapshot> storage_snapshots;
  std::vector<D11StorageArena> arenas;
  uint32_t arena_segments = 0;
  // Mapped snapshots by payload hash (index into storage_snapshots).
  std::unordered_multimap<uint64_t, size_t> snapshot_index;
  std::vector<D11BufferWriteVersion> buffer_write_versions;
  bool finished = false, submitted = false, pass = false;
  bool timestamps_ended = false, gpu_completed = false, elapsed_cached = false;
  uint64_t elapsed_micros = 0;
  uint32_t uniform_allocations = 0, uniform_reuses = 0, uniform_device_reuses = 0;
  ~ZenitD12Commands() {
    for (auto &r : readbacks)
      zenit_d12_buffer_release(r.buffer);
    zenit_d12_device_release(owner);
  }
};
struct D11Submission {
  uint64_t serial;
  D11Com<ID3D11Query> query;
  ZenitD12Commands *commands;
};
struct ZenitD12Queue {
  ZenitD12Device *owner;
  uint64_t next = 1, completed = 0;
  std::vector<D11Submission> pending;
};
struct ZenitD12RenderPass {
  ZenitD12Commands *commands;
  std::vector<ZenitD12ColorAttachment> colors;
  ZenitD12DepthAttachment depth = {};
  std::vector<D11Com<ID3D11RenderTargetView>> rtvs;
  D11Com<ID3D11DepthStencilView> dsv;
  std::vector<D3D11_RECT> regions;
  bool regions_set = false;
  uint32_t width = 0, height = 0;
};
struct ZenitD12Surface {
  ZenitD12Queue *queue;
  D11Com<IDXGISwapChain1> swap;
  uint32_t width, height, format;
  ZenitD12Texture *acquired = nullptr;
  HWND hwnd = nullptr;
  D11Com<IDCompositionDevice> composition;
  D11Com<IDCompositionTarget> composition_target;
  D11Com<IDCompositionVisual> composition_root, composition_parts[4];
  RECT caption_clip = {};
  bool clip_valid = false;
  ~ZenitD12Surface();
};
static constexpr uint32_t MAP_READ = 1, MAP_WRITE = 2, COPY_SRC = 4,
                          COPY_DST = 8, INDEX = 16, VERTEX = 32, UNIFORM = 64,
                          STORAGE = 128;
// CPU wall-clock attribution for diagnostics only; never GPU timing samples.
static bool cpu_timing_trace_enabled() {
  static const bool enabled = [] {
    char flag[2] = {};
    return GetEnvironmentVariableA("ZENIT_WINDOWS_FRAME_TIMING", flag,
                                   sizeof(flag)) && flag[0] == '1';
  }();
  return enabled;
}
static uint64_t cpu_time_micros() {
  static const uint64_t frequency = [] {
    LARGE_INTEGER value = {};
    return QueryPerformanceFrequency(&value) ? (uint64_t)value.QuadPart : 0;
  }();
  LARGE_INTEGER value = {};
  if (!frequency || !QueryPerformanceCounter(&value))
    return 0;
  const uint64_t ticks = (uint64_t)value.QuadPart;
  return ticks / frequency * 1000000 + ticks % frequency * 1000000 / frequency;
}
// Per-entry CPU profile (ZENIT_WINDOWS_FRAME_TIMING=1 only): calls and time per
// exported entry, printed and reset at each Present. Off: one flag check.
struct D11ProfSlot { const char *name; uint64_t us; uint32_t calls; };
static D11ProfSlot d11_prof[48];
static int d11_prof_count;
static uint64_t d11_prof_arena_bytes, d11_prof_arena_hits, d11_prof_arena_max, d11_prof_arena_max_stride, d11_prof_arena_max_source, d11_prof_arena_max_offset, d11_prof_arena_big;
struct D11Prof {
  D11ProfSlot *slot = nullptr;
  uint64_t start = 0;
  D11Prof(const char *name) {
    if (!cpu_timing_trace_enabled()) return;
    for (int i = 0; i < d11_prof_count; ++i)
      if (d11_prof[i].name == name) { slot = &d11_prof[i]; break; }
    if (!slot && d11_prof_count < 48) { slot = &d11_prof[d11_prof_count++]; slot->name = name; }
    start = cpu_time_micros();
  }
  ~D11Prof() {
    if (!slot) return;
    slot->us += cpu_time_micros() - start;
    slot->calls += 1;
  }
};
static void d11_prof_dump() {
  if (!cpu_timing_trace_enabled() || !d11_prof_count) return;
  std::sort(d11_prof, d11_prof + d11_prof_count, [](const D11ProfSlot &a, const D11ProfSlot &b) { return a.us > b.us; });
  fprintf(stderr, "[d3d11-prof]");
  for (int i = 0; i < d11_prof_count && i < 10; ++i)
    if (d11_prof[i].calls) fprintf(stderr, " %s=%lluus/%u", d11_prof[i].name, (unsigned long long)d11_prof[i].us, d11_prof[i].calls);
  fprintf(stderr, " arena_bytes=%llu arena_max=%llu arena_hits=%llu max_stride=%llu max_source=%llu max_offset=%llu big=%llu\n", (unsigned long long)d11_prof_arena_bytes,
          (unsigned long long)d11_prof_arena_max, (unsigned long long)d11_prof_arena_hits, (unsigned long long)d11_prof_arena_max_stride,
          (unsigned long long)d11_prof_arena_max_source, (unsigned long long)d11_prof_arena_max_offset, (unsigned long long)d11_prof_arena_big);
  d11_prof_arena_bytes = d11_prof_arena_hits = d11_prof_arena_max = d11_prof_arena_big = 0;
  for (int i = 0; i < d11_prof_count; ++i) { d11_prof[i].us = 0; d11_prof[i].calls = 0; }
}
#define D11_PROF(name) static const char d11_prof_name[] = name; D11Prof d11_prof_scope(d11_prof_name)
struct CpuTraceScope {
  const char *name;
  uint64_t start;
  explicit CpuTraceScope(const char *label)
      : name(label), start(cpu_timing_trace_enabled() ? cpu_time_micros() : 0) {}
  ~CpuTraceScope() {
    if (start) {
      const uint64_t elapsed = cpu_time_micros() - start;
      if (elapsed >= 1000)
        fprintf(stderr, "[d3d11-cpu] %s_us=%llu\n", name,
                (unsigned long long)elapsed);
    }
  }
};

static int result(HRESULT hr) {
  return SUCCEEDED(hr)
             ? 0
             : (hr == DXGI_ERROR_DEVICE_REMOVED || hr == DXGI_ERROR_DEVICE_RESET
                    ? 4
                    : 2);
}
static int device_failure(ZenitD12Device *device, const char *operation,
                          HRESULT hr) {
  HRESULT reason = device->raw->GetDeviceRemovedReason();
  if (!device->failure_reported) {
    device->failure_reported = true;
    fprintf(stderr,
            "[d3d11] %s failed: HRESULT=0x%08lx, removed_reason=0x%08lx\n",
            operation, (unsigned long)hr, (unsigned long)reason);
    // Address-space pressure is particularly relevant to 32-bit guests;
    // record evidence without assuming that every removed device is an OOM.
    MEMORYSTATUSEX memory = {};
    memory.dwLength = sizeof(memory);
    if (GlobalMemoryStatusEx(&memory))
      fprintf(stderr,
              "[d3d11] process virtual memory: available=%llu total=%llu; "
              "physical available=%llu\n",
              (unsigned long long)memory.ullAvailVirtual,
              (unsigned long long)memory.ullTotalVirtual,
              (unsigned long long)memory.ullAvailPhys);
  }
  return FAILED(reason) ? 4 : result(hr);
}
static bool depth_format(DXGI_FORMAT f) {
  return f == DXGI_FORMAT_D16_UNORM || f == DXGI_FORMAT_D32_FLOAT ||
         f == DXGI_FORMAT_D24_UNORM_S8_UINT ||
         f == DXGI_FORMAT_D32_FLOAT_S8X24_UINT;
}
static uint32_t pixel_bytes(DXGI_FORMAT f) {
  switch (f) {
  case DXGI_FORMAT_R32G32B32A32_FLOAT:
  case DXGI_FORMAT_R32G32B32A32_UINT:
  case DXGI_FORMAT_R32G32B32A32_SINT:
    return 16;
  case DXGI_FORMAT_R32G32B32_FLOAT:
  case DXGI_FORMAT_R32G32B32_UINT:
  case DXGI_FORMAT_R32G32B32_SINT:
    return 12;
  case DXGI_FORMAT_R16G16B16A16_FLOAT:
  case DXGI_FORMAT_R16G16B16A16_UNORM:
  case DXGI_FORMAT_R16G16B16A16_UINT:
  case DXGI_FORMAT_R16G16B16A16_SNORM:
  case DXGI_FORMAT_R16G16B16A16_SINT:
  case DXGI_FORMAT_R32G32_FLOAT:
  case DXGI_FORMAT_R32G32_UINT:
  case DXGI_FORMAT_R32G32_SINT:
    return 8;
  case DXGI_FORMAT_R8G8B8A8_UNORM:
  case DXGI_FORMAT_R8G8B8A8_UNORM_SRGB:
  case DXGI_FORMAT_B8G8R8A8_UNORM:
  case DXGI_FORMAT_B8G8R8A8_UNORM_SRGB:
  case DXGI_FORMAT_R8G8B8A8_UINT:
  case DXGI_FORMAT_R8G8B8A8_SNORM:
  case DXGI_FORMAT_R8G8B8A8_SINT:
  case DXGI_FORMAT_R16G16_FLOAT:
  case DXGI_FORMAT_R16G16_UNORM:
  case DXGI_FORMAT_R16G16_UINT:
  case DXGI_FORMAT_R16G16_SNORM:
  case DXGI_FORMAT_R16G16_SINT:
  case DXGI_FORMAT_R32_FLOAT:
  case DXGI_FORMAT_R32_UINT:
  case DXGI_FORMAT_R32_SINT:
  case DXGI_FORMAT_R10G10B10A2_UNORM:
  case DXGI_FORMAT_R10G10B10A2_UINT:
  case DXGI_FORMAT_R11G11B10_FLOAT:
    return 4;
  case DXGI_FORMAT_R8G8_UNORM:
  case DXGI_FORMAT_R8G8_UINT:
  case DXGI_FORMAT_R8G8_SNORM:
  case DXGI_FORMAT_R8G8_SINT:
  case DXGI_FORMAT_R16_FLOAT:
  case DXGI_FORMAT_R16_UNORM:
  case DXGI_FORMAT_R16_UINT:
  case DXGI_FORMAT_R16_SNORM:
  case DXGI_FORMAT_R16_SINT:
    return 2;
  case DXGI_FORMAT_R8_UNORM:
  case DXGI_FORMAT_R8_UINT:
  case DXGI_FORMAT_R8_SNORM:
  case DXGI_FORMAT_R8_SINT:
  case DXGI_FORMAT_A8_UNORM:
    return 1;
  default:
    return 0;
  }
}
static void unbind_srvs(ID3D11DeviceContext *c) {
  ID3D11ShaderResourceView *empty[128] = {};
  c->VSSetShaderResources(0, 128, empty);
  c->PSSetShaderResources(0, 128, empty);
  c->CSSetShaderResources(0, 128, empty);
  ID3D11UnorderedAccessView *u[8] = {};
  c->CSSetUnorderedAccessViews(0, 8, u, nullptr);
}
extern "C" int zenit_d12_device_create(int force_warp, ZenitD12Device **out) {
  if (!out)
    return 1;
  *out = nullptr;
  auto d = new (std::nothrow) ZenitD12Device;
  if (!d)
    return 2;
  D11Com<IDXGIFactory1> factory;
  HRESULT hr = CreateDXGIFactory1(IID_IDXGIFactory1, (void **)factory.put());
  if (FAILED(hr)) {
    delete d;
    return 2;
  }
  UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
  char env[8] = {};
  if (GetEnvironmentVariableA("ZENIT_D3D11_DEBUG", env, sizeof(env)) &&
      env[0] == '1')
    flags |= D3D11_CREATE_DEVICE_DEBUG;
  D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0},
                    selected;
  auto create = [&](IDXGIAdapter *a, D3D_DRIVER_TYPE type) {
    HRESULT h =
        D3D11CreateDevice(a, type, nullptr, flags, levels, 2, D3D11_SDK_VERSION,
                          d->raw.put(), &selected, d->immediate.put());
    if (h == E_INVALIDARG)
      h = D3D11CreateDevice(a, type, nullptr, flags, levels + 1, 1,
                            D3D11_SDK_VERSION, d->raw.put(), &selected,
                            d->immediate.put());
    return h;
  };
  if (!force_warp)
    for (UINT i = 0;; ++i) {
      D11Com<IDXGIAdapter1> a;
      if (FAILED(factory->EnumAdapters1(i, a.put())))
        break;
      DXGI_ADAPTER_DESC1 desc = {};
      if (FAILED(a->GetDesc1(&desc)) ||
          (desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE))
        continue;
      hr = create(a, D3D_DRIVER_TYPE_UNKNOWN);
      char name[512] = {};
      WideCharToMultiByte(CP_UTF8, 0, desc.Description, -1, name, 512, nullptr,
                          nullptr);
      fprintf(
          stderr,
          "[d3d11-adapter] name=%s feature=0x%x software=0 result=0x%08lx\n",
          name, SUCCEEDED(hr) ? selected : 0, (unsigned long)hr);
      if (SUCCEEDED(hr))
        break;
    }
  if (!d->raw) {
    if (!force_warp &&
        GetEnvironmentVariableA("ZENIT_D3D11_REQUIRE_HARDWARE", nullptr, 0)) {
      delete d;
      return 2;
    }
    hr = create(nullptr, D3D_DRIVER_TYPE_WARP);
    d->software = 1;
    fprintf(
        stderr,
        "[d3d11-adapter] name=WARP feature=0x%x software=1 result=0x%08lx\n",
        SUCCEEDED(hr) ? selected : 0, (unsigned long)hr);
  }
  if (FAILED(hr)) {
    delete d;
    return result(hr);
  }
  D11Com<IDXGIDevice> dxgi;
  D11Com<IDXGIAdapter> adapter;
  if (SUCCEEDED(d->raw->QueryInterface(IID_IDXGIDevice, (void **)dxgi.put())) &&
      SUCCEEDED(dxgi->GetAdapter(adapter.put())))
    d->driver_info = zenit_dxgi_driver_info(adapter);
  *out = d;
  return 0;
}
extern "C" void zenit_d12_device_retain(ZenitD12Device *d) {
  if (d)
    InterlockedIncrement(&d->refs);
}
extern "C" void zenit_d12_device_release(ZenitD12Device *d) {
  if (d && InterlockedDecrement(&d->refs) == 0)
    delete d;
}
extern "C" void zenit_d12_device_driver_info(ZenitD12Device *d, ZenitD12DriverInfo *out) {
  *out = d->driver_info;
}
extern "C" int zenit_d12_device_vertex_viewport_index(ZenitD12Device *) {
  return 0;
}
extern "C" int zenit_d12_device_is_software(ZenitD12Device *d) {
  return d ? d->software : 0;
}
extern "C" void *zenit_d12_device_native(ZenitD12Device *d) {
  return d ? d->raw.p : nullptr;
}
// ZENIT_GPU_LEDGER is a D3D12 diagnostic; the shared wrapper labels every
// resource, so this backend accepts and ignores the labels.
extern "C" void zenit_d12_texture_ledger_label(ZenitD12Texture *, const char *, size_t) {}
extern "C" void zenit_d12_buffer_ledger_label(ZenitD12Buffer *, const char *, size_t) {}
extern "C" int zenit_d12_buffer_create(ZenitD12Device *d, uint64_t size,
                                       uint32_t usage, ZenitD12Buffer **out) {
  D11_PROF("buffer_create");
  if (!out)
    return 1;
  *out = nullptr;
  if (!d || !size || size > UINT_MAX || !usage || (usage & ~1023u) ||
      ((usage & MAP_READ) && (usage & ~(MAP_READ | COPY_DST))) ||
      ((usage & MAP_WRITE) && (usage & (MAP_READ | COPY_DST | 512u))))
    return 1;
  auto b = new (std::nothrow) ZenitD12Buffer;
  if (!b)
    return 2;
  b->owner = d;
  zenit_d12_device_retain(d);
  b->size = size;
  b->usage = usage;
  if (usage & (MAP_READ | MAP_WRITE))
    b->host.resize((size_t)size);
  D3D11_BUFFER_DESC desc = {};
  desc.ByteWidth = (UINT)size;
  desc.Usage = D3D11_USAGE_DEFAULT;
  if (usage & INDEX)
    desc.BindFlags |= D3D11_BIND_INDEX_BUFFER;
  if (usage & VERTEX)
    desc.BindFlags |= D3D11_BIND_VERTEX_BUFFER;
  if (usage & STORAGE) {
    desc.BindFlags |= D3D11_BIND_SHADER_RESOURCE;
    if (!(usage & MAP_WRITE))
      desc.BindFlags |= D3D11_BIND_UNORDERED_ACCESS;
    desc.MiscFlags = D3D11_RESOURCE_MISC_BUFFER_ALLOW_RAW_VIEWS;
    desc.ByteWidth = (desc.ByteWidth + 3) & ~3u;
  }
  if ((usage & UNIFORM) && !(usage & (VERTEX | INDEX | STORAGE)) &&
      size <= 65536) {
    desc.ByteWidth = ((UINT)size + 15) & ~15u;
    desc.BindFlags |= D3D11_BIND_CONSTANT_BUFFER;
  }
  HRESULT hr = d->raw->CreateBuffer(&desc, nullptr, b->raw.put());
  if (FAILED(hr)) {
    delete b;
    return result(hr);
  }
  *out = b;
  return 0;
}
extern "C" void zenit_d12_buffer_retain(ZenitD12Buffer *b) {
  if (b)
    InterlockedIncrement(&b->refs);
}
extern "C" void zenit_d12_buffer_release(ZenitD12Buffer *b) {
  D11_PROF("buffer_release");
  if (b && InterlockedDecrement(&b->refs) == 0)
    delete b;
}
extern "C" void *zenit_d12_buffer_mapping(ZenitD12Buffer *b) {
  D11_PROF("buffer_mapping");
  return b && !b->host.empty() ? b->host.data() : nullptr;
}
extern "C" void *zenit_d12_buffer_native(ZenitD12Buffer *b) {
  return b ? b->raw.p : nullptr;
}
extern "C" int zenit_d12_sample_supported(ZenitD12Device *d, uint32_t format,
                                          uint32_t samples) {
  if (!d || !samples)
    return 0;
  UINT quality = 0;
  return SUCCEEDED(d->raw->CheckMultisampleQualityLevels((DXGI_FORMAT)format,
                                                         samples, &quality)) &&
         quality;
}
static DXGI_FORMAT depth_resource(DXGI_FORMAT f) {
  if (f == DXGI_FORMAT_D16_UNORM)
    return DXGI_FORMAT_R16_TYPELESS;
  if (f == DXGI_FORMAT_D32_FLOAT)
    return DXGI_FORMAT_R32_TYPELESS;
  if (f == DXGI_FORMAT_D24_UNORM_S8_UINT)
    return DXGI_FORMAT_R24G8_TYPELESS;
  return DXGI_FORMAT_R32G8X24_TYPELESS;
}
static DXGI_FORMAT depth_srv(DXGI_FORMAT f) {
  if (f == DXGI_FORMAT_D16_UNORM)
    return DXGI_FORMAT_R16_UNORM;
  if (f == DXGI_FORMAT_D32_FLOAT)
    return DXGI_FORMAT_R32_FLOAT;
  if (f == DXGI_FORMAT_D24_UNORM_S8_UINT)
    return DXGI_FORMAT_R24_UNORM_X8_TYPELESS;
  return DXGI_FORMAT_R32_FLOAT_X8X24_TYPELESS;
}
extern "C" int zenit_d12_texture_create(ZenitD12Device *d, uint32_t dimension,
                                        uint32_t width, uint32_t height,
                                        uint32_t depth, uint32_t mips,
                                        uint32_t format, uint32_t usage,
                                        uint32_t samples,
                                        ZenitD12Texture **out) {
  D11_PROF("texture_create");
  if (!out)
    return 1;
  *out = nullptr;
  bool ds = depth_format((DXGI_FORMAT)format);
  if (!d || dimension < 1 || dimension > 3 || !width || !height || !depth ||
      !mips || !usage || (usage & ~31u) ||
      (!pixel_bytes((DXGI_FORMAT)format) && !ds) ||
      !zenit_d12_sample_supported(d, format, samples) || width > 16384 ||
      height > 16384 || depth > 2048 || (dimension == 1 && height != 1) ||
      (dimension == 3 && (width > 2048 || height > 2048 || samples != 1)) ||
      (samples > 1 && (dimension != 2 || mips != 1 || (usage & 14u))) ||
      (ds && (dimension != 2 || !(usage & 16u) || (usage & ~20u))))
    return 1;
  uint32_t largest = std::max(width, height);
  if (dimension == 3)
    largest = std::max(largest, depth);
  uint32_t maxmips = 1;
  while (largest >>= 1)
    ++maxmips;
  if (mips > maxmips)
    return 1;
  auto t = new (std::nothrow) ZenitD12Texture;
  if (!t)
    return 2;
  t->owner = d;
  zenit_d12_device_retain(d);
  t->dimension = dimension;
  t->width = width;
  t->height = height;
  t->depth = depth;
  t->mips = mips;
  t->format = (DXGI_FORMAT)format;
  t->usage = usage;
  t->samples = samples;
  UINT bind = 0;
  if (usage & 4)
    bind |= D3D11_BIND_SHADER_RESOURCE;
  if (usage & 8)
    bind |= D3D11_BIND_UNORDERED_ACCESS;
  if (usage & 16)
    bind |= ds ? D3D11_BIND_DEPTH_STENCIL : D3D11_BIND_RENDER_TARGET;
  DXGI_FORMAT native =
      ds && (usage & 4) ? depth_resource(t->format) : t->format;
  HRESULT hr;
  if (dimension == 1) {
    D3D11_TEXTURE1D_DESC a = {};
    a.Width = width;
    a.MipLevels = mips;
    a.ArraySize = depth;
    a.Format = native;
    a.Usage = D3D11_USAGE_DEFAULT;
    a.BindFlags = bind;
    ID3D11Texture1D *r = nullptr;
    hr = d->raw->CreateTexture1D(&a, nullptr, &r);
    t->raw = D11Com<ID3D11Resource>(r);
  } else if (dimension == 2) {
    D3D11_TEXTURE2D_DESC a = {};
    a.Width = width;
    a.Height = height;
    a.MipLevels = mips;
    a.ArraySize = depth;
    a.Format = native;
    a.SampleDesc.Count = samples;
    a.Usage = D3D11_USAGE_DEFAULT;
    a.BindFlags = bind;
    if (width == height && depth % 6 == 0 && samples == 1)
      a.MiscFlags = D3D11_RESOURCE_MISC_TEXTURECUBE;
    ID3D11Texture2D *r = nullptr;
    hr = d->raw->CreateTexture2D(&a, nullptr, &r);
    t->raw = D11Com<ID3D11Resource>(r);
  } else {
    D3D11_TEXTURE3D_DESC a = {};
    a.Width = width;
    a.Height = height;
    a.Depth = depth;
    a.MipLevels = mips;
    a.Format = native;
    a.Usage = D3D11_USAGE_DEFAULT;
    a.BindFlags = bind;
    ID3D11Texture3D *r = nullptr;
    hr = d->raw->CreateTexture3D(&a, nullptr, &r);
    t->raw = D11Com<ID3D11Resource>(r);
  }
  if (FAILED(hr)) {
    delete t;
    return result(hr);
  }
  *out = t;
  return 0;
}
extern "C" void zenit_d12_texture_retain(ZenitD12Texture *t) {
  if (t)
    InterlockedIncrement(&t->refs);
}
extern "C" void zenit_d12_texture_release(ZenitD12Texture *t) {
  D11_PROF("texture_release");
  if (t && InterlockedDecrement(&t->refs) == 0)
    delete t;
}
static bool region_valid(ZenitD12Texture *t, const ZenitD12TextureRegion *r) {
  if (!t || !r || r->mip >= t->mips || !r->width || !r->height || !r->depth ||
      t->samples != 1 || !pixel_bytes(t->format))
    return false;
  uint32_t w = std::max(1u, t->width >> r->mip),
           h = std::max(1u, t->height >> r->mip),
           z = t->dimension == 3 ? std::max(1u, t->depth >> r->mip) : 1;
  return (t->dimension == 3 ? r->layer == 0 : r->layer < t->depth) &&
         r->x < w && r->width <= w - r->x && r->y < h &&
         r->height <= h - r->y && r->z < z && r->depth <= z - r->z;
}
extern "C" int zenit_d12_texture_layout(ZenitD12Texture *t,
                                        const ZenitD12TextureRegion *r,
                                        uint64_t offset,
                                        ZenitD12TextureLayout *out) {
  if (!out || !region_valid(t, r) || offset % 512)
    return 1;
  uint64_t row = (uint64_t)r->width * pixel_bytes(t->format),
           pitch = (row + 255) & ~uint64_t(255),
           required = pitch * ((uint64_t)r->height * r->depth - 1) + row;
  if (offset > UINT64_MAX - required)
    return 1;
  *out = {offset,   row,       offset + required, (uint32_t)pitch,
          r->width, r->height, r->depth};
  return 0;
}
extern "C" int zenit_d12_view_create(ZenitD12Texture *t, uint32_t dim,
                                     uint32_t mip, uint32_t mips,
                                     uint32_t layer, uint32_t layers,
                                     ZenitD12View **out) {
  D11_PROF("view_create");
  if (!out)
    return 1;
  *out = nullptr;
  if (!t || t->samples != 1 || !(t->usage & 4) || !mips || mip >= t->mips ||
      mips > t->mips - mip || !layers || layer >= t->depth ||
      layers > t->depth - layer)
    return 1;
  D3D11_SHADER_RESOURCE_VIEW_DESC d = {};
  d.Format = depth_format(t->format) ? depth_srv(t->format) : t->format;
  switch (dim) {
  case 1:
    if (t->dimension != 1 || t->depth != 1 || layer || layers != 1)
      return 1;
    d.ViewDimension = D3D11_SRV_DIMENSION_TEXTURE1D;
    d.Texture1D = {mip, mips};
    break;
  case 2:
    if (t->dimension != 2 || t->depth != 1 || layer || layers != 1)
      return 1;
    d.ViewDimension = D3D11_SRV_DIMENSION_TEXTURE2D;
    d.Texture2D = {mip, mips};
    break;
  case 3:
    if (t->dimension != 2)
      return 1;
    d.ViewDimension = D3D11_SRV_DIMENSION_TEXTURE2DARRAY;
    d.Texture2DArray = {mip, mips, layer, layers};
    break;
  case 4:
    if (t->dimension != 2 || t->width != t->height || layer || layers != 6)
      return 1;
    d.ViewDimension = D3D11_SRV_DIMENSION_TEXTURECUBE;
    d.TextureCube = {mip, mips};
    break;
  case 5:
    if (t->dimension != 2 || t->width != t->height || layer % 6 || layers % 6)
      return 1;
    d.ViewDimension = D3D11_SRV_DIMENSION_TEXTURECUBEARRAY;
    d.TextureCubeArray = {mip, mips, layer, layers / 6};
    break;
  case 6:
    if (t->dimension != 3 || layer || layers != 1)
      return 1;
    d.ViewDimension = D3D11_SRV_DIMENSION_TEXTURE3D;
    d.Texture3D = {mip, mips};
    break;
  default:
    return 1;
  }
  auto v = new (std::nothrow) ZenitD12View;
  if (!v)
    return 2;
  v->texture = t;
  zenit_d12_texture_retain(t);
  v->dimension = dim;
  HRESULT hr =
      t->owner->raw->CreateShaderResourceView(t->raw, &d, v->srv.put());
  if (FAILED(hr)) {
    delete v;
    return result(hr);
  }
  *out = v;
  return 0;
}
extern "C" int zenit_d12_storage_view_create(ZenitD12Texture *t, uint32_t dim,
                                             uint32_t mip, uint32_t layer,
                                             uint32_t layers,
                                             ZenitD12View **out) {
  D11_PROF("storage_view_create");
  if (!out)
    return 1;
  *out = nullptr;
  if (!t || !(t->usage & 8) || mip >= t->mips || !layers || t->samples != 1)
    return 1;
  D3D11_UNORDERED_ACCESS_VIEW_DESC d = {};
  d.Format = t->format;
  switch (dim) {
  case 1:
    if (t->dimension != 1 || layer || layers != 1)
      return 1;
    d.ViewDimension = D3D11_UAV_DIMENSION_TEXTURE1D;
    d.Texture1D.MipSlice = mip;
    break;
  case 2:
    if (t->dimension != 2 || layer || layers != 1)
      return 1;
    d.ViewDimension = D3D11_UAV_DIMENSION_TEXTURE2D;
    d.Texture2D.MipSlice = mip;
    break;
  case 3:
    if (t->dimension != 2 || layer >= t->depth || layers > t->depth - layer)
      return 1;
    d.ViewDimension = D3D11_UAV_DIMENSION_TEXTURE2DARRAY;
    d.Texture2DArray = {mip, layer, layers};
    break;
  case 6:
    if (t->dimension != 3 || layer || layers != 1)
      return 1;
    d.ViewDimension = D3D11_UAV_DIMENSION_TEXTURE3D;
    d.Texture3D = {mip, 0, std::max(1u, t->depth >> mip)};
    break;
  default:
    return 1;
  }
  auto v = new (std::nothrow) ZenitD12View;
  if (!v)
    return 2;
  v->texture = t;
  zenit_d12_texture_retain(t);
  v->dimension = dim;
  v->storage = true;
  HRESULT hr =
      t->owner->raw->CreateUnorderedAccessView(t->raw, &d, v->uav.put());
  if (FAILED(hr)) {
    delete v;
    return result(hr);
  }
  *out = v;
  return 0;
}
extern "C" void zenit_d12_view_release(ZenitD12View *v) {
  D11_PROF("view_release");
  if (v && InterlockedDecrement(&v->refs) == 0)
    delete v;
}
extern "C" int zenit_d12_view_is_storage(ZenitD12View *v) {
  return v && v->storage;
}
extern "C" uint32_t zenit_d12_view_dimension(ZenitD12View *v) {
  return v ? v->dimension : 0;
}
extern "C" uint32_t zenit_d12_view_sample_type(ZenitD12View *v) {
  if (!v)
    return 0;
  if (depth_format(v->texture->format))
    return 3;
  switch (v->texture->format) {
  case DXGI_FORMAT_R8_UINT:
  case DXGI_FORMAT_R8G8_UINT:
  case DXGI_FORMAT_R8G8B8A8_UINT:
  case DXGI_FORMAT_R16_UINT:
  case DXGI_FORMAT_R16G16_UINT:
  case DXGI_FORMAT_R16G16B16A16_UINT:
  case DXGI_FORMAT_R32_UINT:
  case DXGI_FORMAT_R32G32_UINT:
  case DXGI_FORMAT_R32G32B32A32_UINT:
    return 5;
  case DXGI_FORMAT_R8_SINT:
  case DXGI_FORMAT_R8G8_SINT:
  case DXGI_FORMAT_R8G8B8A8_SINT:
  case DXGI_FORMAT_R16_SINT:
  case DXGI_FORMAT_R16G16_SINT:
  case DXGI_FORMAT_R16G16B16A16_SINT:
  case DXGI_FORMAT_R32_SINT:
  case DXGI_FORMAT_R32G32_SINT:
  case DXGI_FORMAT_R32G32B32A32_SINT:
    return 4;
  default:
    return 1;
  }
}
extern "C" void *zenit_d12_view_heap(ZenitD12View *v) {
  return v ? (v->storage ? (void *)v->uav.p : (void *)v->srv.p) : nullptr;
}
extern "C" void *zenit_d12_view_texture(ZenitD12View *v) {
  return v ? v->texture : nullptr;
}
extern "C" int zenit_d12_sampler_create(ZenitD12Device *d, uint32_t filter,
                                        uint32_t u, uint32_t v, uint32_t w,
                                        float min_lod, float max_lod,
                                        uint32_t anisotropy,
                                        uint32_t comparison,
                                        ZenitD12Sampler **out) {
  D11_PROF("sampler_create");
  if (!out)
    return 1;
  *out = nullptr;
  if (!d || u < 1 || u > 5 || v < 1 || v > 5 || w < 1 || w > 5 ||
      comparison < 1 || comparison > 8 || anisotropy < 1 || anisotropy > 16 ||
      !(min_lod <= max_lod))
    return 1;
  D3D11_SAMPLER_DESC a = {};
  a.Filter = (D3D11_FILTER)filter;
  a.AddressU = (D3D11_TEXTURE_ADDRESS_MODE)u;
  a.AddressV = (D3D11_TEXTURE_ADDRESS_MODE)v;
  a.AddressW = (D3D11_TEXTURE_ADDRESS_MODE)w;
  a.MinLOD = min_lod;
  a.MaxLOD = max_lod;
  a.MaxAnisotropy = anisotropy;
  a.ComparisonFunc = (D3D11_COMPARISON_FUNC)comparison;
  auto s = new (std::nothrow) ZenitD12Sampler;
  if (!s)
    return 2;
  s->owner = d;
  zenit_d12_device_retain(d);
  s->filter = filter;
  HRESULT hr = d->raw->CreateSamplerState(&a, s->raw.put());
  if (FAILED(hr)) {
    delete s;
    return result(hr);
  }
  *out = s;
  return 0;
}
extern "C" void zenit_d12_sampler_retain(ZenitD12Sampler *s) {
  if (s)
    InterlockedIncrement(&s->refs);
}
extern "C" void zenit_d12_sampler_release(ZenitD12Sampler *s) {
  if (s && InterlockedDecrement(&s->refs) == 0)
    delete s;
}
extern "C" int zenit_d12_sampler_comparison(ZenitD12Sampler *s) {
  return s && (s->filter & 0x80);
}
extern "C" void *zenit_d12_sampler_heap(ZenitD12Sampler *s) {
  return s ? s->raw.p : nullptr;
}
static uint32_t register_width(uint32_t kind) {
  return kind == 0 ? 3 : kind == 4 ? 4 : (kind == 3 || kind == 5) ? 2 : 16;
}
static uint32_t register_limit(uint32_t kind) {
  return kind == 0 ? 14 : kind == 4 ? 16 : (kind == 3 || kind == 5) ? 8 : 128;
}
static bool lower_registers(const char *bytes, size_t size, std::string &out) {
  std::string source(bytes, size);
  size_t cursor = 0;
  while (cursor < source.size()) {
    size_t pos = source.find("register", cursor);
    if (pos == std::string::npos) {
      out.append(source, cursor, std::string::npos);
      break;
    }
    out.append(source, cursor, pos - cursor);
    size_t p = pos + 8;
    while (p < source.size() && isspace((unsigned char)source[p]))
      ++p;
    if (p == source.size() || source[p] != '(') {
      out.append("register");
      cursor = pos + 8;
      continue;
    }
    ++p;
    while (p < source.size() && isspace((unsigned char)source[p]))
      ++p;
    char type = p < source.size() ? source[p++] : 0;
    uint32_t kind = type == 'b'   ? 0
                    : type == 't' ? 1
                    : type == 's' ? 4
                    : type == 'u' ? 3
                                  : 99;
    if (kind == 99) {
      out.append("register");
      cursor = pos + 8;
      continue;
    }
    char *end = nullptr;
    unsigned long index = strtoul(source.c_str() + p, &end, 10);
    if (end == source.c_str() + p)
      return false;
    p = end - source.c_str();
    while (p < source.size() && isspace((unsigned char)source[p]))
      ++p;
    if (p == source.size() || source[p] != ',') {
      out.append("register");
      cursor = pos + 8;
      continue;
    }
    ++p;
    while (p < source.size() && isspace((unsigned char)source[p]))
      ++p;
    if (source.compare(p, 5, "space"))
      return false;
    p += 5;
    unsigned long group = strtoul(source.c_str() + p, &end, 10);
    if (end == source.c_str() + p)
      return false;
    p = end - source.c_str();
    while (p < source.size() && isspace((unsigned char)source[p]))
      ++p;
    if (p >= source.size() || source[p] != ')' || group > 4 ||
        (group == 4 && (type != 'b' || index)) || index >= register_width(kind))
      return false;
    uint32_t slot = (uint32_t)(group * register_width(kind) + index);
    if (slot >= register_limit(kind))
      return false;
    out += "register(";
    out += type;
    out += std::to_string(slot);
    out += ')';
    cursor = p + 1;
  }
  return true;
}
static uint32_t reflected_dimension(D3D_SRV_DIMENSION d) {
  switch (d) {
  case D3D_SRV_DIMENSION_TEXTURE1D:
    return 1;
  case D3D_SRV_DIMENSION_TEXTURE2D:
    return 2;
  case D3D_SRV_DIMENSION_TEXTURE2DARRAY:
    return 3;
  case D3D_SRV_DIMENSION_TEXTURECUBE:
    return 4;
  case D3D_SRV_DIMENSION_TEXTURECUBEARRAY:
    return 5;
  case D3D_SRV_DIMENSION_TEXTURE3D:
    return 6;
  default:
    return 0;
  }
}
static int reflect_shader(ZenitD12Shader *s) {
  D11Com<ID3D11ShaderReflection> r;
  HRESULT hr = D3DReflect(s->blob->GetBufferPointer(), s->blob->GetBufferSize(),
                          IID_ID3D11ShaderReflection, (void **)r.put());
  if (FAILED(hr))
    return 3;
  D3D11_SHADER_DESC desc = {};
  if (FAILED(r->GetDesc(&desc)))
    return 3;
  for (UINT i = 0; i < desc.BoundResources; ++i) {
    D3D11_SHADER_INPUT_BIND_DESC b = {};
    if (FAILED(r->GetResourceBindingDesc(i, &b)))
      return 3;
    ZenitD12ShaderBinding a = {};
    a.count = b.BindCount;
    switch (b.Type) {
    case D3D_SIT_CBUFFER: {
      a.kind = 0;
      D3D11_SHADER_BUFFER_DESC cb = {};
      if (FAILED(r->GetConstantBufferByName(b.Name)->GetDesc(&cb)))
        return 3;
      a.min_size = cb.Size;
      break;
    }
    case D3D_SIT_TEXTURE:
      a.kind = 1;
      a.dimension = reflected_dimension(b.Dimension);
      if (!a.dimension)
        return 3;
      switch (b.ReturnType) {
      case D3D_RETURN_TYPE_UNORM:
      case D3D_RETURN_TYPE_SNORM:
      case D3D_RETURN_TYPE_FLOAT:
        a.sample_type = 1;
        break;
      case D3D_RETURN_TYPE_SINT:
        a.sample_type = 4;
        break;
      case D3D_RETURN_TYPE_UINT:
        a.sample_type = 5;
        break;
      default:
        return 3;
      }
      break;
    case D3D_SIT_STRUCTURED:
      a.kind = 2;
      a.stride = b.NumSamples;
      if (!a.stride || a.stride > 2048 || a.stride % 4)
        return 3;
      break;
    case D3D_SIT_BYTEADDRESS:
      a.kind = 2;
      break;
    case D3D_SIT_UAV_RWSTRUCTURED:
      a.kind = 3;
      a.stride = b.NumSamples;
      if (!a.stride || a.stride > 2048 || a.stride % 4)
        return 3;
      break;
    case D3D_SIT_UAV_RWBYTEADDRESS:
      a.kind = 3;
      break;
    case D3D_SIT_UAV_RWTYPED:
      a.kind = 5;
      a.dimension = reflected_dimension(b.Dimension);
      if (!a.dimension)
        return 3;
      break;
    case D3D_SIT_SAMPLER:
      a.kind = 4;
      a.sampler_type = (b.uFlags & D3D_SIF_COMPARISON_SAMPLER) ? 3 : 1;
      break;
    default:
      return 3;
    }
    uint32_t width = register_width(a.kind);
    a.group = b.BindPoint / width;
    a.binding = b.BindPoint % width;
    if (a.kind == 0 && b.BindPoint == 12)
      continue;
    if (a.group >= 4 || !a.count || a.count > width - a.binding ||
        b.BindPoint + a.count > register_limit(a.kind))
      return 3;
    s->bindings.push_back(a);
  }
  return 0;
}
extern "C" int zenit_d12_shader_compile(const void *source, size_t size,
                                        const char *entry, uint32_t stage,
                                        ZenitD12Shader **out, char **diagnostic,
                                        size_t *diagnostic_size) {
  if (!out || !diagnostic || !diagnostic_size)
    return 1;
  *out = nullptr;
  *diagnostic = nullptr;
  *diagnostic_size = 0;
  if (!source || !size || !entry || stage < 1 || stage > 3)
    return 1;
  std::string lowered;
  if (!lower_registers((const char *)source, size, lowered))
    return 3;
  auto s = new (std::nothrow) ZenitD12Shader;
  if (!s)
    return 2;
  s->entry = entry;
  s->stage = stage;
  D11Com<ID3DBlob> errors;
  const char *profile = stage == 1   ? "vs_5_0"
                        : stage == 2 ? "ps_5_0"
                                     : "cs_5_0";
  // Runtime HLSL compiles cost 0.1-2 s each (glass ~1.9 s) and otherwise
  // recur on every first visit of a story in every process; the cache keys
  // the lowered source, so register lowering changes invalidate it too.
  HRESULT hr = dxbc_compile_cached(
      "dxbc-d3d11-v1|5_0", lowered.data(), lowered.size(), "zenit-d3d11",
      entry, profile, D3DCOMPILE_ENABLE_STRICTNESS | D3DCOMPILE_OPTIMIZATION_LEVEL3,
      s->blob.put(), errors.put());
  if (errors) {
    *diagnostic_size = errors->GetBufferSize();
    *diagnostic = (char *)malloc(*diagnostic_size + 1);
    if (*diagnostic) {
      memcpy(*diagnostic, errors->GetBufferPointer(), *diagnostic_size);
      (*diagnostic)[*diagnostic_size] = 0;
    } else {
      delete s;
      return 2;
    }
  }
  if (FAILED(hr)) {
    delete s;
    return 3;
  }
  if (!s->blob) {
    delete s;
    return 2;
  }
  int status = reflect_shader(s);
  if (status) {
    delete s;
    return status;
  }
  *out = s;
  return 0;
}
extern "C" int zenit_d12_shader_bindings(ZenitD12Shader *s,
                                         ZenitD12ShaderBinding *out,
                                         uint32_t capacity, uint32_t *count) {
  if (!s || !count)
    return 1;
  *count = (uint32_t)s->bindings.size();
  if (!capacity)
    return 0;
  if (!out || capacity < s->bindings.size())
    return 1;
  std::copy(s->bindings.begin(), s->bindings.end(), out);
  return 0;
}
extern "C" void zenit_d12_shader_retain(ZenitD12Shader *s) {
  if (s)
    InterlockedIncrement(&s->refs);
}
extern "C" void zenit_d12_shader_release(ZenitD12Shader *s) {
  if (s && InterlockedDecrement(&s->refs) == 0)
    delete s;
}
extern "C" const void *zenit_d12_shader_data(ZenitD12Shader *s) {
  return s ? s->blob->GetBufferPointer() : nullptr;
}
extern "C" size_t zenit_d12_shader_size(ZenitD12Shader *s) {
  return s ? s->blob->GetBufferSize() : 0;
}
extern "C" const char *zenit_d12_shader_entry(ZenitD12Shader *s) {
  return s ? s->entry.c_str() : "";
}
extern "C" int zenit_d12_shader_warp_blob(ZenitD12Shader *s, void **out) {
  if (!s || !out)
    return 1;
  s->blob->AddRef();
  *out = s->blob.p;
  return 0;
}
extern "C" void zenit_d12_shader_diagnostic_free(char *p) { free(p); }
extern "C" int zenit_d12_pipeline_layout_create(ZenitD12Device *d,
                                                uint32_t groups,
                                                const ZenitD12LayoutBinding *b,
                                                uint32_t count,
                                                ZenitD12PipelineLayout **out) {
  if (!out)
    return 1;
  *out = nullptr;
  if (!d || groups > 4 || (count && !b))
    return 1;
  for (uint32_t i = 0; i < count; ++i) {
    if (b[i].group >= groups || b[i].kind > 5 || !b[i].count ||
        b[i].binding >= register_width(b[i].kind) ||
        b[i].count > register_width(b[i].kind) - b[i].binding ||
        !(b[i].visibility & 7) || b[i].visibility & ~7u)
      return 1;
    for (uint32_t j = 0; j < i; ++j)
      if (b[i].group == b[j].group && b[i].binding == b[j].binding)
        return 1;
  }
  auto p = new (std::nothrow) ZenitD12PipelineLayout;
  if (!p)
    return 2;
  p->owner = d;
  zenit_d12_device_retain(d);
  p->groups = groups;
  if (count)
    p->bindings.assign(b, b + count);
  *out = p;
  return 0;
}
extern "C" void zenit_d12_pipeline_layout_retain(ZenitD12PipelineLayout *p) {
  if (p)
    InterlockedIncrement(&p->refs);
}
extern "C" void zenit_d12_pipeline_layout_release(ZenitD12PipelineLayout *p) {
  if (p && InterlockedDecrement(&p->refs) == 0)
    delete p;
}
extern "C" ZenitD12Device *
zenit_d12_pipeline_layout_owner(ZenitD12PipelineLayout *p) {
  return p ? p->owner : nullptr;
}
extern "C" const ZenitD12LayoutBinding *
zenit_d12_pipeline_layout_bindings(ZenitD12PipelineLayout *p, uint32_t *count,
                                   uint32_t *groups) {
  if (!p)
    return nullptr;
  if (count)
    *count = (uint32_t)p->bindings.size();
  if (groups)
    *groups = p->groups;
  return p->bindings.data();
}
extern "C" uint32_t zenit_d12_pipeline_layout_table(ZenitD12PipelineLayout *p,
                                                    uint32_t group,
                                                    int sampler) {
  return p && group < p->groups ? group * 2 + (sampler ? 1 : 0) : UINT_MAX;
}
extern "C" uint32_t
zenit_d12_pipeline_layout_draw_info(ZenitD12PipelineLayout *) {
  return 12;
}
static const ZenitD12LayoutBinding *
layout_binding(ZenitD12PipelineLayout *p, uint32_t group, uint32_t binding) {
  for (auto &b : p->bindings)
    if (b.group == group && b.binding == binding)
      return &b;
  return nullptr;
}
static bool shader_layout(ZenitD12PipelineLayout *p, ZenitD12Shader *s,
                          uint32_t visibility) {
  for (auto &r : s->bindings) {
    auto b = layout_binding(p, r.group, r.binding);
    if (!b || b->kind != r.kind || b->count != r.count ||
        !(b->visibility & visibility) ||
        (b->min_size && b->min_size < r.min_size) ||
        (b->view_dimension && r.dimension && b->view_dimension != r.dimension))
      return false;
  }
  return true;
}
extern "C" int
zenit_d12_compute_pipeline_create(ZenitD12Device *d, ZenitD12PipelineLayout *l,
                                  ZenitD12Shader *s,
                                  ZenitD12ComputePipeline **out) {
  if (!out)
    return 1;
  *out = nullptr;
  if (!d || !l || l->owner != d || !s || s->stage != 3 ||
      !shader_layout(l, s, 4))
    return 1;
  auto p = new (std::nothrow) ZenitD12ComputePipeline;
  if (!p)
    return 2;
  p->layout = l;
  zenit_d12_pipeline_layout_retain(l);
  p->bindings = s->bindings;
  HRESULT hr = d->raw->CreateComputeShader(
      zenit_d12_shader_data(s), zenit_d12_shader_size(s), nullptr, p->cs.put());
  if (FAILED(hr)) {
    delete p;
    return result(hr);
  }
  *out = p;
  return 0;
}
extern "C" void zenit_d12_compute_pipeline_retain(ZenitD12ComputePipeline *p) {
  if (p)
    InterlockedIncrement(&p->refs);
}
extern "C" void zenit_d12_compute_pipeline_release(ZenitD12ComputePipeline *p) {
  if (p && InterlockedDecrement(&p->refs) == 0)
    delete p;
}
extern "C" void *zenit_d12_compute_pipeline_native(ZenitD12ComputePipeline *p) {
  return p ? p->cs.p : nullptr;
}
extern "C" void *zenit_d12_compute_pipeline_root(ZenitD12ComputePipeline *p) {
  return p ? p->layout : nullptr;
}
extern "C" ZenitD12PipelineLayout *
zenit_d12_compute_pipeline_layout(ZenitD12ComputePipeline *p) {
  return p ? p->layout : nullptr;
}
extern "C" int
zenit_d12_render_pipeline_create(ZenitD12Device *d, ZenitD12PipelineLayout *l,
                                 ZenitD12Shader *vs, ZenitD12Shader *ps,
                                 const ZenitD12RenderDescriptor *a,
                                 ZenitD12RenderPipeline **out) {
  if (!out)
    return 1;
  *out = nullptr;
  if (!d || !l || l->owner != d || !vs || !ps || vs->stage != 1 ||
      ps->stage != 2 || !a || a->attribute_count > 32 || a->target_count > 8 ||
      (a->attribute_count && !a->attributes) ||
      (a->target_count && !a->targets) || a->topology < 1 || a->topology > 5 ||
      !shader_layout(l, vs, 1) || !shader_layout(l, ps, 2))
    return 1;
  bool dual_source = false;
  for (uint32_t i = 0; i < a->target_count; ++i) {
    const auto &t = a->targets[i];
    dual_source |= t.color_src >= 16 || t.color_dst >= 16 || t.alpha_src >= 16 || t.alpha_dst >= 16;
  }
  if (dual_source) {
    D11Com<ID3D11ShaderReflection> reflection;
    if (FAILED(D3DReflect(ps->blob->GetBufferPointer(), ps->blob->GetBufferSize(), IID_ID3D11ShaderReflection, (void **)reflection.put()))) return 1;
    D3D11_SHADER_DESC desc = {}; if (FAILED(reflection->GetDesc(&desc))) return 1;
    ZenitDualSourceSignature signature;
    for (UINT i = 0; i < desc.OutputParameters; ++i) {
      D3D11_SIGNATURE_PARAMETER_DESC output = {};
      if (FAILED(reflection->GetOutputParameterDesc(i, &output))) return 1;
      if (output.SystemValueType == D3D_NAME_TARGET) signature.target(output.SemanticIndex, output.ComponentType, output.Mask);
      else if (!(output.SystemValueType == D3D_NAME_DEPTH && a->depth.format)) signature.invalid = true;
    }
    if (!signature.valid(a->target_count, a->targets[0].blend != 0)) return 1;
  }
  auto p = new (std::nothrow) ZenitD12RenderPipeline;
  if (!p)
    return 2;
  p->layout = l;
  zenit_d12_pipeline_layout_retain(l);
  p->entry = ps->entry;
  p->sample_mask = a->sample_mask;
  p->bindings = vs->bindings;
  for (auto &b : ps->bindings) {
    bool duplicate = false;
    for (auto &v : p->bindings)
      if (v.group == b.group && v.binding == b.binding) {
        if (v.stride != b.stride || v.kind != b.kind) {
          delete p;
          return 1;
        }
        duplicate = true;
      }
    if (!duplicate)
      p->bindings.push_back(b);
  }
  HRESULT hr = d->raw->CreateVertexShader(zenit_d12_shader_data(vs),
                                          zenit_d12_shader_size(vs), nullptr,
                                          p->vs.put());
  if (SUCCEEDED(hr))
    hr = d->raw->CreatePixelShader(zenit_d12_shader_data(ps),
                                   zenit_d12_shader_size(ps), nullptr,
                                   p->ps.put());
  std::vector<D3D11_INPUT_ELEMENT_DESC> elements;
  for (uint32_t i = 0; i < a->attribute_count; ++i) {
    auto &v = a->attributes[i];
    uint32_t bytes = pixel_bytes((DXGI_FORMAT)v.format);
    if (v.slot >= 32 || !bytes || !v.stride || v.stride > 2048 || v.step > 1 ||
        v.offset > v.stride || bytes > v.stride - v.offset) {
      delete p;
      return 1;
    }
    if ((p->info.slots & (1u << v.slot)) &&
        (p->info.strides[v.slot] != v.stride ||
         p->info.steps[v.slot] != v.step)) {
      delete p;
      return 1;
    }
    p->info.slots |= 1u << v.slot;
    p->info.strides[v.slot] = v.stride;
    p->info.steps[v.slot] = v.step;
    p->info.ends[v.slot] = std::max(p->info.ends[v.slot], v.offset + bytes);
    D3D11_INPUT_ELEMENT_DESC e = {"TEXCOORD",
                                  v.location,
                                  (DXGI_FORMAT)v.format,
                                  v.slot,
                                  v.offset,
                                  v.step ? D3D11_INPUT_PER_INSTANCE_DATA
                                         : D3D11_INPUT_PER_VERTEX_DATA,
                                  v.step};
    elements.push_back(e);
  }
  if (SUCCEEDED(hr) && !elements.empty())
    hr = d->raw->CreateInputLayout(elements.data(), (UINT)elements.size(),
                                   zenit_d12_shader_data(vs),
                                   zenit_d12_shader_size(vs), p->input.put());
  D3D11_BLEND_DESC blend = {};
  blend.AlphaToCoverageEnable = a->alpha_coverage;
  blend.IndependentBlendEnable = !dual_source;
  for (uint32_t i = 0; i < a->target_count; ++i) {
    auto &t = a->targets[i];
    auto &b = blend.RenderTarget[i];
    b.BlendEnable = t.blend;
    b.SrcBlend = (D3D11_BLEND)t.color_src;
    b.DestBlend = (D3D11_BLEND)t.color_dst;
    b.BlendOp = (D3D11_BLEND_OP)t.color_op;
    b.SrcBlendAlpha = (D3D11_BLEND)t.alpha_src;
    b.DestBlendAlpha = (D3D11_BLEND)t.alpha_dst;
    b.BlendOpAlpha = (D3D11_BLEND_OP)t.alpha_op;
    b.RenderTargetWriteMask = (UINT8)t.write_mask;
    p->info.formats[i] = t.format;
  }
  if (SUCCEEDED(hr))
    hr = d->raw->CreateBlendState(&blend, p->blend.put());
  D3D11_RASTERIZER_DESC raster = {};
  raster.FillMode = (D3D11_FILL_MODE)a->fill;
  raster.CullMode = (D3D11_CULL_MODE)a->cull;
  raster.FrontCounterClockwise = a->front_ccw;
  raster.DepthClipEnable = a->depth_clip;
  raster.ScissorEnable = TRUE;
  raster.MultisampleEnable = a->samples > 1;
  raster.DepthBias = a->depth.bias;
  raster.SlopeScaledDepthBias = a->depth.slope;
  raster.DepthBiasClamp = a->depth.clamp;
  if (SUCCEEDED(hr))
    hr = d->raw->CreateRasterizerState(&raster, p->raster.put());
  D3D11_DEPTH_STENCIL_DESC depth = {};
  depth.DepthEnable = a->depth.format != 0;
  depth.DepthWriteMask =
      a->depth.write ? D3D11_DEPTH_WRITE_MASK_ALL : D3D11_DEPTH_WRITE_MASK_ZERO;
  depth.DepthFunc = a->depth.format ? (D3D11_COMPARISON_FUNC)a->depth.compare
                                    : D3D11_COMPARISON_ALWAYS;
  depth.StencilEnable = a->depth.format == DXGI_FORMAT_D24_UNORM_S8_UINT ||
                        a->depth.format == DXGI_FORMAT_D32_FLOAT_S8X24_UINT;
  depth.StencilReadMask = (UINT8)a->depth.read_mask;
  depth.StencilWriteMask = (UINT8)a->depth.write_mask;
  auto face = [](const ZenitD12StencilFace &f) {
    return D3D11_DEPTH_STENCILOP_DESC{
        (D3D11_STENCIL_OP)f.fail, (D3D11_STENCIL_OP)f.depth_fail,
        (D3D11_STENCIL_OP)f.pass, (D3D11_COMPARISON_FUNC)f.compare};
  };
  if (depth.StencilEnable) {
    depth.FrontFace = face(a->depth.front);
    depth.BackFace = face(a->depth.back);
  } else {
    depth.FrontFace = {D3D11_STENCIL_OP_KEEP, D3D11_STENCIL_OP_KEEP,
                       D3D11_STENCIL_OP_KEEP, D3D11_COMPARISON_ALWAYS};
    depth.BackFace = depth.FrontFace;
  }
  if (SUCCEEDED(hr))
    hr = d->raw->CreateDepthStencilState(&depth, p->depth.put());
  if (FAILED(hr)) {
    delete p;
    return result(hr);
  }
  p->info.topology = a->topology;
  p->info.strip_index = a->strip_index;
  p->info.target_count = a->target_count;
  p->info.depth_format = a->depth.format;
  p->info.depth_write = a->depth.write;
  p->info.stencil_write = depth.StencilEnable && depth.StencilWriteMask;
  p->info.samples = a->samples;
  *out = p;
  return 0;
}
extern "C" void zenit_d12_render_pipeline_retain(ZenitD12RenderPipeline *p) {
  if (p)
    InterlockedIncrement(&p->refs);
}
extern "C" void zenit_d12_render_pipeline_release(ZenitD12RenderPipeline *p) {
  if (p && InterlockedDecrement(&p->refs) == 0)
    delete p;
}
extern "C" void *zenit_d12_render_pipeline_native(ZenitD12RenderPipeline *p) {
  return p;
}
extern "C" void *zenit_d12_render_pipeline_root(ZenitD12RenderPipeline *p) {
  return p ? p->layout : nullptr;
}
extern "C" ZenitD12PipelineLayout *
zenit_d12_render_pipeline_layout(ZenitD12RenderPipeline *p) {
  return p ? p->layout : nullptr;
}
extern "C" const char *
zenit_d12_render_pipeline_entry(ZenitD12RenderPipeline *p) {
  return p ? p->entry.c_str() : "";
}
extern "C" void zenit_d12_render_pipeline_info(ZenitD12RenderPipeline *p,
                                               ZenitD12RenderInfo *out) {
  if (p && out)
    *out = p->info;
}
extern "C" int zenit_d12_render_buffer_stride(ZenitD12RenderPipeline *p,
                                              uint32_t group, uint32_t binding,
                                              uint32_t *stride) {
  if (!p || !stride)
    return 1;
  for (auto &b : p->bindings)
    if (b.group == group && b.binding == binding &&
        (b.kind == 2 || b.kind == 3)) {
      *stride = b.stride;
      return 0;
    }
  return 1;
}
static int validate_entries(
    ZenitD12PipelineLayout *p, uint32_t group, const ZenitD12BindingEntry *e,
    uint32_t count,
    const std::vector<ZenitD12ShaderBinding> *reflection = nullptr) {
  if (!p || group >= p->groups || (count && !e))
    return 1;
  uint32_t expected = 0;
  for (auto &b : p->bindings)
    if (b.group == group)
      expected += b.count;
  if (count != expected)
    return 1;
  for (uint32_t i = 0; i < count; ++i) {
    auto b = layout_binding(p, group, e[i].binding);
    if (!b || e[i].array_index >= b->count)
      return 1;
    for (uint32_t j = 0; j < i; ++j)
      if (e[j].binding == e[i].binding && e[j].array_index == e[i].array_index)
        return 1;
    uint32_t resources = (e[i].buffer != nullptr) + (e[i].view != nullptr) +
                         (e[i].sampler != nullptr);
    if (resources != 1)
      return 1;
    if (b->kind == 1 || b->kind == 5) {
      if (!e[i].view || e[i].view->texture->owner != p->owner ||
          e[i].view->storage != (b->kind == 5) || e[i].offset || e[i].size ||
          e[i].stride ||
          (b->view_dimension && b->view_dimension != e[i].view->dimension))
        return 1;
    } else if (b->kind == 4) {
      if (!e[i].sampler || e[i].sampler->owner != p->owner || e[i].offset ||
          e[i].size || e[i].stride ||
          (b->sampler_type == 3) != bool(e[i].sampler->filter & 0x80))
        return 1;
    } else {
      auto v = e[i].buffer;
      if (!v || v->owner != p->owner || (v->usage & MAP_READ) || !e[i].size ||
          e[i].offset > v->size || e[i].size > v->size - e[i].offset ||
          e[i].size < b->min_size)
        return 1;
      if (b->kind == 0) {
        if (!(v->usage & UNIFORM) || e[i].stride || e[i].offset % 16 ||
            e[i].size > 65536)
          return 1;
      } else {
        uint32_t stride = e[i].stride ? e[i].stride : 4;
        if (!(v->usage & STORAGE) || e[i].stride > 2048 || e[i].stride % 4 ||
            e[i].offset % stride || e[i].size % stride ||
            (b->kind == 3 && (v->usage & MAP_WRITE)))
          return 1;
      }
      if (reflection)
        for (auto &r : *reflection)
          if (r.group == group && r.binding == e[i].binding &&
              (e[i].size < r.min_size ||
               ((r.kind == 2 || r.kind == 3) && e[i].stride != r.stride)))
            return 1;
    }
  }
  return 0;
}
extern "C" int
zenit_d12_bind_group_create(ZenitD12Device *d, ZenitD12PipelineLayout *l,
                            uint32_t group, const ZenitD12BindingEntry *entries,
                            uint32_t count, ZenitD12BindGroup **out) {
  if (!out)
    return 1;
  *out = nullptr;
  if (!d || !l || l->owner != d || validate_entries(l, group, entries, count))
    return 1;
  auto b = new (std::nothrow) ZenitD12BindGroup;
  if (!b)
    return 2;
  b->layout = l;
  zenit_d12_pipeline_layout_retain(l);
  b->group = group;
  if (count)
    b->entries.assign(entries, entries + count);
  for (auto &e : b->entries) {
    if (e.buffer)
      zenit_d12_buffer_retain(e.buffer);
    if (e.view)
      InterlockedIncrement(&e.view->refs);
    if (e.sampler)
      zenit_d12_sampler_retain(e.sampler);
  }
  *out = b;
  return 0;
}
ZenitD12BindGroup::~ZenitD12BindGroup() {
  for (auto &e : entries) {
    zenit_d12_buffer_release(e.buffer);
    zenit_d12_view_release(e.view);
    zenit_d12_sampler_release(e.sampler);
  }
  zenit_d12_pipeline_layout_release(layout);
}
extern "C" void zenit_d12_bind_group_release(ZenitD12BindGroup *b) {
  D11_PROF("bind_group_release");
  if (b && InterlockedDecrement(&b->refs) == 0)
    delete b;
}
extern "C" int
zenit_d12_compute_validate_bindings(ZenitD12ComputePipeline *p, uint32_t group,
                                    const ZenitD12BindingEntry *e,
                                    uint32_t count) {
  return p ? validate_entries(p->layout, group, e, count, &p->bindings) : 1;
}
extern "C" int zenit_d12_render_validate_bindings(ZenitD12RenderPipeline *p,
                                                  uint32_t group,
                                                  const ZenitD12BindingEntry *e,
                                                  uint32_t count) {
  D11_PROF("render_validate_bindings");
  return p ? validate_entries(p->layout, group, e, count, &p->bindings) : 1;
}
extern "C" int zenit_d12_commands_create(ZenitD12Device *d,
                                         ZenitD12Commands **out) {
  D11_PROF("commands_create");
  if (!out)
    return 1;
  *out = nullptr;
  if (!d)
    return 1;
  auto c = new (std::nothrow) ZenitD12Commands;
  if (!c)
    return 2;
  c->owner = d;
  zenit_d12_device_retain(d);
  HRESULT hr = d->raw->CreateDeferredContext(0, c->context.put());
  if (FAILED(hr)) {
    int status = device_failure(d, "CreateDeferredContext", hr);
    delete c;
    return status;
  }
  c->context->QueryInterface(IID_ID3D11DeviceContext1,
                             (void **)c->context1.put());
  *out = c;
  return 0;
}
extern "C" void zenit_d12_commands_release(ZenitD12Commands *c) {
  D11_PROF("commands_release");
  CpuTraceScope trace("release");
  if (c && InterlockedDecrement(&c->refs) == 0)
    delete c;
}
extern "C" int zenit_d12_commands_finish(ZenitD12Commands *c) {
  D11_PROF("commands_finish");
  if (!c || c->finished || c->pass)
    return 1;
  const bool trace = cpu_timing_trace_enabled();
  const uint64_t start = trace ? cpu_time_micros() : 0;
  HRESULT hr = c->context->FinishCommandList(FALSE, c->list.put());
  if (trace)
    fprintf(stderr, "[d3d11-cpu] finish_us=%llu result=0x%08lx uniform_allocations=%u uniform_reuses=%u uniform_device_reuses=%u\n",
            (unsigned long long)(cpu_time_micros() - start), (unsigned long)hr, c->uniform_allocations, c->uniform_reuses, c->uniform_device_reuses);
  if (FAILED(hr))
    return device_failure(c->owner, "FinishCommandList", hr);
  c->finished = true;
  return 0;
}
extern "C" int zenit_d12_commands_enable_timestamps(ZenitD12Commands *c) {
  if (!c || c->finished || c->submitted || c->pass || c->timestamp_disjoint)
    return 1;
  D11Com<ID3D11Query> disjoint, start, end;
  D3D11_QUERY_DESC desc = {D3D11_QUERY_TIMESTAMP_DISJOINT, 0};
  HRESULT hr = c->owner->raw->CreateQuery(&desc, disjoint.put());
  desc.Query = D3D11_QUERY_TIMESTAMP;
  if (SUCCEEDED(hr))
    hr = c->owner->raw->CreateQuery(&desc, start.put());
  if (SUCCEEDED(hr))
    hr = c->owner->raw->CreateQuery(&desc, end.put());
  if (FAILED(hr))
    return result(hr);
  // Queries surround playback on the immediate context. This also works with
  // drivers that emulate deferred command lists; no CPU clock is sampled.
  c->timestamp_disjoint = std::move(disjoint);
  c->timestamp_start = std::move(start);
  c->timestamp_end = std::move(end);
  return 0;
}
extern "C" int zenit_d12_commands_elapsed_micros(ZenitD12Commands *c,
                                                 uint64_t *micros) {
  CpuTraceScope cpu_trace("query_read");
  if (!micros)
    return 1;
  *micros = 0;
  char trace_flag[2] = {};
  const bool trace = GetEnvironmentVariableA("ZENIT_D11_TIMESTAMP_TRACE",
                                             trace_flag, sizeof(trace_flag)) &&
                     trace_flag[0] == '1';
  if (trace)
    fprintf(stderr, "[d11-query] submitted=%d completed=%d query=%d\n",
            c && c->submitted, c && c->gpu_completed,
            c && c->timestamp_disjoint.p);
  if (!c || !c->submitted || !c->gpu_completed)
    return 3;
  // A completed command without counters can never produce a later sample.
  // Report failure so optional-query allocation errors do not pin the timing
  // collector's retained commands behind a permanently pending entry.
  if (!c->timestamp_disjoint)
    return 1;
  if (FAILED(c->owner->raw->GetDeviceRemovedReason()))
    return 4;
  if (c->elapsed_cached) {
    *micros = c->elapsed_micros;
    return 0;
  }
  D3D11_QUERY_DATA_TIMESTAMP_DISJOINT disjoint = {};
  uint64_t start = 0, end = 0;
  auto context = c->owner->immediate.p;
  HRESULT hr =
      context->GetData(c->timestamp_disjoint, &disjoint, sizeof(disjoint),
                       D3D11_ASYNC_GETDATA_DONOTFLUSH);
  if (trace)
    fprintf(stderr,
            "[d11-query] disjoint hr=0x%08lx frequency=%llu invalid=%d\n",
            (unsigned long)hr, (unsigned long long)disjoint.Frequency,
            disjoint.Disjoint);
  if (hr == S_FALSE)
    return 3;
  if (FAILED(hr))
    return result(hr);
  if (disjoint.Disjoint || !disjoint.Frequency)
    return 5; // Completed but disjoint; never a CPU substitute sample.
  hr = context->GetData(c->timestamp_start, &start, sizeof(start),
                        D3D11_ASYNC_GETDATA_DONOTFLUSH);
  if (hr == S_FALSE)
    return 3;
  if (FAILED(hr))
    return result(hr);
  hr = context->GetData(c->timestamp_end, &end, sizeof(end),
                        D3D11_ASYNC_GETDATA_DONOTFLUSH);
  if (hr == S_FALSE)
    return 3;
  if (FAILED(hr))
    return result(hr);
  if (trace)
    fprintf(stderr, "[d11-query] ticks start=%llu end=%llu\n",
            (unsigned long long)start, (unsigned long long)end);
  if (end < start)
    return 2;
  // Convert only after subtracting integer ticks, preserving precision on both
  // x86 and x64. Match the shared ABI's integral microsecond result.
  const double elapsed =
      double(end - start) * 1000000.0 / double(disjoint.Frequency);
  if (!(elapsed >= 0.0) || elapsed >= double(UINT64_MAX))
    return 2;
  c->elapsed_micros = uint64_t(elapsed);
  c->elapsed_cached = true;
  *micros = c->elapsed_micros;
  return 0;
}
static bool recording(ZenitD12Commands *c) { return c && !c->finished; }
static uint64_t buffer_write_version(ZenitD12Commands *c,
                                     ID3D11Buffer *buffer) {
  for (const auto &entry : c->buffer_write_versions)
    if (entry.source.p == buffer)
      return entry.version;
  return 0;
}
static void mark_buffer_written(ZenitD12Commands *c, ID3D11Buffer *buffer) {
  for (auto &entry : c->buffer_write_versions)
    if (entry.source.p == buffer) {
      ++entry.version;
      return;
    }
  D11BufferWriteVersion entry;
  buffer->AddRef();
  entry.source = D11Com<ID3D11Buffer>(buffer);
  entry.version = 1;
  c->buffer_write_versions.push_back(std::move(entry));
}
extern "C" int zenit_d12_commands_copy(ZenitD12Commands *c, ZenitD12Buffer *src,
                                       uint64_t so, ZenitD12Buffer *dst,
                                       uint64_t doff, uint64_t bytes) {
  D11_PROF("commands_copy");
  if (!recording(c) || c->pass || !src || !dst || src->owner != c->owner ||
      dst->owner != c->owner || !(src->usage & COPY_SRC) ||
      !(dst->usage & COPY_DST) || !bytes || so > src->size ||
      bytes > src->size - so || doff > dst->size || bytes > dst->size - doff ||
      (src == dst))
    return 1;
  unbind_srvs(c->context);
  // All public raw-buffer writes pass through copy or dispatch copyback.
  // Conservatively invalidate the entire destination, including partial writes.
  if (!(dst->usage & MAP_READ))
    mark_buffer_written(c, dst->raw);
  D3D11_BOX box = {(UINT)so, 0, 0, (UINT)(so + bytes), 1, 1};
  if (dst->usage & MAP_READ) {
    D3D11_BUFFER_DESC desc = {};
    desc.ByteWidth = (UINT)bytes;
    desc.Usage = D3D11_USAGE_STAGING;
    desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    D11Com<ID3D11Buffer> staging;
    D3D11_SUBRESOURCE_DATA initial = {};
    initial.pSysMem = src->host.empty() ? nullptr : src->host.data() + so;
    HRESULT hr = c->owner->raw->CreateBuffer(
        &desc, initial.pSysMem ? &initial : nullptr, staging.put());
    if (FAILED(hr))
      return result(hr);
    if (!initial.pSysMem)
      c->context->CopySubresourceRegion(staging, 0, 0, 0, 0, src->raw, 0, &box);
    D11Readback r;
    r.staging = D11Com<ID3D11Resource>(staging.p);
    staging->AddRef();
    r.buffer = dst;
    zenit_d12_buffer_retain(dst);
    r.offset = doff;
    r.row_bytes = (UINT)bytes;
    c->readbacks.push_back(std::move(r));
  } else if (src->usage & MAP_WRITE) {
    D3D11_BUFFER_DESC desc = {};
    dst->raw->GetDesc(&desc);
    if (desc.BindFlags & D3D11_BIND_CONSTANT_BUFFER) {
      if (doff || bytes != desc.ByteWidth)
        return 1;
      c->context->UpdateSubresource(dst->raw, 0, nullptr, src->host.data() + so,
                                    0, 0);
    } else {
      D3D11_BOX dest = {(UINT)doff, 0, 0, (UINT)(doff + bytes), 1, 1};
      if (!c->context1)
        return 1;
      c->context1->UpdateSubresource1(dst->raw, 0, &dest, src->host.data() + so,
                                      0, 0, 0);
    }
  } else {
    D3D11_BUFFER_DESC desc = {};
    dst->raw->GetDesc(&desc);
    if (desc.BindFlags & D3D11_BIND_CONSTANT_BUFFER) {
      if (doff || so || bytes != desc.ByteWidth)
        return 1;
      c->context->CopyResource(dst->raw, src->raw);
    } else
      c->context->CopySubresourceRegion(dst->raw, 0, (UINT)doff, 0, 0, src->raw,
                                        0, &box);
  }
  return 0;
}
extern "C" int zenit_d12_commands_texture_copy(
    ZenitD12Commands *c, ZenitD12Buffer *b, uint64_t offset, uint32_t row_pitch,
    ZenitD12Texture *t, const ZenitD12TextureRegion *region, int to_texture) {
  D11_PROF("commands_texture_copy");
  ZenitD12TextureLayout layout = {};
  if (!recording(c) || c->pass || !b || !t || b->owner != c->owner ||
      t->owner != c->owner || (to_texture != 0 && to_texture != 1) ||
      zenit_d12_texture_layout(t, region, offset, &layout) ||
      row_pitch < layout.row_bytes || row_pitch % 256 ||
      !(b->usage & (to_texture ? COPY_SRC : COPY_DST)) ||
      !(t->usage & (to_texture ? 2u : 1u)))
    return 1;
  uint64_t required =
      (uint64_t)row_pitch * ((uint64_t)region->height * region->depth - 1) +
      layout.row_bytes;
  if (offset > b->size || required > b->size - offset)
    return 1;
  unbind_srvs(c->context);
  UINT sub = D3D11CalcSubresource(region->mip, region->layer, t->mips);
  D3D11_BOX box = {region->x,
                   region->y,
                   region->z,
                   region->x + region->width,
                   region->y + region->height,
                   region->z + region->depth};
  if (to_texture) {
    if (!(b->usage & MAP_WRITE) || !c->context1)
      return 1;
    std::vector<unsigned char> snapshot((size_t)required);
    memcpy(snapshot.data(), b->host.data() + offset, (size_t)required);
    c->context1->UpdateSubresource1(t->raw, sub, &box, snapshot.data(),
                                    row_pitch, row_pitch * region->height, 0);
  } else {
    if (!(b->usage & MAP_READ))
      return 1;
    D11Com<ID3D11Resource> staging;
    HRESULT hr;
    if (t->dimension == 1) {
      D3D11_TEXTURE1D_DESC desc = {};
      desc.Width = region->width;
      desc.MipLevels = desc.ArraySize = 1;
      desc.Format = t->format;
      desc.Usage = D3D11_USAGE_STAGING;
      desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
      ID3D11Texture1D *r = nullptr;
      hr = c->owner->raw->CreateTexture1D(&desc, nullptr, &r);
      staging = D11Com<ID3D11Resource>(r);
    } else if (t->dimension == 2) {
      D3D11_TEXTURE2D_DESC desc = {};
      desc.Width = region->width;
      desc.Height = region->height;
      desc.MipLevels = desc.ArraySize = desc.SampleDesc.Count = 1;
      desc.Format = t->format;
      desc.Usage = D3D11_USAGE_STAGING;
      desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
      ID3D11Texture2D *r = nullptr;
      hr = c->owner->raw->CreateTexture2D(&desc, nullptr, &r);
      staging = D11Com<ID3D11Resource>(r);
    } else {
      D3D11_TEXTURE3D_DESC desc = {};
      desc.Width = region->width;
      desc.Height = region->height;
      desc.Depth = region->depth;
      desc.MipLevels = 1;
      desc.Format = t->format;
      desc.Usage = D3D11_USAGE_STAGING;
      desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
      ID3D11Texture3D *r = nullptr;
      hr = c->owner->raw->CreateTexture3D(&desc, nullptr, &r);
      staging = D11Com<ID3D11Resource>(r);
    }
    if (FAILED(hr))
      return result(hr);
    c->context->CopySubresourceRegion(staging, 0, 0, 0, 0, t->raw, sub, &box);
    D11Readback r;
    r.staging = std::move(staging);
    r.buffer = b;
    zenit_d12_buffer_retain(b);
    r.offset = offset;
    r.pitch = row_pitch;
    r.row_bytes = (UINT)layout.row_bytes;
    r.height = region->height;
    r.depth = region->depth;
    r.texture = true;
    c->readbacks.push_back(std::move(r));
  }
  return 0;
}
extern "C" int zenit_d12_commands_texture_region_copy(
    ZenitD12Commands *c, ZenitD12Texture *src, const ZenitD12TextureRegion *sr,
    ZenitD12Texture *dst, const ZenitD12TextureRegion *dr) {
  D11_PROF("commands_texture_region_copy");
  if (!recording(c) || c->pass || !region_valid(src, sr) ||
      !region_valid(dst, dr) || src->owner != c->owner ||
      dst->owner != c->owner || !(src->usage & 1) || !(dst->usage & 2) ||
      src->format != dst->format || src->dimension != dst->dimension ||
      sr->width != dr->width || sr->height != dr->height ||
      sr->depth != dr->depth ||
      (src == dst && sr->mip == dr->mip && sr->layer == dr->layer))
    return 1;
  unbind_srvs(c->context);
  D3D11_BOX box = {sr->x,
                   sr->y,
                   sr->z,
                   sr->x + sr->width,
                   sr->y + sr->height,
                   sr->z + sr->depth};
  c->context->CopySubresourceRegion(
      dst->raw, D3D11CalcSubresource(dr->mip, dr->layer, dst->mips), dr->x,
      dr->y, dr->z, src->raw,
      D3D11CalcSubresource(sr->mip, sr->layer, src->mips), &box);
  return 0;
}
extern "C" int zenit_d12_queue_create(ZenitD12Device *d, ZenitD12Queue **out) {
  if (!out)
    return 1;
  *out = nullptr;
  if (!d)
    return 1;
  auto q = new (std::nothrow) ZenitD12Queue;
  if (!q)
    return 2;
  q->owner = d;
  zenit_d12_device_retain(d);
  *out = q;
  return 0;
}
extern "C" int zenit_d12_queue_submit(ZenitD12Queue *q, ZenitD12Commands *c,
                                      uint64_t *serial) {
  D11_PROF("queue_submit");
  CpuTraceScope submit_trace("submit");
  if (!q || !c || !serial || c->owner != q->owner || !c->finished ||
      c->submitted)
    return 1;
  D11Submission s;
  s.serial = q->next;
  D3D11_QUERY_DESC desc = {D3D11_QUERY_EVENT, 0};
  HRESULT hr = q->owner->raw->CreateQuery(&desc, s.query.put());
  if (FAILED(hr))
    return result(hr);
  if (c->timestamp_disjoint) {
    q->owner->immediate->Begin(c->timestamp_disjoint);
    q->owner->immediate->End(c->timestamp_start);
  }
  const bool trace = cpu_timing_trace_enabled();
  const uint64_t execute_start = trace ? cpu_time_micros() : 0;
  arena_upload(c, q->owner->immediate);
  q->owner->immediate->ExecuteCommandList(c->list, FALSE);
  const uint64_t execute_end = trace ? cpu_time_micros() : 0;
  if (c->timestamp_disjoint) {
    q->owner->immediate->End(c->timestamp_end);
    q->owner->immediate->End(c->timestamp_disjoint);
    c->timestamps_ended = true;
  }
  q->owner->immediate->End(s.query);
  q->owner->immediate->Flush();
  if (trace)
    fprintf(stderr, "[d3d11-cpu] serial=%llu execute_us=%llu flush_us=%llu\n",
            (unsigned long long)s.serial,
            (unsigned long long)(execute_end - execute_start),
            (unsigned long long)(cpu_time_micros() - execute_end));
  s.commands = c;
  InterlockedIncrement(&c->refs);
  c->submitted = true;
  q->pending.push_back(std::move(s));
  *serial = q->next++;
  return 0;
}
static int collect_submission(ZenitD12Queue *q, D11Submission &s) {
  CpuTraceScope trace("readback");
  auto c = q->owner->immediate.p;
  for (auto &r : s.commands->readbacks) {
    D3D11_MAPPED_SUBRESOURCE m = {};
    HRESULT hr = c->Map(r.staging, 0, D3D11_MAP_READ, 0, &m);
    if (FAILED(hr))
      return device_failure(q->owner, "Map(readback)", hr);
    auto dst = r.buffer->host.data() + r.offset;
    if (r.texture) {
      for (uint32_t z = 0; z < r.depth; ++z)
        for (uint32_t y = 0; y < r.height; ++y)
          memcpy(dst + ((uint64_t)z * r.height + y) * r.pitch,
                 (const unsigned char *)m.pData + (uint64_t)z * m.DepthPitch +
                     (uint64_t)y * m.RowPitch,
                 r.row_bytes);
    } else
      memcpy(dst, m.pData, r.row_bytes);
    c->Unmap(r.staging, 0);
  }
  return 0;
}
extern "C" int zenit_d12_queue_collect(ZenitD12Queue *q) {
  D11_PROF("queue_collect");
  CpuTraceScope trace("collect");
  if (!q)
    return 1;
  while (!q->pending.empty()) {
    auto &s = q->pending.front();
    BOOL done = FALSE;
    HRESULT hr = q->owner->immediate->GetData(s.query, &done, sizeof(done),
                                              D3D11_ASYNC_GETDATA_DONOTFLUSH);
    if (FAILED(hr))
      return device_failure(q->owner, "GetData(completion)", hr);
    if (hr == S_FALSE || !done)
      break;
    int status = collect_submission(q, s);
    if (status)
      return status;
    s.commands->gpu_completed = true;
    q->completed = s.serial;
    zenit_d12_commands_release(s.commands);
    q->pending.erase(q->pending.begin());
  }
  return 0;
}
extern "C" int zenit_d12_queue_wait(ZenitD12Queue *q, uint64_t serial,
                                    uint32_t timeout) {
  D11_PROF("queue_wait");
  if (!q || serial >= q->next)
    return 1;
  ULONGLONG start = GetTickCount64();
  while (q->completed < serial) {
    int status = zenit_d12_queue_collect(q);
    if (status)
      return status;
    if (q->completed >= serial)
      break;
    HRESULT hr = q->owner->raw->GetDeviceRemovedReason();
    if (FAILED(hr))
      return device_failure(q->owner, "queue_wait", hr);
    if (GetTickCount64() - start >= timeout)
      return 3;
    Sleep(1);
  }
  return 0;
}
extern "C" int zenit_d12_queue_destroy(ZenitD12Queue *q, uint32_t timeout) {
  if (!q)
    return 1;
  int status = zenit_d12_queue_wait(q, q->next - 1, timeout);
  if (status && SUCCEEDED(q->owner->raw->GetDeviceRemovedReason()))
    return status;
  // Removed devices cannot complete pending work. Release the submission's
  // references without publishing readback data or marking commands completed.
  for (auto &submission : q->pending)
    zenit_d12_commands_release(submission.commands);
  q->pending.clear();
  zenit_d12_device_release(q->owner);
  delete q;
  return 0;
}
extern "C" void *zenit_d12_queue_native(ZenitD12Queue *q) {
  return q ? q->owner->immediate.p : nullptr;
}
// Buffer bindings are rebuilt at record time. Mapped upload data is immutable
// in the recorded command list even if its caller overwrites or releases it.
static uint64_t arena_unit(uint32_t stride) { return stride ? stride : 16; }
// Word-at-a-time multiply-xorshift over a recorded payload. Equality is always
// confirmed by memcmp; the hash only spreads candidates cheaply.
static uint64_t payload_hash(const unsigned char *src, uint64_t size) {
  uint64_t h = 0x9E3779B97F4A7C15ULL ^ size;
  uint64_t i = 0;
  for (; i + 8 <= size; i += 8) {
    uint64_t w;
    memcpy(&w, src + i, 8);
    h = (h ^ w) * 0xBF58476D1CE4E5B9ULL;
    h ^= h >> 29;
  }
  for (; i < size; ++i) h = (h ^ src[i]) * 0x94D049BB133111EBULL;
  return h;
}
static int arena_bind(ZenitD12Commands *c, const ZenitD12BindingEntry &e,
                      D11Com<ID3D11Buffer> &out, uint64_t &first) {
  D11_PROF("draw.arena_bind");
  const unsigned char *src = e.buffer->host.data() + e.offset;
  const uint64_t size = e.size, unit = arena_unit(e.stride);
  // Same rule as the snapshot cache: small payloads from the same source range
  // with equal bytes share storage; larger ones are always recorded.
  const bool dedupe = size <= 4096;
  uint64_t key = 0;
  if (dedupe) {
    const uint64_t h = payload_hash(src, size);
    key = h ^ ((uint64_t)(uintptr_t)e.buffer->raw.p * 0x9E3779B97F4A7C15ULL) ^ (e.offset << 1) ^ (size << 33);
    for (auto &a : c->arenas) {
      if (a.stride != e.stride) continue;
      auto range = a.segments.equal_range(key);
      for (auto it = range.first; it != range.second; ++it) {
        const auto &seg = it->second;
        if (seg.source == e.buffer->raw.p && seg.offset == e.offset && seg.size == size &&
            memcmp(a.bytes.data() + seg.first, src, (size_t)size) == 0) {
          out = a.buffer;
          first = seg.first;
          ++d11_prof_arena_hits;
          return 0;
        }
      }
    }
  }
  D11StorageArena *target = nullptr;
  uint64_t at = 0;
  for (auto &a : c->arenas) {
    if (a.stride != e.stride) continue;
    const uint64_t aligned = (a.bytes.size() + unit - 1) / unit * unit;
    if (aligned + size <= a.capacity) { target = &a; at = aligned; break; }
  }
  if (!target) {
    const uint64_t want = size > (1u << 20) ? size : (1u << 20);
    const uint64_t capacity = (want + unit - 1) / unit * unit;
    if (capacity > UINT_MAX) return 1;
    D3D11_BUFFER_DESC d = {};
    d.ByteWidth = (UINT)capacity;
    d.Usage = D3D11_USAGE_DEFAULT;
    d.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    if (e.stride) {
      d.MiscFlags = D3D11_RESOURCE_MISC_BUFFER_STRUCTURED;
      d.StructureByteStride = e.stride;
    } else
      d.MiscFlags = D3D11_RESOURCE_MISC_BUFFER_ALLOW_RAW_VIEWS;
    D11StorageArena arena;
    arena.stride = e.stride;
    arena.capacity = capacity;
    HRESULT hr = c->owner->raw->CreateBuffer(&d, nullptr, arena.buffer.put());
    if (FAILED(hr)) return device_failure(c->owner, "CreateBuffer(storage arena)", hr);
    arena.bytes.reserve((size_t)capacity);
    c->arenas.push_back(std::move(arena));
    target = &c->arenas.back();
    at = 0;
  }
  d11_prof_arena_bytes += size;
  if (size > 16384) ++d11_prof_arena_big;
  if (size > d11_prof_arena_max) { d11_prof_arena_max = size; d11_prof_arena_max_stride = e.stride; d11_prof_arena_max_source = e.buffer->size; d11_prof_arena_max_offset = e.offset; }
  target->bytes.resize((size_t)at);
  target->bytes.insert(target->bytes.end(), src, src + size);
  if (dedupe) target->segments.emplace(key, D11ArenaSegment{e.buffer->raw.p, e.offset, size, at});
  ++c->arena_segments;
  out = target->buffer;
  first = at;
  return 0;
}
// Uploads each arena once, on the immediate context, ahead of the command list.
static void arena_upload(ZenitD12Commands *c, ID3D11DeviceContext *immediate) {
  for (auto &a : c->arenas) {
    if (a.bytes.empty()) continue;
    const uint64_t unit = arena_unit(a.stride);
    a.bytes.resize((size_t)((a.bytes.size() + unit - 1) / unit * unit));
    D3D11_BOX box = {0, 0, 0, (UINT)a.bytes.size(), 1, 1};
    immediate->UpdateSubresource(a.buffer, 0, &box, a.bytes.data(), 0, 0);
    std::vector<unsigned char>().swap(a.bytes);
    a.segments.clear();
  }
}
static int binding_buffer(ZenitD12Commands *c, const ZenitD12BindingEntry &e,
                          uint32_t kind, D11Com<ID3D11Buffer> &out,
                          uint64_t *first_byte = nullptr) {
  if (first_byte) *first_byte = 0;
  if (kind == 2 && first_byte && (e.buffer->usage & MAP_WRITE))
    return arena_bind(c, e, out, *first_byte);
  const bool mapped = (e.buffer->usage & MAP_WRITE) != 0;
  // Large mutable ranges would retain an extra CPU copy per distinct payload.
  // Keep byte-comparison caching bounded; GPU-only snapshots need no CPU copy.
  const bool cacheable = (kind == 2 || (kind == 0 && mapped)) &&
                         (!mapped || e.size <= 4096);
  const uint64_t source_version =
      mapped ? 0 : buffer_write_version(c, e.buffer->raw);
  const unsigned char *payload =
      cacheable && mapped ? e.buffer->host.data() + e.offset : nullptr;
  uint64_t mapped_key = 0;
  if (cacheable && mapped) {
    mapped_key = payload_hash(payload, e.size) ^ ((uint64_t)kind << 1) ^ ((uint64_t)e.stride << 8);
    auto range = c->snapshot_index.equal_range(mapped_key);
    for (auto it = range.first; it != range.second; ++it) {
      const auto &snapshot = c->storage_snapshots[it->second];
      // Mapped uniform snapshots are immutable copies. Equal contents can
      // share storage even when the upload ring supplied a different offset.
      const bool same_source = snapshot.source == e.buffer &&
          snapshot.source_native.p == e.buffer->raw.p && snapshot.offset == e.offset;
      if (snapshot.size == e.size && snapshot.stride == e.stride && snapshot.kind == kind &&
          (same_source || kind == 0) &&
          memcmp(snapshot.bytes.data(), payload, (size_t)e.size) == 0) {
        if (kind == 0) ++c->uniform_reuses;
        out = snapshot.buffer;
        return 0;
      }
    }
  } else if (cacheable) {
    for (const auto &snapshot : c->storage_snapshots) {
      // Mapped uniform snapshots are immutable copies. Equal contents can
      // share storage even when the upload ring supplied a different offset.
      const bool same_source = (!mapped || snapshot.source == e.buffer) &&
          snapshot.source_native.p == e.buffer->raw.p && snapshot.offset == e.offset;
      if (snapshot.size == e.size && snapshot.stride == e.stride &&
          snapshot.kind == kind && (same_source || (kind == 0 && mapped)) &&
          (mapped ? memcmp(snapshot.bytes.data(), payload, (size_t)e.size) == 0
                  : snapshot.source_version == source_version)) {
        if (kind == 0) ++c->uniform_reuses;
        out = snapshot.buffer;
        return 0;
      }
    }
  }
  D11ExclusiveLock uniform_lock(cacheable && kind == 0 ? &c->owner->uniform_lock : nullptr);
  if (uniform_lock.lock) {
    for (const auto &cached : c->owner->uniforms) {
      if (cached.bytes.size() == e.size && memcmp(cached.bytes.data(), payload, (size_t)e.size) == 0) {
        out = cached.buffer;
        ++c->uniform_device_reuses;
        break;
      }
    }
  }
  D3D11_BUFFER_DESC d = {};
  d.ByteWidth = (UINT)e.size;
  d.Usage = D3D11_USAGE_DEFAULT;
  if (kind == 0) {
    d.ByteWidth = (d.ByteWidth + 15) & ~15u;
    d.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
  } else {
    d.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    if (kind == 3)
      d.BindFlags |= D3D11_BIND_UNORDERED_ACCESS;
    if (e.stride) {
      d.MiscFlags = D3D11_RESOURCE_MISC_BUFFER_STRUCTURED;
      d.StructureByteStride = e.stride;
    } else
      d.MiscFlags = D3D11_RESOURCE_MISC_BUFFER_ALLOW_RAW_VIEWS;
  }
  D3D11_SUBRESOURCE_DATA initial = {};
  std::vector<unsigned char> aligned;
  if (e.buffer->usage & MAP_WRITE) {
    aligned.resize(d.ByteWidth);
    memcpy(aligned.data(), e.buffer->host.data() + e.offset, (size_t)e.size);
    initial.pSysMem = aligned.data();
  }
  if (!out.p) {
    HRESULT hr = c->owner->raw->CreateBuffer(&d, initial.pSysMem ? &initial : nullptr, out.put());
    if (FAILED(hr)) return device_failure(c->owner, "CreateBuffer(binding)", hr);
    if (kind == 0) ++c->uniform_allocations;
    if (uniform_lock.lock) {
      D11CachedUniform cached;
      cached.bytes.assign(payload, payload + e.size);
      cached.buffer = out;
      if (c->owner->uniforms.size() == 128) c->owner->uniforms.erase(c->owner->uniforms.begin());
      c->owner->uniforms.push_back(std::move(cached));
      ++c->owner->uniform_buffer_creations;
    }
  }
  uniform_lock.release();
  if (cacheable) {
    D11StorageSnapshot snapshot;
    snapshot.source = e.buffer;
    snapshot.source_native = e.buffer->raw;
    snapshot.buffer = out;
    snapshot.offset = e.offset;
    snapshot.size = e.size;
    snapshot.source_version = source_version;
    snapshot.stride = e.stride;
    snapshot.kind = kind;
    snapshot.bytes = std::move(aligned);
    if (mapped) c->snapshot_index.emplace(mapped_key, c->storage_snapshots.size());
    c->storage_snapshots.push_back(std::move(snapshot));
  }
  if (!initial.pSysMem) {
    if (kind == 0) {
      D3D11_BUFFER_DESC old = {};
      e.buffer->raw->GetDesc(&old);
      if (e.offset || old.ByteWidth != d.ByteWidth)
        return 1;
      c->context->CopyResource(out, e.buffer->raw);
    } else {
      D3D11_BOX box = {(UINT)e.offset, 0, 0, (UINT)(e.offset + e.size), 1, 1};
      c->context->CopySubresourceRegion(out, 0, 0, 0, 0, e.buffer->raw, 0,
                                        &box);
    }
  }
  return 0;
}
extern "C" uint64_t zenit_d11_uniform_buffer_creations(ZenitD12Device *d) {
  D11ExclusiveLock lock(&d->uniform_lock);
  return d->uniform_buffer_creations;
}
extern "C" void zenit_d11_clear_uniform_cache(ZenitD12Device *d) {
  D11ExclusiveLock lock(&d->uniform_lock);
  d->uniforms.clear();
}
// Native acceptance inspects actual distinct snapshots, rather than inferring
// reuse from pixels (which would also pass with an allocation for every draw).
extern "C" uint32_t
zenit_d11_commands_storage_snapshot_count(ZenitD12Commands *c) {
  return c ? (uint32_t)c->storage_snapshots.size() + c->arena_segments : 0;
}
struct D11WritableBinding {
  D11Com<ID3D11Buffer> temporary;
  D11Com<ID3D11Buffer> original;
  UINT offset, size;
};
static int bind_groups(ZenitD12Commands *c, ZenitD12PipelineLayout *layout,
                       ZenitD12BindGroup *const *groups, uint32_t count,
                       bool compute, std::vector<D11WritableBinding> &writes) {
  D11_PROF("draw.bind_groups");
  if (count != layout->groups || (count && !groups))
    return 1;
  for (uint32_t g = 0; g < count; ++g) {
    auto group = groups[g];
    if (!group || group->layout != layout || group->group != g)
      return 1;
    for (auto &e : group->entries) {
      auto b = layout_binding(layout, g, e.binding);
      uint32_t slot = g * register_width(b->kind) + e.binding + e.array_index;
      auto setcb = [&](ID3D11Buffer *p) {
        if (compute)
          c->context->CSSetConstantBuffers(slot, 1, &p);
        else {
          if (b->visibility & 1)
            c->context->VSSetConstantBuffers(slot, 1, &p);
          if (b->visibility & 2)
            c->context->PSSetConstantBuffers(slot, 1, &p);
        }
      };
      auto setsrv = [&](ID3D11ShaderResourceView *p) {
        if (compute)
          c->context->CSSetShaderResources(slot, 1, &p);
        else {
          if (b->visibility & 1)
            c->context->VSSetShaderResources(slot, 1, &p);
          if (b->visibility & 2)
            c->context->PSSetShaderResources(slot, 1, &p);
        }
      };
      if (b->kind == 0 || b->kind == 2 || b->kind == 3) {
        D11Com<ID3D11Buffer> buffer;
        uint64_t first_byte = 0;
        int status = binding_buffer(c, e, b->kind, buffer, b->kind == 2 ? &first_byte : nullptr);
        if (status)
          return status;
        if (b->kind == 0)
          setcb(buffer);
        else if (b->kind == 2) {
          D3D11_SHADER_RESOURCE_VIEW_DESC desc = {};
          desc.Format =
              e.stride ? DXGI_FORMAT_UNKNOWN : DXGI_FORMAT_R32_TYPELESS;
          desc.ViewDimension = e.stride ? D3D11_SRV_DIMENSION_BUFFER
                                        : D3D11_SRV_DIMENSION_BUFFEREX;
          desc.BufferEx.FirstElement = (UINT)(first_byte / (e.stride ? e.stride : 4));
          desc.BufferEx.NumElements =
              (UINT)(e.size / (e.stride ? e.stride : 4));
          desc.BufferEx.Flags = e.stride ? 0 : D3D11_BUFFEREX_SRV_FLAG_RAW;
          D11Com<ID3D11ShaderResourceView> srv;
          HRESULT hr =
              c->owner->raw->CreateShaderResourceView(buffer, &desc, srv.put());
          if (FAILED(hr))
            return result(hr);
          setsrv(srv);
        } else {
          if (!compute)
            return 1;
          D3D11_UNORDERED_ACCESS_VIEW_DESC desc = {};
          desc.Format =
              e.stride ? DXGI_FORMAT_UNKNOWN : DXGI_FORMAT_R32_TYPELESS;
          desc.ViewDimension = D3D11_UAV_DIMENSION_BUFFER;
          desc.Buffer.NumElements = (UINT)(e.size / (e.stride ? e.stride : 4));
          desc.Buffer.Flags = e.stride ? 0 : D3D11_BUFFER_UAV_FLAG_RAW;
          D11Com<ID3D11UnorderedAccessView> uav;
          HRESULT hr = c->owner->raw->CreateUnorderedAccessView(buffer, &desc,
                                                                uav.put());
          if (FAILED(hr))
            return result(hr);
          ID3D11UnorderedAccessView *raw = uav;
          c->context->CSSetUnorderedAccessViews(slot, 1, &raw, nullptr);
          D11WritableBinding w;
          w.temporary = buffer;
          w.original = D11Com<ID3D11Buffer>(e.buffer->raw.p);
          e.buffer->raw->AddRef();
          w.offset = (UINT)e.offset;
          w.size = (UINT)e.size;
          writes.push_back(std::move(w));
        }
      } else if (b->kind == 1)
        setsrv(e.view->srv);
      else if (b->kind == 4) {
        ID3D11SamplerState *p = e.sampler->raw;
        if (compute)
          c->context->CSSetSamplers(slot, 1, &p);
        else {
          if (b->visibility & 1)
            c->context->VSSetSamplers(slot, 1, &p);
          if (b->visibility & 2)
            c->context->PSSetSamplers(slot, 1, &p);
        }
      } else {
        if (!compute)
          return 1;
        ID3D11UnorderedAccessView *p = e.view->uav;
        c->context->CSSetUnorderedAccessViews(slot, 1, &p, nullptr);
      }
    }
  }
  return 0;
}
extern "C" int zenit_d12_commands_dispatch(ZenitD12Commands *c,
                                           ZenitD12ComputePipeline *p,
                                           ZenitD12BindGroup *const *groups,
                                           uint32_t count, uint32_t x,
                                           uint32_t y, uint32_t z) {
  D11_PROF("commands_dispatch");
  if (!recording(c) || c->pass || !p || p->layout->owner != c->owner || !x ||
      !y || !z || x > 65535 || y > 65535 || z > 65535)
    return 1;
  unbind_srvs(c->context);
  std::vector<D11WritableBinding> writes;
  int status = bind_groups(c, p->layout, groups, count, true, writes);
  if (status)
    return status;
  c->context->CSSetShader(p->cs, nullptr, 0);
  c->context->Dispatch(x, y, z);
  unbind_srvs(c->context);
  for (auto &w : writes) {
    mark_buffer_written(c, w.original);
    D3D11_BOX box = {0, 0, 0, w.size, 1, 1};
    c->context->CopySubresourceRegion(w.original, 0, w.offset, 0, 0,
                                      w.temporary, 0, &box);
  }
  return 0;
}
static void destroy_pass(ZenitD12RenderPass *p) {
  for (auto &a : p->colors) {
    zenit_d12_texture_release(a.texture);
    zenit_d12_texture_release(a.resolve);
  }
  zenit_d12_texture_release(p->depth.texture);
  zenit_d12_commands_release(p->commands);
  delete p;
}
extern "C" int zenit_d12_render_pass_begin(
    ZenitD12Commands *c, const ZenitD12ColorAttachment *colors, uint32_t count,
    const ZenitD12DepthAttachment *depth, ZenitD12RenderPass **out) {
  D11_PROF("render_pass_begin");
  if (!out)
    return 1;
  *out = nullptr;
  if (!recording(c) || c->pass || count > 8 || (count && !colors) ||
      (!count && (!depth || !depth->texture)))
    return 1;
  auto p = new (std::nothrow) ZenitD12RenderPass;
  if (!p)
    return 2;
  p->commands = c;
  InterlockedIncrement(&c->refs);
  if (count)
    p->colors.assign(colors, colors + count);
  for (auto &a : p->colors) {
    zenit_d12_texture_retain(a.texture);
    zenit_d12_texture_retain(a.resolve);
  }
  if (depth) {
    p->depth = *depth;
    zenit_d12_texture_retain(depth->texture);
  }
  auto size_ok = [&](ZenitD12Texture *t, uint32_t mip, uint32_t layer) {
    if (!t || t->owner != c->owner || t->dimension != 2 || !(t->usage & 16) ||
        mip >= t->mips || layer >= t->depth)
      return false;
    uint32_t w = std::max(1u, t->width >> mip),
             h = std::max(1u, t->height >> mip);
    if (p->width && (p->width != w || p->height != h))
      return false;
    p->width = w;
    p->height = h;
    return true;
  };
  HRESULT hr = S_OK;
  for (auto &a : p->colors) {
    if (!size_ok(a.texture, a.mip, a.layer) ||
        depth_format(a.texture->format) || a.load_op > 2 || a.store_op > 1) {
      destroy_pass(p);
      return 1;
    }
    if (a.resolve && (!size_ok(a.resolve, a.resolve_mip, a.resolve_layer) ||
                      a.texture->samples == 1 || a.resolve->samples != 1 ||
                      a.resolve->format != a.texture->format)) {
      destroy_pass(p);
      return 1;
    }
    D3D11_RENDER_TARGET_VIEW_DESC d = {};
    d.Format = a.texture->format;
    if (a.texture->samples > 1) {
      if (a.texture->depth > 1) {
        d.ViewDimension = D3D11_RTV_DIMENSION_TEXTURE2DMSARRAY;
        d.Texture2DMSArray = {a.layer, 1};
      } else
        d.ViewDimension = D3D11_RTV_DIMENSION_TEXTURE2DMS;
    } else {
      d.ViewDimension = D3D11_RTV_DIMENSION_TEXTURE2DARRAY;
      d.Texture2DArray = {a.mip, a.layer, 1};
    }
    D11Com<ID3D11RenderTargetView> r;
    hr = c->owner->raw->CreateRenderTargetView(a.texture->raw, &d, r.put());
    if (FAILED(hr)) {
      destroy_pass(p);
      return result(hr);
    }
    p->rtvs.push_back(std::move(r));
  }
  if (depth && depth->texture) {
    auto &a = *depth;
    if (!size_ok(a.texture, a.mip, a.layer) ||
        !depth_format(a.texture->format) || a.depth_load > 2 ||
        a.stencil_load > 2 || a.depth_store > 1 || a.stencil_store > 1) {
      destroy_pass(p);
      return 1;
    }
    D3D11_DEPTH_STENCIL_VIEW_DESC d = {};
    d.Format = a.texture->format;
    if (a.depth_read_only)
      d.Flags |= D3D11_DSV_READ_ONLY_DEPTH;
    if (a.stencil_read_only)
      d.Flags |= D3D11_DSV_READ_ONLY_STENCIL;
    if (a.texture->samples > 1) {
      d.ViewDimension = D3D11_DSV_DIMENSION_TEXTURE2DMSARRAY;
      d.Texture2DMSArray = {a.layer, 1};
    } else {
      d.ViewDimension = D3D11_DSV_DIMENSION_TEXTURE2DARRAY;
      d.Texture2DArray = {a.mip, a.layer, 1};
    }
    hr =
        c->owner->raw->CreateDepthStencilView(a.texture->raw, &d, p->dsv.put());
    if (FAILED(hr)) {
      destroy_pass(p);
      return result(hr);
    }
  }
  unbind_srvs(c->context);
  ID3D11RenderTargetView *raw[8] = {};
  for (uint32_t i = 0; i < count; ++i)
    raw[i] = p->rtvs[i];
  c->context->OMSetRenderTargets(count, raw, p->dsv);
  for (uint32_t i = 0; i < count; ++i) {
    auto &a = p->colors[i];
    if (a.load_op == 1)
      c->context->ClearRenderTargetView(raw[i], a.clear);
    else if (a.load_op == 2 && c->context1)
      c->context1->DiscardView(raw[i]);
  }
  if (p->dsv) {
    UINT flags = 0;
    if (p->depth.depth_load == 1 && !p->depth.depth_read_only)
      flags |= D3D11_CLEAR_DEPTH;
    if (p->depth.stencil_load == 1 && !p->depth.stencil_read_only)
      flags |= D3D11_CLEAR_STENCIL;
    if (flags)
      c->context->ClearDepthStencilView(p->dsv, flags, p->depth.clear,
                                        (UINT8)p->depth.stencil_clear);
  }
  c->pass = true;
  *out = p;
  return 0;
}
extern "C" int zenit_d12_render_pass_regions(ZenitD12RenderPass *p,
                                             const uint32_t *bounds,
                                             uint32_t count) {
  D11_PROF("render_pass_regions");
  if (!p || !p->commands->pass || (count && !bounds))
    return 1;
  std::vector<D3D11_RECT> regions;
  for (uint32_t i = 0; i < count; ++i) {
    const uint32_t *b = bounds + 4 * i;
    if (b[0] > p->width || b[2] > p->width - b[0] || b[1] > p->height ||
        b[3] > p->height - b[1])
      return 1;
    if (!b[2] || !b[3])
      continue;
    std::vector<D3D11_RECT> fragments = {
        {(LONG)b[0], (LONG)b[1], (LONG)(b[0] + b[2]), (LONG)(b[1] + b[3])}};
    for (auto &old : regions) {
      std::vector<D3D11_RECT> next;
      for (auto &f : fragments) {
        LONG l = std::max(f.left, old.left), r = std::min(f.right, old.right),
             t = std::max(f.top, old.top), bot = std::min(f.bottom, old.bottom);
        if (l >= r || t >= bot) {
          next.push_back(f);
          continue;
        }
        if (f.top < t)
          next.push_back({f.left, f.top, f.right, t});
        if (bot < f.bottom)
          next.push_back({f.left, bot, f.right, f.bottom});
        if (f.left < l)
          next.push_back({f.left, t, l, bot});
        if (r < f.right)
          next.push_back({r, t, f.right, bot});
      }
      fragments = std::move(next);
    }
    regions.insert(regions.end(), fragments.begin(), fragments.end());
  }
  p->regions = std::move(regions);
  p->regions_set = count != 0;
  return 0;
}
// A small draw provides exact rectangular clears even on 11.0 drivers whose
// context exposes ID3D11DeviceContext1 but lacks the ClearView capability.
extern "C" int zenit_d12_render_pass_clear_opaque(ZenitD12RenderPass *p,
                                                  const float *color,
                                                  uint32_t x, uint32_t y,
                                                  uint32_t width,
                                                  uint32_t height) {
  D11_PROF("render_pass_clear_opaque");
  if (!p || !p->commands->pass || p->colors.size() != 1 || !color ||
      color[3] != 1 || x > p->width || width > p->width - x || y > p->height ||
      height > p->height - y)
    return 1;
  if (!width || !height)
    return 0;
  auto c = p->commands;
  D3D11_FEATURE_DATA_D3D11_OPTIONS options = {};
  bool clear_view =
      SUCCEEDED(c->owner->raw->CheckFeatureSupport(
          D3D11_FEATURE_D3D11_OPTIONS, &options, sizeof(options))) &&
      options.ClearView;
  const bool trace = cpu_timing_trace_enabled();
  if (trace && InterlockedExchange(&c->owner->clear_diagnostic_reported, 1) == 0)
    fprintf(stderr, "[d3d11-cpu] clear_view=%d context1=%d\n",
            clear_view ? 1 : 0, c->context1 ? 1 : 0);
  D3D11_RECT rect = {(LONG)x, (LONG)y, (LONG)(x + width), (LONG)(y + height)};
  if (c->context1 && clear_view) {
    c->context1->ClearView(p->rtvs[0], color, &rect, 1);
    return 0;
  }
  const uint64_t clear_start = trace ? cpu_time_micros() : 0;
  const char *source =
      "cbuffer Color:register(b0){float4 color;}float4 vs(uint "
      "id:SV_VertexID):SV_Position{float2 p=float2((id<<1)&2,id&2);return "
      "float4(p*float2(2,-2)+float2(-1,1),0,1);}float4 ps():SV_Target{return "
      "color;}";
  D11Com<ID3DBlob> vb, pb;
  HRESULT hr = D3DCompile(source, strlen(source), nullptr, nullptr, nullptr,
                          "vs", "vs_5_0", 0, 0, vb.put(), nullptr);
  if (SUCCEEDED(hr))
    hr = D3DCompile(source, strlen(source), nullptr, nullptr, nullptr, "ps",
                    "ps_5_0", 0, 0, pb.put(), nullptr);
  D11Com<ID3D11VertexShader> vs;
  D11Com<ID3D11PixelShader> ps;
  D11Com<ID3D11Buffer> cb;
  D11Com<ID3D11RasterizerState> rs;
  D11Com<ID3D11DepthStencilState> ds;
  D11Com<ID3D11BlendState> bs;
  if (SUCCEEDED(hr))
    hr = c->owner->raw->CreateVertexShader(
        vb->GetBufferPointer(), vb->GetBufferSize(), nullptr, vs.put());
  if (SUCCEEDED(hr))
    hr = c->owner->raw->CreatePixelShader(
        pb->GetBufferPointer(), pb->GetBufferSize(), nullptr, ps.put());
  D3D11_BUFFER_DESC bd = {};
  bd.ByteWidth = 16;
  bd.Usage = D3D11_USAGE_IMMUTABLE;
  bd.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
  D3D11_SUBRESOURCE_DATA initial = {color, 0, 0};
  if (SUCCEEDED(hr))
    hr = c->owner->raw->CreateBuffer(&bd, &initial, cb.put());
  D3D11_RASTERIZER_DESC rd = {};
  rd.FillMode = D3D11_FILL_SOLID;
  rd.CullMode = D3D11_CULL_NONE;
  rd.DepthClipEnable = TRUE;
  rd.ScissorEnable = TRUE;
  if (SUCCEEDED(hr))
    hr = c->owner->raw->CreateRasterizerState(&rd, rs.put());
  D3D11_DEPTH_STENCIL_DESC dd = {};
  dd.DepthFunc = D3D11_COMPARISON_ALWAYS;
  dd.FrontFace = {D3D11_STENCIL_OP_KEEP, D3D11_STENCIL_OP_KEEP,
                  D3D11_STENCIL_OP_KEEP, D3D11_COMPARISON_ALWAYS};
  dd.BackFace = dd.FrontFace;
  if (SUCCEEDED(hr))
    hr = c->owner->raw->CreateDepthStencilState(&dd, ds.put());
  D3D11_BLEND_DESC bl = {};
  bl.RenderTarget[0].RenderTargetWriteMask = 15;
  if (SUCCEEDED(hr))
    hr = c->owner->raw->CreateBlendState(&bl, bs.put());
  if (FAILED(hr))
    return result(hr);
  ID3D11Buffer *rawcb = cb;
  c->context->PSSetConstantBuffers(0, 1, &rawcb);
  c->context->VSSetShader(vs, nullptr, 0);
  c->context->PSSetShader(ps, nullptr, 0);
  c->context->IASetInputLayout(nullptr);
  c->context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
  c->context->RSSetState(rs);
  c->context->OMSetBlendState(bs, nullptr, UINT_MAX);
  c->context->OMSetDepthStencilState(ds, 0);
  D3D11_VIEWPORT viewport = {0, 0, (float)p->width, (float)p->height, 0, 1};
  c->context->RSSetViewports(1, &viewport);
  c->context->RSSetScissorRects(1, &rect);
  c->context->Draw(3, 0);
  if (trace)
    fprintf(stderr, "[d3d11-cpu] clear_fallback_us=%llu\n",
            (unsigned long long)(cpu_time_micros() - clear_start));
  return 0;
}
static int vertex_buffer(ZenitD12Commands *c, ZenitD12Buffer *b,
                         uint64_t offset, uint64_t bytes, UINT bind,
                         D11Com<ID3D11Buffer> &out) {
  D11_PROF("draw.vertex_buffer");
  if (!(b->usage & MAP_WRITE)) {
    out = D11Com<ID3D11Buffer>(b->raw.p);
    b->raw->AddRef();
    return 0;
  }
  D3D11_BUFFER_DESC d = {};
  d.ByteWidth = (UINT)bytes;
  d.Usage = D3D11_USAGE_IMMUTABLE;
  d.BindFlags = bind;
  D3D11_SUBRESOURCE_DATA initial = {b->host.data() + offset, 0, 0};
  HRESULT hr = c->owner->raw->CreateBuffer(&d, &initial, out.put());
  return FAILED(hr) ? device_failure(c->owner, "CreateBuffer(vertex)", hr) : 0;
}
extern "C" int zenit_d12_render_pass_draw(ZenitD12RenderPass *p,
                                          ZenitD12RenderPipeline *pipeline,
                                          const ZenitD12Draw *draw) {
  D11_PROF("render_pass_draw");
  if (!p || !p->commands->pass || !pipeline || !draw ||
      pipeline->layout->owner != p->commands->owner ||
      draw->buffer_count > 32 || (draw->buffer_count && !draw->buffers) ||
      pipeline->info.target_count != p->colors.size() ||
      draw->group_count != pipeline->layout->groups ||
      (draw->group_count && !draw->groups))
    return 1;
  auto c = p->commands;
  for (uint32_t i = 0; i < p->colors.size(); ++i)
    if (pipeline->info.formats[i] != uint32_t(p->colors[i].texture->format) ||
        pipeline->info.samples != p->colors[i].texture->samples)
      return 1;
  if (pipeline->info.depth_format !=
      (p->depth.texture ? uint32_t(p->depth.texture->format) : 0))
    return 1;
  uint32_t width = draw->width, height = draw->height;
  if (width == UINT_MAX && height == UINT_MAX) {
    width = p->width;
    height = p->height;
  }
  if (draw->x > p->width || width > p->width - draw->x || draw->y > p->height ||
      height > p->height - draw->y || draw->stencil_reference > 255)
    return 1;
  if (!width || !height || !draw->vertices || !draw->instances)
    return 0;
  for (uint32_t g = 0; g < draw->group_count; ++g) {
    if (!draw->groups[g] || zenit_d12_render_validate_bindings(
                                pipeline, g, draw->groups[g]->entries.data(),
                                (uint32_t)draw->groups[g]->entries.size()))
      return 1;
    for (auto &e : draw->groups[g]->entries)
      if (e.view) {
        for (auto &a : p->colors)
          if (e.view->texture == a.texture)
            return 1;
      }
  }
  unbind_srvs(c->context);
  std::vector<D11WritableBinding> writes;
  int status = bind_groups(c, pipeline->layout, draw->groups, draw->group_count,
                           false, writes);
  if (status)
    return status;
  c->context->VSSetShader(pipeline->vs, nullptr, 0);
  c->context->PSSetShader(pipeline->ps, nullptr, 0);
  c->context->IASetInputLayout(pipeline->input);
  c->context->IASetPrimitiveTopology(
      (D3D11_PRIMITIVE_TOPOLOGY)pipeline->info.topology);
  c->context->RSSetState(pipeline->raster);
  c->context->OMSetBlendState(pipeline->blend, draw->blend,
                              pipeline->sample_mask);
  c->context->OMSetDepthStencilState(pipeline->depth, draw->stencil_reference);
  D3D11_VIEWPORT viewport = {0, 0, (float)p->width, (float)p->height, 0, 1};
  if (draw->has_viewport) {
    viewport = {draw->viewport[0], draw->viewport[1], draw->viewport[2],
                draw->viewport[3], draw->viewport[4], draw->viewport[5]};
    if (!(viewport.Width > 0 && viewport.Height > 0 && viewport.MinDepth >= 0 &&
          viewport.MaxDepth <= 1 && viewport.MinDepth <= viewport.MaxDepth))
      return 1;
  }
  c->context->RSSetViewports(1, &viewport);
  UINT bound = 0;
  for (uint32_t i = 0; i < draw->buffer_count; ++i) {
    auto &v = draw->buffers[i];
    if (!v.buffer || v.buffer->owner != c->owner ||
        !(v.buffer->usage & VERTEX) || v.slot >= 32 ||
        !(pipeline->info.slots & (1u << v.slot)) || (bound & (1u << v.slot)) ||
        !v.size || v.offset > v.buffer->size ||
        v.size > v.buffer->size - v.offset)
      return 1;
    UINT stride = pipeline->info.strides[v.slot];
    uint64_t first = pipeline->info.steps[v.slot]
                         ? draw->first_instance
                         : (draw->index_buffer ? 0 : draw->first_vertex),
             count = pipeline->info.steps[v.slot] ? draw->instances
                                                  : draw->vertices;
    if ((!draw->index_buffer || pipeline->info.steps[v.slot]) &&
        ((first + count - 1) * stride + pipeline->info.ends[v.slot] > v.size))
      return 1;
    D11Com<ID3D11Buffer> buffer;
    status = vertex_buffer(c, v.buffer, v.offset, v.size,
                           D3D11_BIND_VERTEX_BUFFER, buffer);
    if (status)
      return status;
    UINT offset = (v.buffer->usage & MAP_WRITE) ? 0 : (UINT)v.offset;
    if (first * stride > UINT_MAX - offset)
      return 1;
    offset += (UINT)(first * stride);
    ID3D11Buffer *raw = buffer;
    c->context->IASetVertexBuffers(v.slot, 1, &raw, &stride, &offset);
    bound |= 1u << v.slot;
  }
  if (bound != pipeline->info.slots)
    return 1;
  if (draw->index_buffer) {
    auto b = draw->index_buffer;
    uint32_t unit = draw->index_format == 1   ? 2
                    : draw->index_format == 2 ? 4
                                              : 0;
    if (!unit || b->owner != c->owner || !(b->usage & INDEX) ||
        draw->index_offset % unit || draw->index_offset > b->size ||
        draw->index_size > b->size - draw->index_offset ||
        ((uint64_t)draw->first_index + draw->vertices) * unit >
            draw->index_size)
      return 1;
    D11Com<ID3D11Buffer> buffer;
    status = vertex_buffer(c, b, draw->index_offset, draw->index_size,
                           D3D11_BIND_INDEX_BUFFER, buffer);
    if (status)
      return status;
    c->context->IASetIndexBuffer(
        buffer, unit == 2 ? DXGI_FORMAT_R16_UINT : DXGI_FORMAT_R32_UINT,
        (b->usage & MAP_WRITE) ? 0 : (UINT)draw->index_offset);
  } else
    c->context->IASetIndexBuffer(nullptr, DXGI_FORMAT_R16_UINT, 0);
  uint32_t info[4] = {draw->index_buffer ? 0u : draw->first_vertex,
                      draw->first_instance, 0, 0};
  D3D11_BUFFER_DESC bd = {};
  bd.ByteWidth = 16;
  bd.Usage = D3D11_USAGE_IMMUTABLE;
  bd.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
  D3D11_SUBRESOURCE_DATA initial = {info, 0, 0};
  D11Com<ID3D11Buffer> constants;
  {
    D11_PROF("draw.info_constants");
    const uint64_t key = (uint64_t)info[0] | ((uint64_t)info[1] << 32);
    D11ExclusiveLock lock(&c->owner->uniform_lock);
    auto found = c->owner->draw_info.find(key);
    if (found != c->owner->draw_info.end()) {
      constants = found->second;
    } else {
      HRESULT hr = c->owner->raw->CreateBuffer(&bd, &initial, constants.put());
      if (FAILED(hr))
        return result(hr);
      if (c->owner->draw_info.size() >= 4096) c->owner->draw_info.clear();
      c->owner->draw_info.emplace(key, constants);
    }
  }
  ID3D11Buffer *raw = constants;
  c->context->VSSetConstantBuffers(12, 1, &raw);
  c->context->PSSetConstantBuffers(12, 1, &raw);
  D3D11_RECT scissor = {(LONG)draw->x, (LONG)draw->y, (LONG)(draw->x + width),
                        (LONG)(draw->y + height)};
  auto issue = [&](const D3D11_RECT &r) {
    if (r.left >= r.right || r.top >= r.bottom)
      return;
    c->context->RSSetScissorRects(1, &r);
    if (draw->index_buffer)
      c->context->DrawIndexedInstanced(draw->vertices, draw->instances,
                                       draw->first_index, draw->base_vertex, 0);
    else
      c->context->DrawInstanced(draw->vertices, draw->instances, 0, 0);
  };
  if (!p->regions_set)
    issue(scissor);
  else
    for (auto &region : p->regions) {
      D3D11_RECT r = {std::max(scissor.left, region.left),
                      std::max(scissor.top, region.top),
                      std::min(scissor.right, region.right),
                      std::min(scissor.bottom, region.bottom)};
      issue(r);
    }
  unbind_srvs(c->context);
  return 0;
}
// Entry form of render_pass_draw (see d3d12_resources.h): the D3D11 backend
// keeps bind groups as plain entry lists, so build them and draw.
extern "C" int zenit_d12_render_pass_draw_entries(
    ZenitD12RenderPass *p, ZenitD12RenderPipeline *pipeline,
    const ZenitD12Draw *draw, const ZenitD12BindingEntry *entries,
    const uint32_t *group_counts, uint32_t group_count) {
  if (!p || !pipeline || !draw || draw->group_count ||
      group_count > 4 || (group_count && !group_counts))
    return 1;
  ZenitD12BindGroup *groups[4] = {};
  int status = 0;
  uint32_t created = 0;
  for (uint32_t g = 0, at = 0; g < group_count; at += group_counts[g], ++g) {
    status = zenit_d12_bind_group_create(p->commands->owner, pipeline->layout,
                                         g, entries + at, group_counts[g],
                                         &groups[g]);
    if (status) {
      if (status == 1)
        status = 6; // bind_group_create rejection: error.InvalidBindGroup
      break;
    }
    ++created;
  }
  if (!status) {
    ZenitD12Draw grouped = *draw;
    grouped.groups = groups;
    grouped.group_count = group_count;
    status = zenit_d12_render_pass_draw(p, pipeline, &grouped);
  }
  for (uint32_t g = 0; g < created; ++g)
    zenit_d12_bind_group_release(groups[g]);
  return status;
}
extern "C" int zenit_d12_render_pass_end(ZenitD12RenderPass *p) {
  D11_PROF("render_pass_end");
  if (!p || !p->commands->pass)
    return 1;
  auto c = p->commands;
  unbind_srvs(c->context);
  c->context->OMSetRenderTargets(0, nullptr, nullptr);
  for (size_t i = 0; i < p->colors.size(); ++i) {
    auto &a = p->colors[i];
    if (a.resolve)
      c->context->ResolveSubresource(
          a.resolve->raw,
          D3D11CalcSubresource(a.resolve_mip, a.resolve_layer, a.resolve->mips),
          a.texture->raw, D3D11CalcSubresource(a.mip, a.layer, a.texture->mips),
          a.texture->format);
    if (a.store_op == 1 && c->context1)
      c->context1->DiscardView(p->rtvs[i]);
  }
  if (p->dsv && p->depth.depth_store == 1 && p->depth.stencil_store == 1 &&
      c->context1)
    c->context1->DiscardView(p->dsv);
  c->pass = false;
  destroy_pass(p);
  return 0;
}
ZenitD12Surface::~ZenitD12Surface() {
  // Detach composition's references before the swap chain member is released.
  // This also handles partially constructed surfaces and removed devices.
  if (composition_target)
    composition_target->SetRoot(nullptr);
  for (auto &part : composition_parts)
    if (part)
      part->SetContent(nullptr);
  if (composition_root)
    composition_root->RemoveAllVisuals();
  if (composition)
    composition->Commit();
}
static HRESULT surface_update_composition(ZenitD12Surface *s) {
  if (!s->composition)
    return S_OK;
  DXGI_SWAP_CHAIN_DESC1 desc = {};
  HRESULT hr = s->swap->GetDesc1(&desc);
  if (FAILED(hr))
    return hr;
  RECT buttons = {}, outer;
  POINT origin = {};
  // Only while DWM actually paints caption buttons over this client (the bridge
  // maintains the property); application-painted controls keep the whole
  // surface, otherwise their slots are cut out and left black.
  if (GetPropW(s->hwnd, L"Zenit.DwmCaption")) {
    hr = DwmGetWindowAttribute(s->hwnd, DWMWA_CAPTION_BUTTON_BOUNDS, &buttons,
                               sizeof(buttons));
    if (FAILED(hr) || !GetWindowRect(s->hwnd, &outer) ||
        !ClientToScreen(s->hwnd, &origin))
      return E_FAIL;
    OffsetRect(&buttons, outer.left - origin.x, outer.top - origin.y);
    buttons.left = std::clamp(buttons.left, 0L, (LONG)desc.Width);
    buttons.right = std::clamp(buttons.right, buttons.left, (LONG)desc.Width);
    buttons.top = std::clamp(buttons.top, 0L, (LONG)desc.Height);
    buttons.bottom = std::clamp(buttons.bottom, buttons.top, (LONG)desc.Height);
  }
  if (s->clip_valid && EqualRect(&buttons, &s->caption_clip))
    return S_OK;
  // Remove redirected HWND pixels under DWM's native caption controls. The
  // submitted texture remains intact for frame readback and capture contracts.
  HDC dc = GetDC(s->hwnd);
  if (!dc)
    return E_FAIL;
  BOOL cleared =
      buttons.right == buttons.left || buttons.bottom == buttons.top ||
      PatBlt(dc, buttons.left, buttons.top, buttons.right - buttons.left,
             buttons.bottom - buttons.top, BLACKNESS);
  ReleaseDC(s->hwnd, dc);
  if (!cleared)
    return E_FAIL;
  const float w = (float)desc.Width, h = (float)desc.Height;
  const float l = (float)buttons.left, r = (float)buttons.right,
              t = (float)buttons.top, b = (float)buttons.bottom;
  const D2D_RECT_F clips[4] = {
      {0, 0, w, t}, {0, t, l, b}, {r, t, w, b}, {0, b, w, h}};
  for (unsigned i = 0; i < 4 && SUCCEEDED(hr); ++i)
    hr = s->composition_parts[i]->SetClip(clips[i]);
  if (SUCCEEDED(hr))
    hr = s->composition->Commit();
  if (SUCCEEDED(hr)) {
    s->caption_clip = buttons;
    s->clip_valid = true;
  }
  return hr;
}
extern "C" int zenit_d12_surface_create(ZenitD12Queue *q, void *hwnd,
                                        uint32_t width, uint32_t height,
                                        uint32_t format, uint32_t buffers,
                                        ZenitD12Surface **out) {
  if (!out)
    return 1;
  *out = nullptr;
  if (!q || !hwnd || !width || !height || buffers < 2 || buffers > 16 ||
      (format != DXGI_FORMAT_R8G8B8A8_UNORM &&
       format != DXGI_FORMAT_B8G8R8A8_UNORM))
    return 1;
  D11Com<IDXGIDevice> device;
  D11Com<IDXGIAdapter> adapter;
  D11Com<IDXGIFactory2> factory;
  HRESULT hr =
      q->owner->raw->QueryInterface(IID_IDXGIDevice, (void **)device.put());
  if (SUCCEEDED(hr))
    hr = device->GetAdapter(adapter.put());
  if (SUCCEEDED(hr))
    hr = adapter->GetParent(IID_IDXGIFactory2, (void **)factory.put());
  if (FAILED(hr))
    return result(hr);
  auto s = new (std::nothrow) ZenitD12Surface;
  if (!s)
    return 2;
  s->queue = q;
  s->hwnd = (HWND)hwnd;
  s->width = width;
  s->height = height;
  s->format = format;
  DXGI_SWAP_CHAIN_DESC1 d = {};
  d.Width = width;
  d.Height = height;
  d.Format = (DXGI_FORMAT)format;
  d.SampleDesc.Count = 1;
  d.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT | DXGI_USAGE_SHADER_INPUT;
  d.BufferCount = buffers;
  // Never stretch an older buffer over a resized client: until the new
  // extent is presented, DWM shows the previous frame unscaled.
  d.Scaling = DXGI_SCALING_NONE;
  d.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
  d.AlphaMode = DXGI_ALPHA_MODE_IGNORE;
  if (GetPropW((HWND)hwnd, L"Zenit.CustomFrame")) {
    // Composition swap chains support only stretch; the visual tree sizes them.
    d.Scaling = DXGI_SCALING_STRETCH;
    // DirectComposition requires sequential presentation; ordinary HWNDs
    // redraw the complete back buffer and can use discard presentation.
    d.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
    d.AlphaMode = DXGI_ALPHA_MODE_PREMULTIPLIED;
    hr = factory->CreateSwapChainForComposition(q->owner->raw, &d, nullptr,
                                                s->swap.put());
    if (SUCCEEDED(hr))
      hr = DCompositionCreateDevice(nullptr, __uuidof(IDCompositionDevice),
                                    (void **)s->composition.put());
    if (SUCCEEDED(hr))
      hr = s->composition->CreateTargetForHwnd((HWND)hwnd, FALSE,
                                               s->composition_target.put());
    if (SUCCEEDED(hr))
      hr = s->composition->CreateVisual(s->composition_root.put());
    for (unsigned i = 0; i < 4 && SUCCEEDED(hr); ++i) {
      hr = s->composition->CreateVisual(s->composition_parts[i].put());
      if (SUCCEEDED(hr))
        hr = s->composition_parts[i]->SetContent(s->swap);
      if (SUCCEEDED(hr))
        hr = s->composition_root->AddVisual(s->composition_parts[i], FALSE,
                                            nullptr);
    }
    if (SUCCEEDED(hr))
      hr = s->composition_target->SetRoot(s->composition_root);
    if (SUCCEEDED(hr))
      hr = surface_update_composition(s);
  } else {
    hr = factory->CreateSwapChainForHwnd(q->owner->raw, (HWND)hwnd, &d, nullptr,
                                         nullptr, s->swap.put());
  }
  if (FAILED(hr)) {
    delete s;
    return result(hr);
  }
  factory->MakeWindowAssociation((HWND)hwnd, DXGI_MWA_NO_ALT_ENTER);
  *out = s;
  return 0;
}
extern "C" int zenit_d12_surface_acquire(ZenitD12Surface *s,
                                         ZenitD12Texture **out) {
  if (!out)
    return 1;
  *out = nullptr;
  if (!s)
    return 1;
  if (s->acquired)
    return 5;
  auto t = new (std::nothrow) ZenitD12Texture;
  if (!t)
    return 2;
  t->owner = s->queue->owner;
  zenit_d12_device_retain(t->owner);
  t->dimension = 2;
  t->width = s->width;
  t->height = s->height;
  t->depth = t->mips = t->samples = 1;
  t->usage = 1 | 2 | 4 | 16;
  t->format = (DXGI_FORMAT)s->format;
  HRESULT hr = s->swap->GetBuffer(0, IID_ID3D11Resource, (void **)t->raw.put());
  if (FAILED(hr)) {
    delete t;
    return result(hr);
  }
  s->acquired = t;
  zenit_d12_texture_retain(t);
  *out = t;
  return 0;
}
extern "C" int zenit_d12_surface_present(ZenitD12Surface *s, ZenitD12Texture *t,
                                         uint32_t interval, int *occluded) {
  if (!s || !t || s->acquired != t || interval > 4 || !occluded)
    return 1;
  d11_prof_dump();
  const bool trace = cpu_timing_trace_enabled();
  const uint64_t start = trace ? cpu_time_micros() : 0;
  HRESULT hr = surface_update_composition(s);
  const uint64_t composition_end = trace ? cpu_time_micros() : 0;
  if (SUCCEEDED(hr))
    hr = s->swap->Present(interval, 0);
  if (trace)
    fprintf(stderr, "[d3d11-cpu] composition_us=%llu present_us=%llu interval=%u result=0x%08lx\n",
            (unsigned long long)(composition_end - start),
            (unsigned long long)(cpu_time_micros() - composition_end), interval,
            (unsigned long)hr);
  *occluded = hr == DXGI_STATUS_OCCLUDED;
  if (FAILED(hr))
    return device_failure(s->queue->owner, "Present", hr);
  s->acquired = nullptr;
  zenit_d12_texture_release(t);
  return 0;
}
extern "C" int zenit_d12_surface_discard(ZenitD12Surface *s,
                                         ZenitD12Texture *t) {
  if (!s || !t || s->acquired != t)
    return 1;
  s->acquired = nullptr;
  zenit_d12_texture_release(t);
  return 0;
}
extern "C" int zenit_d12_surface_resize(ZenitD12Surface *s, uint32_t width,
                                        uint32_t height, uint32_t timeout) {
  if (!s || !width || !height)
    return 1;
  if (s->acquired)
    return 5;
  int status = zenit_d12_queue_wait(s->queue, s->queue->next - 1, timeout);
  if (status)
    return status;
  s->queue->owner->immediate->ClearState();
  s->queue->owner->immediate->Flush();
  HRESULT hr = s->swap->ResizeBuffers(0, width, height, DXGI_FORMAT_UNKNOWN, 0);
  if (hr == DXGI_ERROR_INVALID_CALL)
    return 5;
  if (FAILED(hr))
    return result(hr);
  s->width = width;
  s->height = height;
  s->clip_valid = false;
  hr = surface_update_composition(s);
  if (FAILED(hr))
    return device_failure(s->queue->owner, "UpdateComposition(resize)", hr);
  return 0;
}
extern "C" int zenit_d12_surface_destroy(ZenitD12Surface *s, uint32_t timeout) {
  if (!s)
    return 1;
  if (s->acquired)
    return 5;
  int status = zenit_d12_queue_wait(s->queue, s->queue->next - 1, timeout);
  if (status && SUCCEEDED(s->queue->owner->raw->GetDeviceRemovedReason()))
    return status;
  delete s;
  return 0;
}
extern "C" int zenit_d12_surface_size(ZenitD12Surface *s, uint32_t *width,
                                      uint32_t *height) {
  if (!s || !width || !height)
    return 1;
  *width = s->width;
  *height = s->height;
  return 0;
}

// Compositor sprite atlas (src/zenit_app/sprite_host.zig): an opaque
// composition swap chain that native/windows/compositor_sprites.cpp shows
// through DirectComposition. Its back buffer is rendered once by the regular
// encoder (the returned texture) and presented once; DWM keeps showing it.
struct ZenitD12SpriteAtlas {
  D11Com<IDXGISwapChain1> swap;
};
extern "C" int zenit_d12_sprite_atlas_create(ZenitD12Queue *q, uint32_t w,
                                             uint32_t h, uint32_t format,
                                             ZenitD12SpriteAtlas **out,
                                             ZenitD12Texture **texture_out) {
  if (!out || !texture_out)
    return 1;
  *out = nullptr;
  *texture_out = nullptr;
  if (!q || !w || !h || w > 16384 || h > 16384 ||
      (format != DXGI_FORMAT_R8G8B8A8_UNORM &&
       format != DXGI_FORMAT_B8G8R8A8_UNORM))
    return 1;
  D11Com<IDXGIDevice> device;
  D11Com<IDXGIAdapter> adapter;
  D11Com<IDXGIFactory2> factory;
  HRESULT hr =
      q->owner->raw->QueryInterface(IID_IDXGIDevice, (void **)device.put());
  if (SUCCEEDED(hr))
    hr = device->GetAdapter(adapter.put());
  if (SUCCEEDED(hr))
    hr = adapter->GetParent(IID_IDXGIFactory2, (void **)factory.put());
  if (FAILED(hr))
    return result(hr);
  auto a = new (std::nothrow) ZenitD12SpriteAtlas;
  if (!a)
    return 2;
  DXGI_SWAP_CHAIN_DESC1 d = {};
  d.Width = w;
  d.Height = h;
  d.Format = (DXGI_FORMAT)format;
  d.SampleDesc.Count = 1;
  d.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT | DXGI_USAGE_SHADER_INPUT;
  // Composition swap chains: sequential flip, at least two buffers.
  d.BufferCount = 2;
  d.Scaling = DXGI_SCALING_STRETCH;
  d.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
  d.AlphaMode = DXGI_ALPHA_MODE_IGNORE;
  hr = factory->CreateSwapChainForComposition(q->owner->raw, &d, nullptr,
                                              a->swap.put());
  auto t = SUCCEEDED(hr) ? new (std::nothrow) ZenitD12Texture : nullptr;
  if (SUCCEEDED(hr) && !t)
    hr = E_OUTOFMEMORY;
  if (SUCCEEDED(hr))
    hr = a->swap->GetBuffer(0, IID_ID3D11Resource, (void **)t->raw.put());
  if (FAILED(hr)) {
    if (t) {
      t->owner = nullptr;
      delete t;
    }
    delete a;
    return result(hr);
  }
  t->owner = q->owner;
  zenit_d12_device_retain(t->owner);
  t->dimension = 2;
  t->width = w;
  t->height = h;
  t->depth = t->mips = t->samples = 1;
  t->usage = 1 | 2 | 4 | 16;
  t->format = (DXGI_FORMAT)format;
  *out = a;
  *texture_out = t;
  return 0;
}
// After the render commands were submitted to the atlas' queue.
extern "C" int zenit_d12_sprite_atlas_present(ZenitD12SpriteAtlas *a) {
  if (!a)
    return 1;
  return FAILED(a->swap->Present(0, 0)) ? 2 : 0;
}
extern "C" IUnknown *zenit_d12_sprite_atlas_content(ZenitD12SpriteAtlas *a) {
  return a ? a->swap.p : nullptr;
}
extern "C" void zenit_d12_sprite_atlas_release(ZenitD12SpriteAtlas *a) {
  delete a;
}
// The surface's own DirectComposition device and root visual (custom-frame
// windows), or nulls: compositor sprites join this tree when there is one.
extern "C" int zenit_d12_surface_composition(ZenitD12Surface *s,
                                             IDCompositionDevice **device,
                                             IDCompositionVisual **root) {
  if (!s || !device || !root)
    return 1;
  *device = s->composition.p;
  *root = s->composition_root.p;
  return 0;
}
