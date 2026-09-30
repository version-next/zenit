const std = @import("std");

pub const FillRule = enum {
    nonzero,
    evenodd,
};

pub const Point = struct {
    x: f32,
    y: f32,
};

pub const Contour = struct {
    points: []const Point,
    closed: bool,
};

pub const Shape = struct {
    contours: []const Contour,
    fill: bool = false,
    stroke_width: f32 = 0,
    fill_rule: FillRule = .nonzero,
};

pub const Rep = struct {
    size: u8,
    view_min_x: f32 = 0,
    view_min_y: f32 = 0,
    view_width: f32 = 24,
    view_height: f32 = 24,
    shapes: []const Shape,
};

pub const Asset = struct {
    svg_data: []const u8,
    default_width: u32 = 24,
    default_height: u32 = 24,
    icon_id: ?u16 = null,
    reps: []const Rep = &.{},

    pub fn pickRep(self: Asset, logical_px: f32) ?Rep {
        if (self.reps.len == 0) return null;

        const wanted = @as(i32, @intFromFloat(@round(logical_px)));
        var best = self.reps[0];
        var best_delta: u32 = std.math.maxInt(u32);
        for (self.reps) |rep| {
            const delta = @abs(@as(i32, rep.size) - wanted);
            if (delta < best_delta) {
                best = rep;
                best_delta = delta;
            }
        }
        return best;
    }
};

pub const OwnedContour = struct {
    points: []Point,
    closed: bool,

    pub fn deinit(self: *OwnedContour, allocator: std.mem.Allocator) void {
        allocator.free(self.points);
        self.* = undefined;
    }
};

pub const OwnedShape = struct {
    contours: []OwnedContour,
    fill: bool = false,
    stroke_width: f32 = 0,
    fill_rule: FillRule = .nonzero,

    pub fn deinit(self: *OwnedShape, allocator: std.mem.Allocator) void {
        for (self.contours) |*contour| contour.deinit(allocator);
        allocator.free(self.contours);
        self.* = undefined;
    }
};

pub const OwnedRep = struct {
    size: u8,
    view_min_x: f32 = 0,
    view_min_y: f32 = 0,
    view_width: f32 = 24,
    view_height: f32 = 24,
    shapes: []OwnedShape,

    pub fn deinit(self: *OwnedRep, allocator: std.mem.Allocator) void {
        for (self.shapes) |*shape| shape.deinit(allocator);
        allocator.free(self.shapes);
        self.* = undefined;
    }
};
