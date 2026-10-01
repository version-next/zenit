/// Info.plist 生成器，把 BundleSpec 渲染为 XML
///
/// 之所以代码生成而不是模板替换：CFBundleDocumentTypes / UTExportedTypeDeclarations 是数组结构，
/// 数量由调用方决定，模板字符串处理这种嵌套结构不舒服。
const std = @import("std");

pub const FileType = struct {
    /// 用户可见名称（Finder 里显示）
    name: []const u8,
    /// 文件扩展名（不含点）
    extensions: []const []const u8,
    /// UTI 标识符。如 "com.acme.myapp.document"。
    uti: []const u8,
    /// "Editor" / "Viewer" / "Shell" / "None"
    role: []const u8 = "Editor",
    /// "Owner" / "Default" / "Alternate" / "None"
    handler_rank: []const u8 = "Owner",
    /// UTType 是否由本 app 定义（exported）。false 表示只是引用（imported，如 markdown）。
    exported: bool = true,
    /// UTI 继承的父 type。imported 时常用 ["public.plain-text"]，
    /// exported 文档型常用 ["public.data", "public.content"]。
    conforms_to: []const []const u8 = &.{ "public.data", "public.content" },
};

pub const BundleSpec = struct {
    /// CFBundleDisplayName / CFBundleName，用户可见名称
    display_name: []const u8,
    /// CFBundleIdentifier，反向 DNS，如 "com.acme.myapp"
    bundle_id: []const u8,
    /// CFBundleExecutable, Contents/MacOS/<name> 的文件名
    executable: []const u8,
    /// CFBundleShortVersionString + CFBundleVersion
    version: []const u8 = "0.1.0",
    /// 4 字符 OSType signature。约定：APPL = 应用、????
    /// 用于 PkgInfo 文件 + CFBundleSignature
    signature: []const u8 = "????",
    /// LSMinimumSystemVersion，如 "12.0"
    min_macos: []const u8 = "12.0",
    /// CFBundleIconFile, Resources/<icon_file>.icns 的文件名（不含扩展）
    icon_file: ?[]const u8 = null,
    /// LSApplicationCategoryType
    category: []const u8 = "public.app-category.developer-tools",
    /// 版权字符串（NSHumanReadableCopyright）
    copyright: ?[]const u8 = null,
    /// 文件类型注册（CFBundleDocumentTypes + UT*TypeDeclarations）。
    file_types: []const FileType = &.{},
    /// NSAppTransportSecurity.NSAllowsArbitraryLoads，默认 false（安全），
    /// 如果应用要拉任意 HTTP 图片/链接，调用方显式打开。
    allow_arbitrary_loads: bool = false,
    /// CADisableMinimumFrameDuration，解锁 ProMotion 120Hz。默认 true（编辑器场景值得）。
    disable_min_frame_duration: bool = true,
    /// NSSupportsAutomaticGraphicsSwitching，默认 true（笔记本省电）。
    auto_graphics_switching: bool = true,
    /// NSHighResolutionCapable, Retina 必开。
    high_resolution: bool = true,
};

/// 把 BundleSpec 渲染为完整的 Info.plist XML 字符串。
pub fn render(allocator: std.mem.Allocator, spec: BundleSpec) ![]u8 {
    var buf = std.ArrayList(u8){};
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeAll(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\
    );

    if (spec.disable_min_frame_duration) {
        try w.writeAll("\t<key>CADisableMinimumFrameDuration</key>\n\t<true/>\n");
    }
    try writeKVString(w, "CFBundleDisplayName", spec.display_name);

    // CFBundleDocumentTypes
    if (spec.file_types.len > 0) {
        try w.writeAll("\t<key>CFBundleDocumentTypes</key>\n\t<array>\n");
        for (spec.file_types) |ft| {
            try w.writeAll("\t\t<dict>\n");
            try w.writeAll("\t\t\t<key>CFBundleTypeExtensions</key>\n\t\t\t<array>\n");
            for (ft.extensions) |ext| {
                try w.print("\t\t\t\t<string>{s}</string>\n", .{ext});
            }
            try w.writeAll("\t\t\t</array>\n");
            try w.print("\t\t\t<key>CFBundleTypeName</key>\n\t\t\t<string>{s}</string>\n", .{ft.name});
            try w.print("\t\t\t<key>CFBundleTypeRole</key>\n\t\t\t<string>{s}</string>\n", .{ft.role});
            try w.print("\t\t\t<key>LSHandlerRank</key>\n\t\t\t<string>{s}</string>\n", .{ft.handler_rank});
            try w.writeAll("\t\t\t<key>LSItemContentTypes</key>\n\t\t\t<array>\n");
            try w.print("\t\t\t\t<string>{s}</string>\n", .{ft.uti});
            try w.writeAll("\t\t\t</array>\n");
            try w.writeAll("\t\t</dict>\n");
        }
        try w.writeAll("\t</array>\n");
    }

    try writeKVString(w, "CFBundleExecutable", spec.executable);
    if (spec.icon_file) |icon| {
        try writeKVString(w, "CFBundleIconFile", icon);
    }
    try writeKVString(w, "CFBundleIdentifier", spec.bundle_id);
    try writeKVString(w, "CFBundleName", spec.display_name);
    try writeKVString(w, "CFBundlePackageType", "APPL");
    try writeKVString(w, "CFBundleShortVersionString", spec.version);
    try writeKVString(w, "CFBundleSignature", spec.signature);
    try writeKVString(w, "CFBundleVersion", spec.version);
    try writeKVString(w, "LSApplicationCategoryType", spec.category);
    try writeKVString(w, "LSMinimumSystemVersion", spec.min_macos);

    if (spec.allow_arbitrary_loads) {
        try w.writeAll("\t<key>NSAppTransportSecurity</key>\n");
        try w.writeAll("\t<dict>\n");
        try w.writeAll("\t\t<key>NSAllowsArbitraryLoads</key>\n");
        try w.writeAll("\t\t<true/>\n");
        try w.writeAll("\t</dict>\n");
    }
    if (spec.high_resolution) {
        try w.writeAll("\t<key>NSHighResolutionCapable</key>\n\t<true/>\n");
    }
    if (spec.copyright) |cp| {
        try writeKVString(w, "NSHumanReadableCopyright", cp);
    }
    if (spec.auto_graphics_switching) {
        try w.writeAll("\t<key>NSSupportsAutomaticGraphicsSwitching</key>\n\t<true/>\n");
    }

    // UTExportedTypeDeclarations / UTImportedTypeDeclarations
    var has_exported = false;
    var has_imported = false;
    for (spec.file_types) |ft| {
        if (ft.exported) has_exported = true else has_imported = true;
    }
    if (has_exported) {
        try w.writeAll("\t<key>UTExportedTypeDeclarations</key>\n\t<array>\n");
        for (spec.file_types) |ft| {
            if (!ft.exported) continue;
            try writeUtTypeDecl(w, ft);
        }
        try w.writeAll("\t</array>\n");
    }
    if (has_imported) {
        try w.writeAll("\t<key>UTImportedTypeDeclarations</key>\n\t<array>\n");
        for (spec.file_types) |ft| {
            if (ft.exported) continue;
            try writeUtTypeDecl(w, ft);
        }
        try w.writeAll("\t</array>\n");
    }

    try w.writeAll("</dict>\n</plist>\n");

    return buf.toOwnedSlice(allocator);
}

fn writeKVString(w: anytype, key: []const u8, value: []const u8) !void {
    try w.print("\t<key>{s}</key>\n\t<string>{s}</string>\n", .{ key, value });
}

fn writeUtTypeDecl(w: anytype, ft: FileType) !void {
    try w.writeAll("\t\t<dict>\n");
    try w.writeAll("\t\t\t<key>UTTypeConformsTo</key>\n\t\t\t<array>\n");
    for (ft.conforms_to) |parent| {
        try w.print("\t\t\t\t<string>{s}</string>\n", .{parent});
    }
    try w.writeAll("\t\t\t</array>\n");
    try w.print("\t\t\t<key>UTTypeDescription</key>\n\t\t\t<string>{s}</string>\n", .{ft.name});
    try w.print("\t\t\t<key>UTTypeIdentifier</key>\n\t\t\t<string>{s}</string>\n", .{ft.uti});
    try w.writeAll("\t\t\t<key>UTTypeTagSpecification</key>\n");
    try w.writeAll("\t\t\t<dict>\n");
    try w.writeAll("\t\t\t\t<key>public.filename-extension</key>\n");
    try w.writeAll("\t\t\t\t<array>\n");
    for (ft.extensions) |ext| {
        try w.print("\t\t\t\t\t<string>{s}</string>\n", .{ext});
    }
    try w.writeAll("\t\t\t\t</array>\n\t\t\t</dict>\n\t\t</dict>\n");
}

test "render minimal Info.plist" {
    const allocator = std.testing.allocator;
    const xml = try render(allocator, .{
        .display_name = "Hello",
        .bundle_id = "com.example.hello",
        .executable = "hello",
    });
    defer allocator.free(xml);
    try std.testing.expect(std.mem.indexOf(u8, xml, "com.example.hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<string>hello</string>") != null);
}

test "render with file types" {
    const allocator = std.testing.allocator;
    const xml = try render(allocator, .{
        .display_name = "Demo App",
        .bundle_id = "com.example.demo",
        .executable = "demo",
        .file_types = &.{
            // Owner of a custom format, exported UTType
            .{
                .name = "Demo Document",
                .extensions = &.{"demo"},
                .uti = "com.example.demo.document",
            },
            // Imported UTType, registers as a handler for an existing
            // system UTI without re-defining it.
            .{
                .name = "Markdown",
                .extensions = &.{ "md", "markdown" },
                .uti = "net.daringfireball.markdown",
                .handler_rank = "Alternate",
                .exported = false,
                .conforms_to = &.{"public.plain-text"},
            },
        },
    });
    defer allocator.free(xml);
    try std.testing.expect(std.mem.indexOf(u8, xml, "UTExportedTypeDeclarations") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "UTImportedTypeDeclarations") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "com.example.demo.document") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "net.daringfireball.markdown") != null);
}
