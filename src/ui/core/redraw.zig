/// 帧级重绘标记：
/// on_before_render 钩子中的 markRenderDirty() 会设置该标记，
/// 通知 Cx 有活跃动画需要继续渲染下一帧。
///
/// 线程安全约束：仅在主线程（UI 线程）读写，当前单线程架构下安全。
/// 若未来引入多线程渲染，需改为 atomic 或实例字段。
pub var requested: bool = false;
