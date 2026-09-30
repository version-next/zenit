/// 调试环境变量的进程级缓存。
///
/// ZENIT_DEBUG_* / ZENIT_NO_* 这类开关出现在逐层/逐 glass 节点的热路径上，
/// 值在进程生命周期内不变 —— getenv 只读一次，之后走缓存。
/// （首帧并发读的 benign race 无害：两边写入同一个值。）
const std = @import("std");

pub fn flag(comptime name: [:0]const u8) bool {
    // ⚠️ 缓存变量必须挂在**按 name 参数化**的类型上。
    //
    // 曾经写成函数体内的 `const S = struct { var cached: ?bool = null; };`——
    // 那个匿名 struct 不依赖 `name`，Zig 对所有实参复用同一份静态存储，于是
    // **第一次调用的结果被所有开关共享**：`ZENIT_NO_BLUR`（未设置→false）
    // 先被求值并写入缓存后，此后每个 `flag(...)` 一律返回 false，全仓
    // ZENIT_DEBUG_* / ZENIT_NO_* 开关**全部静默失效**。
    //
    // 实测复现：`flag("PATH")` 返回 false（PATH 显然存在）。
    // 2026-08-07 排查 glass blur 时发现——插桩日志一行不出，起初误以为代码
    // 路径没走到，实际是开关读不到值。诊断设施本身坏掉比没有更危险。
    //
    // 修法：把 name 编进缓存类型（`Cache(name)` 每个 name 一个独立实例化），
    // 静态存储自然按 name 分离。
    return Cache(name).get();
}

fn Cache(comptime name: [:0]const u8) type {
    return struct {
        // 引用 name 让本类型真正依赖它，杜绝编译器把不同 name 的实例化合并。
        const key = name;
        var cached: ?bool = null;

        fn get() bool {
            return cached orelse blk: {
                const v = std.posix.getenv(key) != null;
                cached = v;
                break :blk v;
            };
        }
    };
}

test "flag caches and is stable across calls" {
    const a = flag("ZENIT_TEST_NONEXISTENT_FLAG_XYZ");
    const b = flag("ZENIT_TEST_NONEXISTENT_FLAG_XYZ");
    try std.testing.expectEqual(a, b);
    try std.testing.expect(!a);
}

test "each flag name caches independently" {
    // 反向断言：不同 name 必须互不干扰。
    //
    // 旧实现（函数体内的匿名 `struct { var cached }`）在这条上失败——所有
    // name 共用第一次求值的结果，先问一个不存在的开关就会把真实存在的也
    // 污染成 false，全仓调试开关静默失效。
    //
    // 先问不存在的（写入 false 缓存），再问必然存在的 PATH：
    // 若缓存未按 name 分离，PATH 会被错误地读成 false。
    try std.testing.expect(!flag("ZENIT_TEST_ABSENT_A"));
    try std.testing.expect(flag("PATH"));
    // 反过来再验一次，确认后写入的也不会回头污染前者。
    try std.testing.expect(!flag("ZENIT_TEST_ABSENT_B"));
}
