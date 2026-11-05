/// Process-level cache of debug env vars.
///
/// ZENIT_DEBUG_* / ZENIT_NO_* switches appear in per-layer/per-glass-node hot paths; value constant
/// over process lifetime, getenv read once then cached. (Benign race on first-frame concurrent
/// read: both write same value.)
const std = @import("std");

pub fn flag(comptime name: [:0]const u8) bool {
    // Warning: the cached var must hang off a type **parameterized by name**.
    //
    // A `const S = struct { var cached: ?bool = null; };` inside the function body does not depend
    // on `name`, so Zig reuses one static storage for all args and the **first call's result is
    // shared by all flags**: once `ZENIT_NO_BLUR` (unset -> false) is cached, every `flag(...)`
    // returns false, silently disabling all ZENIT_DEBUG_* / ZENIT_NO_* switches (even
    // `flag("PATH")` reads false). Broken diagnostics are worse than none.
    //
    // Fix: encode name into the cache type (`Cache(name)`, one instance per name) so static storage
    // is segregated by name.
    return Cache(name).get();
}

fn Cache(comptime name: [:0]const u8) type {
    return struct {
        // Reference name so this type truly depends on it, prevent compiler merging instances of
        // different names.
        const key = name;
        var cached: ?bool = null;

        fn get() bool {
            return cached orelse blk: {
                const v = @import("zenit_environment").flag(key);
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
    // Negative assertion: different names must not interfere.
    //
    // If the cache is not segregated by name (anon `struct { var cached }` in the function body),
    // all names share the first evaluation: asking a nonexistent switch first pollutes real ones to
    // false.
    //
    // Ask a nonexistent name first (caches false), then PATH, which must still read true.
    try std.testing.expect(!flag("ZENIT_TEST_ABSENT_A"));
    try std.testing.expect(flag("PATH"));
    // Reverse and re-verify, confirm later writes don't pollute earlier.
    try std.testing.expect(!flag("ZENIT_TEST_ABSENT_B"));
}
