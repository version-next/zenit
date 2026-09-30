//! Semantic fingerprints of the last published text. Keeping snapshots, rather
//! than comparing borrowed slices, detects in-place application buffer edits.
const std = @import("std");
const types = @import("types.zig");

pub const Signature = struct {
    layout: u64,
    paint: u64,
};

// Hash fields individually: struct padding and inactive optional payloads are
// undefined, and pointer identity / ownership do not describe displayed text.
fn hashValue(h: *std.hash.Wyhash, value: anytype) void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .@"struct" => inline for (std.meta.fields(T)) |f| hashValue(h, @field(value, f.name)),
        .optional => {
            hashValue(h, value != null);
            if (value) |v| hashValue(h, v);
        },
        .float => h.update(std.mem.asBytes(&value)),
        else => std.hash.autoHash(h, value),
    }
}

pub fn signature(text: ?types.TextProps) Signature {
    var layout = std.hash.Wyhash.init(0);
    var paint = std.hash.Wyhash.init(0);
    hashValue(&layout, text != null);
    hashValue(&paint, text != null);
    if (text) |t| {
        const content_hash = std.hash.Wyhash.hash(0, t.content);
        hashValue(&layout, content_hash);
        hashValue(&paint, content_hash);
        inline for (.{ "font_size", "font_weight", "font_family", "line_height", "wrap", "max_lines", "baseline_ratio", "use_symbols_font", "use_monospace_font", "use_italic_font", "monospace_char_width", "spans_affect_layout" }) |field| {
            hashValue(&layout, @field(t, field));
        }
        inline for (std.meta.fields(types.TextProps)) |f| {
            if (comptime !std.mem.eql(u8, f.name, "content") and !std.mem.eql(u8, f.name, "inline_buf") and !std.mem.eql(u8, f.name, "inline_len") and !std.mem.eql(u8, f.name, "owned") and !std.mem.eql(u8, f.name, "spans") and !std.mem.eql(u8, f.name, "spans_owned")) {
                hashValue(&paint, @field(t, f.name));
            }
        }
        hashValue(&paint, t.spans.len);
        if (t.spans_affect_layout) hashValue(&layout, t.spans.len);
        for (t.spans) |span| {
            hashValue(&paint, span);
            if (t.spans_affect_layout) {
                inline for (.{ "start", "end", "font_weight", "use_italic_font", "use_monospace_font", "inline_box_padding_left", "inline_box_padding_right" }) |field| {
                    hashValue(&layout, @field(span, field));
                }
            }
        }
    }
    return .{ .layout = layout.final(), .paint = paint.final() };
}
