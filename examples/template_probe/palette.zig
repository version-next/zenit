//! An imported style namespace whose filename is unrelated to styles.
const ui = @import("ui");
pub const Unused = ui.css(.{ .gap = 27 });
