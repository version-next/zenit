const node_mod = @import("node.zig");
const types = @import("types.zig");

const Node = node_mod.Node;
const Transform2D = types.Transform2D;

pub const TransformBuildOptions = struct {
    include_scale: bool = true,
    include_rotation: bool = false,
};

pub fn buildNodeLocalTransform(node: *const Node, options: TransformBuildOptions) Transform2D {
    // NOTE: retained_scene 在 hit-test 路径中也被调，hit_runtime.buildRecursive 依赖 transformRect
    // 与 node.rect 严格一致（World rect 经 sticky/translate 路径已在 syncScrollbarFrame 之后稍有
    // delta）。即使 epoch==0 fallback 也不能完全保证此处行为等价。session 27 + session 29 都试过
    // 并 revert。保持 node.rect 直读。
    const origin = node.style.transform_origin().resolve(node.rectFromWorldOrFallback().w, node.rectFromWorldOrFallback().h);

    var transform = Transform2D.fromRectWithOrigin(
        node.rectFromWorldOrFallback().x + node.style.translate_x + node.frame_state.frame_local.runtime.sticky.x,
        node.rectFromWorldOrFallback().y + node.style.translate_y + node.frame_state.frame_local.runtime.sticky.y,
        node.rectFromWorldOrFallback().w,
        node.rectFromWorldOrFallback().h,
        if (options.include_scale) node.style.scale_x() else 1.0,
        if (options.include_scale) node.style.scale_y() else 1.0,
        origin.x,
        origin.y,
    );

    // Rotation remains opt-in so callers can stage affine adoption incrementally.
    if (options.include_rotation and @abs(node.style.rotate()) > 0.0001) {
        transform = transform.mul(
            Transform2D.rotation(node.style.rotate(), origin.x, origin.y),
        );
    }

    return transform;
}

pub fn buildNodeWorldTransform(node: *const Node, parent_transform: Transform2D, options: TransformBuildOptions) Transform2D {
    return parent_transform.mul(buildNodeLocalTransform(node, options));
}
