/// Liquid Glass Composite Shader  v15
///
/// 物理模型：双界面 slab（top surface 入射 + bottom surface 出射）
/// 折射位移用 Snell 角度差公式：displacement = h * d_eff * (tan(θi) - tan(θr))
/// 色散：R/G/B 各用不同 IOR 产生 chromatic aberration
///
/// 参数范围（全部经过 clamp 保护）：
///                         范围       中性默认    Apple 推荐
///   glass_intensity:    [0, 2]       1.0        1.4
///   specular_opacity:   [0, 1]       0.35       0.38~0.40
///   specular_saturation:[1, 12]      6.0        7.0~7.5
///   refraction_level:   [0, 1]       1.0        1.0
///   blur_level:         [0, 1]       1.0        1.0
///   warp_gain:          [0, 3]       1.0        1.0
///   center_thickness:   [0, 20]      4.0        4.0~5.0（逻辑像素）
///   top_surface:        [0, 4]       2.0        2.0 (convex squircle)
///   top_bezel_width:    [0.04,0.45]  0.18       0.14~0.24
///   bottom_surface:     [0, 4]       0.0        0.0 (flat)
///   bottom_bezel_width: [0.04,0.45]  0.12       0.08~0.20
///   specular_angle:     [-π, π]      -π/3       -60°
///   magnification:      [-1, 2]      0.0        0.2~0.8
///   scale_ratio:        [0.35,1.6]   1.0        0.55~1.25
///   edge_field_strength:[0.2, 4.0]   1.0        1.4~2.4
///   center_zoom_radius: [0.1, 1.5]   0.58       field core ratio / slab coverage
///   center_zoom_falloff:[0.4, 6.0]   2.2        field shoulder hardness
///   backdrop_distance:  [0, 40]      0.0        0~12 px

#include <metal_stdlib>
using namespace metal;

struct GlassUniforms {
    float2 texel_size;
    float corner_radius;
    float glass_intensity;      // 整体强度缩放（0-2，默认1.4）
    float2 rect_size;
    float scale_factor;
    float4 glass_tint;          // RGBA 0-1，用户自定义色调
    float4 specular_params;     // x=opacity, y=saturation, z=refraction, w=blur mix
    float4 optic_params;        // x=warp_gain, y=center_thickness, z=backdrop_distance
    float4 surface_params;      // x=top surface kind, y=top bezel width, z=spec angle, w=magnification
    float4 bottom_surface_params;// x=bottom surface kind, y=bottom bezel width
    float4 lens_params;         // x=field radius, y=field falloff, z=edge field strength, w=scale ratio
    float4 content_uv;          // 玻璃矩形在 padded capture 纹理内的 uv 子区 (off_x, off_y, scale_x, scale_y)
    float4 edge_params;         // blur渐变: x=direction(0off/1to_bottom/2to_top/3to_right/4to_left), y=保留, z=全局强度0-1, w=stop个数
    float4 edge_stop_pos;       // blur 渐变 stop 位置（0~1 占节点沿渐变轴尺寸百分比，升序）
    float4 edge_stop_str;       // blur 渐变 stop 强度（0~1）
    float4 valid_uv;            // capture 内真实背板 uv 子矩形 {x0,y0,x1,y1}（pad 越出 RT 的部分是透明黑）
};

struct GlassVertexOutput {
    float4 position [[position]];
    float2 uv;
};

vertex GlassVertexOutput glass_vertex_main(uint vertex_id [[vertex_id]]) {
    GlassVertexOutput out;
    float2 pos;
    pos.x = (vertex_id == 1) ? 3.0 : -1.0;
    pos.y = (vertex_id == 2) ? 3.0 : -1.0;
    out.position = float4(pos, 0.0, 1.0);
    out.uv = float2((pos.x + 1.0) * 0.5, (1.0 - pos.y) * 0.5);
    return out;
}

// 圆角矩形 SDF（返回带符号距离，内部为负）
float sdf_rr(float2 p, float2 b, float r) {
    float2 q = abs(p) - b + r;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

// SDF 梯度（归一化外法线）
float2 sdf_grad(float2 p, float2 b, float r) {
    const float h = 0.8;
    float2 n = float2(
        sdf_rr(p + float2(h,0), b, r) - sdf_rr(p - float2(h,0), b, r),
        sdf_rr(p + float2(0,h), b, r) - sdf_rr(p - float2(0,h), b, r)
    );
    float m = length(n);
    return m > 1e-5 ? n / m : float2(0, -1);
}

// RGB → 亮度
float luma(float3 c) {
    return dot(c, float3(0.2126, 0.7152, 0.0722));
}

// 调整饱和度（sat=1 不变，sat>1 增强，sat<1 减弱）
float3 saturate_color(float3 c, float sat) {
    float l = luma(c);
    return clamp(mix(float3(l), c, sat), 0.0, 1.0);
}

struct SurfaceSample {
    float height;   // 归一化高度 [0,1]，concave 时 [0,~0.58]
    float slope;    // dh/dt，边缘陡→0 时趋于无穷（被 saturate 限制）
    float center_bias;
};

constant float kDispersionIOR_R = 1.430;
constant float kDispersionIOR_G = 1.450;
constant float kDispersionIOR_B = 1.478;

float circle_height(float t) {
    float omt = 1.0 - saturate(t);
    return sqrt(max(1.0 - omt * omt, 0.0));
}

float circle_deriv(float t) {
    float omt = 1.0 - saturate(t);
    float base = max(circle_height(t), 1e-5);
    return omt / base;
}

float squircle_height(float t) {
    float omt = 1.0 - saturate(t);
    return pow(max(1.0 - omt * omt * omt * omt, 1e-6), 0.25);
}

float squircle_deriv(float t) {
    t = saturate(t);
    float omt = 1.0 - t;
    float poly = omt * omt * omt * omt;
    float base = max(1.0 - poly, 1e-6);
    return (omt * omt * omt) / pow(base, 0.75);
}

SurfaceSample sample_surface(uint kind, float t) {
    t = saturate(t);

    if (kind == 0) {
        return SurfaceSample{ 0.0, 0.0, 0.0 };
    }
    if (kind == 1) {
        return SurfaceSample{ circle_height(t), circle_deriv(t) * 1.08, 0.18 };
    }
    if (kind == 3) {
        return SurfaceSample{ 1.0 - squircle_height(t), -squircle_deriv(t), -0.42 };
    }
    if (kind == 4) {
        float outer_h = circle_height(t) * 1.06;
        float inner_h = (1.0 - squircle_height(t)) * 1.18;
        float blend = smoothstep(0.18, 0.68, t);
        return SurfaceSample{
            mix(outer_h, inner_h, blend),
            mix(circle_deriv(t) * 1.08, -squircle_deriv(t) * 1.26, blend),
            -0.42,
        };
    }

    return SurfaceSample{ squircle_height(t), squircle_deriv(t), 0.05 };
}

/// Snell 角度差位移：光线穿过倾斜 slab 后在屏幕上的偏移量。
/// slope = dh/dt (profile 导数)，thickness_px = 有效厚度（像素），
/// ior = 折射率。返回标量位移（像素）。
/// 公式：displacement = height * thickness * (tan(θi) - tan(θr))
///   其中 θi = atan(slope * thickness / bezel_w)
///         sin(θr) = sin(θi) / ior
float snell_displacement(float slope, float height, float thickness_px, float bezel_w, float ior) {
    // slope 是 profile 空间的导数 dh/dt，转换到物理空间：
    // 物理斜率 = slope * (thickness / bezel_w)
    float physical_slope = slope * thickness_px / max(bezel_w, 1.0);
    float theta_i = atan(physical_slope);
    float sin_i = sin(theta_i);
    float sin_r = clamp(sin_i / ior, -1.0, 1.0);
    float theta_r = asin(sin_r);
    // 位移 = 高度份额 × 厚度 × (tan(入射) - tan(折射))
    float disp = height * thickness_px * (tan(theta_i) - tan(theta_r));
    return disp;
}

fragment float4 glass_fragment_main(
    GlassVertexOutput in [[stage_in]],
    constant GlassUniforms& u [[buffer(0)]],
    texture2d<float> blur_tex  [[texture(0)]],
    texture2d<float> sharp_tex [[texture(1)]],
    sampler smp [[sampler(0)]]
) {
    // ── 参数预处理（全部 clamp，防止跳变/异常值进入计算）───────────
    float gi  = clamp(u.glass_intensity,         0.0,  2.0);
    // gi 门控：glass_intensity=0 承诺"仅 blur"——折射/色散/rim-sharp/饱和度/
    // Fresnel/内阴影全部乘此门控归零；gi∈(1,2] 只增强 specular（spec_str 直接 ×gi）。
    float gi_gate = clamp(gi, 0.0, 1.0);
    float sop = clamp(u.specular_params.x,       0.0,  1.0);
    float sst = clamp(u.specular_params.y,       1.0, 12.0);
    float rl  = clamp(u.specular_params.z,       0.0,  1.0);
    float bl  = clamp(u.specular_params.w,       0.0,  1.0);
    float wg  = clamp(u.optic_params.x,          0.0,  3.0);
    float ct  = clamp(u.optic_params.y,          0.0, 20.0);
    float gap = clamp(u.optic_params.z,          0.0, 40.0);
    uint  top_surface_kind = (uint)clamp(round(u.surface_params.x), 0.0, 4.0);
    float top_bezel_ratio  = clamp(u.surface_params.y, 0.04, 0.45);
    float spec_angle       = u.surface_params.z;
    float magnify          = clamp(u.surface_params.w, -1.0, 2.0);
    uint  bottom_surface_kind = (uint)clamp(round(u.bottom_surface_params.x), 0.0, 4.0);
    float bottom_bezel_ratio  = clamp(u.bottom_surface_params.y, 0.04, 0.45);
    float field_radius        = clamp(u.lens_params.x, 0.1, 1.5);
    float field_falloff       = clamp(u.lens_params.y, 0.4, 6.0);
    float edge_field_strength = clamp(u.lens_params.z, 0.2, 4.0);
    float scale_ratio         = clamp(u.lens_params.w, 0.35, 1.6);

    float  s       = max(u.scale_factor, 0.1);
    float2 rect_px = max(u.rect_size * s, float2(2.0));
    float2 half_px = rect_px * 0.5;
    float  mh      = max(min(half_px.x, half_px.y), 1.0);
    float  cr      = clamp(u.corner_radius * s, 0.0, mh);
    // padded capture：in.uv 覆盖整张 padded 纹理，节点区是其中的子区。
    float2 cuv_off   = u.content_uv.xy;
    float2 cuv_scale = max(u.content_uv.zw, float2(1e-4));
    float2 node_uv   = (in.uv - cuv_off) / cuv_scale;
    float2 p         = (node_uv - 0.5) * rect_px;

    // ── SDF & mask ─────────────────────────────────────────────────
    float  d    = sdf_rr(p, half_px, cr);
    float  aa   = max(fwidth(d) * 0.5, 0.5);
    float  mask = smoothstep(aa, -aa, d);
    if (mask < 0.001) discard_fragment();
    float  inset = max(-d, 0.0);

    // ── 2D 边缘法线（向外）─────────────────────────────────────────
    float2 out_n = sdf_grad(p, half_px, cr);

    // ── Glass Surface sampling ─────────────────────────────────────
    float  top_bezel_w = clamp(mh * top_bezel_ratio, 2.0, mh);
    float  bottom_bezel_w = clamp(mh * bottom_bezel_ratio, 2.0, mh);
    float  t_top    = clamp(inset / top_bezel_w, 0.0, 1.0);
    float  t_bottom = clamp(inset / bottom_bezel_w, 0.0, 1.0);
    SurfaceSample top_surf = sample_surface(top_surface_kind, t_top);
    SurfaceSample bot_surf = sample_surface(bottom_surface_kind, t_bottom);
    float  top_edge_factor = pow(1.0 - t_top, 2.3);
    float  bottom_edge_factor = pow(1.0 - t_bottom, 2.1);

    // ── Pseudo-thickness（top + bottom height，concave 底减薄）────
    float  top_thick = min(top_bezel_w * (0.52 + 0.48 * top_surf.height), 20.0);
    float  bottom_thick = min(bottom_bezel_w * (0.38 + 0.58 * bot_surf.height), 20.0);
    float  gap_scale = 1.0 + min(gap * 0.085, 2.6);
    float  d_eff = max(
        ct +
        top_thick * (0.38 + top_edge_factor * 0.62) +
        bottom_thick * (0.24 + bottom_edge_factor * 0.76) +
        gap * 0.78,
        0.5  // 最小厚度 0.5px，确保 Snell 计算不退化
    );

    // ── 3D 法线（用于 Specular / Fresnel，保留原有精度）────────────
    // tilt 不受 gi 影响：gi 已在折射幅度（rl_wg × gi_gate）中起作用，
    // 同时影响法线倾斜会导致非线性双重放大
    float  tilt = 0.52 + gap * 0.01;
    float  top_slope_n = top_surf.slope * tilt * (0.30 + 0.70 * (1.0 - t_top));
    float  bottom_presence = clamp(abs(bot_surf.center_bias) + abs(bot_surf.height) * 0.26, 0.0, 1.4);
    float  bot_slope_n = bot_surf.slope * tilt * (0.18 + 0.38 * rl + bottom_presence * 0.22) * (0.25 + 0.75 * (1.0 - t_bottom));

    // body region: 过了 bezel 的内部区域
    float  scale_t = saturate((scale_ratio - 0.35) / 1.25);
    float  slab_t = saturate(inset / max(mh, 0.001));
    float  spread_gain = mix(1.15, 3.75, scale_t);
    float  body_t = 1.0 - pow(saturate(1.0 - slab_t), spread_gain);
    float  body_coord = 1.0 - slab_t;
    SurfaceSample top_body = sample_surface(top_surface_kind, body_t);
    SurfaceSample bot_body = sample_surface(bottom_surface_kind, body_t);
    float  body_profile = top_body.height + bot_body.height * 0.55;
    float  body_t_slope = spread_gain * pow(saturate(1.0 - slab_t), max(spread_gain - 1.0, 0.0)) / max(mh, 0.001);
    float  body_profile_slope = (top_body.slope + bot_body.slope * 0.55) * tilt * body_t_slope;

    float  field_cover = max(saturate((field_radius - 0.1) / 1.4), 0.02);
    float  field_hardness = saturate((field_falloff - 0.4) / 5.6);
    float  field_base = 1.0 - exp(-body_t * (0.8 + field_cover * 4.2));
    float  field_envelope = pow(saturate(field_base), mix(0.78, 2.4, field_hardness));
    float  body_grad_gain = 0.18 + 0.82 * pow(saturate(1.0 - body_coord), 0.55) * (0.28 + 0.72 * field_envelope);

    float2 ellipse_axis = max(half_px - float2(cr * 0.35), float2(1.0));
    float2 ellipse_p = p / ellipse_axis;
    float2 radial_dir = normalize(select(float2(0.0, -1.0), ellipse_p, length_squared(ellipse_p) > 1e-6));
    float  body_dir_mix = smoothstep(0.10, 0.92, body_t);
    float2 body_dir = normalize(mix(out_n, radial_dir, body_dir_mix));
    float2 body_grad = -body_dir * body_profile_slope * body_grad_gain;
    float2 edge_grad = out_n * (top_slope_n + bot_slope_n) * (0.16 + 0.34 * top_edge_factor + 0.10 * bottom_edge_factor);
    float3 N = normalize(float3(body_grad + edge_grad, 1.0));

    // ── 折射位移：Snell 角度差公式（物理驱动）──────────────────────
    // 合并 slope = top + bottom（同向叠加），用解析导数而非 refract()
    float  combined_slope = top_surf.slope + bot_surf.slope * 0.55;
    float  combined_height = top_surf.height + bot_surf.height * 0.55;
    // body 区域也有 profile slope
    float  total_slope = mix(combined_slope, top_body.slope + bot_body.slope * 0.55, body_t);
    float  total_height = mix(combined_height, body_profile, body_t);
    // scale_ratio 缩放有效 bezel：大 scale_ratio → bezel 更宽 → 位移分布更均匀；
    // 小 scale_ratio → bezel 更窄 → 位移集中在边缘
    float  effective_bezel = mix(top_bezel_w, mh, body_t) * scale_ratio;

    // Snell 位移：R/G/B 各用不同 IOR → chromatic aberration
    float  disp_r = snell_displacement(total_slope, total_height, d_eff, effective_bezel, kDispersionIOR_R);
    float  disp_g = snell_displacement(total_slope, total_height, d_eff, effective_bezel, kDispersionIOR_G);
    float  disp_b = snell_displacement(total_slope, total_height, d_eff, effective_bezel, kDispersionIOR_B);

    // edge_field_strength 缩放 bezel 区域的位移强度
    float  edge_boost = mix(edge_field_strength, 1.0, body_t);
    disp_r *= edge_boost;
    disp_g *= edge_boost;
    disp_b *= edge_boost;

    // center_zoom_radius / center_zoom_falloff 调制 body 区域的位移包络
    // field_envelope 已包含这两个参数：field_radius 控制覆盖半径，field_falloff 控制衰减
    float  body_disp_envelope = 0.15 + 0.85 * field_envelope;
    disp_r *= mix(1.0, body_disp_envelope, body_t);
    disp_g *= mix(1.0, body_disp_envelope, body_t);
    disp_b *= mix(1.0, body_disp_envelope, body_t);

    // warp_gain 作为感知缩放因子（物理公式给出基础尺度，wg 做微调）
    // refraction_level 控制折射/直射混合；gi_gate 在此归零折射与色散（不重复影响法线）
    float  rl_wg = rl * wg * gi_gate;
    disp_r *= rl_wg * gap_scale;
    disp_g *= rl_wg * gap_scale;
    disp_b *= rl_wg * gap_scale;

    // 位移方向：SDF 梯度指向外，折射让光线向内偏 → 用 -out_n
    // body 区域逐渐过渡到径向方向
    // 位移方向：向外采样（rim 处显示玻璃边界之外的内容 → 边缘内收/压缩感，
    // 对齐 Apple liquid glass 的水滴边缘观感）。向内采样会变成凸透镜外凸放大。
    float2 disp_dir = normalize(mix(out_n, radial_dir, body_dir_mix));

    // 转为 UV 空间位移（物理像素 → padded 纹理 UV，texel_size = 1/纹理像素）
    float2 uv_disp_r = clamp(disp_dir * disp_r * u.texel_size, -0.45, 0.45);
    float2 uv_disp_g = clamp(disp_dir * disp_g * u.texel_size, -0.45, 0.45);
    float2 uv_disp_b = clamp(disp_dir * disp_b * u.texel_size, -0.45, 0.45);

    // Magnification：绕节点中心缩放（padded uv 空间）；padding 提供了真实的
    // 外圈内容，放大采样不再是小纹理插值。
    float  magnify_strength = clamp(magnify, -1.0, 2.0);
    float  magnify_mix = clamp(magnify_strength * (0.10 + 0.26 * field_envelope), -0.55, 0.75);
    float2 sample_center = cuv_off + 0.5 * cuv_scale;
    float2 sample_uv = sample_center + (in.uv - sample_center) * (1.0 - magnify_mix);

    // 钳进有效背板子矩形（不是整张纹理）：贴窗口边的 glass，pad 越出 RT 的
    // 部分是透明黑，rim 位移采进去会拿到纯黑（alpha 归一化对全零区无能为力）。
    float2 uv_lo = u.valid_uv.xy + 0.001;
    float2 uv_hi = u.valid_uv.zw - 0.001;
    float2 uvr = clamp(sample_uv + uv_disp_r, uv_lo, uv_hi);
    float2 uvg = clamp(sample_uv + uv_disp_g, uv_lo, uv_hi);
    float2 uvb = clamp(sample_uv + uv_disp_b, uv_lo, uv_hi);

    // ── 背景采样：blur_level 控制 sharp/blur 混合 ──────────────────
    // rim 区（bezel 内侧）向 sharp 回退：折射位移最强的区域必须保留可辨认
    // 的背景内容，否则弯折的只是一团雾、lensing 完全不可见（对齐 Apple /
    // kube.io：refraction 视觉主要来自边缘弯折的近清晰背板）。
    // rim 的 sharp 回退宽度按物理像素封顶（逻辑 8px），与 bezel 几何解耦：
    // bezel_w 是比例值，大面板（mh 数百 px）会放大出几十 px 宽的"清晰带"，
    // 背景原样透出、完全不像磨砂玻璃。8px 封顶下小 capsule（bezel ≈ 7~8
    // 逻辑 px）观感不变，大面板收敛成细折光线。
    float rim_sharp_w = min(top_bezel_w, 8.0 * s);
    float t_rim = clamp(inset / rim_sharp_w, 0.0, 1.0);
    float rim_sharp = (1.0 - smoothstep(0.0, 0.85, t_rim)) * step(0.5, (float)(top_surface_kind != 0)) * gi_gate;
    // blur 渐变（类 CSS linear-gradient）：把局部 blur 强度当作沿某方向变化的
    // 属性——声明契约见 types.zig BlurGradient。stop strength ≡ blur_level 语义
    // （0=纯 sharp，1=纯 blur），此处沿轴插值出每像素的局部 blur_level；
    // 全局 strength 在基底 bl 与该 profile 之间淡入淡出（见下）。
    float local_bl = bl;
    // gradient 未激活时恒 1 → local_bl == bl 且 gap 项原样保留，普通 glass
    // 路径逐位等价于修改前。
    float gradient_scale = 1.0;
    if (u.edge_params.x > 0.5 && u.edge_params.z > 0.001) {
        int   grad_dir = int(u.edge_params.x + 0.5);
        float gt = (grad_dir == 1) ? node_uv.y
                 : (grad_dir == 2) ? (1.0 - node_uv.y)
                 : (grad_dir == 3) ? node_uv.x
                 : (1.0 - node_uv.x);
        gt = clamp(gt, 0.0, 1.0);
        int   stop_n = clamp(int(u.edge_params.w + 0.5), 2, 4);
        float prof = u.edge_stop_str[0];
        for (int i = 0; i < stop_n - 1; i++) {
            float p0 = u.edge_stop_pos[i];
            float p1 = max(u.edge_stop_pos[i + 1], p0 + 1e-4);
            if (gt >= p0)
                prof = mix(u.edge_stop_str[i], u.edge_stop_str[i + 1], smoothstep(p0, p1, gt));
        }
        float str  = clamp(u.edge_params.z, 0.0, 1.0);
        float pf   = clamp(prof, 0.0, 1.0);
        // 两条语义（types.zig BlurGradient 契约）：
        //   stop strength ≡ 绝对 blur_level（0=纯 sharp，1=纯 blur）；
        //   BlurGradient.strength ≡ 全局淡入淡出乘子——在「无渐变的均匀基底
        //   bl」与「渐变 profile」之间插值：local = mix(bl, prof, str)。
        //
        // 旧写法 local = max(bl, str) * prof 把 str 当成"目标糊度"：只要
        // str > 0.001 渐变就整段生效，profile 落 0 的区域瞬间变 sharp。
        // GlassBox scroll-edge 的 str 随滚动从 0 平滑升起，结果首帧滚动
        // 玻璃条下半截就失去模糊（2026-09-29 用户报告：滚动后背后
        // "Content row N" 锐利透出）。mix 在 str→0 处连续退回基底。
        //
        // 下游极值核对：下游应用的 progressiveBlurEdge（bl=0, str=1）→ mix(0,pf,1)
        // = pf，与旧式 max(0,1)*pf 逐位相同；gap 缩放同理 mix(1,pf,1)=pf。
        gradient_scale = mix(1.0, pf, str);
        local_bl = mix(bl, pf, str);
    }
    // gap（backdrop_distance）是"离背板越远越糊"的物理项，对基底成立；但它
    // 是常数偏置，会把 gradient 的 sharp 端一并抬起来（实测 gap≈2.5 时贡献
    // +0.112，直接吃掉 ramp 尾部）。gradient 激活时按同一 profile 缩放它，
    // 保证 prof=0 处 effective_blur 精确为 0。
    float effective_blur = clamp(local_bl + gap * 0.045 * gradient_scale, 0.0, 1.0) * (1.0 - rim_sharp * 0.85);
    // 采样携带 alpha = coverage：capture pad 超出窗口/RT 的部分是透明黑
    //（有效背板 alpha 恒 1），blur 后 rgb 已按 coverage 预乘。除回 alpha
    // 等价于只对有效背板求加权平均（clamp-to-edge 式延展），否则贴窗口边
    // 的 glass 会晕出一圈黑边。
    float4 br = blur_tex.sample(smp, uvr);
    float4 bg = blur_tex.sample(smp, uvg);
    float4 bb = blur_tex.sample(smp, uvb);
    float3 blur_c = float3(br.r / max(br.a, 1e-3),
                           bg.g / max(bg.a, 1e-3),
                           bb.b / max(bb.a, 1e-3));
    // sharp 未经模糊，pad 区 alpha 是硬 0/1：采到 pad 时无内容可恢复，
    // 按各自 coverage 回退到 blur 的延展色，避免除以 0 得纯黑。
    float4 sr = sharp_tex.sample(smp, uvr);
    float4 sg = sharp_tex.sample(smp, uvg);
    float4 sb = sharp_tex.sample(smp, uvb);
    float3 sharp_c = float3(mix(blur_c.r, sr.r / max(sr.a, 1e-3), saturate(sr.a)),
                            mix(blur_c.g, sg.g / max(sg.a, 1e-3), saturate(sg.a)),
                            mix(blur_c.b, sb.b / max(sb.a, 1e-3), saturate(sb.a)));
    float3 base = mix(blur_c, sharp_c, 1.0 - effective_blur);

    // ── 背景 saturate / brightness（CSS backdrop-filter 顺序：先于折射与高光）──
    // 0 视为未设置（兼容旧的零初始化 uniform）。
    float bd_sat = u.bottom_surface_params.z;
    float bd_bri = u.bottom_surface_params.w;
    if (bd_sat > 0.0 && abs(bd_sat - 1.0) > 1e-3) base = saturate_color(base, bd_sat);
    if (bd_bri > 0.0 && abs(bd_bri - 1.0) > 1e-3) base = clamp(base * bd_bri, 0.0, 1.0);

    // ── 折射饱和度微增强（两面边缘都贡献色散）──────────────────────
    float combined_edge = top_edge_factor + bottom_edge_factor * 0.45;
    float sat_boost = mix(1.0, 1.02 + combined_edge * 0.18, gi_gate);
    base = saturate_color(base, sat_boost);

    // ── Specular Highlight（可调角度）——入射面主高光 ─────────────────
    float2 light2d = normalize(float2(cos(spec_angle), sin(spec_angle)));
    float3 light_dir = normalize(float3(light2d, 0.55));
    float  ndotl     = dot(N, light_dir);
    float  rim_light = smoothstep(-0.3, 1.0, ndotl);
    // rim_mask: bezel 区域强高光 + body 区域保留微弱 ambient specular
    float  rim_mask  = saturate(top_edge_factor * top_edge_factor + 0.08);

    float3 spec_base = saturate_color(base, sst);
    float3 spec_col  = mix(spec_base, float3(1.0), clamp(rim_light * rim_light + top_surf.height * 0.25, 0.0, 1.0));
    float  spec_str  = clamp(rim_light * rim_mask * sop * gi, 0.0, 1.0);
    base = mix(base, spec_col, spec_str);

    // ── 出射面次级高光（bottom surface 内反射）──────────────────────
    if (bottom_surface_kind != 0) {
        float  bot_rim_mask = saturate(bottom_edge_factor * bottom_edge_factor);
        float  bot_ndotl    = dot(N, normalize(float3(-light2d * 0.6, 0.75)));
        float  bot_rim      = smoothstep(-0.2, 0.8, bot_ndotl);
        float  bot_spec_str = clamp(bot_rim * bot_rim_mask * sop * gi * 0.30, 0.0, 0.35);
        float3 bot_spec_col = mix(spec_base, float3(1.0, 1.0, 0.98), bot_rim * 0.5 + bot_surf.height * 0.2);
        base = mix(base, bot_spec_col, bot_spec_str);
    }

    // ── Fresnel 边缘高光（入射面 + 出射面）──────────────────────────
    float cosV     = max(dot(N, float3(0.0, 0.0, -1.0)), 0.0);
    float fresnel  = 0.04 + 0.96 * pow(1.0 - cosV, 5.0);
    float lit_side = max(dot(out_n, light2d), 0.0);
    float rim_w_top = clamp(top_bezel_w * 0.20, 1.5, 5.0);
    float edge_rim_top = 1.0 - smoothstep(0.0, rim_w_top, inset);
    float f_str_top = clamp(fresnel * lit_side * edge_rim_top * (0.78 + gap * 0.015), 0.0, 0.9) * gi_gate;
    base = mix(base, float3(1.0, 1.0, 1.02), f_str_top);
    if (bottom_surface_kind != 0) {
        float rim_w_bot = clamp(bottom_bezel_w * 0.20, 1.5, 5.0);
        float edge_rim_bot = 1.0 - smoothstep(0.0, rim_w_bot, inset);
        float f_str_bot = clamp(fresnel * lit_side * edge_rim_bot * 0.35, 0.0, 0.4) * gi_gate;
        base = mix(base, float3(1.0, 1.0, 1.01), f_str_bot);
    }

    // ── 背光侧内阴影（两面边缘都贡献）──────────────────────────────
    float2 shad2d = -light2d;
    float  edge_rim_combined = edge_rim_top;
    if (bottom_surface_kind != 0) {
        float rim_w_bot2 = clamp(bottom_bezel_w * 0.20, 1.5, 5.0);
        edge_rim_combined = max(edge_rim_top, (1.0 - smoothstep(0.0, rim_w_bot2, inset)) * 0.5);
    }
    float  shad_str = clamp(edge_rim_combined * max(dot(out_n, shad2d), 0.0) * 0.22, 0.0, 0.4) * gi_gate;
    base = base * (1.0 - shad_str);

    // ── Beer-Lambert 有色透射 Tint ──────────────────────────────────
    float ta = clamp(u.glass_tint.a, 0.0, 1.0);
    if (ta > 0.005) {
        const float d_ref = 8.0;
        float3 T_ref = mix(float3(1.0), clamp(u.glass_tint.rgb, float3(0.0), float3(1.0)), ta * 0.60);
        T_ref = max(T_ref, float3(0.05));
        float3 sigma_a = -log(T_ref) / d_ref;
        float  d_eff_clamped = clamp(d_eff, 0.0, 50.0);
        float3 absorb = exp(-sigma_a * d_eff_clamped);
        absorb = clamp(absorb, float3(0.02), float3(1.0));
        base = base * absorb;
    }

    // blur 渐变已在背景采样阶段（effective_blur ← local_bl）参与，沿轴驱动
    // sharp↔blur 混合并让后续折射/高光/tint 盖在正确基底上——不再于此二次叠雾。

    base = clamp(base, 0.0, 1.0);
    return float4(base * mask, mask);
}
