/// trace, env-gated diagnostic helpers shared across modules
///
/// Layered separately from ui / render so that all of them can `@import("trace")`
/// without introducing extra coupling. Default-off; first-call caches the env
/// lookup so the hot path pays nothing once disabled.
///
/// Triggers:
///   ZENIT_TEXT_FLICKER_TRACE=1  -> text_flicker.log
pub const text_flicker = @import("text_flicker.zig");
