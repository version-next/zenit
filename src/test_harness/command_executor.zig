/// command_executor，主线程消费命令并执行 UI 操作
///
/// 极简版本：支持 IME / click / type / key / query / focused / screenshot。
/// 命令派发到 cx.handleX() API。
const std = @import("std");
const ui = @import("ui");
const Cx = ui.Cx;
const Node = ui.Node;
const KeyCode = ui.events.KeyCode;
const Modifiers = ui.events.Modifiers;

const command_queue = @import("command_queue.zig");
const CommandQueue = command_queue.CommandQueue;
const TestCommand = command_queue.TestCommand;
const tree_serializer = @import("tree_serializer.zig");
const JsonWriter = @import("json_writer.zig").JsonWriter;

// ── Callbacks ──

pub const GetCtxFn = *const fn () ?*Cx;
pub const CaptureScreenshotFn = *const fn (path: []const u8) bool;

pub const RecordingState = struct {
    ok: bool = false,
    active: bool = false,
    width: u32 = 0,
    height: u32 = 0,
    fps: u32 = 0,
    duration_ms: u64 = 0,
    file_size: u64 = 0,
    frame_count: u64 = 0,
    dropped_frames: u64 = 0,
    path: [command_queue.RecordingStartPayload.PATH_CAP]u8 = [_]u8{0} ** command_queue.RecordingStartPayload.PATH_CAP,
    path_len: u16 = 0,
    error_message: [256]u8 = [_]u8{0} ** 256,
    error_len: u16 = 0,

    pub fn setPath(self: *RecordingState, value: []const u8) void {
        const len = @min(value.len, self.path.len);
        @memcpy(self.path[0..len], value[0..len]);
        self.path_len = @intCast(len);
    }

    pub fn setError(self: *RecordingState, value: []const u8) void {
        const len = @min(value.len, self.error_message.len);
        @memcpy(self.error_message[0..len], value[0..len]);
        self.error_len = @intCast(len);
    }

    pub fn pathText(self: *const RecordingState) []const u8 {
        return self.path[0..self.path_len];
    }

    pub fn errorText(self: *const RecordingState) []const u8 {
        return self.error_message[0..self.error_len];
    }
};

pub const StartRecordingFn = *const fn (path: []const u8, fps: u32) RecordingState;
pub const RecordingStateFn = *const fn () RecordingState;

/// FrameStats 快照（renderer.FrameStats 的 harness 子集；不引 zenit_app 避免依赖环）
pub const FrameStatsSnapshot = struct {
    retained_hits: u32 = 0,
    retained_misses: u32 = 0,
    retained_partial_repaints: u32 = 0,
    /// 离屏纹理池 acquire 彻底失败的累计次数。> 0 = 画面上出现过**静默降级**
    /// （blur 少几级 / 合成层不画），是"多个玻璃岛同步闪烁"的直接指标。
    offscreen_pool_exhausted: u64 = 0,
    /// text 管线 uniform 槽位溢出到备用 buffer 的累计次数。
    ///
    /// 与 offscreen_pool_exhausted 同类：是"一帧内 clip 切换次数远超预期"的
    /// 直接指标。修复后溢出**不再丢字**（会切到溢出 buffer 继续画），但持续
    /// 增长仍说明 clip 链在逐行重发，该去查 clip 前缀保留，而不是调大上限。
    /// 修复前这里每 +1 就等于**一整批文字没画出来**（症状：整段中文消失、
    /// 位置留白、逐帧闪烁），且因为失败时实例不清空，该帧后续文本全部丢失。
    text_uniform_overflow: u64 = 0,
    path_draw_calls: u32 = 0,
    frame_count: u64 = 0,
    /// backdrop 亮度自适应实测值；-1 = 无（未启用/无玻璃）
    backdrop_luminance: f32 = -1,

    // ── 计时（微秒）──
    // 这些字段此前缺失：真 GPU 时间在 renderer.FrameStats 里一直有，但从没投影
    // 到 harness，导致 GPU 侧性能回退在 e2e 完全不可观测（零门禁）。
    //
    // **单帧值**（噪声大，仅供 log 参考，不要拿来做断言）：
    /// 上一帧真 GPU 执行时间（MTLCommandBuffer GPUEndTime-GPUStartTime）
    gpu_execute_us: u64 = 0,
    /// 上一帧纯 CPU 管线耗时（不含 wait/acquire）
    cpu_frame_us: u64 = 0,
    /// 细分：定位回退落在哪一段
    layout_us: u64 = 0,
    render_gen_us: u64 = 0,
    gpu_encode_us: u64 = 0,
    /// 上一帧总耗时
    total_frame_us: u64 = 0,

    // **跨帧 P95**（门禁断言用的抗噪统计量；取最近 ~120 个真渲染帧）：
    gpu_p95_us: u64 = 0,
    cpu_p95_us: u64 = 0,
    total_p95_us: u64 = 0,
    /// P95 的有效样本数，断言前必须检查它足够大，否则是在对空环/少量样本
    /// 做判断（会得到 0，即"永远绿"的假信号）。
    timing_samples: u32 = 0,
};
pub const GetFrameStatsFn = *const fn () FrameStatsSnapshot;
/// 清空跨帧计时采样环（性能门禁进场景后调用）
pub const ResetTimingFn = *const fn () void;

var g_get_ctx_fn: ?GetCtxFn = null;
var g_capture_screenshot_fn: ?CaptureScreenshotFn = null;
var g_start_recording_fn: ?StartRecordingFn = null;
var g_recording_status_fn: ?RecordingStateFn = null;
var g_stop_recording_fn: ?RecordingStateFn = null;
var g_get_frame_stats_fn: ?GetFrameStatsFn = null;
var g_reset_timing_fn: ?ResetTimingFn = null;
var g_resize_window_fn: ?ResizeWindowFn = null;

pub fn setGetCtxFn(f: GetCtxFn) void {
    g_get_ctx_fn = f;
}

pub fn setCaptureScreenshotFn(f: CaptureScreenshotFn) void {
    g_capture_screenshot_fn = f;
}

pub fn setRecordingCallbacks(start: StartRecordingFn, status: RecordingStateFn, stop: RecordingStateFn) void {
    g_start_recording_fn = start;
    g_recording_status_fn = status;
    g_stop_recording_fn = stop;
}

pub fn setGetFrameStatsFn(f: GetFrameStatsFn) void {
    g_get_frame_stats_fn = f;
}

pub fn setResetTimingFn(f: ResetTimingFn) void {
    g_reset_timing_fn = f;
}

pub const ResizeWindowFn = *const fn (width: u32, height: u32) bool;

pub fn setResizeWindowFn(f: ResizeWindowFn) void {
    g_resize_window_fn = f;
}

fn getCtx() ?*Cx {
    if (g_get_ctx_fn) |f| return f();
    return null;
}

fn publishRecordingState(queue: *CommandQueue, state: RecordingState) void {
    var buf: [2048]u8 = undefined;
    var jw = JsonWriter.init(&buf);
    jw.beginObject();
    jw.key("ok");
    jw.booleanValue(state.ok);
    jw.key("active");
    jw.booleanValue(state.active);
    jw.key("width");
    jw.numberValue(@intCast(state.width));
    jw.key("height");
    jw.numberValue(@intCast(state.height));
    jw.key("fps");
    jw.numberValue(@intCast(state.fps));
    jw.key("duration_ms");
    jw.numberValue(@intCast(@min(state.duration_ms, @as(u64, std.math.maxInt(i64)))));
    jw.key("file_size");
    jw.numberValue(@intCast(@min(state.file_size, @as(u64, std.math.maxInt(i64)))));
    jw.key("frame_count");
    jw.numberValue(@intCast(@min(state.frame_count, @as(u64, std.math.maxInt(i64)))));
    jw.key("dropped_frames");
    jw.numberValue(@intCast(@min(state.dropped_frames, @as(u64, std.math.maxInt(i64)))));
    jw.key("codec");
    jw.stringValue("h264");
    jw.key("container");
    jw.stringValue("mp4");
    if (state.path_len > 0) {
        jw.key("path");
        jw.stringValue(state.pathText());
    }
    if (state.error_len > 0) {
        jw.key("error");
        jw.stringValue(state.errorText());
    }
    jw.endObject();
    if (jw.hasOverflowed()) {
        queue.result.setError("recording result overflow");
    } else {
        queue.result.setJson(jw.getWritten());
    }
}

// ── 主入口 ──

pub fn drainCommands(queue: *CommandQueue) void {
    while (queue.dequeue()) |cmd| {
        const handled = executeCommand(queue, cmd);
        if (handled) {
            queue.signalDone();
        }
    }
}

/// 宿主自定义路由处理器：返回写进 `out` 的 JSON 切片，null = 不认这条路由。
/// **在主线程调用**（drainCommands 内），因此可以安全读写宿主的 UI 状态。
pub const AppRouteFn = *const fn (path: []const u8, body: []const u8, out: []u8) ?[]const u8;
var g_app_route_fn: ?AppRouteFn = null;

pub fn setAppRouteFn(f: AppRouteFn) void {
    g_app_route_fn = f;
}

fn executeCommand(queue: *CommandQueue, cmd_in: TestCommand) bool {
    var cmd = cmd_in;
    defer {
        switch (cmd) {
            .text_input => |*p| p.deinit(queue.allocator),
            .ime_preedit => |*p| p.deinit(queue.allocator),
            .ime_commit => |*p| p.deinit(queue.allocator),
            .query_selector => |*p| p.deinit(queue.allocator),
            .drag => |*p| p.deinit(queue.allocator),
            else => {},
        }
    }

    switch (cmd) {
        .health => {
            queue.result.setJson("{\"status\":\"ok\"}");
            return true;
        },
        .click => |c| {
            if (getCtx()) |ctx| {
                // handleMouseUp 内部已通过 dispatcher 合成 click event (含 click_count)。
                // 不能再调 handleClick，那会再触发一次 mouse_down/up -> 多算一次 click
                // -> consecutive_clicks=2 -> textarea/input 误判 double-click -> selectWordAt。
                // down 与 up 都要带修饰键：宿主判定"加选还是独占选中"通常在
                // up，只在 down 带会让 ⇧ 多选类 e2e 静默失效。
                ctx.handleMouseDown(c.x, c.y, c.modifiers());
                ctx.updateAutomationCursor(c.x, c.y, true);
                ctx.handleMouseUpEx(c.x, c.y, .left, c.modifiers());
                ctx.updateAutomationCursor(c.x, c.y, false);
                queue.result.setJson("{\"ok\":true}");
            } else {
                queue.result.setError("no context");
            }
            return true;
        },
        .click_test_id => |payload| {
            const test_id = payload.getText();
            if (getCtx()) |ctx| {
                if (ctx.root) |root| {
                    if (tree_serializer.findByTestId(root, test_id)) |node| {
                        scrollNodeIntoView(ctx, node);
                        const r = node.globalRect();
                        const x = r.x + r.w * 0.5;
                        const y = r.y + r.h * 0.5;
                        ctx.handleMouseDown(x, y, .{});
                        ctx.updateAutomationCursor(x, y, true);
                        ctx.handleMouseUp(x, y);
                        ctx.updateAutomationCursor(x, y, false);
                        var buf: [256]u8 = undefined;
                        const out = std.fmt.bufPrint(&buf, "{{\"ok\":true,\"clicked_x\":{d:.1},\"clicked_y\":{d:.1}}}", .{ x, y }) catch "{\"ok\":true}";
                        queue.result.setJson(out);
                    } else {
                        queue.result.setError("test_id not found");
                    }
                } else {
                    queue.result.setError("no root");
                }
            } else {
                queue.result.setError("no context");
            }
            return true;
        },
        .app_route => |c| {
            const handler = g_app_route_fn orelse {
                queue.result.setError("no app route handler");
                return true;
            };
            var buf: [command_queue.AppRoutePayload.BODY_CAP * 2]u8 = undefined;
            if (handler(c.getPath(), c.getBody(), &buf)) |written| {
                queue.result.setJson(written);
            } else {
                queue.result.setError("app route rejected");
            }
            return true;
        },
        .mouse_down => |c| {
            if (getCtx()) |ctx| {
                ctx.handleMouseDown(c.x, c.y, c.modifiers());
                ctx.updateAutomationCursor(c.x, c.y, true);
                queue.result.setJson("{\"ok\":true}");
            } else {
                queue.result.setError("no context");
            }
            return true;
        },
        .mouse_move => |c| {
            if (getCtx()) |ctx| {
                ctx.handleMouseMoveEx(c.x, c.y, c.modifiers());
                ctx.updateAutomationCursor(c.x, c.y, null);
                queue.result.setJson("{\"ok\":true}");
            } else {
                queue.result.setError("no context");
            }
            return true;
        },
        .mouse_up => |c| {
            if (getCtx()) |ctx| {
                // 必须走 Ex 并带 modifiers：handleMouseUp 会硬塞 `.{}`，
                // 那样 e2e 永远覆盖不到"抬手时刻修饰键"这条路径
                // （mouse_up 的 modifiers 恒为 false 的缺陷就是这么漏掉的）。
                ctx.handleMouseUpEx(c.x, c.y, .left, c.modifiers());
                ctx.updateAutomationCursor(c.x, c.y, false);
                queue.result.setJson("{\"ok\":true}");
            } else {
                queue.result.setError("no context");
            }
            return true;
        },
        .key_down => |payload| {
            if (getCtx()) |ctx| {
                const name = payload.getKeyName();
                const key_code = parseKeyName(name);
                const mods = Modifiers{
                    .shift = payload.shift,
                    .ctrl = payload.ctrl,
                    .alt = payload.alt,
                    .super = payload.super,
                };
                ctx.handleKeyDown(key_code, mods);
                queue.result.setJson("{\"ok\":true}");
            } else {
                queue.result.setError("no context");
            }
            return true;
        },
        .scroll => |c| {
            if (getCtx()) |ctx| {
                ctx.handleScroll(.{
                    .x = c.x,
                    .y = c.y,
                    .dx = c.dx,
                    .dy = c.dy,
                    .phase = @enumFromInt(c.phase),
                    .momentum = @enumFromInt(c.momentum),
                    .modifiers = .{ .shift = c.shift, .ctrl = c.ctrl, .alt = c.alt, .super = c.super },
                });
                ctx.updateAutomationCursor(c.x, c.y, null);
                queue.result.setJson("{\"ok\":true}");
            } else {
                queue.result.setError("no context");
            }
            return true;
        },
        .magnify => |c| {
            if (getCtx()) |ctx| {
                ctx.handleMagnify(c.magnification, c.x, c.y, @enumFromInt(c.phase));
                ctx.updateAutomationCursor(c.x, c.y, null);
                queue.result.setJson("{\"ok\":true}");
            } else {
                queue.result.setError("no context");
            }
            return true;
        },
        .drag => |payload| {
            if (getCtx()) |ctx| {
                ctx.handleDrag(payload.x, payload.y, payload.kind, payload.paths.getText());
                ctx.updateAutomationCursor(payload.x, payload.y, null);
                queue.result.setJson("{\"ok\":true}");
            } else {
                queue.result.setError("no context");
            }
            return true;
        },
        .text_input => |payload| {
            if (getCtx()) |ctx| {
                ctx.handleTextInput(payload.getText());
                queue.result.setJson("{\"ok\":true}");
            } else {
                queue.result.setError("no context");
            }
            return true;
        },
        .ime_preedit => |payload| {
            if (getCtx()) |ctx| {
                if (ctx.focus_manager.current_focus == null) {
                    queue.result.setError("no focused element - click first");
                    return true;
                }
                ctx.handleImePreedit(payload.text.getText(), payload.cursor_utf8_offset);
                queue.result.setJson("{\"ok\":true}");
            } else {
                queue.result.setError("no context");
            }
            return true;
        },
        .ime_commit => |payload| {
            if (getCtx()) |ctx| {
                if (ctx.focus_manager.current_focus == null) {
                    queue.result.setError("no focused element - click first");
                    return true;
                }
                ctx.handleImeCommit(payload.getText());
                queue.result.setJson("{\"ok\":true}");
            } else {
                queue.result.setError("no context");
            }
            return true;
        },
        .query_tree => {
            if (getCtx()) |ctx| {
                // 强制刷一帧，让前置 mutating 命令（imeCommit / text_input / key_down）
                // 走完 before_render hook + layout，rect/world 才是最新。
                _ = ctx.render();
                if (ctx.root) |root| {
                    // 直接写进结果缓冲（不经 128KB 栈缓冲再截断拷贝）；装不下显式报错，
                    // 绝不返回半截 JSON。
                    const json = tree_serializer.serializeTree(root, &ctx.overlay_stack, &queue.result.buf) catch {
                        queue.result.setError("tree too large for RESULT_BUF_SIZE");
                        return true;
                    };
                    queue.result.len = json.len;
                    queue.result.success = true;
                } else {
                    queue.result.setError("no root");
                }
            } else {
                queue.result.setError("no context");
            }
            return true;
        },
        .query_selector => |payload| {
            if (getCtx()) |ctx| {
                _ = ctx.render();
                if (ctx.root) |root| {
                    const json = tree_serializer.queryByTestId(root, &ctx.overlay_stack, payload.getText(), &queue.result.buf) catch {
                        queue.result.setError("query result too large for RESULT_BUF_SIZE");
                        return true;
                    };
                    queue.result.len = json.len;
                    queue.result.success = true;
                } else {
                    queue.result.setError("no root");
                }
            } else {
                queue.result.setError("no context");
            }
            return true;
        },
        .frame_stats => {
            if (g_get_frame_stats_fn) |f| {
                const st = f();
                // 16 个数值字段，512B 已不够（JsonWriter 静默截断会产出
                // 非法 JSON，客户端只会看到 parse 错而非明确失败）。
                var buf: [1536]u8 = undefined;
                var jw = JsonWriter.init(&buf);
                jw.beginObject();
                jw.key("retained_hits");
                jw.numberValue(@intCast(st.retained_hits));
                jw.key("retained_misses");
                jw.numberValue(@intCast(st.retained_misses));
                jw.key("retained_partial_repaints");
                jw.numberValue(@intCast(st.retained_partial_repaints));
                jw.key("offscreen_pool_exhausted");
                jw.numberValue(@intCast(st.offscreen_pool_exhausted));
                jw.key("text_uniform_overflow");
                jw.numberValue(@intCast(st.text_uniform_overflow));
                jw.key("path_draw_calls");
                jw.numberValue(@intCast(st.path_draw_calls));
                jw.key("frame_count");
                jw.numberValue(@intCast(st.frame_count));
                jw.key("backdrop_luminance_milli");
                jw.numberValue(@intFromFloat(st.backdrop_luminance * 1000));
                jw.key("gpu_execute_us");
                jw.numberValue(@intCast(st.gpu_execute_us));
                jw.key("cpu_frame_us");
                jw.numberValue(@intCast(st.cpu_frame_us));
                jw.key("layout_us");
                jw.numberValue(@intCast(st.layout_us));
                jw.key("render_gen_us");
                jw.numberValue(@intCast(st.render_gen_us));
                jw.key("gpu_encode_us");
                jw.numberValue(@intCast(st.gpu_encode_us));
                jw.key("total_frame_us");
                jw.numberValue(@intCast(st.total_frame_us));
                jw.key("gpu_p95_us");
                jw.numberValue(@intCast(st.gpu_p95_us));
                jw.key("cpu_p95_us");
                jw.numberValue(@intCast(st.cpu_p95_us));
                jw.key("total_p95_us");
                jw.numberValue(@intCast(st.total_p95_us));
                jw.key("timing_samples");
                jw.numberValue(@intCast(st.timing_samples));
                jw.endObject();
                queue.result.setJson(jw.getWritten());
            } else {
                queue.result.setError("frame_stats not supported");
            }
            return true;
        },
        .reset_timing => {
            if (g_reset_timing_fn) |f| {
                f();
                queue.result.setJson("{\"ok\":true}");
            } else {
                queue.result.setError("reset_timing not supported");
            }
            return true;
        },
        .console_query => |query| {
            const ctx = getCtx() orelse {
                queue.result.setError("no context");
                return true;
            };
            const limit: usize = @min(@as(usize, query.limit), 200);
            var snapshot = ctx.console().snapshotSince(queue.allocator, query.after_seq, limit) catch {
                queue.result.setError("console snapshot failed");
                return true;
            };
            defer snapshot.deinit(queue.allocator);

            var jw = JsonWriter.init(&queue.result.buf);
            jw.beginObject();
            jw.key("events");
            jw.beginArray();
            for (snapshot.events) |event| {
                jw.beginObject();
                jw.key("seq");
                jw.numberValue(@intCast(event.seq));
                jw.key("monotonic_us");
                jw.numberValue(@intCast(event.monotonic_us));
                jw.key("thread_id");
                jw.numberValue(@intCast(event.thread_id));
                jw.key("level");
                jw.stringValue(event.level.label());
                jw.key("kind");
                jw.stringValue(@tagName(event.kind));
                jw.key("scope");
                jw.stringValue(event.scope);
                jw.key("group_depth");
                jw.numberValue(event.group_depth);
                jw.key("message");
                jw.stringValue(event.message);
                jw.key("truncated");
                jw.booleanValue(event.truncated);
                if (event.source) |source| {
                    jw.key("source");
                    jw.beginObject();
                    jw.key("file");
                    jw.stringValue(source.file);
                    jw.key("fn_name");
                    jw.stringValue(source.fn_name);
                    jw.key("line");
                    jw.numberValue(source.line);
                    jw.key("column");
                    jw.numberValue(source.column);
                    jw.endObject();
                }
                jw.endObject();
            }
            jw.endArray();
            jw.key("next_cursor");
            jw.numberValue(@intCast(snapshot.next_cursor));
            jw.key("oldest_seq");
            jw.numberValue(@intCast(snapshot.oldest_seq));
            jw.key("newest_seq");
            jw.numberValue(@intCast(snapshot.newest_seq));
            jw.key("gap");
            jw.booleanValue(snapshot.gap);
            jw.key("has_more");
            jw.booleanValue(snapshot.has_more);
            jw.key("evicted_total");
            jw.numberValue(@intCast(snapshot.evicted_total));
            jw.key("dropped_oom");
            jw.numberValue(@intCast(snapshot.dropped_oom));
            jw.key("dropped_oversize");
            jw.numberValue(@intCast(snapshot.dropped_oversize));
            jw.key("clear_generation");
            jw.numberValue(@intCast(snapshot.clear_generation));
            jw.endObject();
            if (jw.hasOverflowed()) {
                queue.result.setError("console response too large; use a smaller limit");
            } else {
                queue.result.len = jw.getWritten().len;
                queue.result.success = true;
            }
            return true;
        },
        .console_clear => {
            if (getCtx()) |ctx| {
                ctx.console().clear();
                queue.result.setJson("{\"ok\":true}");
            } else {
                queue.result.setError("no context");
            }
            return true;
        },
        .get_focused => {
            if (getCtx()) |ctx| {
                if (ctx.focus_manager.current_focus) |focused| {
                    var buf: [4096]u8 = undefined;
                    var jw = JsonWriter.init(&buf);
                    jw.beginObject();
                    jw.key("id");
                    jw.numberValue(@intCast(focused.id));
                    jw.key("tag");
                    jw.stringValue(@tagName(focused.tag));
                    if (focused.meta.ownership.meta.test_id) |tid| {
                        jw.key("test_id");
                        jw.stringValue(tid);
                    }
                    if (focused.meta.ownership.meta.component_name) |cn| {
                        jw.key("component");
                        jw.stringValue(cn);
                    }
                    if (focused.getText()) |t| {
                        jw.key("text");
                        const tlen = @min(t.content.len, 200);
                        jw.stringValue(t.content[0..tlen]);
                    }
                    jw.endObject();
                    queue.result.setJson(jw.getWritten());
                } else {
                    queue.result.setJson("{\"focused\":null}");
                }
            } else {
                queue.result.setError("no context");
            }
            return true;
        },
        .screen_pos => |payload| {
            if (getCtx()) |ctx| {
                _ = ctx.render();
                if (ctx.root) |root| {
                    if (tree_serializer.findByTestId(root, payload.getText())) |node| {
                        scrollNodeIntoView(ctx, node);
                        const r = node.globalRect();
                        var buf: [256]u8 = undefined;
                        const out = std.fmt.bufPrint(&buf, "{{\"x\":{d:.1},\"y\":{d:.1},\"w\":{d:.1},\"h\":{d:.1}}}", .{ r.x, r.y, r.w, r.h }) catch "{}";
                        queue.result.setJson(out);
                    } else {
                        queue.result.setError("test_id not found");
                    }
                } else {
                    queue.result.setError("no root");
                }
            } else {
                queue.result.setError("no context");
            }
            return true;
        },
        .input_state => |payload| {
            // 查 input/textarea 内部 state (event_context 是 *TextInputState)
            if (getCtx()) |ctx| {
                _ = ctx.render();
                if (ctx.root) |root| {
                    if (tree_serializer.findByTestId(root, payload.getText())) |node| {
                        // 在 wrapper 子树里找一个挂了 inputEventHandler 的 input_container
                        const ic = findInputContainer(node) orelse {
                            queue.result.setError("no input_container under test_id");
                            return true;
                        };
                        const ctx_ptr = ic.behavior.events.event_context orelse {
                            queue.result.setError("no event_context on input_container");
                            return true;
                        };
                        // textarea / single-line input 是两种不同的 state struct，
                        // 不能盲 cast 成 TextInputState（内存 layout 差异 -> buffer_len
                        // 落到指针字段会读出 ~10^18 量级垃圾值 -> @intCast(i64) panic）。
                        // 按 on_event 函数指针辨别：inputEventHandler vs textareaEventHandler。
                        const TextInputState = ui.widgets.input.TextInputState;
                        const TextareaState = ui.widgets.input.TextareaState;
                        const inputEventHandler = ui.widgets.input.inputEventHandler;
                        const textareaEventHandler = ui.widgets.input.textareaEventHandler;
                        var buf: [4096]u8 = undefined;
                        var jw = JsonWriter.init(&buf);
                        const on_event = ic.behavior.events.on_event;
                        if (on_event == inputEventHandler) {
                            const state: *TextInputState = @ptrCast(@alignCast(ctx_ptr));
                            // EditableText deliberately reuses inputEventHandler for both
                            // storage modes.  Its multiline variant keeps the canonical
                            // bytes in TextareaDocument, so reading buffer/buffer_len here
                            // reports an empty string while the live editor contains text.
                            // Always go through getText(), and expose the document/wrap
                            // counts needed by full-app newline regressions.
                            const state_text = state.getText();
                            jw.beginObject();
                            jw.key("buffer_len");
                            jw.numberValue(@intCast(state_text.len));
                            jw.key("buffer");
                            jw.stringValue(state_text);
                            jw.key("cursor_pos");
                            jw.numberValue(@intCast(state.cursor_pos));
                            jw.key("anchor");
                            if (state.selection_anchor) |anchor| {
                                jw.numberValue(@intCast(anchor));
                            } else {
                                jw.numberValue(-1);
                            }
                            jw.key("cursor_affinity");
                            jw.stringValue(@tagName(state.cursor_affinity));
                            jw.key("ime_preedit_len");
                            jw.numberValue(@intCast(state.ime_preedit_len));
                            jw.key("ime_phase");
                            jw.stringValue(@tagName(state.ime_phase));
                            jw.key("input_type");
                            jw.stringValue(if (state.multiline) "editable_textarea" else @tagName(state.input_type));
                            jw.key("document_line_count");
                            jw.numberValue(@intCast(if (state.textarea_doc) |doc| doc.lineCount() else 1));
                            jw.key("display_line_count");
                            jw.numberValue(@intCast(if (state.textarea_wrap) |wrap| wrap.displayLineCount() else 1));
                            jw.key("layout_line_count");
                            jw.numberValue(@intCast(blk: {
                                const text_node = state.text_display_node orelse break :blk 0;
                                const layout = text_node.getLayoutOutput().artifacts.text_layout orelse break :blk 0;
                                break :blk layout.line_count;
                            }));
                            jw.key("editor_height");
                            jw.floatValue(ic.rectFromWorldOrFallback().h);
                            jw.key("cursor_rect");
                            if (state.cursor_node) |cursor_node| {
                                const rect = cursor_node.globalRect();
                                jw.beginObject();
                                jw.key("x");
                                jw.floatValue(rect.x);
                                jw.key("y");
                                jw.floatValue(rect.y);
                                jw.key("w");
                                jw.floatValue(rect.w);
                                jw.key("h");
                                jw.floatValue(rect.h);
                                jw.endObject();
                            } else {
                                jw.nullValue();
                            }
                            jw.key("scroll_x");
                            jw.floatValue(state.scroll_x);
                            jw.endObject();
                        } else if (on_event == textareaEventHandler) {
                            const state: *TextareaState = @ptrCast(@alignCast(ctx_ptr));
                            const text = state.getText();
                            jw.beginObject();
                            jw.key("buffer_len");
                            jw.numberValue(@intCast(text.len));
                            jw.key("buffer");
                            jw.stringValue(text);
                            jw.key("cursor_pos");
                            jw.numberValue(@intCast(state.cursor.offset));
                            jw.key("anchor");
                            if (state.cursor.anchor) |a| {
                                jw.numberValue(@intCast(a));
                            } else {
                                jw.numberValue(-1);
                            }
                            jw.key("cursor_affinity");
                            jw.stringValue(@tagName(state.cursor_affinity));
                            jw.key("display_line_count");
                            jw.numberValue(@intCast(state.wrap_map.displayLineCount()));
                            jw.key("cursor_rect");
                            if (state.cursor_node) |cursor_node| {
                                const rect = cursor_node.globalRect();
                                jw.beginObject();
                                jw.key("x");
                                jw.floatValue(rect.x);
                                jw.key("y");
                                jw.floatValue(rect.y);
                                jw.key("w");
                                jw.floatValue(rect.w);
                                jw.key("h");
                                jw.floatValue(rect.h);
                                jw.endObject();
                            } else {
                                jw.nullValue();
                            }
                            jw.key("selection_rects");
                            jw.beginArray();
                            if (state.selection_node) |selection_node| {
                                const rect = selection_node.globalRect();
                                if (rect.w > 0 and rect.h > 0) {
                                    jw.beginObject();
                                    jw.key("x");
                                    jw.floatValue(rect.x);
                                    jw.key("y");
                                    jw.floatValue(rect.y);
                                    jw.key("w");
                                    jw.floatValue(rect.w);
                                    jw.key("h");
                                    jw.floatValue(rect.h);
                                    jw.endObject();
                                }
                            }
                            for (state.extra_sel_nodes.items) |selection_node| {
                                const rect = selection_node.globalRect();
                                if (rect.w <= 0 or rect.h <= 0) continue;
                                jw.beginObject();
                                jw.key("x");
                                jw.floatValue(rect.x);
                                jw.key("y");
                                jw.floatValue(rect.y);
                                jw.key("w");
                                jw.floatValue(rect.w);
                                jw.key("h");
                                jw.floatValue(rect.h);
                                jw.endObject();
                            }
                            jw.endArray();
                            jw.key("ime_preedit_len");
                            jw.numberValue(@intCast(state.ime_preedit_len));
                            jw.key("ime_phase");
                            jw.stringValue(@tagName(state.ime_phase));
                            jw.key("input_type");
                            jw.stringValue("textarea");
                            jw.key("scroll_x");
                            jw.floatValue(0);
                            jw.endObject();
                        } else {
                            queue.result.setError("unknown on_event handler — not input or textarea");
                            return true;
                        }
                        queue.result.setJson(jw.getWritten());
                    } else {
                        queue.result.setError("test_id not found");
                    }
                } else {
                    queue.result.setError("no root");
                }
            } else {
                queue.result.setError("no context");
            }
            return true;
        },
        .screenshot => |payload| {
            const path = payload.getText();
            if (g_capture_screenshot_fn) |f| {
                const ok = f(path);
                if (ok) {
                    var buf: [512]u8 = undefined;
                    const out = std.fmt.bufPrint(&buf, "{{\"ok\":true,\"path\":\"{s}\"}}", .{path}) catch "{\"ok\":true}";
                    queue.result.setJson(out);
                } else {
                    queue.result.setError("screenshot failed");
                }
            } else {
                queue.result.setError("screenshot not supported");
            }
            return true;
        },
        .resize_window => |payload| {
            if (g_resize_window_fn) |f| {
                if (f(payload.width, payload.height)) {
                    var buf: [128]u8 = undefined;
                    const out = std.fmt.bufPrint(&buf, "{{\"ok\":true,\"width\":{d},\"height\":{d}}}", .{ payload.width, payload.height }) catch "{\"ok\":true}";
                    queue.result.setJson(out);
                } else {
                    queue.result.setError("resize failed");
                }
            } else {
                queue.result.setError("resize not supported");
            }
            return true;
        },
        .recording_start => |payload| {
            if (g_start_recording_fn) |f| {
                publishRecordingState(queue, f(payload.getPath(), payload.fps));
            } else {
                queue.result.setError("window recording not supported");
            }
            return true;
        },
        .recording_status => {
            if (g_recording_status_fn) |f| {
                publishRecordingState(queue, f());
            } else {
                queue.result.setError("window recording not supported");
            }
            return true;
        },
        .recording_stop => {
            if (g_stop_recording_fn) |f| {
                publishRecordingState(queue, f());
            } else {
                queue.result.setError("window recording not supported");
            }
            return true;
        },
    }
}

/// 在 wrapper 子树中找一个挂了 event_context 的 input_container (tag=.input)
fn findInputContainer(node: *Node) ?*Node {
    if (node.tag == .input and node.behavior.events.event_context != null) return node;
    for (node.children.items) |child| {
        if (findInputContainer(child)) |found| return found;
    }
    return null;
}

/// Nearest `.scroll` ancestor of `node` (exclusive), or null if none.
fn nearestScrollAncestor(node: *Node) ?*Node {
    var cur: ?*Node = node.parent;
    while (cur) |n| : (cur = n.parent) {
        if (n.tag == .scroll) return n;
    }
    return null;
}

/// Bring `node` into its scroll container's vertical viewport so its
/// `globalRect()` lands on-screen, used before harness click/screen_pos so a
/// row scrolled out of view (e.g. a long sidebar nav list) is still clickable.
///
/// **必须驱动 ScrollArea 的真实 `ScrollState.scroll_y`，不能直接写
/// `content.style.translate_y`**, `scrollbarBeforeRender` 每帧从
/// `state.scroll_y` 重算 translate_y（含 maxScroll re-clamp），手写 translate
/// 会被下一帧 hook 覆盖回去（scroll_y 仍 0），导致命中坐标与视觉脱节、点到错行。
/// 改法：算出 node 在 content 坐标系里的偏移 -> 设 `state.scroll_y`（clamp 到
/// [0, content_h-view_h]，max 直接从 rect 算而非 state，state 尺寸命令执行时机
/// 可能还是旧值）-> 同步 translate_y + state 尺寸 + layout()+render()，之后
/// globalRect 才反映新偏移。只处理最近的 .scroll 祖先（storybook sidebar 够用）。
fn scrollNodeIntoView(ctx: *Cx, node: *Node) void {
    const scroll = nearestScrollAncestor(node) orelse return;
    // 通过 container 的 event_context 拿真实 ScrollState（而非猜 children[0]/translate）。
    const scroll_area = ui.widgets.scroll_area;
    if (scroll.behavior.events.on_event != scroll_area.scrollEventHandler) return;
    const ev_ctx: *scroll_area.ScrollEventCtx = @ptrCast(@alignCast(scroll.behavior.events.event_context orelse return));
    const state = ev_ctx.state;
    const content = ev_ctx.content orelse return;

    const margin: f32 = 8;
    const scroll_rect = scroll.globalRect();
    const node_rect = node.globalRect();
    const content_rect = content.globalRect();
    const view_h = scroll_rect.h - scroll.style.padding.vertical();

    // node 在 content 坐标系里的 top（与当前 scroll 无关：content 与 node 一起平移）。
    const offset_in_content = node_rect.y - content_rect.y;
    // 当前可见坐标里 node 距容器顶。
    const rel_top = node_rect.y - scroll_rect.y;

    // 已完全在视口内则不动。
    if (rel_top >= margin and rel_top + node_rect.h <= view_h - margin) return;

    var target_scroll = state.scroll_y;
    if (rel_top < margin) {
        // node 在上方被裁 -> 让它顶部对齐到 margin。
        target_scroll = offset_in_content - margin;
    } else {
        // node 在下方被裁 -> 让它底部对齐到 view_h - margin。
        target_scroll = offset_in_content + node_rect.h - (view_h - margin);
    }
    // maxScrollY 直接从 rect 算（不靠 state.content_height/viewport_height，那两个
    // 由 before_render hook 从 rect 填，命令执行时机可能还是上一帧的旧值甚至 0，
    // 用旧值会把目标 scroll re-clamp 没了，正是「点到错行/上一目标」的根因）。
    const max_y = @max(content_rect.h - view_h, 0);
    if (target_scroll < 0) target_scroll = 0;
    if (target_scroll > max_y) target_scroll = max_y;

    if (target_scroll != state.scroll_y) {
        state.scroll_y = target_scroll;
        // 把 viewport/content 尺寸也同步给 state，避免下一帧 before_render hook 的
        // maxScroll re-clamp 用旧尺寸又把 scroll_y 拽回去。
        if (view_h > 0) state.viewport_height = view_h;
        if (!state.external_content_height and content_rect.h > 0) state.content_height = content_rect.h;
        // 同步施加 translate_y（与 scroll_y 一致 -> before_render hook 不会再纠偏）。
        // idle 帧 hook 不主动重算 translate_y（只在 bounce/re-clamp 时算），故这里显式写。
        content.style.translate_y = state.contentTranslateY();
        content.markInteractionDirty();
        content.markRenderDirty();
        ctx.needs_redraw = true;
        ctx.layout();
        _ = ctx.render();
    }
}

fn parseKeyName(name: []const u8) KeyCode {
    if (std.mem.eql(u8, name, "tab")) return .tab;
    if (std.mem.eql(u8, name, "enter") or std.mem.eql(u8, name, "return")) return .@"return";
    if (std.mem.eql(u8, name, "escape") or std.mem.eql(u8, name, "esc")) return .escape;
    if (std.mem.eql(u8, name, "space")) return .space;
    if (std.mem.eql(u8, name, "backspace") or std.mem.eql(u8, name, "delete")) return .delete;
    if (std.mem.eql(u8, name, "left")) return .left;
    if (std.mem.eql(u8, name, "right")) return .right;
    if (std.mem.eql(u8, name, "up")) return .up;
    if (std.mem.eql(u8, name, "down")) return .down;
    if (std.mem.eql(u8, name, "home")) return .home;
    if (std.mem.eql(u8, name, "end")) return .end;
    // 字符键
    if (name.len == 1) {
        const c = name[0];
        switch (c) {
            'a' => return .a,
            'b' => return .b,
            'c' => return .c,
            'd' => return .d,
            'e' => return .e,
            'f' => return .f,
            'g' => return .g,
            'h' => return .h,
            'i' => return .i,
            'j' => return .j,
            'k' => return .k,
            'l' => return .l,
            'm' => return .m,
            'n' => return .n,
            'o' => return .o,
            'p' => return .p,
            'q' => return .q,
            'r' => return .r,
            's' => return .s,
            't' => return .t,
            'u' => return .u,
            'v' => return .v,
            'w' => return .w,
            'x' => return .x,
            'y' => return .y,
            'z' => return .z,
            // 符号键：⌘[ / ⌘] 这类层级快捷键要靠它们才测得到。
            '[' => return .left_bracket,
            ']' => return .right_bracket,
            '-' => return .minus,
            '=' => return .equal,
            '/' => return .slash,
            ',' => return .comma,
            '.' => return .period,
            ';' => return .semicolon,
            '\'' => return .quote,
            '\\' => return .backslash,
            '`' => return .grave,
            '0' => return .@"0",
            '1' => return .@"1",
            '2' => return .@"2",
            '3' => return .@"3",
            '4' => return .@"4",
            '5' => return .@"5",
            '6' => return .@"6",
            '7' => return .@"7",
            '8' => return .@"8",
            '9' => return .@"9",
            else => return .unknown,
        }
    }
    return .unknown;
}

var g_console_test_ctx: ?*Cx = null;

fn getConsoleTestCtx() ?*Cx {
    return g_console_test_ctx;
}

fn getNoTestCtx() ?*Cx {
    return null;
}

test "console harness query serializes events and clear mutates the target Cx" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.console().configure(.{ .terminal_level = null });
    cx.console().writeAt(.err, @src(), "harness-needle", .{});

    g_console_test_ctx = cx;
    setGetCtxFn(getConsoleTestCtx);
    defer {
        g_console_test_ctx = null;
        setGetCtxFn(getNoTestCtx);
    }

    var queue = CommandQueue{ .allocator = std.testing.allocator };
    try std.testing.expect(executeCommand(&queue, .{ .console_query = .{ .after_seq = 0, .limit = 10 } }));
    const body = queue.result.getData();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"message\":\"harness-needle\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"level\":\"error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"source\":{") != null);

    try std.testing.expect(executeCommand(&queue, .{ .console_clear = {} }));
    try std.testing.expectEqual(@as(usize, 0), cx.console().stats().live_entries);
    try std.testing.expectEqualStrings("{\"ok\":true}", queue.result.getData());
}

test "recording state serialization exposes cadence and artifact metadata" {
    var queue: CommandQueue = .{};
    var state: RecordingState = .{
        .ok = true,
        .active = true,
        .width = 2200,
        .height = 2000,
        .fps = 60,
        .duration_ms = 1234,
        .file_size = 4567,
        .frame_count = 73,
        .dropped_frames = 2,
    };
    state.setPath("/tmp/zenit recording.mp4");
    publishRecordingState(&queue, state);

    const json = queue.result.getData();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"width\":2200") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"frame_count\":73") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"dropped_frames\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"path\":\"/tmp/zenit recording.mp4\"") != null);
}
