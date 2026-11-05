//! View DSL story: `ui.view` declarative view tree showcase + e2e regression anchor.
//!
//! A small todo: each (keyed add/remove) / show + fallback (empty state) / match (tabs) /
//! sva (cross-slot variant + hover) / on.bind (inline capture id) / on.set (page switch) /
//! fmt + memo. Layout control flow mixed with static siblings covers "fixed content position
//! in region" exactly.
const std = @import("std");
const ui = @import("ui");

const v = ui.view;
const W = ui.widgets;
const TOKENS = ui.theme.refs;

const Todo = struct {
    id: u32,
    title: []const u8,
    done: bool,
};

const Tab = enum { list, stats };

const max_todos = 16;

/// Row's test_id (runtime id -> static string, node borrows not copies).
const row_ids = blk: {
    var ids: [max_todos + 1][]const u8 = undefined;
    for (&ids, 0..) |*s, i| s.* = std.fmt.comptimePrint("story.viewdsl.todo.{d}", .{i});
    break :blk ids;
};

const titles = [_][]const u8{
    "Write the view DSL",
    "Anchor control-flow regions",
    "Cross-review with GLM",
    "Migrate the examples",
    "Ship it",
};

/// Data: double-buffered slices. Signal gets slice from alternate buffer each time, old
/// value not overwritten in place (For compares new/old entries by value; mutating
/// same memory hides changes).
const Store = struct {
    bufs: [2][max_todos]Todo = undefined,
    cur: u1 = 0,
    len: usize = 0,
    next_id: u32 = 1,
    items: *ui.Signal([]const Todo) = undefined,

    fn current(self: *const Store) []const Todo {
        return self.bufs[self.cur][0..self.len];
    }

    fn commit(self: *Store, next: []const Todo) void {
        const nb = self.cur ^ 1;
        @memcpy(self.bufs[nb][0..next.len], next);
        self.cur = nb;
        self.len = next.len;
        self.items.set(self.bufs[nb][0..next.len]);
    }

    fn add(self: *Store) void {
        if (self.len >= max_todos) return;
        var tmp: [max_todos]Todo = undefined;
        const cur = self.current();
        @memcpy(tmp[0..cur.len], cur);
        tmp[cur.len] = .{ .id = self.next_id, .title = titles[(self.next_id - 1) % titles.len], .done = false };
        self.next_id += 1;
        self.commit(tmp[0 .. cur.len + 1]);
    }

    fn toggle(self: *Store, id: u32) void {
        var tmp: [max_todos]Todo = undefined;
        const cur = self.current();
        @memcpy(tmp[0..cur.len], cur);
        for (tmp[0..cur.len]) |*t| {
            if (t.id == id) t.done = !t.done;
        }
        self.commit(tmp[0..cur.len]);
    }

    fn clearDone(self: *Store) void {
        var tmp: [max_todos]Todo = undefined;
        var n: usize = 0;
        for (self.current()) |t| {
            if (!t.done) {
                tmp[n] = t;
                n += 1;
            }
        }
        self.commit(tmp[0..n]);
    }
};

// -- Styles --

const S = struct {
    fn root(t: *const ui.theme.Values) ui.BoxStyle {
        return .{ .gap = t.tokens.space.space300, .width = .{ .px = 520 } };
    }
    fn heading(t: *const ui.theme.Values) ui.TextStyle {
        return .{ .font_size = t.tokens.font_size.xl, .font_weight = 600, .color = t.tokens.color.fg_primary };
    }
    fn hint(t: *const ui.theme.Values) ui.TextStyle {
        return .{ .font_size = t.tokens.font_size.sm, .color = t.tokens.color.fg_secondary };
    }
    fn toolbar(t: *const ui.theme.Values) ui.BoxStyle {
        return .{ .gap = t.tokens.space.space200, .align_items = .center };
    }
    fn list(t: *const ui.theme.Values) ui.BoxStyle {
        return .{
            .width = .fill(),
            .gap = t.tokens.space.space100,
            .padding = ui.Padding.all(t.tokens.space.space200),
            .corner_radius = t.tokens.radius.lg,
            .border = .{ .overlay = true, .width = 1, .color = t.tokens.color.border },
        };
    }
    const Row = ui.sva(.{
        .slots = .{ .root, .dot, .label },
        .base = .{
            .root = .{
                .width = .fill,
                .padding = .{ .y = TOKENS.space.space200, .x = TOKENS.space.space300 },
                .corner_radius = TOKENS.radius.md,
                .gap = TOKENS.space.space200,
                .align_items = .center,
                .cursor = .pointer,
                .background = TOKENS.color.bg_secondary,
                ._hover = .{ .border = .{ .overlay = true, .width = TOKENS.border_width.thin, .color = TOKENS.color.accent } },
            },
            .dot = .{
                .width = ui.arb.px(10),
                .height = ui.arb.px(10),
                .corner_radius = TOKENS.radius.full,
                .border = .{ .overlay = true, .width = TOKENS.border_width.thin, .color = TOKENS.color.fg_secondary },
            },
            .label = .{ .font_size = TOKENS.font_size.lg, .color = TOKENS.color.fg_primary },
        },
        .variants = .{ .done = .{
            .false = .{},
            .true = .{
                .root = .{ .background = TOKENS.color.success_subtle, .border = .{ .overlay = true, .width = TOKENS.border_width.thin, .color = TOKENS.color.success } },
                .dot = .{ .background = TOKENS.color.success, .border_color = TOKENS.color.success },
                .label = .{ .color = TOKENS.color.fg_secondary },
            },
        } },
        .defaults = .{ .done = false },
    });
    fn empty(t: *const ui.theme.Values) ui.TextStyle {
        return .{ .font_size = t.tokens.font_size.lg, .color = t.tokens.color.fg_secondary };
    }
};

// -- Views --

/// Row: component-form row function (must use scope: on.bind to copy id into
/// scope-owned memory).
fn todoRow(store: *Store, t: Todo, scope: *ui.Scope, cx: *ui.Cx) !*ui.Node {
    const on_click = try ui.on.bind(scope, .{ .store = store, .id = t.id }, struct {
        fn f(c: anytype) void {
            c.store.toggle(c.id);
        }
    }.f);
    const parts = S.Row.of(.{ .done = t.done });
    return v.render(scope, cx, v.row(.{
        .style = parts.root,
        .test_id = row_ids[@min(t.id, max_todos)],
        .on_click = on_click,
    }, .{
        v.box(.{ .style = parts.dot }, .{}),
        v.text(.{ .style = parts.label }, t.title),
    }));
}

fn countDone(items: []const Todo) usize {
    var n: usize = 0;
    for (items) |t| n += @intFromBool(t.done);
    return n;
}

fn countAll(items: []const Todo) usize {
    return items.len;
}

fn isEmpty(items: []const Todo) bool {
    return items.len == 0;
}

pub fn build(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const store = try cx.bindState(Store, .{});
    store.items = try scope.createSignal([]const Todo, &.{});
    store.add();
    store.add();
    store.add();

    const tab = try scope.createSignal(Tab, .list);
    const total = ui.map(store.items, countAll);
    const done = ui.map(store.items, countDone);

    return v.render(scope, cx, v.col(.{ .style = S.root, .test_id = "story.viewdsl.root" }, .{
        v.text(.{ .style = S.heading }, "Declarative todo"),
        v.text(.{ .style = S.hint }, "Built with ui.view: each / show / match / sva / on.bind"),

        v.row(.{ .style = S.toolbar }, .{
            W.Button(.{ .label = "Add todo", .variant = .primary, .on_click = ui.on.call(store, Store.add) }),
            W.Button(.{ .label = "Clear done", .variant = .secondary, .on_click = ui.on.call(store, Store.clearDone) }),
            W.Button(.{ .label = "List", .variant = .ghost, .on_click = ui.on.set(tab, .list) }),
            W.Button(.{ .label = "Stats", .variant = .ghost, .on_click = ui.on.set(tab, .stats) }),
        }),

        v.match(tab, .{
            .list = v.col(.{ .style = S.list, .test_id = "story.viewdsl.list" }, .{
                v.show(ui.map(store.items, isEmpty), .{v.text(.{ .style = S.empty }, "Nothing left to do")})
                    .fallback(.{v.eachWith(store, store.items, .id, todoRow)}),
            }),
            .stats = v.text(.{ .style = S.heading, .test_id = "story.viewdsl.stats" }, v.fmt("{d} total / {d} done", .{ total, done })),
        }),

        v.text(.{ .style = S.hint, .test_id = "story.viewdsl.footer" }, v.fmt("{d} of {d} done", .{ done, total })),
    }));
}
