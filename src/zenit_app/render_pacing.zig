/// Shared render pacing configuration.
///
/// Keep CAMetalLayer drawable depth and CPU in-flight frame slots aligned with
/// the renderers' triple-buffered instance storage. Letting these drift apart
/// reintroduces acquire/pacing jitter during sustained editor scroll.
pub const maximum_frame_latency: u32 = 2;
pub const frames_in_flight: u32 = maximum_frame_latency + 1;
