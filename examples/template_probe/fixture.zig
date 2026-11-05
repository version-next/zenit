//! Compiler-tracked source bytes for the headless LP4 adapter.
pub const probe = @import("_view.yix.zig");
pub const Probe = probe.Probe;
pub const Fancy = probe.Fancy;
pub const preview_source = @embedFile("view.yix");
pub const DerivedProbe = probe.DerivedProbe;

pub const Literals = probe.Literals;

pub const Other = @import("_other.yix.zig").Other;
pub const other_source = @embedFile("other.yix");

pub const remount = @import("_remount.yix.zig");
pub const remount_source = @embedFile("remount.yix");

pub const regions = @import("_regions.yix.zig");
pub const regions_source = @embedFile("regions.yix");
