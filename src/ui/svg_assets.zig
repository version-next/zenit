/// SVG asset facade. zenit ships only a minimal set in `common` —— enough
/// for the components that ship with the framework. Application-specific
/// icons (toolbar, navigation, lucide library, etc.) belong in the
/// downstream app's own asset bundle, generated with the same gen tool.
const generated = @import("icons_common_generated.zig");

pub const Asset = generated.Asset;
pub const common = generated;
