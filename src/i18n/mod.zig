//! International text algorithms.
//!
//! Bidi is a complete Unicode 17.0.0 UAX #9 implementation through per-line
//! L2 reordering. Line breaking remains a documented UAX #14 subset.

pub const bidi = @import("bidi.zig");
pub const linebreak = @import("linebreak.zig");
pub const script = @import("script.zig");

pub const BidiClass = bidi.BidiClass;
pub const Direction = bidi.Direction;
pub const Run = bidi.Run;
pub const detectParagraphDirection = bidi.detectParagraphDirection;
pub const resolveBidi = bidi.resolve;
pub const ResolvedBidiText = bidi.ResolvedText;
pub const splitRuns = bidi.splitRuns;

pub const LineBreakClass = linebreak.LineBreakClass;
pub const findBreakOpportunities = linebreak.findBreakOpportunities;
pub const canBreakBetween = linebreak.canBreakBetween;

pub const Script = script.Script;
pub const ScriptRun = script.ScriptRun;
pub const splitScriptRuns = script.splitScriptRuns;
pub const classifyScript = script.classify;

test {
    _ = bidi;
    _ = linebreak;
    _ = script;
}
