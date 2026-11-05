//! Darwin builds of Zenit must give Zig code compact (non-DWARF) unwind entries.
//!
//! Debug builds capture a stack trace on every DebugAllocator alloc and free.
//! With Zig's default asynchronous unwind tables, LLVM cannot express the
//! epilogue CFI as compact unwind and emits DWARF mode for every Zig function,
//! so std's unwinder interprets DWARF CFI per frame. A Storybook switch from
//! Controls to Button makes about ten thousand allocator calls and spent most of
//! its time unwinding. build.zig selects synchronous tables (Apple clang's
//! default) for every macOS Zenit executable; this test reads the running
//! binary's `__unwind_info` to prove the setting reached the generated code.
const std = @import("std");
const builtin = @import("builtin");
const macho = std.macho;

const DyldUnwindSections = extern struct {
    mh: *const anyopaque,
    dwarf_section: ?*const anyopaque,
    dwarf_section_length: usize,
    compact_unwind_section: ?[*]const u8,
    compact_unwind_section_length: usize,
};

extern "c" fn _dyld_find_unwind_sections(addr: *const anyopaque, info: *DyldUnwindSections) bool;

fn lastAtOrBelow(comptime T: type, items: []align(1) const T, target: u32, offset: anytype) usize {
    var lo: usize = 0;
    var hi: usize = items.len;
    while (hi - lo > 1) {
        const mid = lo + (hi - lo) / 2;
        if (offset(items[mid]) <= target) lo = mid else hi = mid;
    }
    return lo;
}

/// Compact unwind encoding recorded for the function that contains `addr`.
fn compactEncodingAt(addr: usize) !u32 {
    var info: DyldUnwindSections = undefined;
    if (!_dyld_find_unwind_sections(@ptrFromInt(addr), &info)) return error.NoUnwindSections;
    const base = info.compact_unwind_section orelse return error.NoCompactUnwind;
    const section = base[0..info.compact_unwind_section_length];
    const target: u32 = @intCast(addr - @intFromPtr(info.mh));

    const header: *align(1) const macho.unwind_info_section_header = @ptrCast(section.ptr);
    const indices: []align(1) const macho.unwind_info_section_header_index_entry = @ptrCast(
        section[header.indexSectionOffset..][0 .. header.indexCount * @sizeOf(macho.unwind_info_section_header_index_entry)],
    );
    const first = indices[
        lastAtOrBelow(macho.unwind_info_section_header_index_entry, indices, target, struct {
            fn f(e: macho.unwind_info_section_header_index_entry) u32 {
                return e.functionOffset;
            }
        }.f)
    ];
    if (first.secondLevelPagesSectionOffset == 0) return error.NoEntry;
    const common: []align(1) const u32 = @ptrCast(
        section[header.commonEncodingsArraySectionOffset..][0 .. header.commonEncodingsArrayCount * 4],
    );

    const page = section[first.secondLevelPagesSectionOffset..];
    const kind: *align(1) const macho.UNWIND_SECOND_LEVEL = @ptrCast(page.ptr);
    switch (kind.*) {
        .REGULAR => {
            const ph: *align(1) const macho.unwind_info_regular_second_level_page_header = @ptrCast(page.ptr);
            const entries: []align(1) const macho.unwind_info_regular_second_level_entry = @ptrCast(
                page[ph.entryPageOffset..][0 .. @as(usize, ph.entryCount) * @sizeOf(macho.unwind_info_regular_second_level_entry)],
            );
            return entries[
                lastAtOrBelow(macho.unwind_info_regular_second_level_entry, entries, target, struct {
                    fn f(e: macho.unwind_info_regular_second_level_entry) u32 {
                        return e.functionOffset;
                    }
                }.f)
            ].encoding;
        },
        .COMPRESSED => {
            const ph: *align(1) const macho.unwind_info_compressed_second_level_page_header = @ptrCast(page.ptr);
            const entries: []align(1) const macho.UnwindInfoCompressedEntry = @ptrCast(
                page[ph.entryPageOffset..][0 .. @as(usize, ph.entryCount) * 4],
            );
            const relative = target - first.functionOffset;
            const entry = entries[
                lastAtOrBelow(macho.UnwindInfoCompressedEntry, entries, relative, struct {
                    fn f(e: macho.UnwindInfoCompressedEntry) u32 {
                        return e.funcOffset;
                    }
                }.f)
            ];
            if (entry.encodingIndex < common.len) return common[entry.encodingIndex];
            const local: []align(1) const u32 = @ptrCast(page[ph.encodingsPageOffset..][0 .. @as(usize, ph.encodingsCount) * 4]);
            return local[entry.encodingIndex - common.len];
        },
        _ => return error.UnknownPageKind,
    }
}

const mode_mask: u32 = 0x0F00_0000;
const dwarf_mode: u32 = switch (builtin.cpu.arch) {
    .aarch64 => 0x0300_0000, // UNWIND_ARM64_MODE_DWARF
    .x86_64 => 0x0400_0000, // UNWIND_X86_64_MODE_DWARF
    else => 0,
};

/// A Zig function with a real frame that allocates, like every frame the
/// DebugAllocator walks when it records an allocation trace.
noinline fn allocatingFrame(gpa: std.mem.Allocator) !usize {
    const buf = try gpa.alloc(u8, 64);
    defer gpa.free(buf);
    @memset(buf, 1);
    return @returnAddress();
}

test "Darwin Zig code gets compact unwind entries, not DWARF CFI" {
    if (comptime !builtin.os.tag.isDarwin()) return error.SkipZigTest;
    try std.testing.expect(builtin.unwind_tables == .sync);

    // Both the test body (via the return address) and a callee are Zig code.
    const caller_pc = try allocatingFrame(std.testing.allocator);
    for ([_]usize{ caller_pc, @intFromPtr(&allocatingFrame), @intFromPtr(&compactEncodingAt) }) |pc| {
        const encoding = try compactEncodingAt(pc);
        try std.testing.expect(encoding != 0);
        try std.testing.expect(encoding & mode_mask != dwarf_mode);
    }
}
