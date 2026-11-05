//! Application-selected, generated design system. No runtime role mapping.
const provider = @import("zenit_theme_provider");
const values = @import("zenit_style_values");

pub const Values = provider.Values;
pub const ThemeTokens = Values;
pub const ColorScheme = values.ColorScheme;
pub const refs = provider.refs;
pub const Token = provider.Token;
pub const resolve = provider.resolve;
pub const modes = provider.modes;
pub const Mode = provider.Mode;
pub const light = modes.light;
pub const dark = modes.dark;
pub const high_contrast = modes.high_contrast;

/// Fixed-shape parser-to-provider adapter, instantiated only in preview builds.
pub const previewValues = provider.previewValues;
