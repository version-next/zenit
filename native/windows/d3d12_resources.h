#pragma once
#include <stdint.h>
#include <stddef.h>
// Bind groups occupy spaces 0..3; draw constants use 4; WARP aliases use 5..8.
#define ZENIT_D12_STATIC_BUFFER_SPACE_OFFSET 5
#ifdef __cplusplus
extern "C" {
#endif
typedef struct ZenitD12Device ZenitD12Device;
typedef struct ZenitD12Queue ZenitD12Queue;
typedef struct ZenitD12Buffer ZenitD12Buffer;
typedef struct ZenitD12Texture ZenitD12Texture;
typedef struct ZenitD12View ZenitD12View;
typedef struct ZenitD12Sampler ZenitD12Sampler;
typedef struct ZenitD12Shader ZenitD12Shader;
typedef struct ZenitD12PipelineLayout ZenitD12PipelineLayout;
typedef struct ZenitD12ComputePipeline ZenitD12ComputePipeline;
typedef struct ZenitD12RenderPipeline ZenitD12RenderPipeline;
typedef struct ZenitD12VertexAttribute {
    uint32_t location, slot, format, offset, stride, step;
} ZenitD12VertexAttribute;
typedef struct ZenitD12ColorTarget {
    uint32_t format, write_mask, blend, color_src, color_dst, color_op, alpha_src, alpha_dst, alpha_op;
} ZenitD12ColorTarget;
typedef struct ZenitD12StencilFace { uint32_t compare, fail, depth_fail, pass; } ZenitD12StencilFace;
typedef struct ZenitD12DepthState {
    uint32_t format, write, compare, read_mask, write_mask; ZenitD12StencilFace front, back;
    int32_t bias; float slope, clamp;
} ZenitD12DepthState;
typedef struct ZenitD12RenderDescriptor {
    const ZenitD12VertexAttribute *attributes; uint32_t attribute_count;
    const ZenitD12ColorTarget *targets; uint32_t target_count;
    uint32_t topology, strip_index, front_ccw, cull, fill, depth_clip, sample_mask, samples, alpha_coverage; ZenitD12DepthState depth;
} ZenitD12RenderDescriptor;
int zenit_d12_render_pipeline_create(ZenitD12Device *, ZenitD12PipelineLayout *,
    ZenitD12Shader *vertex, ZenitD12Shader *fragment, const ZenitD12RenderDescriptor *, ZenitD12RenderPipeline **out);
void zenit_d12_render_pipeline_retain(ZenitD12RenderPipeline *);
void zenit_d12_render_pipeline_release(ZenitD12RenderPipeline *);
void *zenit_d12_render_pipeline_native(ZenitD12RenderPipeline *);
ZenitD12PipelineLayout *zenit_d12_render_pipeline_layout(ZenitD12RenderPipeline *);
typedef struct ZenitD12RenderInfo {
    uint32_t topology, strip_index, target_count, formats[8], strides[32], steps[32], ends[32], slots;
    uint32_t depth_format, depth_write, stencil_write, samples;
} ZenitD12RenderInfo;
void zenit_d12_render_pipeline_info(ZenitD12RenderPipeline *, ZenitD12RenderInfo *);
int zenit_d12_render_buffer_stride(ZenitD12RenderPipeline *, uint32_t group, uint32_t binding, uint32_t *stride);
uint32_t zenit_d12_pipeline_layout_draw_info(ZenitD12PipelineLayout *);
void *zenit_d12_render_pipeline_root(ZenitD12RenderPipeline *);
/* Binding kinds: CBV=0, texture SRV=1, buffer SRV=2, buffer UAV=3,
   sampler=4, texture UAV=5. Group maps to HLSL register space. */
typedef struct ZenitD12LayoutBinding { uint32_t group, binding, kind, count, visibility; uint64_t min_size; uint32_t view_dimension, sample_type, sampler_type, storage_format; } ZenitD12LayoutBinding;
int zenit_d12_pipeline_layout_create(ZenitD12Device *, uint32_t groups,
    const ZenitD12LayoutBinding *, uint32_t count, ZenitD12PipelineLayout **out);
void zenit_d12_pipeline_layout_retain(ZenitD12PipelineLayout *);
ZenitD12Device *zenit_d12_pipeline_layout_owner(ZenitD12PipelineLayout *);
const ZenitD12LayoutBinding *zenit_d12_pipeline_layout_bindings(ZenitD12PipelineLayout *, uint32_t *count, uint32_t *groups);
void zenit_d12_pipeline_layout_release(ZenitD12PipelineLayout *);
uint32_t zenit_d12_pipeline_layout_table(ZenitD12PipelineLayout *, uint32_t group, int sampler);
int zenit_d12_compute_pipeline_create(ZenitD12Device *, ZenitD12PipelineLayout *, ZenitD12Shader *, ZenitD12ComputePipeline **out);
void zenit_d12_compute_pipeline_retain(ZenitD12ComputePipeline *);
void zenit_d12_compute_pipeline_release(ZenitD12ComputePipeline *);
/* Borrowed handles, owned by pipeline. */
void *zenit_d12_compute_pipeline_native(ZenitD12ComputePipeline *);
void *zenit_d12_compute_pipeline_root(ZenitD12ComputePipeline *);
ZenitD12PipelineLayout *zenit_d12_compute_pipeline_layout(ZenitD12ComputePipeline *);
typedef struct ZenitD12Commands ZenitD12Commands;
typedef struct ZenitD12BindGroup ZenitD12BindGroup;
typedef struct ZenitD12RenderPass ZenitD12RenderPass;
typedef struct ZenitD12Surface ZenitD12Surface;
/* Queue and HWND must outlive Surface. Status 5 means outstanding back-buffer
   references/acquisition; timeout/removed statuses match queue waits. */
int zenit_d12_surface_create(ZenitD12Queue *, void *hwnd, uint32_t width, uint32_t height,
    uint32_t format, uint32_t buffers, ZenitD12Surface **out);
int zenit_d12_surface_resize(ZenitD12Surface *, uint32_t width, uint32_t height, uint32_t timeout_ms);
int zenit_d12_surface_acquire(ZenitD12Surface *, ZenitD12Texture **out);
int zenit_d12_surface_present(ZenitD12Surface *, ZenitD12Texture *, uint32_t interval, int *occluded);
int zenit_d12_surface_discard(ZenitD12Surface *, ZenitD12Texture *);
int zenit_d12_surface_destroy(ZenitD12Surface *, uint32_t timeout_ms);
int zenit_d12_surface_size(ZenitD12Surface *, uint32_t *width, uint32_t *height);
typedef struct ZenitD12ColorAttachment {
    ZenitD12Texture *texture; uint32_t mip, layer, load_op, store_op; float clear[4];
    ZenitD12Texture *resolve; uint32_t resolve_mip,resolve_layer;
} ZenitD12ColorAttachment;
typedef struct ZenitD12DepthAttachment {
    ZenitD12Texture *texture; uint32_t mip,layer,depth_load,depth_store,stencil_load,stencil_store;
    float clear; uint32_t stencil_clear,depth_read_only,stencil_read_only;
} ZenitD12DepthAttachment;
typedef struct ZenitD12VertexBinding {
    ZenitD12Buffer *buffer; uint64_t offset, size; uint32_t slot;
} ZenitD12VertexBinding;
typedef struct ZenitD12Draw {
    const ZenitD12VertexBinding *buffers; uint32_t buffer_count;
    uint32_t first_vertex, vertices, first_instance, instances;
    uint32_t x, y, width, height; float blend[4]; uint32_t stencil_reference;
    ZenitD12BindGroup *const *groups; uint32_t group_count;
    ZenitD12Buffer *index_buffer; uint64_t index_offset, index_size;
    uint32_t index_format, first_index; int32_t base_vertex;
    uint32_t has_viewport; float viewport[6];
} ZenitD12Draw;
int zenit_d12_render_pass_begin(ZenitD12Commands *, const ZenitD12ColorAttachment *, uint32_t, const ZenitD12DepthAttachment *, ZenitD12RenderPass **out);
int zenit_d12_render_pass_draw(ZenitD12RenderPass *, ZenitD12RenderPipeline *, const ZenitD12Draw *);
int zenit_d12_render_pass_regions(ZenitD12RenderPass *, const uint32_t *, uint32_t);
int zenit_d12_render_pass_clear_opaque(ZenitD12RenderPass *, const float *, uint32_t, uint32_t, uint32_t, uint32_t);
int zenit_d12_render_pass_end(ZenitD12RenderPass *);
/* stride=0 is ByteAddressBuffer; nonzero is StructuredBuffer (bytes/element).
   CBV stride must be zero. Exactly one buffer/view/sampler per entry.
   Entries cover every bounded array element. View/sample/sampler classes in
   LayoutBinding use 1..6 view dimensions, 1=float 2=unfilterable_float
   3=depth 4=sint 5=uint, and 1=filtering 2=non_filtering 3=comparison.
   Zero metadata is unspecified for native clients; Zig supplies typed metadata. */
typedef struct ZenitD12BindingEntry {
    uint32_t binding, array_index; ZenitD12Buffer *buffer;
    uint64_t offset, size; uint32_t stride; ZenitD12View *view; ZenitD12Sampler *sampler;
} ZenitD12BindingEntry;
int zenit_d12_bind_group_create(ZenitD12Device *, ZenitD12PipelineLayout *, uint32_t group,
    const ZenitD12BindingEntry *, uint32_t count, ZenitD12BindGroup **out);
/* A draw with its bind groups given as entries instead of bind-group objects:
   group_counts[i] entries for group i, concatenated in group order. Same
   validation and recorded result as creating the groups and calling
   zenit_d12_render_pass_draw; draw->group_count must be 0 (groups is ignored).
   Status 6: an entry that bind_group_create would reject. */
int zenit_d12_render_pass_draw_entries(ZenitD12RenderPass *, ZenitD12RenderPipeline *, const ZenitD12Draw *,
    const ZenitD12BindingEntry *entries, const uint32_t *group_counts, uint32_t group_count);
void zenit_d12_bind_group_release(ZenitD12BindGroup *);
int zenit_d12_compute_validate_bindings(ZenitD12ComputePipeline *, uint32_t group,
    const ZenitD12BindingEntry *, uint32_t count);
int zenit_d12_render_validate_bindings(ZenitD12RenderPipeline *, uint32_t group,
    const ZenitD12BindingEntry *, uint32_t count);
int zenit_d12_commands_dispatch(ZenitD12Commands *, ZenitD12ComputePipeline *,
    ZenitD12BindGroup *const *, uint32_t count, uint32_t x, uint32_t y, uint32_t z);
/* Stages: 1 vertex, 2 pixel, 3 compute. Status 3 = compiler rejection.
   Diagnostics use native malloc and must be freed, even on failed compilation. */
int zenit_d12_shader_compile(const void *source, size_t source_size, const char *entry,
    uint32_t stage, ZenitD12Shader **out, char **diagnostic, size_t *diagnostic_size);
typedef struct ZenitD12ShaderBinding {
    uint32_t group, binding, kind, count, dimension, sample_type, sampler_type, stride;
    uint64_t min_size;
} ZenitD12ShaderBinding;
/* capacity=0 queries count; caller owns the output array. Unsupported classes return 3. */
int zenit_d12_shader_bindings(ZenitD12Shader *, ZenitD12ShaderBinding *, uint32_t capacity, uint32_t *count);
void zenit_d12_shader_retain(ZenitD12Shader *);
void zenit_d12_shader_release(ZenitD12Shader *);
const void *zenit_d12_shader_data(ZenitD12Shader *);
int zenit_d12_shader_non_uniform_buffer_atomics(ZenitD12Shader *);
size_t zenit_d12_shader_size(ZenitD12Shader *);
int zenit_d12_shader_atomic_switch(ZenitD12Shader *, ZenitD12Shader **);
int zenit_d12_shader_warp_blob(ZenitD12Shader *, void **);
void zenit_d12_shader_diagnostic_free(char *);
typedef struct ZenitD12TextureRegion {
    uint32_t mip, layer, x, y, z, width, height, depth;
} ZenitD12TextureRegion;
typedef struct ZenitD12TextureLayout {
    uint64_t offset, row_bytes, required_bytes;
    uint32_t row_pitch, width, height, depth;
} ZenitD12TextureLayout;
/* Status: 0 success, 1 invalid descriptor, 2 allocation/device failure. */
typedef struct ZenitD12DriverInfo {
    uint32_t vendor_id, device_id; uint16_t driver_version[4];
    uint32_t driver_version_known, software;
} ZenitD12DriverInfo;
int zenit_d12_device_create(int force_warp, ZenitD12Device **out);
void zenit_d12_device_driver_info(ZenitD12Device *, ZenitD12DriverInfo *);
void zenit_d12_device_retain(ZenitD12Device *device);
void zenit_d12_device_release(ZenitD12Device *device);
int zenit_d12_device_vertex_viewport_index(ZenitD12Device *device);
int zenit_d12_device_is_software(ZenitD12Device *device);
int zenit_d12_buffer_create(ZenitD12Device *device, uint64_t size, uint32_t usage,
                            ZenitD12Buffer **out);
void zenit_d12_buffer_retain(ZenitD12Buffer *buffer);
void zenit_d12_buffer_release(ZenitD12Buffer *buffer);
void *zenit_d12_buffer_mapping(ZenitD12Buffer *buffer);
/* Device-local typed color and attachment-only depth textures. MSAA: 2D, one mip. */
int zenit_d12_sample_supported(ZenitD12Device *, uint32_t format, uint32_t samples);
int zenit_d12_texture_create(ZenitD12Device *, uint32_t dimension, uint32_t width,
    uint32_t height, uint32_t depth, uint32_t mips, uint32_t format, uint32_t usage, uint32_t samples, ZenitD12Texture **out);
void zenit_d12_texture_retain(ZenitD12Texture *);
void zenit_d12_texture_release(ZenitD12Texture *);
int zenit_d12_texture_layout(ZenitD12Texture *, const ZenitD12TextureRegion *, uint64_t offset,
    ZenitD12TextureLayout *out);
int zenit_d12_commands_texture_copy(ZenitD12Commands *, ZenitD12Buffer *, uint64_t offset,
    uint32_t row_pitch, ZenitD12Texture *, const ZenitD12TextureRegion *, int to_texture);
/* Exact-format single-sample color regions, equal extents; distinct subresources. */
int zenit_d12_commands_texture_region_copy(ZenitD12Commands *, ZenitD12Texture *,
    const ZenitD12TextureRegion *, ZenitD12Texture *, const ZenitD12TextureRegion *);
/* View dimensions: 1=1D, 2=2D, 3=2D array, 4=cube, 5=cube array, 6=3D. */
int zenit_d12_view_create(ZenitD12Texture *, uint32_t dimension, uint32_t base_mip,
    uint32_t mips, uint32_t base_layer, uint32_t layers, ZenitD12View **out);
void zenit_d12_view_release(ZenitD12View *);
int zenit_d12_storage_view_create(ZenitD12Texture *, uint32_t dimension, uint32_t mip, uint32_t layer, uint32_t layers, ZenitD12View **out);
int zenit_d12_view_is_storage(ZenitD12View *);
uint32_t zenit_d12_view_dimension(ZenitD12View *);
uint32_t zenit_d12_view_sample_type(ZenitD12View *);
int zenit_d12_sampler_create(ZenitD12Device *, uint32_t filter, uint32_t address_u,
    uint32_t address_v, uint32_t address_w, float min_lod, float max_lod,
    uint32_t anisotropy, uint32_t comparison, ZenitD12Sampler **out);
void zenit_d12_sampler_retain(ZenitD12Sampler *);
void zenit_d12_sampler_release(ZenitD12Sampler *);
int zenit_d12_sampler_comparison(ZenitD12Sampler *);
/* Borrowed COM handles. Keep the owning view/sampler alive; never Release. */
void *zenit_d12_view_heap(ZenitD12View *);
void *zenit_d12_view_texture(ZenitD12View *);
void *zenit_d12_sampler_heap(ZenitD12Sampler *);
/* Queue/command status additionally: 3 timeout, 4 device removed.
   Queue/encoder mutation is confined to one thread. Buffers can be destroyed
   after recording; command references and the submission retain their storage.
   On failed wait/deinit, ownership remains with the caller for retry.
   D3D11 destroy succeeds on a permanently removed device, releasing pending
   references without completing work. Timeout still preserves ownership. */
int zenit_d12_queue_create(ZenitD12Device *, ZenitD12Queue **out);
int zenit_d12_queue_submit(ZenitD12Queue *, ZenitD12Commands *, uint64_t *serial);
int zenit_d12_queue_wait(ZenitD12Queue *, uint64_t serial, uint32_t timeout_ms);
int zenit_d12_queue_collect(ZenitD12Queue *);
int zenit_d12_queue_destroy(ZenitD12Queue *, uint32_t timeout_ms);
int zenit_d12_commands_create(ZenitD12Device *, ZenitD12Commands **out);
int zenit_d12_commands_copy(ZenitD12Commands *, ZenitD12Buffer *source, uint64_t source_offset,
                            ZenitD12Buffer *destination, uint64_t destination_offset, uint64_t bytes);
int zenit_d12_commands_finish(ZenitD12Commands *);
/* Enable before recording work. Results are unavailable until fence completion. */
int zenit_d12_commands_enable_timestamps(ZenitD12Commands *);
/* Elapsed status: 0 valid, 3 pending/unavailable, 5 completed disjoint. */
int zenit_d12_commands_elapsed_micros(ZenitD12Commands *, uint64_t *micros);
/* Immutable diagnostic labels, borrowed from their owning shader/pipeline. */
const char *zenit_d12_shader_entry(ZenitD12Shader *);
const char *zenit_d12_render_pipeline_entry(ZenitD12RenderPipeline *);
void zenit_d12_commands_release(ZenitD12Commands *);
/* Borrowed COM handles, for command recording; never Release these handles. */
void *zenit_d12_queue_native(ZenitD12Queue *queue);
void *zenit_d12_device_native(ZenitD12Device *device);
void *zenit_d12_buffer_native(ZenitD12Buffer *buffer);
#ifdef __cplusplus
}
#endif
