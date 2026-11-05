#include "dual_source_validation.h"
#include <float.h>
#include "d3d12_resources.h"
#include <windows.h>
#include <d3d12.h>
#include <d3dcompiler.h>
#include <d3d12shader.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
struct ZenitD12PipelineLayout {
    ID3D12RootSignature *root;
    ZenitD12Device *owner;
    ZenitD12LayoutBinding *bindings;
    uint32_t count, groups, table[4][2], draw_info;
    LONG refs;
};
struct ZenitD12ComputePipeline { ID3D12PipelineState *raw; ZenitD12PipelineLayout *layout; ID3D12ShaderReflection *reflection; LONG refs; };
static D3D12_DESCRIPTOR_RANGE_TYPE range_type(uint32_t kind) {
    return kind == 0 ? D3D12_DESCRIPTOR_RANGE_TYPE_CBV : kind == 4 ? D3D12_DESCRIPTOR_RANGE_TYPE_SAMPLER :
        kind == 3 || kind == 5 ? D3D12_DESCRIPTOR_RANGE_TYPE_UAV : D3D12_DESCRIPTOR_RANGE_TYPE_SRV;
}
extern "C" void zenit_d12_pipeline_layout_release(ZenitD12PipelineLayout *layout) {
    if (!layout || InterlockedDecrement(&layout->refs) != 0) return;
    layout->root->Release(); zenit_d12_device_release(layout->owner); free(layout->bindings); free(layout);
}
extern "C" int zenit_d12_pipeline_layout_create(ZenitD12Device *device, uint32_t groups,
    const ZenitD12LayoutBinding *bindings, uint32_t count, ZenitD12PipelineLayout **out) {
    if (!out) return 1;
    *out = nullptr;
    if (!device || groups > 4 || count > 1024 || (count && !bindings)) return 1;
    uint32_t resource_total = 0, sampler_total = 0;
    for (uint32_t i = 0; i < count; ++i) {
        const auto &b = bindings[i];
        if (b.group >= groups || b.kind > 5 || !b.count || b.count > 65536 || b.binding > UINT32_MAX - b.count ||
            !b.visibility || (b.visibility & ~7u) || b.view_dimension>6 || b.sample_type>5 || b.sampler_type>3) return 1;
        uint32_t &total = b.kind == 4 ? sampler_total : resource_total;
        if (b.count > (b.kind == 4 ? 2048u : 1000000u) - total) return 1;
        total += b.count;
        for (uint32_t j = 0; j < i; ++j) {
            const auto &a = bindings[j];
            if (a.group == b.group && (a.binding == b.binding || (range_type(a.kind) == range_type(b.kind) &&
                a.binding < b.binding + b.count && b.binding < a.binding + a.count))) return 1;
        }
    }
    auto layout = (ZenitD12PipelineLayout *)calloc(1, sizeof(ZenitD12PipelineLayout));
    if (!layout) return 2;
    auto ranges = (D3D12_DESCRIPTOR_RANGE *)calloc(count ? count * 2 : 1, sizeof(D3D12_DESCRIPTOR_RANGE));
    layout->bindings = (ZenitD12LayoutBinding *)calloc(count ? count : 1, sizeof(ZenitD12LayoutBinding));
    if (!ranges || !layout->bindings) { free(ranges); free(layout->bindings); free(layout); return 2; }
    if (count) memcpy(layout->bindings, bindings, count * sizeof(*bindings));
    D3D12_ROOT_PARAMETER parameters[9] = {};
    uint32_t range_index = 0, parameter_count = 0;
    for (uint32_t group = 0; group < 4; ++group) for (uint32_t sampler = 0; sampler < 2; ++sampler) {
        layout->table[group][sampler] = UINT32_MAX;
        uint32_t begin = range_index, offset = 0;
        // Descriptor order follows the caller's immutable layout order.
        for (uint32_t i = 0; i < count; ++i) {
            const auto &b = bindings[i];
            if (b.group != group || uint32_t(b.kind == 4) != sampler) continue;
            if (b.count > (sampler ? 2048u : 1000000u) - offset) { free(ranges); free(layout->bindings); free(layout); return 1; }
            auto &range = ranges[range_index++];
            range.RangeType = range_type(b.kind); range.NumDescriptors = b.count;
            range.BaseShaderRegister = b.binding; range.RegisterSpace = group; range.OffsetInDescriptorsFromTableStart = offset;
            if (zenit_d12_device_is_software(device) && b.count>1 && (b.kind==2 || b.kind==3)) {
                auto &alias=ranges[range_index++]; alias=range;
                alias.RegisterSpace=group+ZENIT_D12_STATIC_BUFFER_SPACE_OFFSET;
            }
            offset += b.count;
        }
        if (range_index == begin) continue;
        auto &parameter = parameters[parameter_count];
        parameter.ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
        parameter.ShaderVisibility = D3D12_SHADER_VISIBILITY_ALL;
        parameter.DescriptorTable.pDescriptorRanges = ranges + begin;
        parameter.DescriptorTable.NumDescriptorRanges = range_index - begin;
        layout->table[group][sampler] = parameter_count++;
    }
    layout->draw_info=parameter_count;
    auto &draw_parameter=parameters[parameter_count++];
    draw_parameter.ParameterType=D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS;
    draw_parameter.ShaderVisibility=D3D12_SHADER_VISIBILITY_VERTEX;
    draw_parameter.Constants={0,4,4}; // b0, space4, four DWORDs.
    D3D12_ROOT_SIGNATURE_DESC desc = {}; desc.Flags=D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT; desc.NumParameters = parameter_count; desc.pParameters = parameters;
    ID3DBlob *blob = nullptr, *errors = nullptr;
    HRESULT hr = D3D12SerializeRootSignature(&desc, D3D_ROOT_SIGNATURE_VERSION_1, &blob, &errors);
    if (errors) errors->Release();
    free(ranges);
    if (SUCCEEDED(hr)) hr = ((ID3D12Device *)zenit_d12_device_native(device))->CreateRootSignature(0,
        blob->GetBufferPointer(), blob->GetBufferSize(), IID_ID3D12RootSignature, (void **)&layout->root);
    if (blob) blob->Release();
    if (FAILED(hr)) { free(layout->bindings); free(layout); return 2; }
    layout->owner = device; layout->refs = 1; layout->count = count; layout->groups = groups;
    zenit_d12_device_retain(device); *out = layout; return 0;
}
extern "C" uint32_t zenit_d12_pipeline_layout_table(ZenitD12PipelineLayout *layout, uint32_t group, int sampler) {
    if (!layout || group >= layout->groups || sampler < 0 || sampler > 1) return UINT32_MAX;
    return layout->table[group][sampler];
}
static int reflected_kind(const D3D12_SHADER_INPUT_BIND_DESC &binding) {
    switch (binding.Type) {
    case D3D_SIT_CBUFFER: return 0;
    case D3D_SIT_TEXTURE: return 1;
    case D3D_SIT_TBUFFER: case D3D_SIT_STRUCTURED: case D3D_SIT_BYTEADDRESS: return 2;
    case D3D_SIT_SAMPLER: return 4;
    case D3D_SIT_UAV_RWTYPED: return binding.Dimension == D3D_SRV_DIMENSION_BUFFER ? 3 : 5;
    case D3D_SIT_UAV_RWSTRUCTURED: case D3D_SIT_UAV_RWBYTEADDRESS: return 3;
    // The common buffer binding has no counter resource; do not accept a PSO
    // whose append/consume operations cannot be bound correctly.
    case D3D_SIT_UAV_APPEND_STRUCTURED: case D3D_SIT_UAV_CONSUME_STRUCTURED:
    case D3D_SIT_UAV_RWSTRUCTURED_WITH_COUNTER: return -1;
    default: return -1;
    }
}
static bool reflected_layout(ID3D12ShaderReflection *reflection, ZenitD12PipelineLayout *layout,
    uint32_t stage, uint32_t visibility) {
    D3D12_SHADER_DESC desc={};
    if (FAILED(reflection->GetDesc(&desc)) || D3D12_SHVER_GET_TYPE(desc.Version)!=stage) return false;
    for (uint32_t i=0;i<desc.BoundResources;++i) {
        D3D12_SHADER_INPUT_BIND_DESC resource={};
        if (FAILED(reflection->GetResourceBindingDesc(i,&resource))) return false;
        if (resource.Space==4 && resource.BindPoint==0 && resource.BindCount==1 &&
            resource.Type==D3D_SIT_CBUFFER && visibility==1 && strcmp(resource.Name,"ZenitDrawInfo")==0) {
            D3D12_SHADER_BUFFER_DESC buffer={};
            if (FAILED(reflection->GetConstantBufferByName(resource.Name)->GetDesc(&buffer)) || buffer.Size>16) return false;
            continue;
        }
        int kind=reflected_kind(resource); bool found=false;
        for (uint32_t j=0;j<layout->count;++j) {
            const auto &b=layout->bindings[j];
            if (kind>=0 && b.group==resource.Space && b.kind==uint32_t(kind) && (b.visibility & visibility) &&
                resource.BindCount!=UINT32_MAX && resource.BindCount && resource.BindPoint>=b.binding &&
                resource.BindPoint-b.binding<b.count && resource.BindCount<=b.count-(resource.BindPoint-b.binding)) { found=true; break; }
        }
        if (!found) return false;
    }
    return true;
}
extern "C" int zenit_d12_compute_pipeline_create(ZenitD12Device *device, ZenitD12PipelineLayout *layout,
    ZenitD12Shader *shader, ZenitD12ComputePipeline **out) {
    if (!out) return 1;
    *out = nullptr;
    if (!device || !layout || layout->owner != device || !shader) return 1;
    ID3D12ShaderReflection *reflection = nullptr;
    HRESULT hr = D3DReflect(zenit_d12_shader_data(shader), zenit_d12_shader_size(shader), IID_ID3D12ShaderReflection, (void **)&reflection);
    if (FAILED(hr)) return 2;
    bool valid=reflected_layout(reflection,layout,D3D12_SHVER_COMPUTE_SHADER,4u);
    if (!valid) { reflection->Release(); return 1; }
    auto pipeline = (ZenitD12ComputePipeline *)calloc(1, sizeof(ZenitD12ComputePipeline));
    if (!pipeline) { reflection->Release(); return 2; }
    D3D12_COMPUTE_PIPELINE_STATE_DESC desc = {}; desc.pRootSignature = layout->root;
    desc.CS = {zenit_d12_shader_data(shader), zenit_d12_shader_size(shader)};
    ID3DBlob *warp=nullptr;
    if (zenit_d12_device_is_software(device) && zenit_d12_shader_warp_blob(shader,(void **)&warp)) {
        reflection->Release(); free(pipeline); return 2;
    }
    if (warp) desc.CS={warp->GetBufferPointer(),warp->GetBufferSize()};
    hr = ((ID3D12Device *)zenit_d12_device_native(device))->CreateComputePipelineState(&desc, IID_ID3D12PipelineState, (void **)&pipeline->raw);
    if (warp) warp->Release();
    if (FAILED(hr)) { fprintf(stderr,"compute PSO creation failed: 0x%08lx\n",(unsigned long)hr); reflection->Release(); free(pipeline); return 2; }
    pipeline->reflection = reflection; pipeline->refs = 1; pipeline->layout = layout; InterlockedIncrement(&layout->refs); *out = pipeline; return 0;
}
extern "C" void zenit_d12_compute_pipeline_release(ZenitD12ComputePipeline *pipeline) {
    if (!pipeline || InterlockedDecrement(&pipeline->refs) != 0) return;
    pipeline->reflection->Release(); pipeline->raw->Release(); zenit_d12_pipeline_layout_release(pipeline->layout); free(pipeline);
}
extern "C" void *zenit_d12_compute_pipeline_native(ZenitD12ComputePipeline *pipeline) { return pipeline->raw; }
extern "C" void *zenit_d12_compute_pipeline_root(ZenitD12ComputePipeline *pipeline) { return pipeline->layout->root; }
extern "C" ZenitD12PipelineLayout *zenit_d12_compute_pipeline_layout(ZenitD12ComputePipeline *pipeline) { return pipeline->layout; }

extern "C" void zenit_d12_pipeline_layout_retain(ZenitD12PipelineLayout *p) { InterlockedIncrement(&p->refs); }
extern "C" ZenitD12Device *zenit_d12_pipeline_layout_owner(ZenitD12PipelineLayout *p) { return p->owner; }
extern "C" const ZenitD12LayoutBinding *zenit_d12_pipeline_layout_bindings(ZenitD12PipelineLayout *p, uint32_t *count, uint32_t *groups) {
    *count=p->count; *groups=p->groups; return p->bindings;
}
extern "C" void zenit_d12_compute_pipeline_retain(ZenitD12ComputePipeline *p) { InterlockedIncrement(&p->refs); }
// One reflected shader register (resource element) a draw must bind. Built
// once per pipeline from the shader reflection: querying reflection objects on
// every draw cost several microseconds of COM calls and name lookups.
struct D12Requirement {
    uint32_t space, slot, element_kind, type, stride; uint64_t minimum;
    uint32_t dimension, sample; bool storage, comparison;
};
static int reflect_requirements(ID3D12ShaderReflection *reflection, D12Requirement **out, uint32_t *count) {
    D3D12_SHADER_DESC desc={}; if (FAILED(reflection->GetDesc(&desc))) return 2;
    uint32_t total=0;
    for (uint32_t i=0;i<desc.BoundResources;++i) {
        D3D12_SHADER_INPUT_BIND_DESC r={}; if (FAILED(reflection->GetResourceBindingDesc(i,&r))) return 2;
        total+=r.BindCount;
    }
    auto list=(D12Requirement *)calloc(total?total:1,sizeof(D12Requirement)); if (!list) return 2;
    uint32_t n=0;
    for (uint32_t i=0;i<desc.BoundResources;++i) {
        D3D12_SHADER_INPUT_BIND_DESC r={}; if (FAILED(reflection->GetResourceBindingDesc(i,&r))) { free(list); return 2; }
        D12Requirement q={}; q.space=r.Space; q.element_kind=uint32_t(reflected_kind(r));
        if (r.Type==D3D_SIT_STRUCTURED || r.Type==D3D_SIT_UAV_RWSTRUCTURED) { q.type=0; q.stride=r.NumSamples; }
        else if (r.Type==D3D_SIT_CBUFFER) {
            D3D12_SHADER_BUFFER_DESC b={};
            if (FAILED(reflection->GetConstantBufferByName(r.Name)->GetDesc(&b))) { fprintf(stderr,"reflection constant buffer failed: %s\n",r.Name); free(list); return 2; }
            q.type=0; q.minimum=b.Size;
        } else if (r.Type==D3D_SIT_TEXTURE || r.Type==D3D_SIT_UAV_RWTYPED) {
            q.type=1; q.storage=r.Type==D3D_SIT_UAV_RWTYPED;
            q.dimension=r.Dimension==D3D_SRV_DIMENSION_TEXTURE1D?1:r.Dimension==D3D_SRV_DIMENSION_TEXTURE2D?2:
                r.Dimension==D3D_SRV_DIMENSION_TEXTURE2DARRAY?3:r.Dimension==D3D_SRV_DIMENSION_TEXTURECUBE?4:
                r.Dimension==D3D_SRV_DIMENSION_TEXTURECUBEARRAY?5:r.Dimension==D3D_SRV_DIMENSION_TEXTURE3D?6:0;
            q.sample=r.ReturnType==D3D_RETURN_TYPE_SINT?4:r.ReturnType==D3D_RETURN_TYPE_UINT?5:
                (r.ReturnType==D3D_RETURN_TYPE_FLOAT || r.ReturnType==D3D_RETURN_TYPE_UNORM || r.ReturnType==D3D_RETURN_TYPE_SNORM)?1:0;
        } else if (r.Type==D3D_SIT_SAMPLER) { q.type=2; q.comparison=(r.uFlags & D3D_SIF_COMPARISON_SAMPLER)!=0; }
        else if (r.Type==D3D_SIT_BYTEADDRESS || r.Type==D3D_SIT_UAV_RWBYTEADDRESS) q.type=0;
        else q.type=3; // Unsupported: any draw on this space is rejected.
        for (uint32_t element=0;element<r.BindCount;++element) { list[n]=q; list[n].slot=r.BindPoint+element; ++n; }
    }
    *out=list; *count=n; return 0;
}
// Same checks and status as validate_reflected_bindings, on cached requirements.
static int validate_requirements(const D12Requirement *list, uint32_t n, ZenitD12PipelineLayout *layout, uint32_t group,
    const ZenitD12BindingEntry *entries, uint32_t count) {
    for (uint32_t i=0;i<n;++i) {
        const auto &q=list[i];
        if (q.space!=group) continue;
        if (q.type==3) return 1;
        bool found=false;
        for (uint32_t j=0;j<count && !found;++j) {
            const auto &e=entries[j];
            bool matching=false;
            for (uint32_t k=0;k<layout->count;++k) {
                const auto &b=layout->bindings[k];
                if (b.group==group && b.binding==e.binding && b.kind==q.element_kind &&
                    e.binding<=q.slot && e.array_index==q.slot-e.binding) { matching=true; break; }
            }
            if (!matching) continue;
            if (q.type==1) {
                if (!e.view || bool(zenit_d12_view_is_storage(e.view))!=q.storage || !q.dimension || !q.sample || zenit_d12_view_dimension(e.view)!=q.dimension || (zenit_d12_view_sample_type(e.view)!=q.sample && !(q.sample==1 && zenit_d12_view_sample_type(e.view)==3))) return 1;
            } else if (q.type==2) {
                if (!e.sampler || q.comparison!=bool(zenit_d12_sampler_comparison(e.sampler))) return 1;
            } else if (!e.buffer || e.stride!=q.stride || e.size<q.minimum) return 1;
            found=true;
        }
        if (!found) return 1;
    }
    return 0;
}
static int validate_reflected_bindings(ID3D12ShaderReflection *reflection, ZenitD12PipelineLayout *layout, uint32_t group,
    const ZenitD12BindingEntry *entries, uint32_t count) {
    D3D12_SHADER_DESC desc={}; if (FAILED(reflection->GetDesc(&desc))) return 2;
    for (uint32_t i=0;i<desc.BoundResources;++i) {
        D3D12_SHADER_INPUT_BIND_DESC r={}; if (FAILED(reflection->GetResourceBindingDesc(i,&r))) return 2;
        if (r.Space!=group) continue;
        uint32_t stride=0, minimum=0;
        if (r.Type==D3D_SIT_STRUCTURED || r.Type==D3D_SIT_UAV_RWSTRUCTURED) stride=r.NumSamples;
        else if (r.Type==D3D_SIT_CBUFFER) {
            D3D12_SHADER_BUFFER_DESC b={};
            if (FAILED(reflection->GetConstantBufferByName(r.Name)->GetDesc(&b))) { fprintf(stderr,"reflection constant buffer failed: %s\n",r.Name); return 2; }
            minimum=b.Size;
        } else if (r.Type!=D3D_SIT_BYTEADDRESS && r.Type!=D3D_SIT_UAV_RWBYTEADDRESS && r.Type!=D3D_SIT_TEXTURE && r.Type!=D3D_SIT_SAMPLER && r.Type!=D3D_SIT_UAV_RWTYPED) return 1;
        for (uint32_t element=0;element<r.BindCount;++element) {
            bool found=false;
            for (uint32_t j=0;j<count;++j) {
                const auto &e=entries[j];
                bool matching=false;
                for (uint32_t k=0;k<layout->count;++k) {
                    const auto &b=layout->bindings[k];
                    if (b.group==group && b.binding==e.binding && int(b.kind)==reflected_kind(r) &&
                        e.binding<=r.BindPoint+element && e.array_index==r.BindPoint+element-e.binding) matching=true;
                }
                if (matching) {
                    if (r.Type==D3D_SIT_TEXTURE || r.Type==D3D_SIT_UAV_RWTYPED) {
                        uint32_t dimension=r.Dimension==D3D_SRV_DIMENSION_TEXTURE1D?1:r.Dimension==D3D_SRV_DIMENSION_TEXTURE2D?2:
                            r.Dimension==D3D_SRV_DIMENSION_TEXTURE2DARRAY?3:r.Dimension==D3D_SRV_DIMENSION_TEXTURECUBE?4:
                            r.Dimension==D3D_SRV_DIMENSION_TEXTURECUBEARRAY?5:r.Dimension==D3D_SRV_DIMENSION_TEXTURE3D?6:0;
                        uint32_t sample=r.ReturnType==D3D_RETURN_TYPE_SINT?4:r.ReturnType==D3D_RETURN_TYPE_UINT?5:
                            (r.ReturnType==D3D_RETURN_TYPE_FLOAT || r.ReturnType==D3D_RETURN_TYPE_UNORM || r.ReturnType==D3D_RETURN_TYPE_SNORM)?1:0;
                        if (!e.view || bool(zenit_d12_view_is_storage(e.view))!=(r.Type==D3D_SIT_UAV_RWTYPED) || !dimension || !sample || zenit_d12_view_dimension(e.view)!=dimension || (zenit_d12_view_sample_type(e.view)!=sample && !(sample==1 && zenit_d12_view_sample_type(e.view)==3))) return 1;
                    } else if (r.Type==D3D_SIT_SAMPLER) {
                        if (!e.sampler || bool(r.uFlags & D3D_SIF_COMPARISON_SAMPLER)!=bool(zenit_d12_sampler_comparison(e.sampler))) return 1;
                    } else if (!e.buffer || e.stride!=stride || e.size<minimum) return 1;
                    found=true; break;
                }
            }
            if (!found) return 1;
        }
    }
    return 0;
}

extern "C" int zenit_d12_compute_validate_bindings(ZenitD12ComputePipeline *p, uint32_t group,
    const ZenitD12BindingEntry *entries, uint32_t count) {
    return validate_reflected_bindings(p->reflection,p->layout,group,entries,count);
}

struct ZenitD12RenderPipeline {
    ID3D12PipelineState *raw; ZenitD12PipelineLayout *layout; LONG refs; ID3D12ShaderReflection *vertex,*fragment;
    // Vertex then fragment requirements; requirement_status 2 if reflection failed.
    D12Requirement *requirements; uint32_t requirement_counts[2]; int requirement_status;
    uint32_t topology, strip_index, target_count, formats[8], strides[32], steps[32], ends[32], slots;
    uint32_t depth_format,depth_write,stencil_write,samples;
    char fragment_entry[96];
};
extern "C" const char *zenit_d12_render_pipeline_entry(ZenitD12RenderPipeline *p) { return p->fragment_entry; }
static bool vertex_format(uint32_t format, uint32_t *bytes, uint32_t *type) {
    *type=D3D_REGISTER_COMPONENT_FLOAT32;
    switch ((DXGI_FORMAT)format) {
    case DXGI_FORMAT_R8G8_UINT: *type=D3D_REGISTER_COMPONENT_UINT32; *bytes=2; return true;
    case DXGI_FORMAT_R8G8_SINT: *type=D3D_REGISTER_COMPONENT_SINT32; *bytes=2; return true;
    case DXGI_FORMAT_R8G8_UNORM: case DXGI_FORMAT_R8G8_SNORM: *bytes=2; return true;
    case DXGI_FORMAT_R8G8B8A8_UINT: *type=D3D_REGISTER_COMPONENT_UINT32; *bytes=4; return true;
    case DXGI_FORMAT_R8G8B8A8_SINT: *type=D3D_REGISTER_COMPONENT_SINT32; *bytes=4; return true;
    case DXGI_FORMAT_R8G8B8A8_UNORM: case DXGI_FORMAT_R8G8B8A8_SNORM: *bytes=4; return true;
    case DXGI_FORMAT_R16G16_UINT: *type=D3D_REGISTER_COMPONENT_UINT32; *bytes=4; return true;
    case DXGI_FORMAT_R16G16_SINT: *type=D3D_REGISTER_COMPONENT_SINT32; *bytes=4; return true;
    case DXGI_FORMAT_R16G16_UNORM: case DXGI_FORMAT_R16G16_SNORM: case DXGI_FORMAT_R16G16_FLOAT: *bytes=4; return true;
    case DXGI_FORMAT_R16G16B16A16_UINT: *type=D3D_REGISTER_COMPONENT_UINT32; *bytes=8; return true;
    case DXGI_FORMAT_R16G16B16A16_SINT: *type=D3D_REGISTER_COMPONENT_SINT32; *bytes=8; return true;
    case DXGI_FORMAT_R16G16B16A16_UNORM: case DXGI_FORMAT_R16G16B16A16_SNORM: case DXGI_FORMAT_R16G16B16A16_FLOAT: *bytes=8; return true;
    case DXGI_FORMAT_R32_UINT: *type=D3D_REGISTER_COMPONENT_UINT32; *bytes=4; return true;
    case DXGI_FORMAT_R32_SINT: *type=D3D_REGISTER_COMPONENT_SINT32; *bytes=4; return true;
    case DXGI_FORMAT_R32_FLOAT: *bytes=4; return true;
    case DXGI_FORMAT_R32G32_UINT: *type=D3D_REGISTER_COMPONENT_UINT32; *bytes=8; return true;
    case DXGI_FORMAT_R32G32_SINT: *type=D3D_REGISTER_COMPONENT_SINT32; *bytes=8; return true;
    case DXGI_FORMAT_R32G32_FLOAT: *bytes=8; return true;
    case DXGI_FORMAT_R32G32B32_UINT: *type=D3D_REGISTER_COMPONENT_UINT32; *bytes=12; return true;
    case DXGI_FORMAT_R32G32B32_SINT: *type=D3D_REGISTER_COMPONENT_SINT32; *bytes=12; return true;
    case DXGI_FORMAT_R32G32B32_FLOAT: *bytes=12; return true;
    case DXGI_FORMAT_R32G32B32A32_UINT: *type=D3D_REGISTER_COMPONENT_UINT32; *bytes=16; return true;
    case DXGI_FORMAT_R32G32B32A32_SINT: *type=D3D_REGISTER_COMPONENT_SINT32; *bytes=16; return true;
    case DXGI_FORMAT_R32G32B32A32_FLOAT: *bytes=16; return true;
    default: return false;
    }
}
static uint32_t color_type(uint32_t format) {
    switch ((DXGI_FORMAT)format) {
    case DXGI_FORMAT_R8_UINT: case DXGI_FORMAT_R16_UINT: case DXGI_FORMAT_R32_UINT:
    case DXGI_FORMAT_R8G8_UINT: case DXGI_FORMAT_R16G16_UINT: case DXGI_FORMAT_R32G32_UINT:
    case DXGI_FORMAT_R8G8B8A8_UINT: case DXGI_FORMAT_R16G16B16A16_UINT: case DXGI_FORMAT_R32G32B32A32_UINT: return D3D_REGISTER_COMPONENT_UINT32;
    case DXGI_FORMAT_R8_SINT: case DXGI_FORMAT_R16_SINT: case DXGI_FORMAT_R32_SINT:
    case DXGI_FORMAT_R8G8_SINT: case DXGI_FORMAT_R16G16_SINT: case DXGI_FORMAT_R32G32_SINT:
    case DXGI_FORMAT_R8G8B8A8_SINT: case DXGI_FORMAT_R16G16B16A16_SINT: case DXGI_FORMAT_R32G32B32A32_SINT: return D3D_REGISTER_COMPONENT_SINT32;
    default: return D3D_REGISTER_COMPONENT_FLOAT32;
    }
}
static bool blend_factor(uint32_t f, bool alpha) {
    if (f<1 || f>19 || f==12 || f==13) return false;
    return !alpha || (f!=3 && f!=4 && f!=9 && f!=10 && f!=11 && f!=16 && f!=17);
}
extern "C" int zenit_d12_render_pipeline_create(ZenitD12Device *device, ZenitD12PipelineLayout *layout,
    ZenitD12Shader *vertex, ZenitD12Shader *fragment, const ZenitD12RenderDescriptor *input, ZenitD12RenderPipeline **out) {
    if (!out) return 1; *out=nullptr;
    if (!device || !layout || layout->owner!=device || !vertex || !fragment || !input ||
        input->attribute_count>32 || (input->attribute_count && !input->attributes) ||
        (!input->target_count && !input->depth.format) || input->target_count>8 || (input->target_count && !input->targets) || input->topology<1 || input->topology>5 ||
        input->strip_index>2 || (input->strip_index && input->topology!=3 && input->topology!=5) ||
        input->front_ccw>1 || input->cull<1 || input->cull>3 || input->fill<2 || input->fill>3 || input->depth_clip>1 || !input->samples || input->samples>32 || (input->samples & (input->samples-1)) || input->alpha_coverage>1) return 1;
    auto raw_device=(ID3D12Device *)zenit_d12_device_native(device);
    D3D12_INPUT_ELEMENT_DESC elements[32]={};
    uint32_t strides[32]={}, steps[32]={}, ends[32]={}, slots=0;
    for (uint32_t i=0;i<input->attribute_count;++i) {
        const auto &a=input->attributes[i]; uint32_t bytes=0,type=0;
        if (a.slot>=32 || !a.stride || a.stride>2048 || a.stride%4 || a.step>1 || !vertex_format(a.format,&bytes,&type) ||
            a.offset>a.stride || bytes>a.stride-a.offset || a.offset%(bytes<4?bytes:4)) return 1;
        if ((slots & (1u<<a.slot)) && (strides[a.slot]!=a.stride || steps[a.slot]!=a.step)) return 1;
        for (uint32_t j=0;j<i;++j) if (input->attributes[j].location==a.location) return 1;
        D3D12_FEATURE_DATA_FORMAT_SUPPORT support={}; support.Format=(DXGI_FORMAT)a.format;
        if (FAILED(raw_device->CheckFeatureSupport(D3D12_FEATURE_FORMAT_SUPPORT,&support,sizeof(support))) ||
            !(support.Support1 & D3D12_FORMAT_SUPPORT1_IA_VERTEX_BUFFER)) return 1;
        slots|=1u<<a.slot; strides[a.slot]=a.stride; steps[a.slot]=a.step;
        if (ends[a.slot]<a.offset+bytes) ends[a.slot]=a.offset+bytes;
        elements[i].SemanticName="TEXCOORD"; elements[i].SemanticIndex=a.location;
        elements[i].Format=(DXGI_FORMAT)a.format; elements[i].InputSlot=a.slot; elements[i].AlignedByteOffset=a.offset;
        elements[i].InputSlotClass=a.step?D3D12_INPUT_CLASSIFICATION_PER_INSTANCE_DATA:D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA;
        elements[i].InstanceDataStepRate=a.step;
    }
    D3D12_GRAPHICS_PIPELINE_STATE_DESC desc={}; desc.pRootSignature=layout->root;
    desc.VS={zenit_d12_shader_data(vertex),zenit_d12_shader_size(vertex)};
    desc.PS={zenit_d12_shader_data(fragment),zenit_d12_shader_size(fragment)};
    desc.InputLayout={elements,input->attribute_count}; desc.SampleMask=input->sample_mask; desc.SampleDesc.Count=input->samples;
    desc.PrimitiveTopologyType=input->topology==1?D3D12_PRIMITIVE_TOPOLOGY_TYPE_POINT:
        input->topology<=3?D3D12_PRIMITIVE_TOPOLOGY_TYPE_LINE:D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
    desc.IBStripCutValue=input->strip_index==1?D3D12_INDEX_BUFFER_STRIP_CUT_VALUE_0xFFFF:
        input->strip_index==2?D3D12_INDEX_BUFFER_STRIP_CUT_VALUE_0xFFFFFFFF:D3D12_INDEX_BUFFER_STRIP_CUT_VALUE_DISABLED;
    desc.RasterizerState.FillMode=(D3D12_FILL_MODE)input->fill; desc.RasterizerState.CullMode=(D3D12_CULL_MODE)input->cull;
    desc.RasterizerState.MultisampleEnable=input->samples>1;
    desc.RasterizerState.FrontCounterClockwise=input->front_ccw; desc.RasterizerState.DepthClipEnable=input->depth_clip;
    desc.DepthStencilState.DepthFunc=D3D12_COMPARISON_FUNC_ALWAYS;
    desc.DepthStencilState.StencilReadMask=desc.DepthStencilState.StencilWriteMask=0xff;
    desc.DepthStencilState.FrontFace.StencilFunc=desc.DepthStencilState.BackFace.StencilFunc=D3D12_COMPARISON_FUNC_ALWAYS;
    desc.DepthStencilState.FrontFace.StencilFailOp=desc.DepthStencilState.FrontFace.StencilDepthFailOp=desc.DepthStencilState.FrontFace.StencilPassOp=D3D12_STENCIL_OP_KEEP;
    desc.DepthStencilState.BackFace=desc.DepthStencilState.FrontFace;
    const auto &depth=input->depth;
    if (depth.format) {
        if (depth.format!=DXGI_FORMAT_D16_UNORM && depth.format!=DXGI_FORMAT_D32_FLOAT &&
            depth.format!=DXGI_FORMAT_D24_UNORM_S8_UINT && depth.format!=DXGI_FORMAT_D32_FLOAT_S8X24_UINT) return 1;
        if (depth.write>1 || depth.compare<1 || depth.compare>8 || depth.read_mask>255 || depth.write_mask>255 ||
            !(depth.slope>=-FLT_MAX && depth.slope<=FLT_MAX) || !(depth.clamp>=-FLT_MAX && depth.clamp<=FLT_MAX)) return 1;
        const ZenitD12StencilFace faces[2]={depth.front,depth.back};
        for (const auto &f:faces) if (f.compare<1 || f.compare>8 || f.fail<1 || f.fail>8 || f.depth_fail<1 || f.depth_fail>8 || f.pass<1 || f.pass>8) return 1;
        D3D12_FEATURE_DATA_FORMAT_SUPPORT support={}; support.Format=(DXGI_FORMAT)depth.format;
        if (FAILED(raw_device->CheckFeatureSupport(D3D12_FEATURE_FORMAT_SUPPORT,&support,sizeof(support))) || !(support.Support1 & D3D12_FORMAT_SUPPORT1_DEPTH_STENCIL)) return 1;
        if (!zenit_d12_sample_supported(device,depth.format,input->samples)) return 1;
        desc.DSVFormat=(DXGI_FORMAT)depth.format;
        auto &d=desc.DepthStencilState; d.DepthEnable=TRUE; d.DepthWriteMask=depth.write?D3D12_DEPTH_WRITE_MASK_ALL:D3D12_DEPTH_WRITE_MASK_ZERO;
        d.DepthFunc=(D3D12_COMPARISON_FUNC)depth.compare;
        d.StencilEnable=depth.format==DXGI_FORMAT_D24_UNORM_S8_UINT || depth.format==DXGI_FORMAT_D32_FLOAT_S8X24_UINT;
        d.StencilReadMask=(UINT8)depth.read_mask; d.StencilWriteMask=(UINT8)depth.write_mask;
        d.FrontFace={(D3D12_STENCIL_OP)depth.front.fail,(D3D12_STENCIL_OP)depth.front.depth_fail,(D3D12_STENCIL_OP)depth.front.pass,(D3D12_COMPARISON_FUNC)depth.front.compare};
        d.BackFace={(D3D12_STENCIL_OP)depth.back.fail,(D3D12_STENCIL_OP)depth.back.depth_fail,(D3D12_STENCIL_OP)depth.back.pass,(D3D12_COMPARISON_FUNC)depth.back.compare};
        desc.RasterizerState.DepthBias=depth.bias; desc.RasterizerState.SlopeScaledDepthBias=depth.slope; desc.RasterizerState.DepthBiasClamp=depth.clamp;
    }
    desc.BlendState.AlphaToCoverageEnable=input->alpha_coverage; desc.BlendState.IndependentBlendEnable=TRUE; desc.NumRenderTargets=input->target_count;
    bool dual_source=false;
    for(uint32_t i=0;i<input->target_count;++i) {
        const auto &t=input->targets[i];
        dual_source |= t.color_src>=16 || t.color_dst>=16 || t.alpha_src>=16 || t.alpha_dst>=16;
    }
    if(dual_source) {
        if(input->target_count!=1 || !input->targets[0].blend) return 1;
        desc.BlendState.IndependentBlendEnable=FALSE;
    }
    for (uint32_t i=0;i<input->target_count;++i) {
        const auto &t=input->targets[i];
        if (t.write_mask>15 || t.blend>1 || !blend_factor(t.color_src,false) || !blend_factor(t.color_dst,false) ||
            !blend_factor(t.alpha_src,true) || !blend_factor(t.alpha_dst,true) || t.color_op<1 || t.color_op>5 || t.alpha_op<1 || t.alpha_op>5) return 1;
        D3D12_FEATURE_DATA_FORMAT_SUPPORT support={}; support.Format=(DXGI_FORMAT)t.format;
        if (FAILED(raw_device->CheckFeatureSupport(D3D12_FEATURE_FORMAT_SUPPORT,&support,sizeof(support))) ||
            !(support.Support1 & D3D12_FORMAT_SUPPORT1_RENDER_TARGET) || (t.blend && !(support.Support1 & D3D12_FORMAT_SUPPORT1_BLENDABLE))) return 1;
        if (!zenit_d12_sample_supported(device,t.format,input->samples)) return 1;
        desc.RTVFormats[i]=(DXGI_FORMAT)t.format;
        auto &b=desc.BlendState.RenderTarget[i]; b.BlendEnable=t.blend; b.RenderTargetWriteMask=(UINT8)t.write_mask;
        b.SrcBlend=(D3D12_BLEND)t.color_src; b.DestBlend=(D3D12_BLEND)t.color_dst; b.BlendOp=(D3D12_BLEND_OP)t.color_op;
        b.SrcBlendAlpha=(D3D12_BLEND)t.alpha_src; b.DestBlendAlpha=(D3D12_BLEND)t.alpha_dst; b.BlendOpAlpha=(D3D12_BLEND_OP)t.alpha_op;
    }
    ID3D12ShaderReflection *vs=nullptr,*ps=nullptr;
    HRESULT hr=D3DReflect(desc.VS.pShaderBytecode,desc.VS.BytecodeLength,IID_ID3D12ShaderReflection,(void **)&vs);
    if (SUCCEEDED(hr)) hr=D3DReflect(desc.PS.pShaderBytecode,desc.PS.BytecodeLength,IID_ID3D12ShaderReflection,(void **)&ps);
    if (FAILED(hr)) { if (vs) vs->Release(); if (ps) ps->Release(); return 2; }
    bool valid=reflected_layout(vs,layout,D3D12_SHVER_VERTEX_SHADER,1u) && reflected_layout(ps,layout,D3D12_SHVER_PIXEL_SHADER,2u);
    D3D12_SHADER_DESC vdesc={},pdesc={};
    if (FAILED(vs->GetDesc(&vdesc)) || FAILED(ps->GetDesc(&pdesc))) valid=false;
    bool position=false;
    for (uint32_t i=0;valid && i<vdesc.OutputParameters;++i) {
        D3D12_SIGNATURE_PARAMETER_DESC p={}; if (FAILED(vs->GetOutputParameterDesc(i,&p))) { valid=false; break; }
        if (p.SystemValueType==D3D_NAME_POSITION) position=true;
    }
    if (!position) valid=false;
    for (uint32_t i=0;valid && i<vdesc.InputParameters;++i) {
        D3D12_SIGNATURE_PARAMETER_DESC p={}; if (FAILED(vs->GetInputParameterDesc(i,&p))) { valid=false; break; }
        if (p.SystemValueType!=D3D_NAME_UNDEFINED) continue;
        bool found=false;
        for (uint32_t j=0;j<input->attribute_count;++j) {
            const auto &a=input->attributes[j]; uint32_t bytes,type; vertex_format(a.format,&bytes,&type);
            if (!_stricmp(p.SemanticName,"TEXCOORD") && p.SemanticIndex==a.location && uint32_t(p.ComponentType)==type) found=true;
        }
        if (!found) valid=false;
    }
    for (uint32_t i=0;valid && i<pdesc.InputParameters;++i) {
        D3D12_SIGNATURE_PARAMETER_DESC p={}; if (FAILED(ps->GetInputParameterDesc(i,&p))) { valid=false; break; }
        if (p.SystemValueType!=D3D_NAME_UNDEFINED) continue;
        bool found=false;
        for (uint32_t j=0;j<vdesc.OutputParameters;++j) {
            D3D12_SIGNATURE_PARAMETER_DESC v={}; if (FAILED(vs->GetOutputParameterDesc(j,&v))) { valid=false; break; }
            if (!_stricmp(p.SemanticName,v.SemanticName) && p.SemanticIndex==v.SemanticIndex && p.ComponentType==v.ComponentType && !(p.Mask & ~v.Mask)) found=true;
        }
        if (!found) valid=false;
    }
    ZenitDualSourceSignature lcd_signature;
    for (uint32_t i=0;valid && i<pdesc.OutputParameters;++i) {
        D3D12_SIGNATURE_PARAMETER_DESC p={}; if (FAILED(ps->GetOutputParameterDesc(i,&p))) { valid=false; break; }
        if (p.SystemValueType==D3D_NAME_TARGET) {
            if(dual_source) lcd_signature.target(p.SemanticIndex, p.ComponentType, p.Mask);
            const uint32_t target=dual_source && p.SemanticIndex==1 ? 0 : p.SemanticIndex;
            if(target>=input->target_count || uint32_t(p.ComponentType)!=color_type(input->targets[target].format)) valid=false;
        }
        else if (p.SystemValueType!=D3D_NAME_TARGET && !(p.SystemValueType==D3D_NAME_DEPTH && depth.format)) valid=false; // Depth/coverage output needs a future depth/MSAA path.
    }
    if(dual_source && !lcd_signature.valid(input->target_count, input->targets[0].blend != 0)) valid=false;
    if (!valid) { vs->Release(); ps->Release(); return 1; }
    auto pipeline=(ZenitD12RenderPipeline *)calloc(1,sizeof(ZenitD12RenderPipeline)); if (!pipeline) { vs->Release(); ps->Release(); return 2; }
    ID3DBlob *warp_vertex=nullptr,*warp_fragment=nullptr;
    if (zenit_d12_device_is_software(device) &&
        (zenit_d12_shader_warp_blob(vertex,(void **)&warp_vertex) || zenit_d12_shader_warp_blob(fragment,(void **)&warp_fragment))) {
        if (warp_vertex) warp_vertex->Release();
        if (warp_fragment) warp_fragment->Release();
        free(pipeline); vs->Release(); ps->Release(); return 2;
    }
    if (warp_vertex) desc.VS={warp_vertex->GetBufferPointer(),warp_vertex->GetBufferSize()};
    if (warp_fragment) desc.PS={warp_fragment->GetBufferPointer(),warp_fragment->GetBufferSize()};
    hr=raw_device->CreateGraphicsPipelineState(&desc,IID_ID3D12PipelineState,(void **)&pipeline->raw);
    if (warp_vertex) warp_vertex->Release();
    if (warp_fragment) warp_fragment->Release();
    if (FAILED(hr)) { free(pipeline); vs->Release(); ps->Release(); return 2; }
    pipeline->vertex=vs; pipeline->fragment=ps;
    {
        D12Requirement *v=nullptr,*f=nullptr; uint32_t nv=0,nf=0;
        int status=reflect_requirements(vs,&v,&nv);
        if (!status) status=reflect_requirements(ps,&f,&nf);
        if (!status) {
            pipeline->requirements=(D12Requirement *)calloc(nv+nf?nv+nf:1,sizeof(D12Requirement));
            if (!pipeline->requirements) status=2;
            else { memcpy(pipeline->requirements,v,nv*sizeof(*v)); memcpy(pipeline->requirements+nv,f,nf*sizeof(*f)); pipeline->requirement_counts[0]=nv; pipeline->requirement_counts[1]=nf; }
        }
        free(v); free(f); pipeline->requirement_status=status;
    }
    strncpy(pipeline->fragment_entry, zenit_d12_shader_entry(fragment), sizeof(pipeline->fragment_entry)-1);
    pipeline->layout=layout; zenit_d12_pipeline_layout_retain(layout); pipeline->refs=1;
    pipeline->samples=input->samples; pipeline->depth_format=depth.format; pipeline->depth_write=depth.write;
    pipeline->stencil_write=desc.DepthStencilState.StencilEnable && depth.write_mask &&
        (depth.front.fail!=1 || depth.front.depth_fail!=1 || depth.front.pass!=1 || depth.back.fail!=1 || depth.back.depth_fail!=1 || depth.back.pass!=1);
    pipeline->topology=input->topology; pipeline->strip_index=input->strip_index; pipeline->target_count=input->target_count; pipeline->slots=slots;
    for (uint32_t i=0;i<input->target_count;++i) pipeline->formats[i]=input->targets[i].format;
    memcpy(pipeline->strides,strides,sizeof(strides)); memcpy(pipeline->steps,steps,sizeof(steps)); memcpy(pipeline->ends,ends,sizeof(ends));
    *out=pipeline; return 0;
}
extern "C" void zenit_d12_render_pipeline_retain(ZenitD12RenderPipeline *p) { InterlockedIncrement(&p->refs); }
extern "C" void zenit_d12_render_pipeline_release(ZenitD12RenderPipeline *p) {
    if (!p || InterlockedDecrement(&p->refs)!=0) return;
    p->vertex->Release(); p->fragment->Release(); p->raw->Release(); zenit_d12_pipeline_layout_release(p->layout); free(p->requirements); free(p);
}
extern "C" void *zenit_d12_render_pipeline_native(ZenitD12RenderPipeline *p) { return p->raw; }
extern "C" ZenitD12PipelineLayout *zenit_d12_render_pipeline_layout(ZenitD12RenderPipeline *p) { return p->layout; }
#ifdef ZENIT_D12_TEST
// Ownership check after all caller-side shader/layout/device wrappers die.
// This asks real COM objects for their retained device, without a second draw path.
extern "C" int zenit_d12_test_render_pipeline_owned(ZenitD12RenderPipeline *p) {
    ID3D12Device *ps_device=nullptr,*root_device=nullptr;
    HRESULT hr=p->raw->GetDevice(IID_ID3D12Device,(void **)&ps_device);
    if (SUCCEEDED(hr)) hr=p->layout->root->GetDevice(IID_ID3D12Device,(void **)&root_device);
    bool valid=SUCCEEDED(hr) && ps_device==root_device && ps_device==zenit_d12_device_native(p->layout->owner);
    if (ps_device) ps_device->Release(); if (root_device) root_device->Release();
    return valid;
}
#endif

extern "C" void zenit_d12_render_pipeline_info(ZenitD12RenderPipeline *p, ZenitD12RenderInfo *out) {
    out->samples=p->samples; out->depth_format=p->depth_format; out->depth_write=p->depth_write; out->stencil_write=p->stencil_write;
    out->topology=p->topology; out->strip_index=p->strip_index; out->target_count=p->target_count; out->slots=p->slots;
    memcpy(out->formats,p->formats,sizeof(p->formats)); memcpy(out->strides,p->strides,sizeof(p->strides));
    memcpy(out->steps,p->steps,sizeof(p->steps)); memcpy(out->ends,p->ends,sizeof(p->ends));
}
extern "C" void *zenit_d12_render_pipeline_root(ZenitD12RenderPipeline *p) { return p->layout->root; }

extern "C" int zenit_d12_render_validate_bindings(ZenitD12RenderPipeline *p, uint32_t group,
    const ZenitD12BindingEntry *entries, uint32_t count) {
    if (p->requirement_status) return p->requirement_status;
    int status=validate_requirements(p->requirements,p->requirement_counts[0],p->layout,group,entries,count);
    return status?status:validate_requirements(p->requirements+p->requirement_counts[0],p->requirement_counts[1],p->layout,group,entries,count);
}

extern "C" uint32_t zenit_d12_pipeline_layout_draw_info(ZenitD12PipelineLayout *layout) { return layout->draw_info; }
extern "C" int zenit_d12_render_buffer_stride(ZenitD12RenderPipeline *p, uint32_t group, uint32_t binding, uint32_t *stride) {
    if (!p || !stride) return 1;
    bool found=false; *stride=0;
    ID3D12ShaderReflection *reflections[2]={p->vertex,p->fragment};
    for (auto reflection:reflections) {
        D3D12_SHADER_DESC desc={}; if (FAILED(reflection->GetDesc(&desc))) return 2;
        for (uint32_t i=0;i<desc.BoundResources;++i) {
            D3D12_SHADER_INPUT_BIND_DESC resource={};
            if (FAILED(reflection->GetResourceBindingDesc(i,&resource))) return 2;
            if (resource.Space!=group || resource.BindPoint!=binding) continue;
            if (resource.Type!=D3D_SIT_STRUCTURED && resource.Type!=D3D_SIT_BYTEADDRESS) continue;
            uint32_t value=resource.Type==D3D_SIT_STRUCTURED?resource.NumSamples:0;
            if (found && *stride!=value) return 1;
            *stride=value; found=true;
        }
    }
    return found?0:1;
}
