//! PaintReplay story: regression anchor for cached replay duplicate emission (paint
//! invariant gate).
//!
//! Repro conditions together: several "overflow_hidden + background, children inside"
//! containers, plus nearby lists and hover targets changing -- list add/remove / hover
//! re-records the parent while these containers' subtrees are clean and use cached replay.
//! If replay emits and then the node emits its own content again, the parent background
//! lands after its children: opaque covers children (progress fill disappears), alpha
//! darkens them; single frame only, screenshots can't catch it. E2E reads /stats
//! paint_duplicate_fills (per-frame self-check, see ui core/paint_invariants.zig), asserts
//! 0, and samples fill pixels to confirm children are visible.
const std = @import("std");
const ui = @import("ui");

const v = ui.view;
const W = ui.widgets;

const Row = struct { id: u32, title: []const u8 };
const max_rows = 12;
const titles = [_][]const u8{ "alpha", "beta", "gamma", "delta", "epsilon", "zeta" };
const initial = [_]Row{ .{ .id = 1, .title = "alpha" }, .{ .id = 2, .title = "beta" } };

const S = struct {
    const root = ui.css(.{ .width = .fill, .align_self = .stretch, .height = .fit, .direction = .column, .gap = 14 });
    const label = ui.css(.{ .font_size = 13, .color = .fg_secondary });
    const rows = ui.css(.{ .width = .fill, .height = .fit, .direction = .column, .gap = 4 });
    const row = ui.css(.{ .width = 320, .height = 28, .padding = .{ .x = 10 }, .align_items = .center, .corner_radius = 6, .background = .bg_secondary, ._hover = .{ .background = .bg_hover } });
    const row_text = ui.css(.{ .font_size = 13, .color = .fg_primary });
    const toolbar = ui.css(.{ .no_cross_stretch = true, .height = .fit, .direction = .row, .gap = 10, .align_items = .center });

    /// Opaque: progress track + fill (children covered = fill disappears)
    const track = ui.css(.{ .width = 320, .height = 8, .corner_radius = 4, .background = ui.Color.hex(0x1e2230), .overflow_hidden = true });
    const fill = ui.css(.{ .width = 120, .height = .fill, .background = ui.Color.hex(0x4cc38a) });
    /// Rounded card: background + rounded clip, with color blocks and text inside
    const card = ui.css(.{ .width = 320, .height = .fit, .direction = .row, .gap = 10, .padding = 10, .align_items = .center, .corner_radius = 10, .background = ui.Color.hex(0x262b3a), .overflow_hidden = true });
    const card_swatch = ui.css(.{ .width = 24, .height = 24, .corner_radius = 4, .background = ui.Color.hex(0xe8a33d) });
    const card_text = ui.css(.{ .font_size = 13, .color = ui.Color.hex(0xf2f2f2) });
    /// Translucent: capsule background + dot (children darkened by overlay)
    const pill = ui.css(.{ .no_cross_stretch = true, .width = .fit, .height = 22, .padding = .{ .x = 8 }, .gap = 6, .direction = .row, .align_items = .center, .corner_radius = .full, .background = ui.Color.rgba(76, 140, 255, 110), .overflow_hidden = true });
    const pill_dot = ui.css(.{ .width = 10, .height = 10, .corner_radius = 5, .background = ui.Color.hex(0xff5d6c) });
    const pill_text = ui.css(.{ .font_size = 12, .color = .fg_primary });
};

const Ctx = struct { rows: *ui.Signal([]const Row), next: *ui.Signal(u32) };

fn addRow(c: Ctx) void {
    const list = c.rows.peek();
    var buf: [max_rows]Row = undefined;
    const keep = if (list.len == max_rows) list[1..] else list;
    @memcpy(buf[0..keep.len], keep);
    const id = c.next.peek();
    buf[keep.len] = .{ .id = id, .title = titles[id % titles.len] };
    c.rows.set(buf[0 .. keep.len + 1]);
    c.next.set(id + 1);
}

fn removeRow(c: Ctx) void {
    const list = c.rows.peek();
    if (list.len == 0) return;
    c.rows.set(list[1..]);
}

fn rowView(item: Row, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    return v.render(scope, cx, v.box(.{ .style = S.row }, .{v.text(.{ .style = S.row_text }, item.title)}));
}

pub fn build(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const rows = try scope.createSignalFor([]const Row, &initial);
    const next = try scope.createSignal(u32, initial.len + 1);
    const ctx: Ctx = .{ .rows = rows, .next = next };
    const add = try ui.on.bind(scope, ctx, addRow);
    const remove = try ui.on.bind(scope, ctx, removeRow);
    return v.render(scope, cx, v.col(.{ .style = S.root }, .{
        v.text(.{ .style = S.label }, "Cache replay: containers with overflow_hidden + background stay intact while siblings change"),
        v.box(.{ .style = S.toolbar }, .{
            v.attrs(.{ .test_id = "story.paintreplay.add" }, W.Button(.{ .label = "Add row", .variant = .primary, .size = .sm, .on_click = add })),
            v.attrs(.{ .test_id = "story.paintreplay.remove" }, W.Button(.{ .label = "Remove row", .variant = .secondary, .size = .sm, .on_click = remove })),
        }),
        // List add/remove shifts container below, parent rereconds; container subtree unchanged
        // -> uses cached replay
        v.col(.{ .style = S.rows, .test_id = "story.paintreplay.rows" }, .{v.each(rows, .id, rowView)}),
        v.box(.{ .style = S.track, .test_id = "story.paintreplay.track" }, .{v.box(.{ .style = S.fill, .test_id = "story.paintreplay.fill" }, .{})}),
        v.box(.{ .style = S.card, .test_id = "story.paintreplay.card" }, .{
            v.box(.{ .style = S.card_swatch, .test_id = "story.paintreplay.swatch" }, .{}),
            v.text(.{ .style = S.card_text }, "Rounded card with clipped children"),
        }),
        v.box(.{ .style = S.pill, .test_id = "story.paintreplay.pill" }, .{
            v.box(.{ .style = S.pill_dot, .test_id = "story.paintreplay.dot" }, .{}),
            v.text(.{ .style = S.pill_text }, "translucent pill"),
        }),
    }));
}
