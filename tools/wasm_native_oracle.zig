//! Run precisely the same fixture as the wasm exports to generate the oracle.
pub fn main(init: @import("std").process.Init) !void {
    try @import("smoke").nativeMain(init);
}
