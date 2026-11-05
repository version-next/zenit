//! Process-level env debug flags (cached after first read). Cx and its cx_* modules share it.

const std = @import("std");

pub fn devtoolsHitDebugEnabled() bool {
    const raw = @import("zenit_environment").getNative("ZENIT_DEVTOOLS_HIT_DEBUG") orelse return false;
    const value = std.mem.span(raw);
    if (value.len == 0) return true;
    return !std.mem.eql(u8, value, "0");
}

var cursor_change_debug_enabled_cache: ?bool = null;
var hit_scene_debug_enabled_cache: ?bool = null;
/// ZENIT_HIT_SCENE_DEBUG=1: print hit result (with proxy AABB) and rebuild branch per mouse_move,
/// diagnose 'partial rebuild gap' hit scrambling.
pub fn hitSceneDebugEnabled() bool {
    return readBoolEnvCached(&hit_scene_debug_enabled_cache, "ZENIT_HIT_SCENE_DEBUG");
}
var render_dirty_debug_enabled_cache: ?bool = null;
var wants_frame_debug_enabled_cache: ?bool = null;

pub fn readBoolEnvCached(cache: *?bool, env_name: [:0]const u8) bool {
    if (cache.*) |v| return v;
    const raw = @import("zenit_environment").getNative(env_name) orelse {
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
/// ZENIT_LAYOUT_INTEGRITY=1: shadow-sync completeness check resumes per-frame (default samples
/// every 64 frames)
pub fn layoutIntegrityEveryFrameEnabled() bool {
    return readBoolEnvCached(&layout_integrity_every_frame_cache, "ZENIT_LAYOUT_INTEGRITY");
}

pub fn renderDirtyDebugEnabled() bool {
    return readBoolEnvCached(&render_dirty_debug_enabled_cache, "ZENIT_RENDER_DIRTY_DEBUG");
}

pub fn wantsFrameDebugEnabled() bool {
    return readBoolEnvCached(&wants_frame_debug_enabled_cache, "ZENIT_DEBUG_WANTS_FRAME");
}
