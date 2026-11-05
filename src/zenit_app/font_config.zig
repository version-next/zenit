//! Font configuration shared by native App runtimes.
pub const FontConfig = struct {
    /// BCP-47 language for Windows DirectWrite fallback (for example zh-CN or ja-JP). Null: the
    /// user's UI language, so CJK text falls back to the faces and glyph forms the system uses.
    locale: ?[:0]const u8 = null,
    /// Default font size (for ui.text default 14pt). `small` slot.
    small_size: u32 = 14,
    /// Medium font (for H3 etc). `medium` slot.
    medium_size: u32 = 18,
    /// Large font (for H2 etc). `large` slot.
    large_size: u32 = 24,
    /// Font family fallback chain. First found wins. "system-ui" is the platform UI font: SF Pro on
    /// macOS, the system message font on Windows (Segoe UI; Microsoft YaHei UI, Yu Gothic UI or
    /// Malgun Gothic on CJK systems), fontconfig's system-ui on Linux. The rest only back it up.
    fallback_families: []const []const u8 = if (@import("builtin").target.os.tag == .windows) &.{ "system-ui", "Segoe UI", "Arial", "Inter" } else &.{
        "system-ui",
        "Helvetica Neue",
        "Arial",
        "Helvetica",
        "Inter",
        "Menlo",
    },
};
