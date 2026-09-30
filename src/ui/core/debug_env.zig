//! 进程级 env 调试开关（首次读取后缓存）。Cx 与其拆分出的 cx_* 模块共用。

const std = @import("std");

pub fn devtoolsHitDebugEnabled() bool {
    const raw = std.c.getenv("ZENIT_DEVTOOLS_HIT_DEBUG") orelse return false;
    const value = std.mem.span(raw);
    if (value.len == 0) return true;
    return !std.mem.eql(u8, value, "0");
}

var cursor_change_debug_enabled_cache: ?bool = null;
var hit_scene_debug_enabled_cache: ?bool = null;
/// ZENIT_HIT_SCENE_DEBUG=1：逐 mouse_move 打印命中结果（含 proxy AABB）与
/// 每次 hit-test 场景重建走的分支——诊断「partial 重建缺口」类命中错乱。
pub fn hitSceneDebugEnabled() bool {
    return readBoolEnvCached(&hit_scene_debug_enabled_cache, "ZENIT_HIT_SCENE_DEBUG");
}
var render_dirty_debug_enabled_cache: ?bool = null;
var wants_frame_debug_enabled_cache: ?bool = null;

pub fn readBoolEnvCached(cache: *?bool, env_name: [:0]const u8) bool {
    if (cache.*) |v| return v;
    const raw = std.c.getenv(env_name) orelse {
        cache.* = false;
        return false;
    };
    const value = std.mem.span(raw);
    if (value.len == 0) {
        cache.* = true;
        return true;
    }
    const enabled = !std.mem.eql(u8, value, "0") and !std.ascii.eqlIgnoreCase(value, "false");
    cache.* = enabled;
    return enabled;
}

pub fn cursorChangeDebugEnabled() bool {
    return readBoolEnvCached(&cursor_change_debug_enabled_cache, "ZENIT_CURSOR_DEBUG");
}

var layout_integrity_every_frame_cache: ?bool = null;
/// ZENIT_LAYOUT_INTEGRITY=1：shadow-sync 完整性校验恢复逐帧（默认每 64 帧采样）
pub fn layoutIntegrityEveryFrameEnabled() bool {
    return readBoolEnvCached(&layout_integrity_every_frame_cache, "ZENIT_LAYOUT_INTEGRITY");
}

pub fn renderDirtyDebugEnabled() bool {
    return readBoolEnvCached(&render_dirty_debug_enabled_cache, "ZENIT_RENDER_DIRTY_DEBUG");
}

pub fn wantsFrameDebugEnabled() bool {
    return readBoolEnvCached(&wants_frame_debug_enabled_cache, "ZENIT_DEBUG_WANTS_FRAME");
}
