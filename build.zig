const std = @import("std");
// Zig's build graph must invalidate native objects when included bridge files
// change, including incremental acceptance bundles that reuse the guest cache.
const linux_native_revision_flag = blk: {
    @setEvalBranchQuota(1000000);
    break :blk std.fmt.comptimePrint("-DZENIT_LINUX_NATIVE_REV=0x{x}ULL", .{std.hash.Wyhash.hash(0, @embedFile("native/linux/wayland/cursor.inc") ++ @embedFile("native/linux/wayland/keyboard.inc") ++ @embedFile("native/linux/wayland/pointer.inc") ++
        @embedFile("native/linux/wayland/clipboard.inc") ++ @embedFile("native/linux/wayland/text_input.inc") ++ @embedFile("native/linux/wayland/scaling.inc") ++ @embedFile("native/linux/wayland/window.h") ++ @embedFile("vendor/libdecor/libdecor.h") ++
        @embedFile("native/linux/vulkan_pipeline.inc") ++ @embedFile("native/linux/vulkan_resources.inc") ++
        @embedFile("native/linux/vulkan_device.h") ++ @embedFile("native/linux/png.inc") ++
        @embedFile("native/linux/text_layout.h") ++ @embedFile("native/linux/opengl_device.h") ++ @embedFile("native/linux/opengl_resources.inc") ++ @embedFile("native/linux/opengl_pipeline.inc"))});
};
// Hash local native include contents explicitly. Enumerate macOS includes and
// shared headers in native/, so newly added bridge includes cannot silently
// reuse an old native object. Stable path order avoids filesystem-order churn.
fn macosNativeFlags(owner: *std.Build, source: *std.Build) []const []const u8 {
    // Zig 0.17 caches configuration separately from compiler dependency
    // manifests. Register both file contents and directory entries: raw IO
    // alone would reuse stale flags, including when a new header is added.
    owner.dependOnDirectoryContents(source.path("native"));
    owner.dependOnDirectoryContents(source.path("native/macos"));
    var dir = source.root.openDir(owner.graph.io, "native", .{ .iterate = true }) catch @panic("open native includes");
    defer dir.close(owner.graph.io);
    var walker = dir.walk(owner.allocator) catch @panic("walk native includes");
    defer walker.deinit();
    var paths: std.ArrayList([]const u8) = .empty;
    while (walker.next(owner.graph.io) catch @panic("enumerate native includes")) |entry| {
        if (entry.kind == .directory and std.mem.startsWith(u8, entry.path, "macos/")) {
            owner.dependOnDirectoryContents(source.path(source.pathJoin(&.{ "native", entry.path })));
        }
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.path, "macos/") and std.mem.indexOfScalar(u8, entry.path, '/') != null) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".inc") and !std.mem.endsWith(u8, entry.basename, ".h")) continue;
        paths.append(owner.allocator, owner.dupe(entry.path)) catch @panic("native include paths");
    }
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    var digest = std.hash.Wyhash.init(0);
    for (paths.items) |path| {
        owner.dependOnFileContents(source.path(source.pathJoin(&.{ "native", path })));
        const bytes = dir.readFileAlloc(owner.graph.io, path, owner.allocator, .limited(16 * 1024 * 1024)) catch @panic("read native include");
        digest.update(path);
        digest.update("\x00");
        digest.update(bytes);
        digest.update("\x00");
    }
    return owner.allocator.dupe([]const u8, &.{ "-fobjc-arc", owner.fmt("-DZENIT_MACOS_RENDER_REV=0x{x}ULL", .{digest.final()}) }) catch @panic("macOS native flags");
}
const macos_bundle = @import("src/system_sdk/bundle/macos_app.zig");

// Zig's x86 PE linker defaults to a 2 GiB process address space. Produce a
// separate installation image with LAA; never modify the compilation cache.
fn installWindowsExecutable(b: *std.Build, exe: *std.Build.Step.Compile) *std.Build.Step {
    if (exe.root_module.resolved_target.?.result.cpu.arch != .x86)
        return &b.addInstallArtifact(exe, .{}).step;
    const symbols = b.addInstallArtifact(exe, .{
        .dest_dir = .disabled,
        .pdb_dir = if (exe.producesPdbFile()) .{ .override = .bin } else .disabled,
    });
    const tool = b.addExecutable(.{ .name = "zenit-windows-large-address", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/windows_large_address.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    }) });
    const run = b.addRunArtifact(tool);
    run.addFileArg(exe.getEmittedBin());
    const output = run.addOutputFileArg(exe.out_filename);
    const install = b.addInstallFileWithDir(output, .bin, exe.out_filename);
    install.step.dependOn(&symbols.step);
    return &install.step;
}

// ============================================================================
// Public build API for consumers
//
// A downstream project's build.zig can reach these via
// `const zenit = @import("zenit");` (Zig ≥ 0.15, dep declared in build.zig.zon):
//
//     const zenit_dep = b.dependency("zenit", .{ .target = target, .optimize = optimize });
//     zenit.attach(zenit_dep, exe);                       // modules + native bridges
//     const bundled = zenit.bundleApp(b, .{ ... });       // optional .app packaging
// ============================================================================

// Runtime-compiled shader strings live in nested C++ headers. Include their
// content in compile flags so changing an optical/procedural shader cannot
// leave a stale executable in the cross-compilation cache.
fn windowsD2DFlags(owner: *std.Build, source: *std.Build) []const []const u8 {
    var digest = std.hash.Wyhash.init(0);
    for ([_][]const u8{ "d2d_composite.h", "conic_effect.h", "glass_effect.h", "glass_shader.h" }) |name| {
        const path = source.pathJoin(&.{ source.root.sub_path, "native/windows", name });
        const bytes = source.root.root_dir.handle.readFileAlloc(owner.graph.io, path, owner.allocator, .limited(1024 * 1024)) catch @panic("read Windows effect header");
        digest.update(bytes);
    }
    return owner.allocator.dupe([]const u8, &.{ "-O2", "-std=c++17", "-fno-exceptions", "-fno-rtti", owner.fmt("-DZENIT_D2D_CONTENT=0x{x}", .{digest.final()}) }) catch @panic("Windows effect flags");
}

/// A complete externally owned icon provider.
pub const IconProvider = struct {
    /// Full provider catalog, exported publicly as `ui.icons`.
    icons: *std.Build.Module,
    /// Provider-neutral semantic subset used by Zenit's own components.
    system_icons: *std.Build.Module,
};

pub const AttachOptions = struct {
    /// Optional external provider. This is the migration path for keeping a
    /// licensed icon catalog in a private package instead of the Zenit package.
    /// The provider's `icons` module must import `icon_ir`; its `system_icons`
    /// module must import `zenit_icons`. `attachWithOptions` wires both imports
    /// to Zenit's canonical module instances so `icon_ir.Asset` stays type-safe.
    icon_provider: ?IconProvider = null,
    /// Generated by generateTheme; one provider per dependency UI instance.
    theme_provider: ?*std.Build.Module = null,
};

/// Generate a standalone theme provider using the host tool. The returned
/// module shares canonical value types with this dependency's UI.
/// UI provider selection is a separate integration step; this helper does
/// not silently replace the active theme of an existing ui module.
pub fn generateTheme(
    b: *std.Build,
    dep: *std.Build.Dependency,
    input: std.Build.LazyPath,
    options: struct { target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode = .debug },
) *std.Build.Module {
    const run = b.addRunArtifact(dep.artifact("zenit-tokens"));
    run.addArg("generate");
    run.addFileArg(input);
    run.addArg("--out");
    const output = run.addOutputFileArg("theme.gen.zig");
    const module = b.createModule(.{ .root_source_file = output, .target = options.target, .optimize = options.optimize });
    module.addImport("zenit_style_values", dep.module("zenit_style_values"));
    return module;
}

/// One provider per UI module. Repeating the same choice is safe; conflicting
/// choices must use separate dependency/module graphs.
pub fn wireThemeProvider(ui_module: *std.Build.Module, provider: *std.Build.Module) void {
    if (ui_module.import_table.get("zenit_selected_theme")) |selected| {
        if (selected != provider) @panic("one UI module cannot use two theme providers");
        return;
    }
    provider.addImport("zenit_style_values", ui_module.import_table.get("zenit_style_values").?);
    ui_module.addImport("zenit_selected_theme", provider);
    ui_module.addImport("zenit_theme_provider", provider);
}

fn cloneModule(b: *std.Build, source: *std.Build.Module) *std.Build.Module {
    const result = b.createModule(.{ .root_source_file = source.root_source_file, .target = source.resolved_target, .optimize = source.optimize });
    var it = source.import_table.iterator();
    while (it.next()) |entry| result.addImport(entry.key_ptr.*, entry.value_ptr.*);
    return result;
}

/// Wire an externally owned icon provider into a `ui` module.
///
/// This is the low-level companion to `attachWithOptions` for consumers that
/// construct Zenit's module graph themselves. Pass the exact `icon_ir` module
/// instance already imported by `ui`; creating another instance makes
/// `icon_ir.Asset` a different Zig type at the provider boundary.
pub fn wireIconProvider(
    ui_module: *std.Build.Module,
    icon_ir_module: *std.Build.Module,
    provider: IconProvider,
) void {
    provider.icons.addImport("icon_ir", icon_ir_module);
    provider.system_icons.addImport("zenit_icons", provider.icons);
    ui_module.addImport("zenit_icons", provider.icons);
    ui_module.addImport("zenit_system_icons", provider.system_icons);
}

/// Wire zenit into a consumer executable in one call: adds the `ui` and
/// `zenit_app` module imports, compiles the target's native bridges out of the
/// zenit package, and links the required native libraries.
pub fn attach(zenit_dep: *std.Build.Dependency, exe: *std.Build.Step.Compile) void {
    attachWithOptions(zenit_dep, exe, .{});
}

/// `attach`, with optional icon and theme providers. One Zenit
/// dependency instance has one `ui` module, so all executables sharing that
/// instance must use the same provider. Separate applications naturally have
/// separate build graphs and may choose independently.
pub fn attachWithOptions(
    zenit_dep: *std.Build.Dependency,
    exe: *std.Build.Step.Compile,
    options: AttachOptions,
) void {
    const ui_module = zenit_dep.module("ui");
    if (options.theme_provider) |provider| wireThemeProvider(ui_module, provider);
    if (options.icon_provider) |provider| {
        wireIconProvider(ui_module, zenit_dep.module("icon_ir"), provider);
    }

    exe.root_module.addImport("ui", ui_module);
    exe.root_module.addImport("zenit_app", zenit_dep.module("zenit_app"));
    addNativeLibs(zenit_dep, exe);
}

/// Just the native side of `attach` (bridges + frameworks), for consumers who
/// wire module imports themselves. Safe to call on any target.
pub fn addNativeLibs(zenit_dep: *std.Build.Dependency, exe: *std.Build.Step.Compile) void {
    if (exe.rootModuleTarget().os.tag == .windows) {
        // Consumer apps use the same renderer initialization as the examples.
        // Preserve a larger caller reserve while ensuring enough stack in Debug.
        exe.stack_size = windowsStackReserve(exe.stack_size);
        exe.root_module.addCSourceFile(.{ .file = zenit_dep.path("native/windows/window_bridge.c"), .flags = &.{} });
        exe.root_module.addCSourceFile(.{ .file = zenit_dep.path("native/windows/recording_bridge.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
        exe.root_module.linkSystemLibrary("mfuuid", .{});
        exe.root_module.addCSourceFile(.{ .file = zenit_dep.path("native/windows/file_dialog.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
        exe.root_module.addCSourceFile(.{ .file = zenit_dep.path("native/windows/drop_bridge.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
        exe.root_module.addCSourceFile(.{ .file = zenit_dep.path("native/windows/drag_data.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
        exe.root_module.addCSourceFile(.{ .file = zenit_dep.path("native/windows/drag_source.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
        exe.root_module.addCSourceFile(.{ .file = zenit_dep.path("native/windows/accessibility_bridge.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
        exe.root_module.addCSourceFile(.{ .file = zenit_dep.path("native/windows/d3d11_probe.c"), .flags = &.{"-O2"} });
        exe.root_module.addCSourceFile(.{ .file = zenit_dep.path("native/windows/d2d_composite.cpp"), .flags = windowsD2DFlags(exe.step.owner, zenit_dep.builder) });
        exe.root_module.addCSourceFile(.{ .file = zenit_dep.path("native/windows/dwrite_bridge.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
        exe.root_module.linkSystemLibrary("user32", .{});
        exe.root_module.linkSystemLibrary("dwmapi", .{});
        exe.root_module.linkSystemLibrary("gdi32", .{});
        exe.root_module.linkSystemLibrary("imm32", .{});
        exe.root_module.linkSystemLibrary("dwrite", .{});
        exe.root_module.linkSystemLibrary("d3d11", .{});
        exe.root_module.linkSystemLibrary("d2d1", .{});
        exe.root_module.linkSystemLibrary("dxgi", .{});
        exe.root_module.linkSystemLibrary("dxguid", .{});
        exe.root_module.linkSystemLibrary("ole32", .{});
        exe.root_module.linkSystemLibrary("shell32", .{});
        exe.root_module.linkSystemLibrary("uuid", .{});
        exe.root_module.linkSystemLibrary("uiautomationcore", .{});
        exe.root_module.linkSystemLibrary("oleaut32", .{});
        exe.root_module.linkSystemLibrary("windowscodecs", .{});
        exe.root_module.link_libc = true;
        exe.root_module.link_libcpp = true;
        return;
    }
    if (exe.rootModuleTarget().os.tag == .linux) {
        const mod = exe.root_module;
        for ([_][]const u8{ "vendor/vulkan-headers/include", "vendor/wayland/include", "vendor/xkbcommon-headers/include", "vendor/wayland/protocols" }) |path| mod.addIncludePath(zenit_dep.path(path));
        for ([_][]const u8{ "native/linux/vulkan_device.c", "native/linux/opengl_device.c", "native/linux/wayland/window.c", "native/linux/font_discovery.c", "native/linux/text_layout.c", "vendor/wayland/protocols/wayland-protocol.c", "vendor/wayland/protocols/xdg-shell-protocol.c", "vendor/wayland/protocols/fractional-scale-v1-protocol.c", "vendor/wayland/protocols/viewporter-protocol.c", "vendor/wayland/protocols/cursor-shape-v1-protocol.c", "vendor/wayland/protocols/tablet-v2-protocol.c", "vendor/wayland/protocols/text-input-unstable-v3-protocol.c" }) |path| mod.addCSourceFile(.{ .file = zenit_dep.path(path), .flags = &.{ linux_native_revision_flag, "-std=c11", "-D_POSIX_C_SOURCE=200809L" } });
        mod.linkSystemLibrary("dl", .{});
        mod.linkSystemLibrary("fontconfig", .{});
        addFreeTypeLibs(mod);
        mod.link_libc = true;
        return;
    }
    if (exe.rootModuleTarget().os.tag != .macos) return;
    const bridges = [_][]const u8{
        "native/macos/window_bridge.m",
        "native/macos/screen_recording_bridge.m",
        "native/macos/metal_bridge.m",
        "native/macos/coretext_bridge.m",
        "native/macos/image_bridge.m",
    };
    for (bridges) |src| exe.root_module.addCSourceFile(.{
        .file = zenit_dep.path(src),
        .flags = macosNativeFlags(exe.step.owner, zenit_dep.builder),
    });
    const frameworks = [_][]const u8{
        "Cocoa",        "Metal",                  "QuartzCore", "IOSurface",
        "CoreVideo",    "UniformTypeIdentifiers", "Foundation", "CoreText",
        "CoreGraphics", "CoreFoundation",         "ImageIO",    "AVFoundation",
        "CoreMedia",
    };
    for (frameworks) |fw| exe.root_module.linkFramework(fw, .{});
    exe.root_module.link_libc = true;
}

/// Stable install location for the Bun/TypeScript automation client. The
/// dependency itself normally lives under Zig's opaque package cache, so
/// downstream scripts should import the installed copy instead of guessing
/// the cache path.
pub const harness_client_install_path = "share/zenit/harness/client.ts";

/// Install Zenit's typed Harness client below the consumer's install prefix
/// and attach it to the ordinary `zig build` install step.
///
/// A downstream `e2e/*.ts` file can then import:
///
///     import { health } from "../zig-out/share/zenit/harness/client.ts";
///
/// This only installs developer tooling; Harness RPC still has to be enabled
/// for the Zenit dependency with `.@"test-mode" = true`.
pub fn installHarnessClient(b: *std.Build, zenit_dep: *std.Build.Dependency) void {
    const install = b.addInstallFile(
        zenit_dep.path("e2e/client.ts"),
        harness_client_install_path,
    );
    b.getInstallStep().dependOn(&install.step);
}

/// Stable install location for Zenit's scenario UI automation toolkit (bun scripts + schema).
/// All .ts relative import, install same dir ready to use.
pub const scenario_tooling_install_dir = "share/zenit/scenario";

/// Install Zenit scenario automation toolkit to consumer zig-out/share/zenit/scenario/, enable
/// downstream `bun zig-out/share/zenit/scenario/scenario_runner.ts <scenario.yaml>`.
/// Like installHarnessClient: dev tools only; harness RPC still needs `.@"test-mode" = true`.
pub fn installScenarioTooling(b: *std.Build, zenit_dep: *std.Build.Dependency) void {
    const files = [_][]const u8{
        "client.ts",
        "png.ts",
        "design_diff.ts",
        "golden_compare.ts",
        "mock.ts",
        "pencil_export.ts",
        "scenario_runner.ts",
        "controller.ts",
        "watcher.ts",
        "scenario.schema.json",
        "report.schema.json",
    };
    for (files) |f| {
        const install = b.addInstallFile(
            zenit_dep.path(b.fmt("e2e/{s}", .{f})),
            b.fmt("share/zenit/scenario/{s}", .{f}),
        );
        b.getInstallStep().dependOn(&install.step);
    }
}

/// Package a consumer executable as a macOS `.app` bundle. Re-exported from
/// zenit's internal bundling module so `zenit.bundleApp(b, .{...})` works from
/// a consumer build.zig. See `BundleSpec` for options (icon, signing, etc.).
pub const bundleApp = macos_bundle.bundleApp;
pub const BundleSpec = macos_bundle.BundleSpec;
pub const BundleResult = macos_bundle.BundleResult;
pub const notarizeBundle = macos_bundle.notarizeBundle;
pub const NotarizeSpec = macos_bundle.NotarizeSpec;
/// Signing policy type. Consumer picks ad_hoc vs developer_id by condition (e.g.
/// -Drelease-sign present) needs explicit type name for function return.
pub const Signing = macos_bundle.Signing;
pub const DeveloperIdSigning = macos_bundle.DeveloperIdSigning;
pub const NotaryAuth = macos_bundle.NotaryAuth;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Linux bootstrap is an independent graph: it must not pull in Cocoa,
    // Metal shaders, Windows SDK, FreeType or the UI until those are ported.
    const linux_arch = b.option(std.Target.Cpu.Arch, "linux-arch", "Linux Vulkan probe target: aarch64 (default) or x86_64") orelse .aarch64;
    if (linux_arch != .aarch64 and linux_arch != .x86_64) @panic("linux-arch must be aarch64 or x86_64");
    const linux_target = b.resolveTargetQuery(.{ .cpu_arch = linux_arch, .os_tag = .linux, .abi = .gnu });
    const glslc = b.option([]const u8, "glslc", "Host GLSL-to-SPIR-V compiler") orelse "glslc";
    const probe_vertex_compile = b.addSystemCommand(&.{ glslc, "--target-env=vulkan1.0", "-Werror" });
    probe_vertex_compile.addFileArg(b.path("src/gpu/vulkan/shaders/probe.vert"));
    probe_vertex_compile.addArg("-o");
    const probe_vertex = probe_vertex_compile.addOutputFileArg("probe.vert.spv");
    const probe_fragment_compile = b.addSystemCommand(&.{ glslc, "--target-env=vulkan1.0", "-Werror" });
    probe_fragment_compile.addFileArg(b.path("src/gpu/vulkan/shaders/probe.frag"));
    probe_fragment_compile.addArg("-o");
    const probe_fragment = probe_fragment_compile.addOutputFileArg("probe.frag.spv");
    const resource_fragment_compile = b.addSystemCommand(&.{ glslc, "--target-env=vulkan1.1", "-Werror" });
    resource_fragment_compile.addFileArg(b.path("src/gpu/vulkan/shaders/resource.frag"));
    resource_fragment_compile.addArg("-o");
    const resource_fragment = resource_fragment_compile.addOutputFileArg("resource.frag.spv");
    const resource_indices_compile = b.addSystemCommand(&.{ glslc, "--target-env=vulkan1.1", "-Werror", "-O" });
    resource_indices_compile.addFileArg(b.path("src/gpu/vulkan/shaders/resource_indices.vert"));
    resource_indices_compile.addArg("-o");
    const resource_indices = resource_indices_compile.addOutputFileArg("resource_indices.vert.spv");
    const resource_values_compile = b.addSystemCommand(&.{ glslc, "--target-env=vulkan1.1", "-Werror" });
    resource_values_compile.addFileArg(b.path("src/gpu/vulkan/shaders/resource_values.frag"));
    resource_values_compile.addArg("-o");
    const resource_values = resource_values_compile.addOutputFileArg("resource_values.frag.spv");
    const blend_fragment_compile = b.addSystemCommand(&.{ glslc, "--target-env=vulkan1.1", "-Werror" });
    blend_fragment_compile.addFileArg(b.path("src/gpu/vulkan/shaders/blend_probe.frag"));
    blend_fragment_compile.addArg("-o");
    const blend_fragment = blend_fragment_compile.addOutputFileArg("blend_probe.frag.spv");
    const ui_shader_compile = b.addSystemCommand(&.{"python3"});
    ui_shader_compile.addFileArg(b.path("scripts/compile_vulkan_ui_shaders.py"));
    ui_shader_compile.addArgs(&.{ "--glslc", glslc, "--spirv-val", b.option([]const u8, "spirv-val", "Host SPIR-V validator") orelse "spirv-val", "--out" });
    const ui_shader_dir = ui_shader_compile.addOutputDirectoryArg("vulkan-ui-shaders");
    for ([_][]const u8{ "blur", "composite", "path", "image", "damage_clear", "icon", "text", "sdf_primitives", "glass" }) |program| {
        ui_shader_compile.addFileArg(b.path(b.fmt("src/gpu/d3d12/shaders/{s}.hlsl", .{program})));
    }
    b.step("linux-vulkan-shaders", "Compile and validate all UI shader entries for Vulkan")
        .dependOn(&b.addInstallDirectory(.{ .source_dir = ui_shader_dir, .install_dir = .prefix, .install_subdir = "share/zenit/vulkan-shaders" }).step);
    const ui_shaders_module = b.createModule(.{ .root_source_file = ui_shader_dir.path(b, "shaders.zig"), .target = linux_target, .optimize = optimize });
    const vulkan_device = b.createModule(.{ .root_source_file = b.path("src/gpu/gpu.zig"), .target = linux_target, .optimize = optimize });
    vulkan_device.addImport("vulkan_ui_shaders", ui_shaders_module);
    // Compile the probes with the selected renderer backend too: shared GPU
    // descriptors and backend contract must resolve to the actual Vulkan types.
    const native_descriptor_opts = b.addOptions();
    native_descriptor_opts.addOption([]const u8, "gpu_backend", "vulkan");
    vulkan_device.addOptions("build_options", native_descriptor_opts);
    const vulkan_probe_root = b.createModule(.{ .root_source_file = b.path("tools/linux_vulkan_probe.zig"), .target = linux_target, .optimize = optimize, .link_libc = true });
    vulkan_probe_root.addImport("vulkan_device", vulkan_device);
    vulkan_probe_root.addAnonymousImport("probe_vertex", .{ .root_source_file = probe_vertex });
    vulkan_probe_root.addAnonymousImport("probe_fragment", .{ .root_source_file = probe_fragment });
    vulkan_probe_root.addIncludePath(b.path("vendor/vulkan-headers/include"));
    vulkan_probe_root.addCSourceFile(.{ .file = b.path("native/linux/vulkan_device.c"), .flags = &.{ linux_native_revision_flag, "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    vulkan_probe_root.linkSystemLibrary("dl", .{});
    const vulkan_probe = b.addExecutable(.{ .name = "zenit-linux-vulkan-probe", .root_module = vulkan_probe_root });
    b.step("linux-vulkan-probe", "Build Linux Vulkan graphics/readback probe (run on target)")
        .dependOn(&b.addInstallArtifact(vulkan_probe, .{}).step);
    const pipeline_probe_root = b.createModule(.{ .root_source_file = b.path("tools/linux_vulkan_pipeline_probe.zig"), .target = linux_target, .optimize = optimize, .link_libc = true });
    pipeline_probe_root.addImport("vulkan_device", vulkan_device);
    pipeline_probe_root.addAnonymousImport("resource_indices", .{ .root_source_file = resource_indices });
    pipeline_probe_root.addAnonymousImport("resource_values", .{ .root_source_file = resource_values });
    pipeline_probe_root.addAnonymousImport("resource_fragment", .{ .root_source_file = resource_fragment });
    pipeline_probe_root.addAnonymousImport("probe_vertex", .{ .root_source_file = probe_vertex });
    pipeline_probe_root.addAnonymousImport("probe_fragment", .{ .root_source_file = probe_fragment });
    pipeline_probe_root.addImport("vulkan_ui_shaders", ui_shaders_module);
    pipeline_probe_root.addAnonymousImport("blend_fragment", .{ .root_source_file = blend_fragment });
    pipeline_probe_root.addIncludePath(b.path("vendor/vulkan-headers/include"));
    pipeline_probe_root.addCSourceFile(.{ .file = b.path("native/linux/vulkan_device.c"), .flags = &.{ linux_native_revision_flag, "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    pipeline_probe_root.linkSystemLibrary("dl", .{});
    const pipeline_probe = b.addExecutable(.{ .name = "zenit-linux-vulkan-pipeline-probe", .root_module = pipeline_probe_root });
    b.step("linux-vulkan-pipeline-probe", "Build live Vulkan UI pipeline validation")
        .dependOn(&b.addInstallArtifact(pipeline_probe, .{}).step);
    const renderer_resource_probe_root = b.createModule(.{ .root_source_file = b.path("tools/linux_vulkan_renderer_resources_probe.zig"), .target = linux_target, .optimize = optimize, .link_libc = true });
    renderer_resource_probe_root.addImport("vulkan_device", vulkan_device);
    renderer_resource_probe_root.addIncludePath(b.path("vendor/vulkan-headers/include"));
    renderer_resource_probe_root.addCSourceFile(.{ .file = b.path("native/linux/vulkan_device.c"), .flags = &.{ linux_native_revision_flag, "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    renderer_resource_probe_root.linkSystemLibrary("dl", .{});
    const linux_image_renderer = b.createModule(.{ .root_source_file = b.path("src/render/image_renderer.zig"), .target = linux_target, .optimize = optimize });
    linux_image_renderer.addImport("gpu", vulkan_device);
    renderer_resource_probe_root.addImport("image_renderer", linux_image_renderer);
    const renderer_resource_probe = b.addExecutable(.{ .name = "zenit-linux-vulkan-renderer-resources-probe", .root_module = renderer_resource_probe_root });
    b.step("linux-vulkan-renderer-resources-probe", "Validate renderer-owned Vulkan resource adapters on target")
        .dependOn(&b.addInstallArtifact(renderer_resource_probe, .{}).step);
    const opengl_probe_gpu = b.createModule(.{ .root_source_file = b.path("src/gpu/gpu.zig"), .target = linux_target, .optimize = optimize });
    const opengl_probe_options = b.addOptions();
    opengl_probe_options.addOption([]const u8, "gpu_backend", "opengl");
    opengl_probe_gpu.addOptions("build_options", opengl_probe_options);
    const opengl_resources_root = b.createModule(.{ .root_source_file = b.path("tools/linux_vulkan_renderer_resources_probe.zig"), .target = linux_target, .optimize = optimize, .link_libc = true });
    opengl_resources_root.addImport("vulkan_device", opengl_probe_gpu);
    // The alias keeps one contract suite for both production drivers.
    const opengl_image_renderer = b.createModule(.{ .root_source_file = b.path("src/render/image_renderer.zig"), .target = linux_target, .optimize = optimize });
    opengl_image_renderer.addImport("gpu", opengl_probe_gpu);
    opengl_resources_root.addImport("image_renderer", opengl_image_renderer);
    opengl_resources_root.addImport("linux_wayland", b.createModule(.{ .root_source_file = b.path("src/platform/linux/wayland/window.zig"), .target = linux_target, .optimize = optimize }));
    opengl_resources_root.addIncludePath(b.path("vendor/vulkan-headers/include"));
    opengl_resources_root.addIncludePath(b.path("vendor/wayland/include"));
    opengl_resources_root.addIncludePath(b.path("vendor/wayland/protocols"));
    opengl_resources_root.addIncludePath(b.path("vendor/xkbcommon-headers/include"));
    opengl_resources_root.addCSourceFiles(.{ .files = &.{ "native/linux/vulkan_device.c", "native/linux/opengl_device.c", "native/linux/wayland/window.c", "vendor/wayland/protocols/wayland-protocol.c", "vendor/wayland/protocols/xdg-shell-protocol.c", "vendor/wayland/protocols/fractional-scale-v1-protocol.c", "vendor/wayland/protocols/viewporter-protocol.c", "vendor/wayland/protocols/cursor-shape-v1-protocol.c", "vendor/wayland/protocols/tablet-v2-protocol.c", "vendor/wayland/protocols/text-input-unstable-v3-protocol.c" }, .flags = &.{ linux_native_revision_flag, "-std=c11", "-D_POSIX_C_SOURCE=200809L", "-Wall", "-Wextra", "-Werror" } });
    opengl_resources_root.linkSystemLibrary("dl", .{});
    const opengl_resources_probe = b.addExecutable(.{ .name = "zenit-linux-opengl-renderer-resources-probe", .root_module = opengl_resources_root });
    b.step("linux-opengl-renderer-resources-probe", "Validate renderer-owned OpenGL resources and commands on hardware")
        .dependOn(&b.addInstallArtifact(opengl_resources_probe, .{}).step);
    const linux_probe_platform = b.createModule(.{ .root_source_file = b.path("src/platform.zig"), .target = linux_target, .optimize = optimize });
    const wayland_probe_root = b.createModule(.{ .root_source_file = b.path("tools/linux_wayland_vulkan_probe.zig"), .target = linux_target, .optimize = optimize, .link_libc = true });
    wayland_probe_root.addImport("vulkan_device", vulkan_device);
    wayland_probe_root.addImport("linux_platform", linux_probe_platform);
    wayland_probe_root.addAnonymousImport("probe_vertex", .{ .root_source_file = probe_vertex });
    wayland_probe_root.addAnonymousImport("probe_fragment", .{ .root_source_file = probe_fragment });
    wayland_probe_root.addIncludePath(b.path("vendor/vulkan-headers/include"));
    wayland_probe_root.addIncludePath(b.path("vendor/wayland/include"));
    wayland_probe_root.addIncludePath(b.path("vendor/xkbcommon-headers/include"));
    wayland_probe_root.addIncludePath(b.path("vendor/wayland/protocols"));
    wayland_probe_root.addCSourceFiles(.{ .files = &.{ "native/linux/vulkan_device.c", "native/linux/wayland/window.c" }, .flags = &.{ linux_native_revision_flag, "-std=c11", "-D_POSIX_C_SOURCE=200809L", "-Wall", "-Wextra", "-Werror" } });
    // Generated protocol metadata is compiled as generated; no handwritten edits.
    wayland_probe_root.addCSourceFiles(.{ .files = &.{ "vendor/wayland/protocols/wayland-protocol.c", "vendor/wayland/protocols/xdg-shell-protocol.c", "vendor/wayland/protocols/fractional-scale-v1-protocol.c", "vendor/wayland/protocols/viewporter-protocol.c", "vendor/wayland/protocols/cursor-shape-v1-protocol.c", "vendor/wayland/protocols/tablet-v2-protocol.c", "vendor/wayland/protocols/text-input-unstable-v3-protocol.c" }, .flags = &.{"-std=c11"} });
    wayland_probe_root.linkSystemLibrary("dl", .{});
    const wayland_probe = b.addExecutable(.{ .name = "zenit-linux-wayland-vulkan-probe", .root_module = wayland_probe_root });
    b.step("linux-wayland-vulkan-probe", "Build Linux Wayland/Vulkan presentation probe (run in desktop session)")
        .dependOn(&b.addInstallArtifact(wayland_probe, .{}).step);

    const clipboard_transport_root = b.createModule(.{ .root_source_file = b.path("tools/linux_wayland_clipboard_transport_probe.zig"), .target = linux_target, .optimize = optimize, .link_libc = true });
    clipboard_transport_root.addIncludePath(b.path("vendor/wayland/include"));
    clipboard_transport_root.addIncludePath(b.path("vendor/wayland/protocols"));
    clipboard_transport_root.addIncludePath(b.path("vendor/xkbcommon-headers/include"));
    clipboard_transport_root.addCSourceFiles(.{ .files = &.{"tools/linux_wayland_clipboard_transport_probe.c"}, .flags = &.{ linux_native_revision_flag, "-std=c11", "-D_POSIX_C_SOURCE=200809L", "-UNDEBUG", "-Wall", "-Wextra", "-Werror" } });
    clipboard_transport_root.addCSourceFiles(.{ .files = &.{ "vendor/wayland/protocols/wayland-protocol.c", "vendor/wayland/protocols/xdg-shell-protocol.c", "vendor/wayland/protocols/fractional-scale-v1-protocol.c", "vendor/wayland/protocols/viewporter-protocol.c", "vendor/wayland/protocols/cursor-shape-v1-protocol.c", "vendor/wayland/protocols/tablet-v2-protocol.c", "vendor/wayland/protocols/text-input-unstable-v3-protocol.c" }, .flags = &.{"-std=c11"} });
    clipboard_transport_root.linkSystemLibrary("dl", .{});
    const clipboard_transport = b.addExecutable(.{ .name = "zenit-linux-wayland-clipboard-transport-probe", .root_module = clipboard_transport_root });
    b.step("linux-wayland-clipboard-transport-probe", "Build native clipboard pipe, ownership and failure contracts")
        .dependOn(&b.addInstallArtifact(clipboard_transport, .{}).step);
    const ime_protocol_root = b.createModule(.{ .root_source_file = b.path("tools/linux_wayland_ime_protocol_probe.zig"), .target = linux_target, .optimize = optimize, .link_libc = true });
    ime_protocol_root.addImport("wayland_window", b.createModule(.{ .root_source_file = b.path("src/platform/linux/wayland/window.zig"), .target = linux_target, .optimize = optimize }));
    ime_protocol_root.addIncludePath(b.path("vendor/wayland/include"));
    ime_protocol_root.addIncludePath(b.path("vendor/wayland/protocols"));
    ime_protocol_root.addIncludePath(b.path("vendor/xkbcommon-headers/include"));
    ime_protocol_root.addCSourceFiles(.{ .files = &.{"tools/linux_wayland_ime_protocol_probe.c"}, .flags = &.{ linux_native_revision_flag, "-std=c11", "-D_POSIX_C_SOURCE=200809L", "-UNDEBUG", "-Wall", "-Wextra", "-Werror" } });
    ime_protocol_root.addCSourceFiles(.{ .files = &.{ "vendor/wayland/protocols/wayland-protocol.c", "vendor/wayland/protocols/xdg-shell-protocol.c", "vendor/wayland/protocols/fractional-scale-v1-protocol.c", "vendor/wayland/protocols/viewporter-protocol.c", "vendor/wayland/protocols/cursor-shape-v1-protocol.c", "vendor/wayland/protocols/tablet-v2-protocol.c", "vendor/wayland/protocols/text-input-unstable-v3-protocol.c" }, .flags = &.{"-std=c11"} });
    ime_protocol_root.linkSystemLibrary("dl", .{});
    const ime_protocol = b.addExecutable(.{ .name = "zenit-linux-wayland-ime-protocol-probe", .root_module = ime_protocol_root });
    b.step("linux-wayland-ime-protocol-probe", "Build native text-input-v3 batching and lifecycle contracts")
        .dependOn(&b.addInstallArtifact(ime_protocol, .{}).step);
    const scroll_protocol_root = b.createModule(.{ .root_source_file = b.path("tools/linux_wayland_scroll_probe.zig"), .target = linux_target, .optimize = optimize, .link_libc = true });
    scroll_protocol_root.addImport("wayland_window", b.createModule(.{ .root_source_file = b.path("src/platform/linux/wayland/window.zig"), .target = linux_target, .optimize = optimize }));
    scroll_protocol_root.addIncludePath(b.path("vendor/wayland/include"));
    scroll_protocol_root.addIncludePath(b.path("vendor/wayland/protocols"));
    scroll_protocol_root.addIncludePath(b.path("vendor/xkbcommon-headers/include"));
    scroll_protocol_root.addCSourceFiles(.{ .files = &.{"tools/linux_wayland_scroll_probe.c"}, .flags = &.{ linux_native_revision_flag, "-std=c11", "-D_POSIX_C_SOURCE=200809L", "-UNDEBUG", "-Wall", "-Wextra", "-Werror" } });
    scroll_protocol_root.addCSourceFiles(.{ .files = &.{ "vendor/wayland/protocols/wayland-protocol.c", "vendor/wayland/protocols/xdg-shell-protocol.c", "vendor/wayland/protocols/fractional-scale-v1-protocol.c", "vendor/wayland/protocols/viewporter-protocol.c", "vendor/wayland/protocols/cursor-shape-v1-protocol.c", "vendor/wayland/protocols/tablet-v2-protocol.c", "vendor/wayland/protocols/text-input-unstable-v3-protocol.c" }, .flags = &.{"-std=c11"} });
    scroll_protocol_root.linkSystemLibrary("dl", .{});
    const scroll_protocol = b.addExecutable(.{ .name = "zenit-linux-wayland-scroll-probe", .root_module = scroll_protocol_root });
    b.step("linux-wayland-scroll-probe", "Build Wayland scroll direction, frame and device contracts")
        .dependOn(&b.addInstallArtifact(scroll_protocol, .{}).step);
    if (b.graph.host.result.os.tag == .linux and b.graph.host.result.cpu.arch == linux_arch) {
        const run_vulkan_probe = b.addRunArtifact(vulkan_probe);
        run_vulkan_probe.addPassthruArgs();
        b.step("run-linux-vulkan-probe", "Run live Vulkan probe; software devices require --allow-software")
            .dependOn(&run_vulkan_probe.step);
        const run_wayland_probe = b.addRunArtifact(wayland_probe);
        run_wayland_probe.addPassthruArgs();
        b.step("run-linux-wayland-vulkan-probe", "Run Wayland/Vulkan probe in a desktop session")
            .dependOn(&run_wayland_probe.step);
    }

    const yix_compiler_module = b.createModule(.{ .root_source_file = b.path("src/yix/compiler.zig"), .target = b.graph.host });

    const yix_exe = b.addExecutable(.{ .name = "yix", .root_module = b.createModule(.{ .root_source_file = b.path("tools/yix.zig"), .target = b.graph.host }) });
    yix_exe.root_module.addImport("yix_compiler", yix_compiler_module);
    b.installArtifact(yix_exe);
    const yix_run = b.addRunArtifact(yix_exe);
    yix_run.addPassthruArgs();
    const yix_step = b.step("yix", "Compile one .yix / .yss file: zig build yix -- INPUT OUTPUT.zig");
    yix_step.dependOn(&yix_run.step);
    // Each .yix / .yss paired with generated sibling `_<name>.zig` (card.yix -> _card.yix.zig)
    // in repo; hand-written imports directly; ui relative import, downstream build
    // doesn't need Yix compiler, ZLS / GitHub / any editor reads directly.
    // gen-yix regenerate; check-yix diff only, stale or hand-changed fail (join test-headless).
    const yix_source_roots = [_][]const u8{ "src/ui", "examples", "tests/yix" };
    // Explicit gen-yix / check-yix: always run
    const gen_yix_run = b.addRunArtifact(yix_exe);
    gen_yix_run.setCwd(b.path("."));
    gen_yix_run.addArg("gen");
    gen_yix_run.addArgs(&yix_source_roots);
    gen_yix_run.has_side_effects = true;
    b.step("gen-yix", "Regenerate the checked-in _<name>.yix.zig / _<name>.yss.zig next to each .yix / .yss").dependOn(&gen_yix_run.step);
    const check_yix_run = b.addRunArtifact(yix_exe);
    check_yix_run.setCwd(b.path("."));
    check_yix_run.addArg("check");
    check_yix_run.addArgs(&yix_source_roots);
    check_yix_run.has_side_effects = true;
    b.step("check-yix", "Fail when a checked-in _<name>.yix.zig / _<name>.yss.zig is stale or hand-edited").dependOn(&check_yix_run.step);
    // Pre-build sibling handling: write = regenerate if stale (write only changed, atomic),
    // check = fail if stale (CI), off = ignore. Default: dep build off (don't write to package),
    // CI check, local write. All .yix/.yss registered input; `--watch` changed trigger.
    const YixGen = enum { write, check, off };
    const yix_gen_default: YixGen = if (b.pkg_hash.len != 0) .off else if (b.graph.environ_map.get("CI") != null) .check else .write;
    const yix_gen = b.option(YixGen, "yix-gen", "Before compiling: write (regenerate stale _x.yix.zig twins), check (fail if stale; CI default) or off") orelse yix_gen_default;
    // Pre-compile cacheable: input all .yix/.yss + siblings, output marker. No change -> skip;
    // `--watch` per input. Sibling is input, write mode hand-changed restored (else cache hit =
    // cached
    // hand-edit); true regenerate reruns, next contents same skip file, stabilize. Mid-run new .yix
    // not in input, need zig build rerun.
    var twins: YixTwins = .{ .b = b, .step = switch (yix_gen) {
        .off => null,
        inline else => |mode| blk: {
            const run = b.addRunArtifact(yix_exe);
            run.setName(if (mode == .write) "yix gen (before compile)" else "yix check (before compile)");
            run.setCwd(b.path("."));
            run.addArg(if (mode == .write) "gen" else "check");
            run.addArg("--stamp");
            _ = run.addOutputFileArg("yix.stamp");
            run.addArgs(&yix_source_roots);
            for (yix_source_roots) |root| addYixInputs(b, run, root);
            break :blk &run.step;
        },
    } };

    // E2E test harness flags
    const test_mode = b.option(bool, "test-mode", "Enable e2e test harness (file RPC server)") orelse false;
    const e2e_port = b.option(u16, "e2e-port", "E2E server port (used in default RPC dir name)") orelse 19816;

    // GPU backend choice (C1). `metal` production; `null` no-device deterministic reference
    // implementation, prove `gpu.Backend.*` abstraction—only second impl compiles proves
    // signature backend-neutral not Metal-baked. Compile-time choice, no runtime branch.
    const gpu_backend = b.option(
        []const u8,
        "gpu-backend",
        "GPU backend: metal, null (reference), d3d12 or d3d11 (Windows), vulkan (Linux), opengl (Linux compatibility)",
    ) orelse if (target.result.os.tag == .linux) "vulkan" else "metal";
    if (!std.mem.eql(u8, gpu_backend, "metal") and !std.mem.eql(u8, gpu_backend, "null") and !std.mem.eql(u8, gpu_backend, "d3d12") and !std.mem.eql(u8, gpu_backend, "d3d11") and !std.mem.eql(u8, gpu_backend, "vulkan") and !std.mem.eql(u8, gpu_backend, "opengl")) {
        std.debug.print("invalid -Dgpu-backend={s} (expected 'metal', 'null', 'd3d12', 'd3d11', 'vulkan' or 'opengl')\n", .{gpu_backend});
        std.process.exit(1);
    }

    const build_opts = b.addOptions();
    build_opts.addOption(bool, "test_mode", test_mode);
    build_opts.addOption(bool, "engine_diagnostics", b.option(bool, "engine-diagnostics", "Enable opt-in per-frame GPU engine diagnostics in development builds") orelse test_mode or optimize == .debug);
    build_opts.addOption(u16, "e2e_port", e2e_port);
    build_opts.addOption([]const u8, "gpu_backend", gpu_backend);
    const build_options_module = build_opts.createModule();

    // Modules (all 9 of zenit framework + icon_ir single file)

    const text_module = b.createModule(.{
        .root_source_file = b.path("src/text/text.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (target.result.os.tag != .macos and target.result.os.tag != .windows) {
        addFreeTypeLibs(text_module);
    }

    if (target.result.os.tag == .linux) {
        const font_root = b.createModule(.{ .root_source_file = b.path("tools/linux_font_smoke.zig"), .target = target, .optimize = optimize, .link_libc = true });
        font_root.addImport("text", text_module);
        const font_smoke = b.addExecutable(.{ .name = "zenit-linux-font-smoke", .root_module = font_root });
        addCoreTextBridge(b, font_smoke);
        b.step("linux-font-smoke", "Build Linux system-font discovery and scaling gate").dependOn(&b.addInstallArtifact(font_smoke, .{}).step);
    }

    const platform_module = b.createModule(.{
        .root_source_file = b.path("src/platform.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Cross-compile a real native Win32 window from any development host.
    // It paints only the bridge's diagnostic GDI frame, not the Zenit renderer.
    const default_windows_arch: std.Target.Cpu.Arch = if (b.graph.host.result.os.tag == .windows and b.graph.host.result.cpu.arch == .x86_64) .x86_64 else .aarch64;
    const windows_arch = b.option(std.Target.Cpu.Arch, "windows-arch", "Windows target: x86, x86_64 or aarch64 (native on Windows, otherwise aarch64)") orelse default_windows_arch;
    if (windows_arch != .aarch64 and windows_arch != .x86_64 and windows_arch != .x86) @panic("windows-arch must be aarch64, x86_64 or x86");
    // Keep the historical build-step names for existing VM automation.
    const windows_arm64 = b.resolveTargetQuery(.{
        .cpu_arch = windows_arch,
        .os_tag = .windows,
        .abi = .gnu,
    });
    const export_windows_modules = target.result.os.tag == .windows and
        target.result.cpu.arch == windows_arch and target.result.abi == .gnu;
    const windows_smoke_platform = b.createModule(.{
        .root_source_file = b.path("src/platform.zig"),
        .target = windows_arm64,
        .optimize = optimize,
    });
    const windows_smoke_root = b.createModule(.{
        .root_source_file = b.path("tools/windows_smoke.zig"),
        .target = windows_arm64,
        .optimize = optimize,
    });
    const windows_smoke_sdk = b.createModule(.{
        .root_source_file = b.path("src/system_sdk/system_sdk.zig"),
        .target = windows_arm64,
        .optimize = optimize,
    });
    windows_smoke_sdk.addImport("platform", windows_smoke_platform);
    windows_smoke_root.addImport("platform", windows_smoke_platform);
    windows_smoke_root.addImport("system_sdk", windows_smoke_sdk);
    const windows_recording_contract = b.addExecutable(.{ .name = "zenit-windows-recording-contract", .root_module = b.createModule(.{ .target = windows_arm64, .optimize = optimize }) });
    windows_recording_contract.root_module.addCSourceFiles(.{ .files = &.{ "native/windows/recording_bridge.cpp", "native/windows/recording_tests.cpp" }, .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti", "-DZENIT_RECORDING_CONTRACT_DELAY=1" } });
    windows_recording_contract.root_module.linkSystemLibrary("mfuuid", .{});
    windows_recording_contract.root_module.linkSystemLibrary("ole32", .{});
    windows_recording_contract.root_module.link_libc = true;
    windows_recording_contract.root_module.link_libcpp = true;
    b.step("windows-arm64-recording-contract", "Cross-compile the Windows Media Foundation recorder contract")
        .dependOn(&b.addInstallArtifact(windows_recording_contract, .{}).step);

    const windows_smoke = b.addExecutable(.{ .name = "zenit-windows-smoke", .root_module = windows_smoke_root });
    windows_smoke.root_module.addCSourceFile(.{ .file = b.path("native/windows/window_bridge.c"), .flags = &.{"-DZENIT_GDI_PROBE=1"} });
    windows_smoke.root_module.addCSourceFile(.{ .file = b.path("native/windows/recording_bridge.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
    windows_smoke.root_module.linkSystemLibrary("mfuuid", .{});
    windows_smoke.root_module.addCSourceFile(.{ .file = b.path("native/windows/file_dialog.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
    windows_smoke.root_module.addCSourceFile(.{ .file = b.path("native/windows/drop_bridge.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
    windows_smoke.root_module.addCSourceFile(.{ .file = b.path("native/windows/drag_data.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
    windows_smoke.root_module.addCSourceFile(.{ .file = b.path("native/windows/drag_source.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
    windows_smoke.root_module.addCSourceFile(.{ .file = b.path("native/windows/accessibility_bridge.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
    windows_smoke.root_module.addCSourceFile(.{ .file = b.path("native/windows/d3d11_probe.c"), .flags = &.{"-O2"} });
    windows_smoke.root_module.addCSourceFile(.{ .file = b.path("native/windows/d2d_composite.cpp"), .flags = windowsD2DFlags(b, b) });
    windows_smoke.root_module.addCSourceFile(.{ .file = b.path("native/windows/dwrite_bridge.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
    windows_smoke.root_module.linkSystemLibrary("user32", .{});
    windows_smoke.root_module.linkSystemLibrary("dwmapi", .{});
    windows_smoke.root_module.linkSystemLibrary("gdi32", .{});
    windows_smoke.root_module.linkSystemLibrary("imm32", .{});
    windows_smoke.root_module.linkSystemLibrary("d3d11", .{});
    windows_smoke.root_module.linkSystemLibrary("d2d1", .{});
    windows_smoke.root_module.linkSystemLibrary("dwrite", .{});
    windows_smoke.root_module.linkSystemLibrary("dxgi", .{});
    windows_smoke.root_module.linkSystemLibrary("dxguid", .{});
    windows_smoke.root_module.linkSystemLibrary("ole32", .{});
    windows_smoke.root_module.linkSystemLibrary("shell32", .{});
    windows_smoke.root_module.linkSystemLibrary("uuid", .{});
    windows_smoke.root_module.linkSystemLibrary("uiautomationcore", .{});
    windows_smoke.root_module.linkSystemLibrary("oleaut32", .{});
    windows_smoke.root_module.linkSystemLibrary("windowscodecs", .{});
    windows_smoke.root_module.link_libc = true;
    windows_smoke.root_module.link_libcpp = true;
    const install_windows_smoke = b.addInstallArtifact(windows_smoke, .{});
    b.step("windows-arm64-smoke", "Cross-compile Win32 ARM64 window with D3D11 clear and GDI fallback")
        .dependOn(&install_windows_smoke.step);
    const windows_font_smoke_root = b.createModule(.{
        .root_source_file = b.path("tools/windows_font_smoke.zig"),
        .target = windows_arm64,
        .optimize = optimize,
    });
    const windows_font_smoke = b.addExecutable(.{ .name = "zenit-windows-font-smoke", .root_module = windows_font_smoke_root });
    windows_font_smoke.root_module.addCSourceFile(.{ .file = b.path("native/windows/dwrite_bridge.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
    windows_font_smoke.root_module.linkSystemLibrary("dwrite", .{});
    windows_font_smoke.root_module.linkSystemLibrary("d2d1", .{});
    windows_font_smoke.root_module.linkSystemLibrary("ole32", .{});
    windows_font_smoke.root_module.linkSystemLibrary("windowscodecs", .{});
    windows_font_smoke.root_module.linkSystemLibrary("dxguid", .{});
    windows_font_smoke.root_module.linkSystemLibrary("user32", .{});
    windows_font_smoke.root_module.link_libc = true;
    b.step("windows-arm64-font-smoke", "Cross-compile DirectWrite discovery and measurement on ARM64")
        .dependOn(&b.addInstallArtifact(windows_font_smoke, .{}).step);
    const windows_drop_contract = b.addExecutable(.{ .name = "zenit-windows-drop-contract", .root_module = b.createModule(.{ .target = windows_arm64, .optimize = optimize }) });
    windows_drop_contract.root_module.addCSourceFile(.{ .file = b.path("native/windows/drop_bridge_tests.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
    for ([_][]const u8{ "ole32", "uuid", "user32", "shell32", "gdi32", "windowscodecs", "uiautomationcore", "oleaut32" }) |library| windows_drop_contract.root_module.linkSystemLibrary(library, .{});
    windows_drop_contract.root_module.link_libc = true;
    windows_drop_contract.root_module.link_libcpp = true;
    b.step("windows-arm64-drop-contract", "Cross-compile native OLE and accessibility snapshot robustness checks")
        .dependOn(&b.addInstallArtifact(windows_drop_contract, .{}).step);

    const d12_options = b.addOptions();
    d12_options.addOption([]const u8, "gpu_backend", "d3d12");
    d12_options.addOption(bool, "test_mode", false);
    const d12_gpu = b.createModule(.{ .root_source_file = b.path("src/gpu/gpu.zig"), .target = windows_arm64, .optimize = optimize });
    const d12_options_module = d12_options.createModule();
    d12_gpu.addImport("build_options", d12_options_module);
    const d12_contract_root = b.createModule(.{ .root_source_file = b.path("tools/windows_gpu_resources_contract.zig"), .target = windows_arm64, .optimize = optimize });
    d12_contract_root.addImport("gpu", d12_gpu);
    const gpu_contract_options = b.addOptions();
    const GpuContractScope = enum { all, sdf, other, app, resources, resources_core, resources_shared, bindings, buffer_arrays, atomic_probe_failure };
    gpu_contract_options.addOption(GpuContractScope, "scope", b.option(GpuContractScope, "windows-gpu-contract-scope", "Native GPU contracts: all, sdf, other, focused app, bindings, buffer_arrays, atomic_probe_failure, or resources (sdf + other cover all; resources_core + resources_shared = resources)") orelse .all);
    d12_contract_root.addOptions("contract_options", gpu_contract_options);
    const d12_text = b.createModule(.{ .root_source_file = b.path("src/text/text.zig"), .target = windows_arm64, .optimize = optimize });
    const d12_trace = b.createModule(.{ .root_source_file = b.path("src/trace/mod.zig"), .target = windows_arm64, .optimize = optimize });
    const d12_icon_ir = b.createModule(.{ .root_source_file = b.path("src/icon_ir.zig"), .target = windows_arm64, .optimize = optimize });
    const d12_svg_safety = b.createModule(.{ .root_source_file = b.path("src/svg_safety.zig"), .target = windows_arm64, .optimize = optimize });
    const d12_svg = b.createModule(.{ .root_source_file = b.path("src/render/svg.zig"), .target = windows_arm64, .optimize = optimize });
    d12_svg.addImport("icon_ir", d12_icon_ir);
    d12_svg.addImport("svg_safety", d12_svg_safety);
    const d12_render = b.createModule(.{ .root_source_file = b.path("src/render/render.zig"), .target = windows_arm64, .optimize = optimize });
    d12_render.addImport("gpu", d12_gpu);
    d12_render.addImport("text", d12_text);
    d12_render.addImport("trace", d12_trace);
    d12_render.addImport("icon_ir", d12_icon_ir);
    d12_render.addImport("svg_safety", d12_svg_safety);
    d12_render.addImport("svg", d12_svg);
    const d12_app_renderer = b.createModule(.{ .root_source_file = b.path("src/zenit_app/renderer.zig"), .target = windows_arm64, .optimize = optimize });
    d12_app_renderer.addImport("gpu", d12_gpu);
    d12_app_renderer.addImport("render", d12_render);
    d12_app_renderer.addImport("build_options", d12_options_module);
    d12_contract_root.addImport("app_renderer", d12_app_renderer);
    d12_contract_root.addImport("render", d12_render);
    d12_contract_root.addImport("text", d12_text);
    d12_contract_root.addImport("icon_ir", d12_icon_ir);
    const d12_contract = b.addExecutable(.{ .name = "zenit-windows-gpu-resources-contract", .root_module = d12_contract_root });
    // Its AppRenderer contracts construct whole renderers on the stack, like the apps.
    d12_contract.stack_size = windowsStackReserve(d12_contract.stack_size);
    d12_contract.root_module.addCSourceFile(.{ .file = b.path("native/windows/dwrite_bridge.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
    d12_contract.root_module.linkSystemLibrary("dwrite", .{});
    d12_contract.root_module.linkSystemLibrary("d2d1", .{});
    for ([_][]const u8{ "native/windows/d3d12_resources.cpp", "native/windows/d3d12_shader.cpp", "native/windows/d3d12_pipeline.cpp", "native/windows/d3d12_png.cpp", "native/windows/d3d12_resources_tests.cpp", "native/windows/d3d12_views_tests.cpp" }) |source|
        d12_contract.root_module.addCSourceFile(.{ .file = b.path(source), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti", "-DZENIT_D12_TEST=1" } });
    for ([_][]const u8{ "d3d12", "dcomp", "dwmapi", "gdi32", "dxgi", "dxguid", "uuid", "d3dcompiler_47", "user32", "ole32", "windowscodecs" }) |library| d12_contract.root_module.linkSystemLibrary(library, .{});
    d12_contract.root_module.link_libc = true;
    d12_contract.root_module.link_libcpp = true;
    const windows_gpu_fixture_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tools/windows_gpu_device_fixture.zig"),
        .target = b.graph.host,
    }) });
    const run_windows_gpu_fixtures = b.addRunArtifact(windows_gpu_fixture_tests);
    b.step("test-windows-gpu-fixtures", "Verify Windows GPU contract upload fixtures").dependOn(&run_windows_gpu_fixtures.step);
    const windows_gpu_contract_step = b.step("windows-arm64-gpu-resources-contract", "Cross-compile real D3D12 buffer upload/copy/readback contracts");
    windows_gpu_contract_step.dependOn(&b.addInstallArtifact(d12_contract, .{}).step);
    windows_gpu_contract_step.dependOn(&run_windows_gpu_fixtures.step);

    const system_sdk_module = b.createModule(.{
        .root_source_file = b.path("src/system_sdk/system_sdk.zig"),
        .target = target,
        .optimize = optimize,
    });
    system_sdk_module.addImport("platform", platform_module);

    const text_core_module = b.createModule(.{
        .root_source_file = b.path("src/text_core/text_core.zig"),
        .target = target,
        .optimize = optimize,
    });

    const trace_module = b.createModule(.{
        .root_source_file = b.path("src/trace/mod.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Public export (b.addModule), not private: consumers creating **custom business icons**
    // need a generated icon module to `@import("icon_ir")`, and it must be the exact same module
    // instance used inside ui, otherwise `icon_ir.Asset` becomes a distinct type at the boundary.
    // See tools/gen_svg_assets.zig for the custom icon pipeline; base_icon_id >= 2200 avoids
    // mask-cache key segments 0..16 and 1000..
    const icon_ir_module = b.addModule("icon_ir", .{
        .root_source_file = b.path("src/icon_ir.zig"),
        .target = target,
        .optimize = optimize,
    });
    const svg_safety_module = b.createModule(.{
        .root_source_file = b.path("src/svg_safety.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Minimal SVG rasterization module (root=src/render/svg.zig, depends only on std +
    // icon_ir + svg_safety, no gpu/text/metal). Consumers: ui module (custom bitmap cursor
    // Cx.setCustomCursor) and ui_core test root (imports core/tests.zig -> core.zig).
    // gen_svg_assets builds the same (see gen steps below).
    // Public export (b.addModule), not private: offline generators for **custom business icons**
    // must reuse **the same** module instance. Creating their own puts src/render/ files in two
    // modules ("file exists in modules" compile error); same reason as icon_ir
    // (type/instance uniqueness).
    const svg_raster_module = b.addModule("svg", .{
        .root_source_file = b.path("src/render/svg.zig"),
        .target = target,
        .optimize = optimize,
    });
    svg_raster_module.addImport("icon_ir", icon_ir_module);
    svg_raster_module.addImport("svg_safety", svg_safety_module);

    // Icon selection is a build-graph concern, never a source-tree rewrite.
    // Public consumers get Lucide by default. Internal path dependencies may
    // opt into the licensed Untitled catalog with `-Dicon-set=untitled` or by
    // forwarding `.@"icon-set" = "untitled"` through `b.dependency`.
    const icon_set_name = b.option(
        []const u8,
        "icon-set",
        "Built-in icon provider: lucide (public default) or untitled (internal checkout only)",
    ) orelse "lucide";
    const is_lucide = std.mem.eql(u8, icon_set_name, "lucide");
    const is_untitled = std.mem.eql(u8, icon_set_name, "untitled");
    if (!is_lucide and !is_untitled) {
        std.debug.print("invalid -Dicon-set={s} (expected 'lucide' or 'untitled')\n", .{icon_set_name});
        std.process.exit(1);
    }

    const icons_module = b.createModule(.{
        .root_source_file = b.path(if (is_lucide)
            "src/ui/icons_lucide_generated.zig"
        else
            "private/zenit-icons-untitled/icons_generated.zig"),
        .target = target,
        .optimize = optimize,
    });
    icons_module.addImport("icon_ir", icon_ir_module);

    const system_icons_module = b.createModule(.{
        .root_source_file = b.path(if (is_lucide)
            "src/ui/system_icons_lucide.zig"
        else
            "private/zenit-icons-untitled/system_icons.zig"),
        .target = target,
        .optimize = optimize,
    });
    system_icons_module.addImport("zenit_icons", icons_module);

    // ── gen-icons: offline SVG → icon_ir.Asset codegen ──────────────────────
    // svg.zig only deps on std + icon_ir, so we build a minimal `svg` module
    // for the generator (no gpu/text/metal pull-in). Output is committed.
    {
        const gen_svg_module = b.createModule(.{
            .root_source_file = b.path("src/render/svg.zig"),
            .target = target,
            .optimize = optimize,
        });
        gen_svg_module.addImport("icon_ir", icon_ir_module);
        gen_svg_module.addImport("svg_safety", svg_safety_module);

        const gen_mod = b.createModule(.{
            .root_source_file = b.path("tools/gen_svg_assets.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        });
        gen_mod.addImport("icon_ir", icon_ir_module);
        gen_mod.addImport("svg", gen_svg_module);

        const gen_exe = b.addExecutable(.{ .name = "gen_svg_assets", .root_module = gen_mod });

        const run_lucide = b.addRunArtifact(gen_exe);
        run_lucide.addArgs(&.{
            "src/ui/icons_oss",
            "src/ui/icons_lucide_generated.zig",
            "icons_oss/",
            "1000",
        });
        const fmt_lucide = b.addSystemCommand(&.{
            b.graph.zig_exe,
            "fmt",
            "src/ui/icons_lucide_generated.zig",
        });
        fmt_lucide.step.dependOn(&run_lucide.step);
        const gen_lucide_step = b.step(
            "gen-icons-lucide",
            "Regenerate the public Lucide icon module",
        );
        gen_lucide_step.dependOn(&fmt_lucide.step);

        const run_common = b.addRunArtifact(gen_exe);
        run_common.addArgs(&.{
            "src/ui/icons_common",
            "src/ui/icons_common_generated.zig",
            "icons_common/",
            "0",
        });
        const fmt_common = b.addSystemCommand(&.{
            b.graph.zig_exe,
            "fmt",
            "src/ui/icons_common_generated.zig",
        });
        fmt_common.step.dependOn(&run_common.step);
        const gen_common_step = b.step(
            "gen-icons-common",
            "Regenerate the public provider-neutral common icon module",
        );
        gen_common_step.dependOn(&fmt_common.step);

        const run_untitled = b.addRunArtifact(gen_exe);
        run_untitled.addArgs(&.{
            "private/zenit-icons-untitled/icons",
            "private/zenit-icons-untitled/icons_generated.zig",
            "icons/",
            "1000",
        });
        const fmt_untitled = b.addSystemCommand(&.{
            b.graph.zig_exe,
            "fmt",
            "private/zenit-icons-untitled/icons_generated.zig",
        });
        fmt_untitled.step.dependOn(&run_untitled.step);
        const gen_untitled_step = b.step(
            "gen-icons-untitled",
            "Regenerate the internal Untitled icon module",
        );
        gen_untitled_step.dependOn(&fmt_untitled.step);

        const gen_step = b.step(
            "gen-icons",
            "Regenerate the module selected by -Dicon-set (lucide by default)",
        );
        gen_step.dependOn(if (is_lucide) &fmt_lucide.step else &fmt_untitled.step);

        const gen_all_step = b.step(
            "gen-icons-all",
            "Regenerate both icon modules (internal checkout only)",
        );
        gen_all_step.dependOn(&fmt_lucide.step);
        gen_all_step.dependOn(&fmt_common.step);
        gen_all_step.dependOn(&fmt_untitled.step);
    }

    // ── gen-component-index: AST scan → DevTools goto-source table ──────────
    // Maps component_name → definition site so the DevTools Elements tree can
    // open a component's source in an editor. std-only (uses std.zig.Ast), so
    // the generator needs no module wiring. Output is committed.
    {
        const gen_mod = b.createModule(.{
            .root_source_file = b.path("tools/gen_component_index.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        });
        const gen_exe = b.addExecutable(.{ .name = "gen_component_index", .root_module = gen_mod });
        const run_gen = b.addRunArtifact(gen_exe);
        run_gen.addArgs(&.{
            "src/ui/component_index_generated.zig",
            "src/ui:zenit:src/ui",
        });
        const gen_step = b.step(
            "gen-component-index",
            "Regenerate src/ui/component_index_generated.zig by AST-scanning src/ui",
        );
        gen_step.dependOn(&run_gen.step);
    }

    // Phase 5: i18n basics (bidi UAX #9 + linebreak UAX #14 simplified)
    const i18n_module = b.createModule(.{
        .root_source_file = b.path("src/i18n/mod.zig"),
        .target = target,
        .optimize = optimize,
    });

    // wrap_map precise break rules reuse i18n.linebreak (UAX #14 pair table +
    // isCJK); kept in sync with text_layout.findLineBreak.
    text_core_module.addImport("i18n", i18n_module);

    // Bring the actual Zenit UI graph into Windows executables. All modules
    // share the selected Windows target (x86_64 or aarch64).
    const windows_i18n = b.createModule(.{ .root_source_file = b.path("src/i18n/mod.zig"), .target = windows_arm64, .optimize = optimize });
    const windows_text_core = b.createModule(.{ .root_source_file = b.path("src/text_core/text_core.zig"), .target = windows_arm64, .optimize = optimize });
    windows_text_core.addImport("i18n", windows_i18n);
    const windows_text = b.createModule(.{ .root_source_file = b.path("src/text/text.zig"), .target = windows_arm64, .optimize = optimize });
    windows_font_smoke_root.addImport("text", windows_text);
    const windows_fallback_stack = b.createModule(.{
        .root_source_file = b.path("src/render/font_fallback_stack.zig"),
        .target = windows_arm64,
        .optimize = optimize,
    });
    windows_fallback_stack.addImport("text", windows_text);
    windows_font_smoke_root.addImport("font_fallback_stack", windows_fallback_stack);
    const windows_trace = b.createModule(.{ .root_source_file = b.path("src/trace/mod.zig"), .target = windows_arm64, .optimize = optimize });
    const windows_icon_ir = if (export_windows_modules) icon_ir_module else b.createModule(.{ .root_source_file = b.path("src/icon_ir.zig"), .target = windows_arm64, .optimize = optimize });
    const windows_svg_safety = b.createModule(.{ .root_source_file = b.path("src/svg_safety.zig"), .target = windows_arm64, .optimize = optimize });
    const windows_svg = b.createModule(.{ .root_source_file = b.path("src/render/svg.zig"), .target = windows_arm64, .optimize = optimize });
    windows_svg.addImport("icon_ir", windows_icon_ir);
    windows_svg.addImport("svg_safety", windows_svg_safety);
    const windows_icons = b.createModule(.{ .root_source_file = b.path("src/ui/icons_lucide_generated.zig"), .target = windows_arm64, .optimize = optimize });
    windows_icons.addImport("icon_ir", windows_icon_ir);
    const windows_system_icons = b.createModule(.{ .root_source_file = b.path("src/ui/system_icons_lucide.zig"), .target = windows_arm64, .optimize = optimize });
    windows_system_icons.addImport("zenit_icons", windows_icons);
    const windows_ui = if (export_windows_modules)
        b.addModule("ui", .{ .root_source_file = b.path("src/ui/ui.zig"), .target = windows_arm64, .optimize = optimize })
    else
        b.createModule(.{ .root_source_file = b.path("src/ui/ui.zig"), .target = windows_arm64, .optimize = optimize });
    windows_ui.addImport("system_sdk", windows_smoke_sdk);
    windows_ui.addImport("icon_ir", windows_icon_ir);
    windows_ui.addImport("zenit_icons", windows_icons);
    windows_ui.addImport("zenit_system_icons", windows_system_icons);
    windows_ui.addImport("text_core", windows_text_core);
    windows_ui.addImport("trace", windows_trace);
    windows_ui.addImport("platform", windows_smoke_platform);
    windows_ui.addImport("i18n", windows_i18n);
    windows_ui.addImport("text", windows_text);
    windows_ui.addImport("svg_safety", windows_svg_safety);
    windows_ui.addImport("svg", windows_svg);
    // Shared UI and render commands must use identical text/icon module types.
    const d12_icons = b.createModule(.{ .root_source_file = b.path("src/ui/icons_lucide_generated.zig"), .target = windows_arm64, .optimize = optimize });
    d12_icons.addImport("icon_ir", d12_icon_ir);
    const d12_system_icons = b.createModule(.{ .root_source_file = b.path("src/ui/system_icons_lucide.zig"), .target = windows_arm64, .optimize = optimize });
    d12_system_icons.addImport("zenit_icons", d12_icons);
    const d12_ui = b.createModule(.{ .root_source_file = b.path("src/ui/ui.zig"), .target = windows_arm64, .optimize = optimize });
    d12_ui.addImport("system_sdk", windows_smoke_sdk);
    d12_ui.addImport("platform", windows_smoke_platform);
    d12_ui.addImport("text_core", windows_text_core);
    d12_ui.addImport("i18n", windows_i18n);
    d12_ui.addImport("text", d12_text);
    d12_ui.addImport("trace", d12_trace);
    d12_ui.addImport("icon_ir", d12_icon_ir);
    d12_ui.addImport("zenit_icons", d12_icons);
    d12_ui.addImport("zenit_system_icons", d12_system_icons);
    d12_ui.addImport("svg_safety", d12_svg_safety);
    d12_ui.addImport("svg", d12_svg);
    d12_contract_root.addImport("ui", d12_ui);
    windows_font_smoke_root.addImport("ui", windows_ui);
    const windows_ui_smoke_root = b.createModule(.{ .root_source_file = b.path("tools/windows_ui_smoke.zig"), .target = windows_arm64, .optimize = optimize });
    windows_ui_smoke_root.addImport("platform", windows_smoke_platform);
    windows_ui_smoke_root.addImport("system_sdk", windows_smoke_sdk);
    windows_ui_smoke_root.addImport("ui", windows_ui);
    windows_ui_smoke_root.addImport("text", windows_text);
    const windows_ui_smoke = b.addExecutable(.{ .name = "zenit-windows-ui-smoke", .root_module = windows_ui_smoke_root });
    windows_ui_smoke.root_module.addCSourceFile(.{ .file = b.path("native/windows/window_bridge.c"), .flags = &.{} });
    windows_ui_smoke.root_module.addCSourceFile(.{ .file = b.path("native/windows/recording_bridge.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
    windows_ui_smoke.root_module.linkSystemLibrary("mfuuid", .{});
    windows_ui_smoke.root_module.addCSourceFile(.{ .file = b.path("native/windows/file_dialog.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
    windows_ui_smoke.root_module.addCSourceFile(.{ .file = b.path("native/windows/drop_bridge.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
    windows_ui_smoke.root_module.addCSourceFile(.{ .file = b.path("native/windows/drag_data.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
    windows_ui_smoke.root_module.addCSourceFile(.{ .file = b.path("native/windows/drag_source.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
    windows_ui_smoke.root_module.addCSourceFile(.{ .file = b.path("native/windows/accessibility_bridge.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
    windows_ui_smoke.root_module.addCSourceFile(.{ .file = b.path("native/windows/d3d11_probe.c"), .flags = &.{"-O2"} });
    windows_ui_smoke.root_module.addCSourceFile(.{ .file = b.path("native/windows/d2d_composite.cpp"), .flags = windowsD2DFlags(b, b) });
    windows_ui_smoke.root_module.addCSourceFile(.{ .file = b.path("native/windows/dwrite_bridge.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
    for ([_][]const u8{ "user32", "dwmapi", "gdi32", "imm32", "d3d11", "d2d1", "dxgi", "dxguid", "dwrite", "ole32", "shell32", "uuid", "windowscodecs", "uiautomationcore", "oleaut32" }) |lib| windows_ui_smoke.root_module.linkSystemLibrary(lib, .{});
    windows_ui_smoke.root_module.link_libc = true;
    windows_ui_smoke.root_module.link_libcpp = true;
    b.step("windows-arm64-ui-probe", "Cross-compile the interactive Zenit UI probe on Windows ARM64")
        .dependOn(&b.addInstallArtifact(windows_ui_smoke, .{}).step);

    const d11_contract = b.addExecutable(.{ .name = "zenit-windows-d3d11-contract", .root_module = b.createModule(.{ .root_source_file = b.path("tools/windows_d3d11_contract.zig"), .target = windows_arm64, .optimize = optimize, .link_libc = true, .link_libcpp = true }) });
    for ([_][]const u8{ "native/windows/d3d11_backend.cpp", "native/windows/d3d11_renderer_tests.cpp" }) |source|
        d11_contract.root_module.addCSourceFile(.{ .file = b.path(source), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
    for ([_][]const u8{ "d3d11", "dcomp", "dwmapi", "gdi32", "dxgi", "dxguid", "uuid", "d3dcompiler_47" }) |lib| d11_contract.root_module.linkSystemLibrary(lib, .{});
    b.step("windows-d3d11-contract", "Build native D3D11 hardware resource acceptance").dependOn(installWindowsExecutable(b, d11_contract));

    // The public Windows App uses the Direct2D paint-table subset. Other
    // legacy AppRenderer exports still compile against the Null GPU.
    const windows_app_opts = b.addOptions();
    windows_app_opts.addOption(bool, "test_mode", test_mode);
    windows_app_opts.addOption(u16, "e2e_port", e2e_port);
    windows_app_opts.addOption([]const u8, "gpu_backend", if (std.mem.eql(u8, gpu_backend, "d3d12") or std.mem.eql(u8, gpu_backend, "d3d11")) gpu_backend else "null");
    const windows_app_opts_module = windows_app_opts.createModule();
    const windows_gpu = b.createModule(.{ .root_source_file = b.path("src/gpu/gpu.zig"), .target = windows_arm64, .optimize = optimize });
    windows_gpu.addImport("build_options", windows_app_opts_module);
    const windows_render = b.createModule(.{ .root_source_file = b.path("src/render/render.zig"), .target = windows_arm64, .optimize = optimize });
    windows_render.addImport("gpu", windows_gpu);
    windows_render.addImport("text", windows_text);
    windows_render.addImport("trace", windows_trace);
    windows_render.addImport("icon_ir", windows_icon_ir);
    windows_render.addImport("svg_safety", windows_svg_safety);
    windows_render.addImport("svg", windows_svg);
    const windows_test_harness = b.createModule(.{ .root_source_file = b.path("src/test_harness/mod.zig"), .target = windows_arm64, .optimize = optimize });
    windows_test_harness.addImport("ui", windows_ui);
    windows_test_harness.addImport("build_options", windows_app_opts_module);
    const windows_app = if (export_windows_modules)
        b.addModule("zenit_app", .{ .root_source_file = b.path("src/zenit_app/app.zig"), .target = windows_arm64, .optimize = optimize })
    else
        b.createModule(.{ .root_source_file = b.path("src/zenit_app/app.zig"), .target = windows_arm64, .optimize = optimize });
    windows_app.addImport("gpu", windows_gpu);
    windows_app.addImport("render", windows_render);
    windows_app.addImport("ui", windows_ui);
    windows_app.addImport("system_sdk", windows_smoke_sdk);
    windows_app.addImport("platform", windows_smoke_platform);
    windows_app.addImport("text", windows_text);
    windows_app.addImport("test_harness", windows_test_harness);
    windows_app.addImport("build_options", windows_app_opts_module);
    // Optimize native GPU command encoding independently of the app mode.
    // Use -Dnative-debug=true for unoptimized C++ with UBSan.
    const native_debug = b.option(bool, "native-debug", "Compile the Windows GPU backend C++ unoptimized, with UBSan (debugging it)") orelse false;
    const gpu_cpp_flags: []const []const u8 = if (native_debug)
        &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" }
    else
        &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti", "-O2", "-fno-sanitize=undefined" };
    if (std.mem.eql(u8, gpu_backend, "d3d12")) {
        for ([_][]const u8{ "native/windows/d3d12_resources.cpp", "native/windows/d3d12_shader.cpp", "native/windows/d3d12_pipeline.cpp", "native/windows/d3d12_png.cpp" }) |source|
            windows_app.addCSourceFile(.{ .file = b.path(source), .flags = gpu_cpp_flags });
        for ([_][]const u8{ "d3d12", "dcomp", "dwmapi", "gdi32", "dxgi", "d3dcompiler_47", "windowscodecs" }) |lib| windows_app.linkSystemLibrary(lib, .{});
    }

    windows_ui_smoke_root.addImport("zenit_app", windows_app);
    if (std.mem.eql(u8, gpu_backend, "d3d11")) {
        for ([_][]const u8{ "native/windows/d3d11_backend.cpp", "native/windows/d3d12_png.cpp" }) |source|
            windows_app.addCSourceFile(.{ .file = b.path(source), .flags = gpu_cpp_flags });
        for ([_][]const u8{ "d3d11", "dcomp", "dxgi", "d3dcompiler_47", "windowscodecs" }) |lib| windows_app.linkSystemLibrary(lib, .{});
    }
    const windows_app_gate_root = b.createModule(.{ .root_source_file = b.path("tools/windows_app_gate.zig"), .target = windows_arm64, .optimize = optimize });
    windows_app_gate_root.addImport("zenit_app", windows_app);
    const windows_app_gate = b.addExecutable(.{ .name = "zenit-windows-app-gate", .root_module = windows_app_gate_root });
    windows_app_gate.root_module.addCSourceFile(.{ .file = b.path("native/windows/window_bridge.c"), .flags = &.{} });
    windows_app_gate.root_module.addCSourceFile(.{ .file = b.path("native/windows/recording_bridge.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
    windows_app_gate.root_module.linkSystemLibrary("mfuuid", .{});
    windows_app_gate.root_module.addCSourceFile(.{ .file = b.path("native/windows/file_dialog.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
    windows_app_gate.root_module.addCSourceFile(.{ .file = b.path("native/windows/drop_bridge.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
    windows_app_gate.root_module.addCSourceFile(.{ .file = b.path("native/windows/drag_data.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
    windows_app_gate.root_module.addCSourceFile(.{ .file = b.path("native/windows/drag_source.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
    windows_app_gate.root_module.addCSourceFile(.{ .file = b.path("native/windows/accessibility_bridge.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
    windows_app_gate.root_module.addCSourceFile(.{ .file = b.path("native/windows/d3d11_probe.c"), .flags = &.{"-O2"} });
    windows_app_gate.root_module.addCSourceFile(.{ .file = b.path("native/windows/d2d_composite.cpp"), .flags = windowsD2DFlags(b, b) });
    windows_app_gate.root_module.addCSourceFile(.{ .file = b.path("native/windows/dwrite_bridge.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
    for ([_][]const u8{ "user32", "dwmapi", "gdi32", "imm32", "d3d11", "d2d1", "dxgi", "dwrite", "dxguid", "ole32", "shell32", "uuid", "windowscodecs", "uiautomationcore", "oleaut32" }) |lib| windows_app_gate.root_module.linkSystemLibrary(lib, .{});
    windows_app_gate.root_module.link_libc = true;
    windows_app_gate.root_module.link_libcpp = true;
    b.step("windows-arm64-app-gate", "Cross-compile the pixel-producing public Zenit App entry point on Windows ARM64")
        .dependOn(&b.addInstallArtifact(windows_app_gate, .{}).step);

    const windows_input_example_root = b.createModule(.{ .root_source_file = b.path("examples/text_input/main.zig"), .target = windows_arm64, .optimize = optimize });
    windows_input_example_root.addImport("ui", windows_ui);
    windows_input_example_root.addImport("zenit_app", windows_app);
    const windows_input_example = b.addExecutable(.{ .name = "zenit-windows-text-input", .root_module = windows_input_example_root });
    windows_input_example.root_module.addCSourceFile(.{ .file = b.path("native/windows/window_bridge.c"), .flags = &.{} });
    windows_input_example.root_module.addCSourceFile(.{ .file = b.path("native/windows/recording_bridge.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
    windows_input_example.root_module.linkSystemLibrary("mfuuid", .{});
    windows_input_example.root_module.addCSourceFile(.{ .file = b.path("native/windows/file_dialog.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
    windows_input_example.root_module.addCSourceFile(.{ .file = b.path("native/windows/drop_bridge.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
    windows_input_example.root_module.addCSourceFile(.{ .file = b.path("native/windows/drag_data.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
    windows_input_example.root_module.addCSourceFile(.{ .file = b.path("native/windows/drag_source.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
    windows_input_example.root_module.addCSourceFile(.{ .file = b.path("native/windows/accessibility_bridge.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
    windows_input_example.root_module.addCSourceFile(.{ .file = b.path("native/windows/d3d11_probe.c"), .flags = &.{"-O2"} });
    windows_input_example.root_module.addCSourceFile(.{ .file = b.path("native/windows/d2d_composite.cpp"), .flags = windowsD2DFlags(b, b) });
    windows_input_example.root_module.addCSourceFile(.{ .file = b.path("native/windows/dwrite_bridge.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
    for ([_][]const u8{ "user32", "dwmapi", "gdi32", "imm32", "d3d11", "d2d1", "dxgi", "dwrite", "dxguid", "ole32", "shell32", "uuid", "windowscodecs", "uiautomationcore", "oleaut32" }) |lib| windows_input_example.root_module.linkSystemLibrary(lib, .{});
    windows_input_example.root_module.link_libc = true;
    windows_input_example.root_module.link_libcpp = true;
    b.step("windows-arm64-text-input", "Cross-compile the Zenit text_input example as a Win32 ARM64 app")
        .dependOn(installWindowsExecutable(b, windows_input_example));

    const windows_render_gallery_root = b.createModule(.{ .root_source_file = b.path("tools/windows_render_gallery.zig"), .target = windows_arm64, .optimize = optimize });
    windows_render_gallery_root.addImport("ui", windows_ui);
    windows_render_gallery_root.addImport("render", windows_render);
    windows_render_gallery_root.addImport("text", windows_text);
    windows_render_gallery_root.addImport("zenit_app", windows_app);
    const windows_render_gallery = b.addExecutable(.{ .name = "zenit-windows-render-gallery", .root_module = windows_render_gallery_root });
    windows_render_gallery.root_module.addCSourceFile(.{ .file = b.path("native/windows/window_bridge.c"), .flags = &.{"-DZENIT_WINDOW_CONTRACT=1"} });
    windows_render_gallery.root_module.addCSourceFile(.{ .file = b.path("native/windows/recording_bridge.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
    windows_render_gallery.root_module.linkSystemLibrary("mfuuid", .{});
    windows_render_gallery.root_module.addCSourceFile(.{ .file = b.path("native/windows/file_dialog.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
    windows_render_gallery.root_module.addCSourceFile(.{ .file = b.path("native/windows/drop_bridge.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
    windows_render_gallery.root_module.addCSourceFile(.{ .file = b.path("native/windows/drag_data.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
    windows_render_gallery.root_module.addCSourceFile(.{ .file = b.path("native/windows/drag_source.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
    windows_render_gallery.root_module.addCSourceFile(.{ .file = b.path("native/windows/accessibility_bridge.cpp"), .flags = &.{ "-DZENIT_WINDOW_CONTRACT=1", "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
    windows_render_gallery.root_module.addCSourceFile(.{ .file = b.path("native/windows/d3d11_probe.c"), .flags = &.{ "-O2", "-DZENIT_PAINT_CONTRACT=1" } });
    windows_render_gallery.root_module.addCSourceFile(.{ .file = b.path("native/windows/d2d_composite.cpp"), .flags = windowsD2DFlags(b, b) });
    windows_render_gallery.root_module.addCSourceFile(.{ .file = b.path("native/windows/dwrite_bridge.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
    for ([_][]const u8{ "user32", "dwmapi", "gdi32", "imm32", "d3d11", "d2d1", "dxgi", "dwrite", "dxguid", "ole32", "shell32", "uuid", "windowscodecs", "uiautomationcore", "oleaut32" }) |lib| windows_render_gallery.root_module.linkSystemLibrary(lib, .{});
    windows_render_gallery.root_module.link_libc = true;
    windows_render_gallery.root_module.link_libcpp = true;
    b.step("windows-arm64-render-gallery", "Cross-compile the Windows image rendering regression fixture")
        .dependOn(installWindowsExecutable(b, windows_render_gallery));

    const windows_storybook_root = b.createModule(.{ .root_source_file = b.path("examples/storybook/main.zig"), .target = windows_arm64, .optimize = optimize });
    windows_storybook_root.addImport("ui", windows_ui);
    windows_storybook_root.addImport("zenit_app", windows_app);
    const windows_storybook = b.addExecutable(.{ .name = "zenit-windows-storybook", .root_module = windows_storybook_root });
    // Debug renderer initialization uses large value temporaries. Windows' default
    // executable stack is too small; reserve address space (not committed RAM).
    for ([_]*std.Build.Step.Compile{ windows_storybook, windows_input_example, windows_render_gallery }) |exe| {
        exe.stack_size = windowsStackReserve(exe.stack_size);
    }
    windows_storybook.root_module.addCSourceFile(.{ .file = b.path("native/windows/window_bridge.c"), .flags = &.{} });
    windows_storybook.root_module.addCSourceFile(.{ .file = b.path("native/windows/recording_bridge.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
    windows_storybook.root_module.linkSystemLibrary("mfuuid", .{});
    windows_storybook.root_module.addCSourceFile(.{ .file = b.path("native/windows/file_dialog.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
    windows_storybook.root_module.addCSourceFile(.{ .file = b.path("native/windows/drop_bridge.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
    windows_storybook.root_module.addCSourceFile(.{ .file = b.path("native/windows/drag_data.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
    windows_storybook.root_module.addCSourceFile(.{ .file = b.path("native/windows/drag_source.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
    windows_storybook.root_module.addCSourceFile(.{ .file = b.path("native/windows/accessibility_bridge.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
    windows_storybook.root_module.addCSourceFile(.{ .file = b.path("native/windows/d3d11_probe.c"), .flags = &.{"-O2"} });
    windows_storybook.root_module.addCSourceFile(.{ .file = b.path("native/windows/d2d_composite.cpp"), .flags = windowsD2DFlags(b, b) });
    windows_storybook.root_module.addCSourceFile(.{ .file = b.path("native/windows/dwrite_bridge.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
    for ([_][]const u8{ "user32", "dwmapi", "gdi32", "imm32", "d3d11", "d2d1", "dxgi", "dwrite", "dxguid", "ole32", "shell32", "uuid", "windowscodecs", "uiautomationcore", "oleaut32" }) |lib| windows_storybook.root_module.linkSystemLibrary(lib, .{});
    windows_storybook.root_module.link_libc = true;
    windows_storybook.root_module.link_libcpp = true;
    b.step("windows-arm64-storybook", "Cross-compile the shared Storybook and DevTools on Windows ARM64")
        .dependOn(installWindowsExecutable(b, windows_storybook));

    const windows_chrome_root = b.createModule(.{ .root_source_file = b.path("examples/window_chrome/main.zig"), .target = windows_arm64, .optimize = optimize });
    windows_chrome_root.addImport("ui", windows_ui);
    windows_chrome_root.addImport("zenit_app", windows_app);
    const windows_chrome = b.addExecutable(.{ .name = "zenit-windows-window-chrome", .root_module = windows_chrome_root });
    windows_chrome.stack_size = windowsStackReserve(windows_chrome.stack_size);
    windows_chrome.root_module.addCSourceFile(.{ .file = b.path("native/windows/window_bridge.c"), .flags = &.{} });
    windows_chrome.root_module.addCSourceFile(.{ .file = b.path("native/windows/recording_bridge.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
    windows_chrome.root_module.linkSystemLibrary("mfuuid", .{});
    windows_chrome.root_module.addCSourceFile(.{ .file = b.path("native/windows/file_dialog.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
    windows_chrome.root_module.addCSourceFile(.{ .file = b.path("native/windows/drop_bridge.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
    windows_chrome.root_module.addCSourceFile(.{ .file = b.path("native/windows/drag_data.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
    windows_chrome.root_module.addCSourceFile(.{ .file = b.path("native/windows/drag_source.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
    windows_chrome.root_module.addCSourceFile(.{ .file = b.path("native/windows/accessibility_bridge.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
    windows_chrome.root_module.addCSourceFile(.{ .file = b.path("native/windows/d3d11_probe.c"), .flags = &.{"-O2"} });
    windows_chrome.root_module.addCSourceFile(.{ .file = b.path("native/windows/d2d_composite.cpp"), .flags = windowsD2DFlags(b, b) });
    windows_chrome.root_module.addCSourceFile(.{ .file = b.path("native/windows/dwrite_bridge.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
    for ([_][]const u8{ "user32", "dwmapi", "gdi32", "imm32", "d3d11", "d2d1", "dxgi", "dwrite", "dxguid", "ole32", "shell32", "uuid", "windowscodecs", "uiautomationcore", "oleaut32" }) |lib| windows_chrome.root_module.linkSystemLibrary(lib, .{});
    windows_chrome.root_module.link_libc = true;
    windows_chrome.root_module.link_libcpp = true;
    b.step("windows-window-chrome", "Cross-compile the shared Storybook and DevTools on Windows ARM64")
        .dependOn(&b.addInstallArtifact(windows_chrome, .{}).step);
    const windows_window_root = b.createModule(.{ .root_source_file = b.path("examples/adaptive_window/main.zig"), .target = windows_arm64, .optimize = optimize });
    windows_window_root.addImport("ui", windows_ui);
    windows_window_root.addImport("zenit_app", windows_app);
    const windows_window = b.addExecutable(.{ .name = "zenit-windows-adaptive-window", .root_module = windows_window_root });
    windows_window.stack_size = windowsStackReserve(windows_window.stack_size);
    windows_window.root_module.addCSourceFile(.{ .file = b.path("native/windows/window_bridge.c"), .flags = &.{} });
    windows_window.root_module.addCSourceFile(.{ .file = b.path("native/windows/recording_bridge.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
    windows_window.root_module.linkSystemLibrary("mfuuid", .{});
    windows_window.root_module.addCSourceFile(.{ .file = b.path("native/windows/file_dialog.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
    windows_window.root_module.addCSourceFile(.{ .file = b.path("native/windows/drop_bridge.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
    windows_window.root_module.addCSourceFile(.{ .file = b.path("native/windows/drag_data.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
    windows_window.root_module.addCSourceFile(.{ .file = b.path("native/windows/drag_source.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
    windows_window.root_module.addCSourceFile(.{ .file = b.path("native/windows/accessibility_bridge.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
    windows_window.root_module.addCSourceFile(.{ .file = b.path("native/windows/d3d11_probe.c"), .flags = &.{"-O2"} });
    windows_window.root_module.addCSourceFile(.{ .file = b.path("native/windows/d2d_composite.cpp"), .flags = windowsD2DFlags(b, b) });
    windows_window.root_module.addCSourceFile(.{ .file = b.path("native/windows/dwrite_bridge.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });
    for ([_][]const u8{ "user32", "dwmapi", "gdi32", "imm32", "d3d11", "d2d1", "dxgi", "dwrite", "dxguid", "ole32", "shell32", "uuid", "windowscodecs", "uiautomationcore", "oleaut32" }) |lib| windows_window.root_module.linkSystemLibrary(lib, .{});
    windows_window.root_module.link_libc = true;
    windows_window.root_module.link_libcpp = true;
    b.step("windows-adaptive-window", "Build the platform-adaptive window example")
        .dependOn(&b.addInstallArtifact(windows_window, .{}).step);

    // i18n unit tests
    const i18n_test_module = b.createModule(.{
        .root_source_file = b.path("src/i18n/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    const i18n_tests = b.addTest(.{ .root_module = i18n_test_module });
    const run_i18n_tests = b.addRunArtifact(i18n_tests);
    const i18n_test_step = b.step("test-i18n", "Run i18n module tests");
    i18n_test_step.dependOn(&run_i18n_tests.step);

    const bidi_conformance_module = b.createModule(.{
        .root_source_file = b.path("tools/bidi_conformance.zig"),
        .target = b.graph.host,
        .optimize = .safe,
    });
    const bidi_conformance_i18n_module = b.createModule(.{
        .root_source_file = b.path("src/i18n/mod.zig"),
        .target = b.graph.host,
        .optimize = .safe,
    });
    bidi_conformance_module.addImport("i18n", bidi_conformance_i18n_module);
    const bidi_conformance = b.addExecutable(.{
        .name = "bidi-conformance",
        .root_module = bidi_conformance_module,
    });
    const run_bidi_conformance = b.addRunArtifact(bidi_conformance);
    run_bidi_conformance.addFileArg(b.path("vendor/unicode/17.0.0/BidiTest.txt"));
    run_bidi_conformance.addFileArg(b.path("vendor/unicode/17.0.0/BidiCharacterTest.txt"));
    const bidi_conformance_step = b.step(
        "test-bidi-conformance",
        "Run complete Unicode 17.0.0 UAX #9 conformance data",
    );
    bidi_conformance_step.dependOn(&run_bidi_conformance.step);

    // Cross-platform tests (macOS / Linux / Windows)
    const system_sdk_test_module = b.createModule(.{
        .root_source_file = b.path("src/system_sdk/system_sdk.zig"),
        .target = target,
        .optimize = optimize,
    });
    system_sdk_test_module.addImport("platform", platform_module);
    const system_sdk_tests = b.addTest(.{
        .root_module = system_sdk_test_module,
    });
    const run_system_sdk_tests = b.addRunArtifact(system_sdk_tests);
    const system_sdk_test_step = b.step("test-system-sdk", "Run system SDK tests");
    system_sdk_test_step.dependOn(&run_system_sdk_tests.step);

    const windows_sdk_test_root = b.createModule(.{
        .root_source_file = b.path("src/system_sdk/windows_test.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    windows_sdk_test_root.addImport("platform", b.createModule(.{
        .root_source_file = b.path("src/platform.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    }));
    const windows_sdk_tests = b.addTest(.{ .root_module = windows_sdk_test_root });
    const run_windows_sdk_tests = b.addRunArtifact(windows_sdk_tests);
    b.step("test-windows-sdk-unit", "Run Windows SDK mock event tests on the host")
        .dependOn(&run_windows_sdk_tests.step);

    if (target.result.os.tag == .macos) {
        const capability_matrix_module = b.createModule(.{
            .root_source_file = b.path("tools/macos_capability_matrix.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        });
        capability_matrix_module.addImport("system_sdk", system_sdk_module);
        const capability_matrix = b.addExecutable(.{
            .name = "macos-capability-matrix",
            .root_module = capability_matrix_module,
        });
        addMacOSWindowBridge(b, capability_matrix);
        addImageBridge(b, capability_matrix);
        const run_capability_matrix = b.addRunArtifact(capability_matrix);
        const capability_matrix_step = b.step("capability-matrix", "Print generated macOS capability truth matrix");
        capability_matrix_step.dependOn(&run_capability_matrix.step);
    }

    // System SDK cross-target compile verification (build only)
    const cross_check_step = b.step("check-system-sdk-cross", "Compile System SDK tests for Linux/Windows (no run)");
    inline for (.{
        .{ .arch = std.Target.Cpu.Arch.x86_64, .os = std.Target.Os.Tag.linux, .abi = std.Target.Abi.gnu },
        .{ .arch = std.Target.Cpu.Arch.x86_64, .os = std.Target.Os.Tag.windows, .abi = std.Target.Abi.gnu },
    }) |t| {
        const cross_target = b.resolveTargetQuery(.{
            .cpu_arch = t.arch,
            .os_tag = t.os,
            .abi = t.abi,
        });
        const cross_platform_module = b.createModule(.{
            .root_source_file = b.path("src/platform.zig"),
            .target = cross_target,
            .optimize = .debug,
        });
        const cross_test_module = b.createModule(.{
            .root_source_file = b.path("src/system_sdk/system_sdk.zig"),
            .target = cross_target,
            .optimize = .debug,
        });
        cross_test_module.addImport("platform", cross_platform_module);
        const cross_tests = b.addTest(.{
            .root_module = cross_test_module,
        });
        cross_check_step.dependOn(&cross_tests.step);
    }

    // Reactive system tests (platform-independent)
    const reactive_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = twins.path("src/ui/reactive.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_reactive_tests = b.addRunArtifact(reactive_tests);
    const reactive_test_step = b.step("test-reactive", "Run reactive system tests");
    reactive_test_step.dependOn(&run_reactive_tests.step);

    // text_core unit tests
    const text_core_test_module = b.createModule(.{
        .root_source_file = b.path("src/text_core/text_core.zig"),
        .target = target,
        .optimize = optimize,
    });
    text_core_test_module.addImport("i18n", i18n_module);
    const text_core_tests = b.addTest(.{
        .root_module = text_core_test_module,
    });
    const run_text_core_tests = b.addRunArtifact(text_core_tests);
    const text_core_test_step = b.step("test-text-core", "Run text_core module tests");
    text_core_test_step.dependOn(&run_text_core_tests.step);

    // text module test root. Tests without an addTest entry never run.
    // MUST point the root to font_catalog.zig, not text.zig: text.zig is a re-export, and Zig
    // does not recursively collect test blocks in imported files unless refAllDecls. Pointing
    // to text.zig finishes in ~3ms with no tests executed; a suspiciously fast run signals
    // incomplete coverage.
    const text_test_module = b.createModule(.{
        .root_source_file = b.path("src/text/font_catalog.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (target.result.os.tag != .macos and target.result.os.tag != .windows) addFreeTypeLibs(text_test_module);
    const text_tests = b.addTest(.{ .root_module = text_test_module });
    if (target.result.os.tag == .macos) {
        // font_catalog uses CoreText bridge; without linking it's undefined symbols.
        text_tests.root_module.addCSourceFile(.{
            .file = b.path("native/macos/coretext_bridge.m"),
            .flags = macosNativeFlags(b, b),
        });
        for ([_][]const u8{
            "Foundation", "CoreText", "CoreGraphics", "CoreFoundation", "AppKit",
        }) |fw| text_tests.root_module.linkFramework(fw, .{});
        text_tests.root_module.link_libc = true;
    }
    const run_text_tests = b.addRunArtifact(text_tests);
    const text_test_step = b.step("test-text", "Run text module tests (font catalog / weights)");
    text_test_step.dependOn(&run_text_tests.step);

    const text_oracle_module = b.createModule(.{
        .root_source_file = b.path("tools/text_coordinate_oracle.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    text_oracle_module.addImport("text_core", text_core_module);
    const text_oracle = b.addExecutable(.{
        .name = "text-coordinate-oracle",
        .root_module = text_oracle_module,
    });
    const run_text_oracle = b.addRunArtifact(text_oracle);
    const text_oracle_step = b.step("text-corpus-dump", "Print the committed T0 text coordinate corpus");
    text_oracle_step.dependOn(&run_text_oracle.step);

    const text_property_module = b.createModule(.{
        .root_source_file = b.path("tools/text_coordinate_property.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    text_property_module.addImport("text_core", text_core_module);
    const text_property = b.addExecutable(.{
        .name = "text-coordinate-property",
        .root_module = text_property_module,
    });
    const run_text_property = b.addRunArtifact(text_property);
    const text_property_step = b.step("test-text-properties", "Run deterministic seedable text coordinate property tests");
    text_property_step.dependOn(&run_text_property.step);

    // Canonical token values, shared by providers and the renderer.
    const style_values_module = b.addModule("zenit_style_values", .{
        .root_source_file = b.path("src/tokens/style_values.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Token tools run on the host, even when their generated provider targets
    // a different architecture. Keep a separate canonical host module graph.
    const token_values_host = b.createModule(.{ .root_source_file = b.path("src/tokens/style_values.zig"), .target = b.graph.host });
    const preset_fixture = b.createModule(.{ .root_source_file = b.path("tests/tokens/preset_fixture.zig"), .target = b.graph.host });
    preset_fixture.addImport("zenit_style_values", token_values_host);
    const token_model = b.createModule(.{ .root_source_file = b.path("src/tokens/model.zig"), .target = b.graph.host });
    token_model.addImport("zenit_style_values", token_values_host);
    const token_resolver = b.createModule(.{ .root_source_file = b.path("src/tokens/resolve.zig"), .target = b.graph.host });
    token_resolver.addImport("token_model", token_model);
    const token_emitter = b.createModule(.{ .root_source_file = b.path("src/tokens/emit.zig"), .target = b.graph.host });
    token_emitter.addImport("token_model", token_model);
    const token_cli = b.createModule(.{ .root_source_file = b.path("tools/tokens.zig"), .target = b.graph.host });
    token_cli.addImport("token_resolver", token_resolver);
    token_cli.addImport("token_emitter", token_emitter);
    token_cli.addImport("token_model", token_model);
    const token_exe = b.addExecutable(.{ .name = "zenit-tokens", .root_module = token_cli });
    b.installArtifact(token_exe);
    const token_run = b.addRunArtifact(token_exe);
    token_run.addPassthruArgs();
    b.step("tokens", "Check, generate or explain a Design System theme JSON").dependOn(&token_run.step);
    const default_theme_run = b.addRunArtifact(token_exe);
    default_theme_run.addArgs(&.{"generate"});
    default_theme_run.addFileArg(b.path("src/tokens/default.json"));
    default_theme_run.addArg("--out");
    const default_theme_src = default_theme_run.addOutputFileArg("theme.gen.zig");
    const default_theme = b.createModule(.{ .root_source_file = default_theme_src, .target = target, .optimize = optimize });
    default_theme.addImport("zenit_style_values", style_values_module);
    // The Windows UI module graphs (windows_ui / d12_ui) consume the same token
    // values and generated default theme, compiled for the Windows target.
    const windows_style_values = b.createModule(.{ .root_source_file = b.path("src/tokens/style_values.zig"), .target = windows_arm64, .optimize = optimize });
    const windows_default_theme = b.createModule(.{ .root_source_file = default_theme_src, .target = windows_arm64, .optimize = optimize });
    windows_default_theme.addImport("zenit_style_values", windows_style_values);
    for ([_]*std.Build.Module{ windows_ui, d12_ui }) |module| {
        module.addImport("zenit_style_values", windows_style_values);
        module.addImport("zenit_theme_provider", windows_default_theme);
    }
    const example_theme_run = b.addRunArtifact(token_exe);
    example_theme_run.addArgs(&.{"generate"});
    example_theme_run.addFileArg(b.path("examples/theme.json"));
    example_theme_run.addArg("--out");
    const example_theme = b.createModule(.{ .root_source_file = example_theme_run.addOutputFileArg("theme.gen.zig"), .target = target, .optimize = optimize });
    example_theme.addImport("zenit_style_values", style_values_module);
    const test_tokens = b.step("test-tokens", "Test token validation, generated providers, default material values and allocation failures");
    const token_tests_module = b.createModule(.{ .root_source_file = b.path("tests/tokens/resolve_tests.zig"), .target = b.graph.host });
    token_tests_module.addImport("token_resolver", token_resolver);
    token_tests_module.addImport("token_model", token_model);
    token_tests_module.addImport("token_emitter", token_emitter);
    const token_tests = b.addTest(.{ .root_module = token_tests_module });
    test_tokens.dependOn(&b.addRunArtifact(token_tests).step);
    const emitter_tests_module = b.createModule(.{ .root_source_file = b.path("tests/tokens/emit_tests.zig"), .target = b.graph.host });
    emitter_tests_module.addImport("token_model", token_model);
    emitter_tests_module.addImport("token_emitter", token_emitter);
    test_tokens.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = emitter_tests_module })).step);
    const preset_tests = b.addTest(.{ .root_module = preset_fixture });
    test_tokens.dependOn(&b.addRunArtifact(preset_tests).step);
    const generated_tests_module = b.createModule(.{ .root_source_file = b.path("tests/tokens/provider_tests.zig"), .target = b.graph.host });
    generated_tests_module.addImport("zenit_style_values", token_values_host);
    generated_tests_module.addImport("preset_fixture", preset_fixture);
    for ([_][]const u8{ "example", "edge", "empty", "default" }) |fixture| {
        const run = b.addRunArtifact(token_exe);
        run.addArg("generate");
        run.addFileArg(b.path(if (std.mem.eql(u8, fixture, "example")) "docs/design-system/theme.example.json" else if (std.mem.eql(u8, fixture, "default")) "src/tokens/default.json" else b.fmt("tests/tokens/{s}.json", .{fixture})));
        run.addArg("--out");
        const out = run.addOutputFileArg("theme.gen.zig");
        const generated = b.createModule(.{ .root_source_file = out, .target = b.graph.host });
        generated.addImport("zenit_style_values", token_values_host);
        generated_tests_module.addImport(fixture, generated);
    }
    test_tokens.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = generated_tests_module })).step);
    const token_type_error = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/tokens/type_error.zig"), .target = b.graph.host }) });
    token_type_error.root_module.addImport("example", generated_tests_module.import_table.get("example").?);
    token_type_error.expect_errors = .{ .contains = "expected type 'theme.gen.spaceToken', found 'theme.gen.colorToken'" };
    test_tokens.dependOn(&token_type_error.step);

    // Keep the editor dependency's build graph isolated: ZLS is compiled only
    // when its explicit tooling step runs. Always use this build's Zig binary.
    const zls_name = if (b.graph.host.result.os.tag == .windows) "zenit-zls.exe" else "zenit-zls";
    const zls_build = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "-Doptimize=safe", "-Dversion-string=0.17.0-dev+zenit", "--prefix" });
    const zls_output = zls_build.addOutputDirectoryArg("zls");
    zls_build.setCwd(b.path("vendor/zls"));
    zls_build.has_side_effects = true;
    const zls_binary = zls_output.path(b, if (b.graph.host.result.os.tag == .windows) "bin/zls.exe" else "bin/zls");
    const zls_install = b.addInstallFileWithDir(zls_binary, .bin, zls_name);
    zls_install.step.dependOn(&zls_build.step);
    b.step("zls", "Build the pinned Zig 0.17 ZLS dependency").dependOn(&zls_install.step);
    const zls_tests = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "test", "test-build-system", "-Doptimize=debug", "-Dversion-string=0.17.0-dev+zenit", "--summary", "all" });
    zls_tests.setCwd(b.path("vendor/zls"));
    zls_tests.has_side_effects = true;
    b.step("test-zls", "Test pinned ZLS and real Zig 0.17 build protocol").dependOn(&zls_tests.step);

    // yix-lsp: .yix language server (delegates to ZLS; see docs/YIX_EDITOR.md)
    const yix_lsp_module = b.createModule(.{ .root_source_file = b.path("tools/yix_lsp.zig"), .target = b.graph.host, .optimize = optimize });
    yix_lsp_module.addImport("yix_compiler", yix_compiler_module);
    // .yss token completion/hover uses theme.json (shares token tool parser)
    yix_lsp_module.addImport("token_resolver", token_resolver);
    yix_lsp_module.addImport("token_model", token_model);
    const yix_lsp_exe = b.addExecutable(.{ .name = "yix-lsp", .root_module = yix_lsp_module });
    b.installArtifact(yix_lsp_exe);
    const install_yix_lsp = b.addInstallArtifact(yix_lsp_exe, .{});
    const yix_lsp_step = b.step("yix-lsp", "Build Yix language server and pinned ZLS");
    yix_lsp_step.dependOn(&install_yix_lsp.step);
    yix_lsp_step.dependOn(&zls_install.step);
    b.step("dev-tools", "Build development language servers").dependOn(yix_lsp_step);
    const yix_lsp_tests = b.addRunArtifact(b.addTest(.{ .root_module = yix_lsp_module }));
    // E2E: pinned ZLS + scripted client;
    // excludes test-headless
    const yix_lsp_smoke = b.addSystemCommand(&.{ "python3", "tests/yix/lsp/smoke.py" });
    yix_lsp_smoke.addArtifactArg(yix_lsp_exe);
    yix_lsp_smoke.setCwd(b.path("."));
    yix_lsp_smoke.has_side_effects = true;
    yix_lsp_smoke.step.dependOn(&zls_install.step);
    yix_lsp_smoke.addFileArg(zls_binary);
    yix_lsp_smoke.setEnvironmentVariable("PATH", b.fmt("{s}{s}{s}", .{ std.fs.path.dirname(b.graph.zig_exe).?, if (b.graph.host.result.os.tag == .windows) ";" else ":", b.graph.environ_map.get("PATH") orelse "" }));
    b.step("yix-lsp-smoke", "End-to-end yix-lsp check against a real ZLS (hover / definition / completion / diagnostics)").dependOn(&yix_lsp_smoke.step);
    const yix_test_module = b.createModule(.{ .root_source_file = b.path("tests/yix/compiler_tests.zig"), .target = b.graph.host });
    yix_test_module.addImport("yix_compiler", yix_compiler_module);
    const yix_compiler_tests = b.addTest(.{ .root_module = yix_test_module });
    const run_yix_compiler_tests = b.addRunArtifact(yix_compiler_tests);
    run_yix_compiler_tests.setCwd(b.path(".")); // consistency tests read src/ui/view.zig
    b.step("test-yix-compiler", "Test YIX/YSS compilation and diagnostics").dependOn(&run_yix_compiler_tests.step);
    const test_yix_step = b.step("test-yix", "Test Yix compilation, golden output and generated UI behavior");
    test_yix_step.dependOn(&run_yix_compiler_tests.step);
    test_yix_step.dependOn(&yix_lsp_tests.step);
    // Deterministic protocol regressions use a ZLS stub, so no installed ZLS is required.
    const yix_lsp_versions = b.addSystemCommand(&.{ "python3", "tests/yix/lsp/review_versions.py" });
    yix_lsp_versions.addArtifactArg(yix_lsp_exe);
    yix_lsp_versions.setCwd(b.path("."));
    yix_lsp_versions.has_side_effects = true;
    test_yix_step.dependOn(&yix_lsp_versions.step);
    const yix_lsp_exit = b.addSystemCommand(&.{ "python3", "tests/yix/lsp/exit_lifecycle.py" });
    yix_lsp_exit.addArtifactArg(yix_lsp_exe);
    yix_lsp_exit.setCwd(b.path("."));
    yix_lsp_exit.has_side_effects = true;
    test_yix_step.dependOn(&yix_lsp_exit.step);
    const yix_zls_selection = b.addSystemCommand(&.{ "python3", "tests/yix/lsp/zls_selection.py" });
    yix_zls_selection.addArtifactArg(yix_lsp_exe);
    yix_zls_selection.has_side_effects = true;
    test_yix_step.dependOn(&yix_zls_selection.step);
    const yix_cli_output = b.addSystemCommand(&.{ "python3", "tests/yix/cli_output.py" });
    yix_cli_output.addArtifactArg(yix_exe);
    yix_cli_output.setCwd(b.path("."));
    yix_cli_output.has_side_effects = true;
    test_yix_step.dependOn(&yix_cli_output.step);

    const yix_cli_tests = b.addRunArtifact(b.addTest(.{ .root_module = yix_exe.root_module }));
    yix_cli_tests.setCwd(b.path("."));
    test_yix_step.dependOn(&yix_cli_tests.step);

    const evidence_validator_module = b.createModule(.{
        .root_source_file = b.path("tools/evidence_manifest_validator.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    const evidence_validator = b.addExecutable(.{
        .name = "evidence-manifest-validator",
        .root_module = evidence_validator_module,
    });
    const run_evidence_validator = b.addRunArtifact(evidence_validator);
    run_evidence_validator.addPassthruArgs();
    const evidence_validator_step = b.step("evidence-validate", "Validate a gate evidence manifest and its status invariants");
    evidence_validator_step.dependOn(&run_evidence_validator.step);

    const release_candidate_validator_module = b.createModule(.{
        .root_source_file = b.path("tools/release_candidate_validator.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    const release_candidate_validator = b.addExecutable(.{
        .name = "release-candidate-validator",
        .root_module = release_candidate_validator_module,
    });
    const run_release_candidate_validator = b.addRunArtifact(release_candidate_validator);
    run_release_candidate_validator.addPassthruArgs();
    const release_candidate_validator_step = b.step(
        "release-candidate-validate",
        "Fail closed unless the complete clean-revision macOS candidate matrix is present",
    );
    release_candidate_validator_step.dependOn(&run_release_candidate_validator.step);

    // Application graph shared by macOS Metal and Linux Vulkan.
    if (target.result.os.tag == .macos or target.result.os.tag == .linux) {
        const gpu_module = b.createModule(.{
            .root_source_file = b.path("src/gpu/gpu.zig"),
            .target = target,
            .optimize = optimize,
        });
        gpu_module.addImport("build_options", build_options_module);
        if (target.result.os.tag == .linux) gpu_module.addImport("vulkan_ui_shaders", ui_shaders_module);

        const render_module = b.createModule(.{
            .root_source_file = b.path("src/render/render.zig"),
            .target = target,
            .optimize = optimize,
        });
        render_module.addImport("gpu", gpu_module);
        render_module.addImport("text", text_module);
        render_module.addImport("trace", trace_module);
        render_module.addImport("icon_ir", icon_ir_module);
        render_module.addImport("svg_safety", svg_safety_module);
        // svg: module dependency, not relative imports. svg.zig is independent
        // module root; relative imports cause "file exists in modules" error.
        // Downstream generators reuse this structure.
        render_module.addImport("svg", svg_raster_module);

        // Use addModule not createModule: allows downstream consumers to fetch via
        // dep.module("ui") / dep.module("zenit_app"). Other internal modules
        // (gpu / render / system_sdk / text) remain private.
        const ui_module = b.addModule("ui", .{
            .root_source_file = twins.path("src/ui/ui.zig"),
            .target = target,
            .optimize = optimize,
        });
        ui_module.addImport("zenit_style_values", style_values_module);
        ui_module.addImport("zenit_theme_provider", default_theme);
        ui_module.addImport("system_sdk", system_sdk_module);
        ui_module.addImport("icon_ir", icon_ir_module);
        ui_module.addImport("zenit_icons", icons_module);
        ui_module.addImport("zenit_system_icons", system_icons_module);
        ui_module.addImport("text_core", text_core_module);
        ui_module.addImport("trace", trace_module);
        ui_module.addImport("platform", platform_module);
        ui_module.addImport("i18n", i18n_module);
        // v0.5 §5: cx.shapeText calls text.TextShaper.shape() for GlyphRun;
        // ShapingCache replaces ASCII-first measure path. ui_module must expose
        // text module (CoreText/HarfBuzz bridge); all consumers (ui_test,
        // ui_core_tests, bench, app) link text + CoreText bridge.
        ui_module.addImport("text", text_module);
        ui_module.addImport("svg_safety", svg_safety_module);
        // Custom bitmap cursors: ui/core.zig rasterizes SVG to RGBA via
        // svg.rasterize, passes to system_sdk.
        ui_module.addImport("svg", svg_raster_module);

        // .yss schema (properties / enum values / default theme tokens) generated
        // from ui style type reflection and committed. Shared with .yss compiler
        // and yix-lsp. gen-yss-schema regenerates; check-yss-schema verifies
        // (included in test-headless).
        const yss_schema_exe = b.addExecutable(.{ .name = "yss-schema", .root_module = b.createModule(.{ .root_source_file = b.path("tools/yss_schema.zig"), .target = target, .optimize = .debug }) });
        yss_schema_exe.root_module.addImport("ui", ui_module);
        const yss_schema_args = [_][]const u8{ "src/yix/style_schema_generated.zig", "src/ui/core/types.zig", "src/ui/core/builders.zig" };
        const gen_yss_schema_run = b.addRunArtifact(yss_schema_exe);
        gen_yss_schema_run.setCwd(b.path("."));
        gen_yss_schema_run.addArg("gen");
        gen_yss_schema_run.addArgs(&yss_schema_args);
        gen_yss_schema_run.has_side_effects = true;
        b.step("gen-yss-schema", "Regenerate src/yix/style_schema_generated.zig from the ui style types").dependOn(&gen_yss_schema_run.step);
        const check_yss_schema_run = b.addRunArtifact(yss_schema_exe);
        check_yss_schema_run.setCwd(b.path("."));
        check_yss_schema_run.addArg("check");
        check_yss_schema_run.addArgs(&yss_schema_args);
        check_yss_schema_run.has_side_effects = true;
        b.step("check-yss-schema", "Fail when src/yix/style_schema_generated.zig is stale relative to the ui style types").dependOn(&check_yss_schema_run.step);

        const example_ui = cloneModule(b, ui_module);
        wireThemeProvider(example_ui, example_theme);
        const yix_counter_module = b.createModule(.{ .root_source_file = twins.path("examples/yix_counter/_counter.yix.zig"), .target = target, .optimize = optimize });
        yix_counter_module.addImport("ui", example_ui);
        const yix_runtime_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = twins.path("tests/yix/runtime_tests.zig"), .target = target, .optimize = optimize }) });
        yix_runtime_tests.root_module.addImport("ui", example_ui);
        // Example yix_counter outside test dir (uses named module); sibling
        // stories import twins directly.
        yix_runtime_tests.root_module.addImport("yix_counter", yix_counter_module);
        addCoreTextBridge(b, yix_runtime_tests);
        const run_yix_runtime_tests = b.addRunArtifact(yix_runtime_tests);
        test_yix_step.dependOn(&run_yix_runtime_tests.step);

        const css_errors_step = b.step("test-css-errors", "Check object recipe compile-time diagnostics");
        const css_error_cases = .{
            .{ "duplicate_color_alias", "ui.css: .color and .text_color name the same property; specify only one" },
            .{ "cva_unknown_compound", "ui.cva .compound: no variant .missing" },
            .{ "cva_nested_compound_condition", "ui.cva .compound: condition ._focus cannot be nested inside another condition" },
            .{ "recipe_text_condition", "ui.cva / ui.sva on text: conditions apply to boxes; use a variant for text state" },
            .{ "recipe_text_layout", "ui.css: a text style has no field .padding (layout fields such as .gap / .padding belong on a box)" },
            .{ "recipe_text_derived", "ui.sva on text: derived supplies box geometry; omit this text slot from derived" },
            .{ "token_wrong_category", "ui.css: expected space token, got color" },
            .{ "typography_on_box", "ui.css: a box style has no field .typography" },
            .{ "sva_unknown_slot", "ui.sva: undeclared slot .missing" },
            .{ "sva_unknown_default", "ui.sva .defaults: no variant .missing" },
            .{ "sva_unknown_compound", "ui.sva .compound: no variant .missing" },
            .{ "sva_duplicate_slot", "ui.sva: duplicate slot .root" },
            .{ "box_disabled_no_state", "ui.view: the style uses condition ._disabled (YSS :disabled), but this element gives it no state; set a11y.disabled or state={.{ .disabled = … }} (bool or a bool source) on the element" },
            .{ "template_attrs_shadow", "Yix template: the component also declares a parameter .style, but `style` on a component element is applied to its root node, so the parameter can never be set from a template. Rename the component parameter" },
            .{ "icon_color_and_tint", "ui.view.icon: the style sets icon-color and the element also has tint=; give the icon color in one place" },
            .{ "text_when_box_fields", "ui.view.text: v.when(…) on text can only switch text fields; put conditional box fields (padding, background …) in box=" },
            .{ "transition_unknown_word", "transition \"background quik ease-out\": `quik` is neither a duration (200ms, 0.2s, a duration token such as fast) nor an easing" },
            .{ "parts_missing_dimension", "ui.view.slotParts: missing dimension .size — give every dimension of the recipe (write the default explicitly)" },
            .{ "signal_mutable_slice", "a signal / Model of a mutable slice []u8 is not supported; use []const u8 (the signal keeps its own copy)" },
            .{ "text_child_reactive_label", "Yix: this component takes its text as the `label` parameter, which needs static text; use label={source} for reactive text" },
            .{ "event_prop_literal", "Yix: .on_click of this component is an event; give it a statement such as `{save()}` or `{n += 1}`, not a literal value" },
            .{ "value_prop_statement", "Yix: .block of this component takes a value, not an event; pass a value expression (statements like `x = 1` or `save()` only go to Handler parameters)" },
        };
        inline for (css_error_cases) |c| {
            const negative = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/css_errors/" ++ c[0] ++ ".zig"), .target = target, .optimize = optimize }) });
            negative.root_module.addImport("ui", ui_module);
            negative.expect_errors = .{ .contains = c[1] };
            addCoreTextBridge(b, negative);
            css_errors_step.dependOn(&negative.step);
        }

        // E2E test harness module (linked into app when test_mode=true)
        const test_harness_module = b.createModule(.{
            .root_source_file = b.path("src/test_harness/mod.zig"),
            .target = target,
            .optimize = optimize,
        });
        test_harness_module.addImport("ui", ui_module);
        test_harness_module.addImport("build_options", build_options_module);

        const app_module = b.addModule("zenit_app", .{
            .root_source_file = b.path("src/zenit_app/app.zig"),
            .target = target,
            .optimize = optimize,
        });
        app_module.addImport("gpu", gpu_module);
        app_module.addImport("render", render_module);
        app_module.addImport("ui", ui_module);
        app_module.addImport("system_sdk", system_sdk_module);
        app_module.addImport("platform", platform_module);
        app_module.addImport("text", text_module);
        app_module.addImport("test_harness", test_harness_module);
        app_module.addImport("build_options", build_options_module);

        const example_harness = cloneModule(b, test_harness_module);
        example_harness.addImport("ui", example_ui);
        const example_app = cloneModule(b, app_module);
        example_app.addImport("ui", example_ui);
        example_app.addImport("test_harness", example_harness);

        // GPU abstraction tests
        const gpu_test_module = b.createModule(.{
            .root_source_file = b.path("src/gpu/gpu.zig"),
            .target = target,
            .optimize = optimize,
        });
        gpu_test_module.addImport("build_options", build_options_module);
        const gpu_tests = b.addTest(.{ .root_module = gpu_test_module });
        const run_gpu_tests = b.addRunArtifact(gpu_tests);
        const gpu_test_step = b.step("test-gpu", "Run GPU abstraction tests");
        gpu_test_step.dependOn(&run_gpu_tests.step);

        // render module tests (damage-rect prescan and CPU-only tests).
        // SEPARATE root module required: addCSourceFile/linkFramework forward to the root;
        // reusing render_module injects the bridge .m twice into storybook etc.
        // (duplicate symbol error).
        const render_test_module = b.createModule(.{
            .root_source_file = b.path("src/render/render.zig"),
            .target = target,
            .optimize = optimize,
        });
        render_test_module.addImport("gpu", gpu_module);
        render_test_module.addImport("text", text_module);
        render_test_module.addImport("trace", trace_module);
        render_test_module.addImport("icon_ir", icon_ir_module);
        render_test_module.addImport("svg_safety", svg_safety_module);
        // svg module dependency same as render_module (icon_renderer imports svg)
        render_test_module.addImport("svg", svg_raster_module);
        const render_tests = b.addTest(.{ .root_module = render_test_module });
        addCoreTextBridge(b, render_tests);
        render_tests.root_module.addCSourceFile(.{
            .file = b.path("native/macos/metal_bridge.m"),
            .flags = macosNativeFlags(b, b),
        });
        render_tests.root_module.linkFramework("Metal", .{});
        render_tests.root_module.linkFramework("QuartzCore", .{});
        const run_render_tests = b.addRunArtifact(render_tests);
        const render_test_step = b.step("test-render", "Run render module tests");
        render_test_step.dependOn(&run_render_tests.step);

        const lcd_validation = b.addExecutable(.{
            .name = "zenit-text-dual-source-validation",
            .root_module = b.createModule(.{ .root_source_file = b.path("tools/windows_dual_source_validation_test.zig"), .target = b.graph.host, .optimize = .debug, .link_libc = true, .link_libcpp = true }),
        });
        lcd_validation.root_module.addCSourceFile(.{ .file = b.path("tools/windows_dual_source_validation_test.cpp"), .flags = &.{ "-std=c++17", "-DZENIT_TEST_ZIG_ENTRY=1" } });
        const run_lcd_validation = b.addRunArtifact(lcd_validation);
        b.step("test-text-dual-source", "Validate LCD secondary shader signatures on the host").dependOn(&run_lcd_validation.step);
        render_test_step.dependOn(&run_lcd_validation.step);

        // Live-device Metal integration tests are a separate infrastructure
        // contract. They must never be hidden as SkipZigTest/no-op cases inside
        // the deterministic developer suite.
        const metal_preflight_module = b.createModule(.{
            .root_source_file = b.path("tools/metal_preflight.zig"),
            .target = target,
            .optimize = optimize,
        });
        metal_preflight_module.addImport("gpu", gpu_module);
        const metal_preflight = b.addExecutable(.{
            .name = "metal-preflight",
            .root_module = metal_preflight_module,
        });
        metal_preflight.root_module.addCSourceFile(.{
            .file = b.path("native/macos/metal_bridge.m"),
            .flags = macosNativeFlags(b, b),
        });
        metal_preflight.root_module.linkFramework("Metal", .{});
        metal_preflight.root_module.linkFramework("QuartzCore", .{});
        metal_preflight.root_module.linkFramework("Foundation", .{});
        metal_preflight.root_module.linkFramework("CoreFoundation", .{});
        const run_metal_preflight = b.addRunArtifact(metal_preflight);

        const metal_integration_module = b.createModule(.{
            .root_source_file = b.path("src/render/metal_integration_tests.zig"),
            .target = target,
            .optimize = optimize,
        });
        metal_integration_module.addImport("gpu", gpu_module);
        metal_integration_module.addImport("text", text_module);
        metal_integration_module.addImport("trace", trace_module);
        const metal_integration_tests = b.addTest(.{
            .name = "metal-integration-tests",
            .root_module = metal_integration_module,
        });
        addCoreTextBridge(b, metal_integration_tests);
        metal_integration_tests.root_module.addCSourceFile(.{
            .file = b.path("native/macos/metal_bridge.m"),
            .flags = macosNativeFlags(b, b),
        });
        metal_integration_tests.root_module.addCSourceFile(.{
            .file = b.path("native/macos/tests/fractional_drawable.m"),
            .flags = &.{"-fobjc-arc"},
        });
        metal_integration_tests.root_module.linkFramework("Cocoa", .{});
        metal_integration_tests.root_module.linkFramework("Metal", .{});
        metal_integration_tests.root_module.linkFramework("QuartzCore", .{});
        const run_metal_integration_tests = b.addRunArtifact(metal_integration_tests);
        if (b.option([]const u8, "glass-evidence-dir", "Export offscreen glass material QA images during test-metal")) |dir| {
            run_metal_integration_tests.setEnvironmentVariable("ZENIT_GLASS_EVIDENCE_DIR", dir);
        }
        if (b.option([]const u8, "glass-reference-shader", "Saved glass Metal shader for before/after material QA")) |path| {
            run_metal_integration_tests.setEnvironmentVariable("ZENIT_GLASS_REFERENCE_SHADER", path);
        }
        run_metal_integration_tests.step.dependOn(&run_metal_preflight.step);
        const metal_integration_step = b.step("test-metal", "Run tests that require a live Metal device");
        metal_integration_step.dependOn(&run_metal_integration_tests.step);

        // UI tests (with system_sdk + text_core + trace + icon_ir)
        const ui_test_module = b.createModule(.{
            .root_source_file = twins.path("src/ui/ui.zig"),
            .target = target,
            .optimize = optimize,
        });
        ui_test_module.addImport("system_sdk", system_sdk_module);
        ui_test_module.addImport("icon_ir", icon_ir_module);
        ui_test_module.addImport("zenit_icons", icons_module);
        ui_test_module.addImport("zenit_system_icons", system_icons_module);
        ui_test_module.addImport("zenit_style_values", style_values_module);
        ui_test_module.addImport("zenit_theme_provider", default_theme);
        ui_test_module.addImport("text_core", text_core_module);
        ui_test_module.addImport("trace", trace_module);
        ui_test_module.addImport("i18n", i18n_module);
        ui_test_module.addImport("platform", platform_module);
        ui_test_module.addImport("text", text_module); // v0.5 §5 GlyphRun pipeline
        ui_test_module.addImport("svg_safety", svg_safety_module);
        // zig build test-ui -Dtest-filter=<substring> runs only matching tests;
        // full run ~10 min. Omit for all tests.
        const ui_test_filter = b.option([]const u8, "test-filter", "Only run test-ui/test-ui-core tests whose name contains this substring");
        const ui_tests = b.addTest(.{
            .root_module = ui_test_module,
            .filters = if (ui_test_filter) |f| b.dupeStrings(&.{f}) else &.{},
        });
        // v0.5 §5: cx.shapeText calls TextShaper -> CoreText bridge; test
        // target links.
        addCoreTextBridge(b, ui_tests);
        const run_ui_tests = b.addRunArtifact(ui_tests);
        const ui_test_step = b.step("test-ui", "Run UI system tests");
        ui_test_step.dependOn(&run_ui_tests.step);

        // ui_core integration tests (src/ui/core/tests.zig), cx-mount tests.
        // Separate test target: root = src/ui/tests_root.zig (imports core/tests.zig); tests.zig
        // uses relative paths to core.zig + components/. The file must be imported from a root or
        // its tests never compile.
        const ui_core_tests_root = b.createModule(.{
            .root_source_file = twins.path("src/ui/tests_root.zig"),
            .target = target,
            .optimize = optimize,
        });
        ui_core_tests_root.addImport("system_sdk", system_sdk_module);
        ui_core_tests_root.addImport("icon_ir", icon_ir_module);
        ui_core_tests_root.addImport("zenit_icons", icons_module);
        ui_core_tests_root.addImport("zenit_system_icons", system_icons_module);
        ui_core_tests_root.addImport("zenit_style_values", style_values_module);
        ui_core_tests_root.addImport("zenit_theme_provider", default_theme);
        ui_core_tests_root.addImport("text_core", text_core_module);
        ui_core_tests_root.addImport("trace", trace_module);
        ui_core_tests_root.addImport("i18n", i18n_module);
        ui_core_tests_root.addImport("platform", platform_module);
        ui_core_tests_root.addImport("text", text_module); // v0.5 §5 GlyphRun pipeline
        ui_core_tests_root.addImport("svg_safety", svg_safety_module);
        ui_core_tests_root.addImport("svg", svg_raster_module); // core.zig (via tests.zig) needs
        const ui_core_tests = b.addTest(.{
            .root_module = ui_core_tests_root,
            .filters = if (ui_test_filter) |f| b.dupeStrings(&.{f}) else &.{},
        });
        // v0.5 §5: cx.shapeText calls TextShaper -> CoreText bridge; test
        // target links.
        addCoreTextBridge(b, ui_core_tests);
        const run_ui_core_tests = b.addRunArtifact(ui_core_tests);
        const ui_core_tests_step = b.step("test-ui-core", "Run ui_core integration tests (src/ui/core/tests.zig)");
        ui_core_tests_step.dependOn(&run_ui_core_tests.step);

        // OOM transaction campaign is a named gate instead of an accidental
        // side effect of the broad suite. Each target enumerates allocator
        // failure points and asserts rollback/commit invariants at a distinct
        // production boundary.
        const allocation_reactive_module = b.createModule(.{
            .root_source_file = twins.path("src/ui/reactive.zig"),
            .target = target,
            .optimize = optimize,
        });
        const allocation_reactive_tests = b.addTest(.{
            .name = "allocation-campaign-reactive",
            .root_module = allocation_reactive_module,
            .filters = &.{"allocation campaign:"},
        });
        const run_allocation_reactive = b.addRunArtifact(allocation_reactive_tests);

        const allocation_ui_module = b.createModule(.{
            .root_source_file = twins.path("src/ui/ui.zig"),
            .target = target,
            .optimize = optimize,
        });
        allocation_ui_module.addImport("system_sdk", system_sdk_module);
        allocation_ui_module.addImport("icon_ir", icon_ir_module);
        allocation_ui_module.addImport("zenit_icons", icons_module);
        allocation_ui_module.addImport("zenit_system_icons", system_icons_module);
        allocation_ui_module.addImport("zenit_style_values", style_values_module);
        allocation_ui_module.addImport("zenit_theme_provider", default_theme);
        allocation_ui_module.addImport("text_core", text_core_module);
        allocation_ui_module.addImport("trace", trace_module);
        allocation_ui_module.addImport("i18n", i18n_module);
        allocation_ui_module.addImport("platform", platform_module);
        allocation_ui_module.addImport("text", text_module);
        allocation_ui_module.addImport("svg_safety", svg_safety_module);
        const allocation_ui_tests = b.addTest(.{
            .name = "allocation-campaign-ui",
            .root_module = allocation_ui_module,
            .filters = &.{"allocation campaign:"},
        });
        addCoreTextBridge(b, allocation_ui_tests);
        const run_allocation_ui = b.addRunArtifact(allocation_ui_tests);

        const allocation_core_module = b.createModule(.{
            .root_source_file = twins.path("src/ui/tests_root.zig"),
            .target = target,
            .optimize = optimize,
        });
        allocation_core_module.addImport("system_sdk", system_sdk_module);
        allocation_core_module.addImport("icon_ir", icon_ir_module);
        allocation_core_module.addImport("zenit_icons", icons_module);
        allocation_core_module.addImport("zenit_system_icons", system_icons_module);
        allocation_core_module.addImport("zenit_style_values", style_values_module);
        allocation_core_module.addImport("zenit_theme_provider", default_theme);
        allocation_core_module.addImport("text_core", text_core_module);
        allocation_core_module.addImport("trace", trace_module);
        allocation_core_module.addImport("i18n", i18n_module);
        allocation_core_module.addImport("platform", platform_module);
        allocation_core_module.addImport("text", text_module);
        allocation_core_module.addImport("svg_safety", svg_safety_module);
        const allocation_core_tests = b.addTest(.{
            .name = "allocation-campaign-core",
            .root_module = allocation_core_module,
            .filters = &.{"allocation campaign:"},
        });
        addCoreTextBridge(b, allocation_core_tests);
        const run_allocation_core = b.addRunArtifact(allocation_core_tests);

        const allocation_campaign_step = b.step(
            "test-allocation-campaign",
            "Sweep allocator failure points across transactional framework boundaries",
        );
        allocation_campaign_step.dependOn(&run_allocation_reactive.step);
        allocation_campaign_step.dependOn(&run_allocation_ui.step);
        allocation_campaign_step.dependOn(&run_allocation_core.step);

        // Timing ring: GPU perf gate stats. renderer.zig pulls Metal/ObjC
        // bridges (can't enter normal test target), so percentile logic isolated
        // in timing_ring.zig. Separate target ensures gate math is actually tested.
        const timing_ring_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/zenit_app/timing_ring.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        const run_timing_ring_tests = b.addRunArtifact(timing_ring_tests);
        const timing_ring_test_step = b.step("test-timing-ring", "Run frame timing ring tests");
        timing_ring_test_step.dependOn(&run_timing_ring_tests.step);

        const window_lifecycle_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/zenit_app/window_lifecycle.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        const run_window_lifecycle_tests = b.addRunArtifact(window_lifecycle_tests);
        const window_lifecycle_test_step = b.step(
            "test-window-lifecycle",
            "Run deterministic multi-window lifecycle and routing tests",
        );
        window_lifecycle_test_step.dependOn(&run_window_lifecycle_tests.step);
        // Owned-window placement is pure geometry shared by every backend.
        const owned_window_tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("src/platform/owned_window.zig"),
            .target = target,
            .optimize = optimize,
        }) });
        window_lifecycle_test_step.dependOn(&b.addRunArtifact(owned_window_tests).step);

        // Process-level text hook stack (multi-app: closing window doesn't
        // tear down other apps' measure hooks). runtime.zig pulls Metal/ObjC
        // bridges; logic isolated in separate file for testing.
        const text_hook_owner_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/zenit_app/text_hook_owners.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        const run_text_hook_owner_tests = b.addRunArtifact(text_hook_owner_tests);
        const text_hook_owner_test_step = b.step(
            "test-text-hook-owners",
            "Run process-wide text hook ownership stack tests",
        );
        text_hook_owner_test_step.dependOn(&run_text_hook_owner_tests.step);

        const selector_scale_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/zenit_app/selector_scale.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        const run_selector_scale_tests = b.addRunArtifact(selector_scale_tests);
        const selector_scale_test_step = b.step(
            "test-selector-scale",
            "Run HiDPI FontSelector scale propagation tests",
        );
        selector_scale_test_step.dependOn(&run_selector_scale_tests.step);

        // The generic System SDK test root does not force analysis of the
        // macOS backend's private helpers/tests. Keep a dedicated root so
        // native input ordering regressions are part of the headless gate.
        const system_sdk_backend_test_module = b.createModule(.{
            .root_source_file = b.path("src/system_sdk/backends_tests.zig"),
            .target = target,
            .optimize = optimize,
        });
        system_sdk_backend_test_module.addImport("platform", platform_module);
        const system_sdk_backend_tests = b.addTest(.{
            .root_module = system_sdk_backend_test_module,
        });
        const run_system_sdk_backend_tests = b.addRunArtifact(system_sdk_backend_tests);
        const system_sdk_backend_test_step = b.step(
            "test-system-sdk-backends",
            "Run deterministic native backend tests",
        );
        system_sdk_backend_test_step.dependOn(&run_system_sdk_backend_tests.step);

        // Deterministic suite: must run without a live Metal device or WindowServer. `test` remains
        // a
        // convenient local alias; `test-all` adds the explicit live-device contract.
        // Covers test_harness (file-RPC owner lock etc.) and http_server tests.
        // WARNING: must be a **separate module**, cannot reuse test_harness_module:
        // addCoreTextBridge uses addCSourceFile, and C sources on modules **propagate to**
        // executables depending on it. zenit_app depends on test_harness_module, so hello_button
        // etc.
        // would link coretext_bridge.m twice (32 duplicate symbols). Create a separate module for
        // tests, with C sources only on this path.
        const harness_test_module = b.createModule(.{
            .root_source_file = b.path("src/test_harness/mod.zig"),
            .target = target,
            .optimize = optimize,
        });
        harness_test_module.addImport("ui", ui_module);
        harness_test_module.addImport("build_options", build_options_module);
        // svg.zig: 10 tests were orphan. Module imported by render/ui
        // (would show compile errors), but no addTest root => never executed.
        // 1840-line SVG parser handling external input without test coverage is
        // release risk.
        const svg_test_module = b.createModule(.{
            .root_source_file = b.path("src/render/svg.zig"),
            .target = target,
            .optimize = optimize,
        });
        svg_test_module.addImport("icon_ir", icon_ir_module);
        svg_test_module.addImport("svg_safety", svg_safety_module);
        const svg_tests = b.addTest(.{ .root_module = svg_test_module });
        const run_svg_tests = b.addRunArtifact(svg_tests);
        const svg_test_step = b.step("test-svg", "Run SVG parser/rasterizer tests");
        svg_test_step.dependOn(&run_svg_tests.step);

        const harness_tests = b.addTest(.{ .root_module = harness_test_module });
        // command_executor.zig tests pull CoreText extern symbols via
        // ui -> text; missing link causes undefined symbols. Were orphan tests.
        addCoreTextBridge(b, harness_tests);
        const run_harness_tests = b.addRunArtifact(harness_tests);
        const harness_test_step = b.step("test-harness", "Run test_harness (file-RPC) tests");
        harness_test_step.dependOn(&run_harness_tests.step);

        // Two tests found by orphan scan: bundle Info.plist rendering
        // (build-time code used only by build.zig), zenit_app module root
        // refAllDecls (no test target rooted it before).
        const info_plist_tests = b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/system_sdk/bundle/info_plist.zig"), .target = b.graph.host }) }));
        const app_tests_exe = b.addTest(.{ .root_module = cloneModule(b, app_module) });
        addMacOSNativeLibs(b, app_tests_exe);
        const app_tests = b.addRunArtifact(app_tests_exe);
        const app_test_step = b.step("test-app", "Run zenit_app module tests and the bundle Info.plist tests");
        app_test_step.dependOn(&info_plist_tests.step);
        app_test_step.dependOn(&app_tests.step);

        const test_headless_step = b.step("test-headless", "Run deterministic tests (no live Metal device required)");
        const pe_tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("tools/windows_large_address_test.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }) });
        test_headless_step.dependOn(&b.addRunArtifact(pe_tests).step);
        test_headless_step.dependOn(app_test_step);
        test_headless_step.dependOn(window_lifecycle_test_step);
        test_headless_step.dependOn(test_tokens);
        test_headless_step.dependOn(&run_harness_tests.step);
        test_headless_step.dependOn(&run_timing_ring_tests.step);
        test_headless_step.dependOn(&run_window_lifecycle_tests.step);
        test_headless_step.dependOn(&run_text_hook_owner_tests.step);
        test_headless_step.dependOn(&run_selector_scale_tests.step);
        test_headless_step.dependOn(&run_system_sdk_backend_tests.step);
        test_headless_step.dependOn(&run_system_sdk_tests.step);
        test_headless_step.dependOn(&run_text_core_tests.step);
        test_headless_step.dependOn(&run_text_property.step);
        test_headless_step.dependOn(&run_reactive_tests.step);
        test_headless_step.dependOn(&run_ui_tests.step);
        test_headless_step.dependOn(&run_gpu_tests.step);
        test_headless_step.dependOn(&run_render_tests.step);
        test_headless_step.dependOn(&run_ui_core_tests.step);
        test_headless_step.dependOn(&run_i18n_tests.step);
        test_headless_step.dependOn(&run_svg_tests.step);
        test_headless_step.dependOn(&run_bidi_conformance.step);
        // test-text (src/text/font_catalog.zig) was standalone step; never
        // linked into test-headless or CI. 11 tests only ran locally. Incomplete
        // fix of original orphan-module problem.
        test_headless_step.dependOn(&run_text_tests.step);
        test_headless_step.dependOn(&run_yix_compiler_tests.step);
        test_headless_step.dependOn(&check_yix_run.step);
        test_headless_step.dependOn(&check_yss_schema_run.step);
        test_headless_step.dependOn(&run_yix_runtime_tests.step);
        test_headless_step.dependOn(css_errors_step);

        const test_step = b.step("test", "Alias for deterministic test-headless suite");
        test_step.dependOn(test_headless_step);

        // Native ObjC bridge tests (native/macos/tests/*_test.{m,zig}), run via
        // scripts/test_native_*.sh in separate processes: each *_test.m #imports the entire
        // window_bridge.m as one TU; attaching it to a module in the build graph would propagate
        // C/ObjC sources to dependent exes (duplicate symbols with bridges already in the platform
        // module). Scripts use zig test with -M to reference source files directly, bypassing
        // build.zig modules, so they are naturally isolated. Not in test-headless: requires a macOS
        // session + Metal device (drag tests create MetalView, input_pump needs a GUI session to
        // start NSApplication), semantically test-metal; test-headless additionally runs in a Null
        // backend subprocess.
        const test_native_step = b.step("test-native", "Run native macOS ObjC bridge tests (native/macos/tests)");
        const native_test_scripts = [_][]const u8{
            "scripts/test_native_clipboard.sh",
            "scripts/test_native_drag_events.sh",
            "scripts/test_native_global_events.sh",
            "scripts/test_native_menu_actions.sh",
            "scripts/test_native_fullscreen_header.sh",
            "scripts/test_native_memory.sh",
            "scripts/test_native_text_events.sh",
            "scripts/test_native_input_pump.sh",
            "scripts/test_native_window_capabilities.sh",
        };
        for (native_test_scripts) |script| {
            const run_native = b.addSystemCommand(&.{ "bash", script });
            run_native.setName(script);
            run_native.setCwd(b.path("."));
            // Scripts' zig test uses same zig (CI setup-zig not at /opt/zig).
            run_native.setEnvironmentVariable("ZIG_BIN", b.graph.zig_exe);
            run_native.has_side_effects = true;
            test_native_step.dependOn(&run_native.step);
            if (std.mem.eql(u8, script, "scripts/test_native_fullscreen_header.sh")) {
                b.step("test-fullscreen-header-native", "Verify hidden AppKit fullscreen header lifecycle and toolbar ownership")
                    .dependOn(&run_native.step);
            }
        }

        const test_all_step = b.step("test-all", "Run deterministic, live-device Metal and native bridge tests");
        const windows_batch_contract = b.addSystemCommand(&.{ "python3", "tools/windows_batch_test.py" });
        const run_geometry_test = b.addSystemCommand(&.{ "bash", "scripts/test_windows_geometry.sh" });
        b.step("test-windows-window-geometry", "Verify shared window sizing at fractional DPI and menu wrap boundaries").dependOn(&run_geometry_test.step);
        test_all_step.dependOn(&run_geometry_test.step);
        b.step("test-windows-batch", "Verify offline Windows batch preparation and strict acceptance").dependOn(&windows_batch_contract.step);
        test_all_step.dependOn(&windows_batch_contract.step);
        const windows_upload_contract = b.addSystemCommand(&.{ "python3", "tools/windows_upload_parts_test.py" });
        b.step("test-windows-upload", "Verify authenticated resumable batch evidence transfer").dependOn(&windows_upload_contract.step);
        test_all_step.dependOn(&windows_upload_contract.step);
        const windows_optical_oracle = b.addSystemCommand(&.{ "bun", "test", "e2e/windows-optical-oracle.test.ts" });
        b.step("test-windows-optical-oracle", "Verify independent optical ray and color-space contracts").dependOn(&windows_optical_oracle.step);
        test_all_step.dependOn(&windows_optical_oracle.step);
        test_all_step.dependOn(&run_windows_gpu_fixtures.step);
        test_all_step.dependOn(test_headless_step);
        test_all_step.dependOn(metal_integration_step);
        test_all_step.dependOn(test_native_step);

        // RHI second backend gate (C1). Backend is global build option; cannot
        // instantiate both in one build, so subprocess reruns headless. Purpose:
        // continuous falsification of gpu.Backend abstraction. Any Metal-specific
        // rendering changes fail to compile here.
        const null_backend_check = b.addSystemCommand(&.{
            b.graph.zig_exe, "build", "-Dgpu-backend=null", "test-headless",
        });
        null_backend_check.setName("test-headless on null backend");
        const null_backend_step = b.step(
            "test-null-backend",
            "Compile and run deterministic tests against the Null GPU backend (proves the RHI abstraction)",
        );
        null_backend_step.dependOn(&null_backend_check.step);

        const package_consumer = b.addSystemCommand(&.{ "bash", "scripts/test_package_consumer.sh" });
        const package_consumer_step = b.step(
            "test-package-consumer",
            "Build and launch a downstream app against direct and Zig-filtered packages",
        );
        package_consumer_step.dependOn(&package_consumer.step);

        // Examples (6 zenit demos)

        const ExampleSpec = struct {
            name: []const u8,
            display_name: []const u8,
            step_name: []const u8,
            step_desc: []const u8,
        };
        const examples = [_]ExampleSpec{
            .{ .name = "adaptive_window", .display_name = "Adaptive Window", .step_name = "adaptive-window", .step_desc = "Build the platform-adaptive window example: custom/native chrome, shared Header, fullscreen Header host, one real window per desktop preset" },
            .{ .name = "window_chrome", .display_name = "Window Chrome", .step_name = "window-chrome", .step_desc = "Build the cross-platform custom Header example" },
            .{
                .name = "hello_button",
                .display_name = "Hello Button",
                .step_name = "hello-button",
                .step_desc = "Build hello_button example",
            },
            .{
                .name = "counter_reactive",
                .display_name = "Reactive Counter",
                .step_name = "counter-reactive",
                .step_desc = "Build counter_reactive example (Signal/Memo/Effect demo)",
            },
            .{
                .name = "zig_native",
                .display_name = "Zig-native Components",
                .step_name = "zig-native",
                .step_desc = "Build zig_native example (components written in Zig with ui.view, no Yix / YSS)",
            },
            .{
                .name = "yix_counter",
                .display_name = "Yix Counter",
                .step_name = "yix-counter",
                .step_desc = "Build the counter from Yix source (M0 compiler)",
            },
            .{
                .name = "virtual_list_perf",
                .display_name = "100k Virtual List",
                .step_name = "virtual-list-perf",
                .step_desc = "Build virtual_list_perf example (100k row VirtualList stress test)",
            },
            .{
                .name = "text_input",
                .display_name = "Text Input Demo",
                .step_name = "text-input",
                .step_desc = "Build text_input example (Input/Textarea + text_core integration)",
            },
            .{
                .name = "multi_window",
                .display_name = "Multi Window",
                .step_name = "multi-window",
                .step_desc = "Build multi_window example (two native windows, per-window routing)",
            },
            .{
                .name = "storybook",
                .display_name = "zenit Storybook",
                .step_name = "storybook",
                .step_desc = "Build storybook example (all-component showcase + e2e target)",
            },
            .{
                .name = "devtools_probe",
                .display_name = "DevTools Probe",
                .step_name = "devtools-probe",
                .step_desc = "Build devtools_probe (DevTools performance panel real-window acceptance probe)",
            },
            .{
                .name = "interop_probe",
                .display_name = "zenit Interop Probe",
                .step_name = "interop-probe",
                .step_desc = "Build interop_probe (rich clipboard / drag-out real-system verification target)",
            },
            .{
                .name = "console_probe",
                .display_name = "Console Probe",
                .step_name = "console-probe",
                .step_desc = "Build Console + DevTools real-window verification target",
            },
            .{
                .name = "design_probe",
                .display_name = "Design Probe",
                .step_name = "design-probe",
                .step_desc = "Build design_probe (pencil 视觉稿还原比对靶场)",
            },
        };
        for (examples) |spec| {
            const example_mod = b.createModule(.{
                .root_source_file = twins.path(b.fmt("examples/{s}/main.zig", .{spec.name})),
                .target = target,
                .optimize = optimize,
            });
            example_mod.addImport("ui", example_ui);
            example_mod.addImport("zenit_app", example_app);

            const example_exe = b.addExecutable(.{
                .name = spec.name,
                .root_module = example_mod,
            });
            addMacOSNativeLibs(b, example_exe);

            const build_step = b.step(spec.step_name, spec.step_desc);
            if (target.result.os.tag == .macos) {
                const example_bundle = macos_bundle.bundleApp(b, .{
                    .exe = example_exe,
                    .display_name = spec.display_name,
                    .bundle_id = b.fmt("com.zenit.{s}", .{spec.step_name}),
                    .version = "0.1.0",
                    .signing = .ad_hoc,
                    .clear_quarantine = true,
                });
                build_step.dependOn(example_bundle.final_step);
            } else {
                build_step.dependOn(&b.addInstallArtifact(example_exe, .{}).step);
            }

            const run = b.addRunArtifact(example_exe);
            run.step.dependOn(&example_exe.step);
            const example_run_step_name = b.fmt("run-{s}", .{spec.step_name});
            const example_run_desc = b.fmt("Run {s} example", .{spec.name});
            const example_run_step = b.step(example_run_step_name, example_run_desc);
            example_run_step.dependOn(&run.step);
        }

        // Bench (Phase 0) - perf baseline recording
        // Run: zig build bench [-- filter] [-- json=path]

        // Facade single module re-exports all bench types (Cx, reactive symbols, ui builders).
        // Must be in src/ui/ (Zig 0.15 strict module paths forbid cross-dir imports). A separate
        // reactive bench module with relative imports causes "file in two modules", so reactive is
        // re-exported via the facade and bench accesses it via `zenit.SignalOwner`.
        const zenit_facade_bench_module = b.createModule(.{
            .root_source_file = twins.path("src/ui/bench_facade.zig"),
            .target = target,
            .optimize = .fast,
        });
        // Cx re-export via facade needs sub-imports (same structure as ui_module)
        zenit_facade_bench_module.addImport("system_sdk", system_sdk_module);
        zenit_facade_bench_module.addImport("icon_ir", icon_ir_module);
        zenit_facade_bench_module.addImport("zenit_icons", icons_module);
        zenit_facade_bench_module.addImport("zenit_system_icons", system_icons_module);
        zenit_facade_bench_module.addImport("zenit_style_values", style_values_module);
        zenit_facade_bench_module.addImport("zenit_theme_provider", default_theme);
        zenit_facade_bench_module.addImport("text_core", text_core_module);
        zenit_facade_bench_module.addImport("trace", trace_module);
        zenit_facade_bench_module.addImport("platform", platform_module);
        zenit_facade_bench_module.addImport("i18n", i18n_module);
        zenit_facade_bench_module.addImport("text", text_module); // v0.5 §5 GlyphRun pipeline
        zenit_facade_bench_module.addImport("svg_safety", svg_safety_module);
        const resource_pool_bench_module = b.createModule(.{
            .root_source_file = b.path("src/gpu/resource_pool.zig"),
            .target = target,
            .optimize = .fast,
        });

        const bench_module = b.createModule(.{
            .root_source_file = b.path("src/bench/main.zig"),
            .target = target,
            .optimize = .fast, // bench always uses ReleaseFast
        });
        bench_module.addImport("zenit", zenit_facade_bench_module);
        bench_module.addImport("resource_pool", resource_pool_bench_module);
        bench_module.addImport("i18n", i18n_module);

        const bench_exe = b.addExecutable(.{
            .name = "zenit_bench",
            .root_module = bench_module,
        });
        // v0.5-p3: text_layout gets char widths via CoreText bridge. ReleaseFast
        // dead-code elimination preserves bridge symbol refs => bench exe must
        // link CoreText bridge (same as ui_test).
        addCoreTextBridge(b, bench_exe);
        const bench_install = b.addInstallArtifact(bench_exe, .{});
        const bench_run = b.addRunArtifact(bench_exe);
        bench_run.step.dependOn(&bench_install.step);
        bench_run.addPassthruArgs();

        const bench_step = b.step("bench", "Run perf baselines (zig build bench [-- filter] [-- json=path])");
        bench_step.dependOn(&bench_run.step);
    }
    // Architecture-neutral names are the preferred entry points. Preserve the
    // old names as aliases for existing VM automation; both install one artifact.
    const historical_steps = b.allocator.dupe(*std.Build.Step.TopLevel, b.top_level_steps.values()) catch @panic("OOM");
    for (historical_steps) |top| {
        const prefix = "windows-arm64-";
        if (std.mem.startsWith(u8, top.step.name, prefix)) {
            const name = b.fmt("windows-{s}", .{top.step.name[prefix.len..]});
            b.step(name, "Build the Windows target selected by -Dwindows-arch").dependOn(&top.step);
        }
    }
    const build_config_tests = b.addTest(.{
        .root_module = b.createModule(.{ .root_source_file = b.path("build.zig"), .target = b.graph.host, .optimize = .debug }),
        .filters = &.{ "build paths match", "Windows stack reserve" },
    });
    b.step("test-build-config", "Verify build path matching and Windows stack reserve").dependOn(&b.addRunArtifact(build_config_tests).step);
    wireReflection(b);
    twins.attachDependencies();
}

// ============================================================================
// macOS native bridges
// ============================================================================

/// zenit required macOS native bridges: window + harness recording +
/// metal + coretext + image.
fn addLinuxNativeLibs(b: *std.Build, exe: *std.Build.Step.Compile) void {
    const mod = exe.root_module;
    for ([_][]const u8{ "vendor/vulkan-headers/include", "vendor/wayland/include", "vendor/xkbcommon-headers/include", "vendor/wayland/protocols" }) |path| mod.addIncludePath(b.path(path));
    mod.addCSourceFiles(.{ .files = &.{ "native/linux/vulkan_device.c", "native/linux/opengl_device.c", "native/linux/wayland/window.c", "native/linux/font_discovery.c", "native/linux/text_layout.c" }, .flags = &.{ linux_native_revision_flag, "-std=c11", "-D_POSIX_C_SOURCE=200809L", "-Wall", "-Wextra", "-Werror" } });
    mod.addCSourceFiles(.{ .files = &.{ "vendor/wayland/protocols/wayland-protocol.c", "vendor/wayland/protocols/xdg-shell-protocol.c", "vendor/wayland/protocols/fractional-scale-v1-protocol.c", "vendor/wayland/protocols/viewporter-protocol.c", "vendor/wayland/protocols/cursor-shape-v1-protocol.c", "vendor/wayland/protocols/tablet-v2-protocol.c", "vendor/wayland/protocols/text-input-unstable-v3-protocol.c" }, .flags = &.{"-std=c11"} });
    mod.linkSystemLibrary("dl", .{});
    mod.linkSystemLibrary("fontconfig", .{});
    addFreeTypeLibs(mod);
    mod.link_libc = true;
}

fn addMacOSNativeLibs(b: *std.Build, exe: *std.Build.Step.Compile) void {
    if (exe.rootModuleTarget().os.tag == .linux) {
        addLinuxNativeLibs(b, exe);
        return;
    }
    addMacOSWindowBridge(b, exe);
    addMacOSScreenRecordingBridge(b, exe);
    addMacOSMetalBridge(b, exe);
    addCoreTextBridge(b, exe);
    addImageBridge(b, exe);
}

fn addMacOSScreenRecordingBridge(b: *std.Build, exe: *std.Build.Step.Compile) void {
    exe.root_module.addCSourceFile(.{
        .file = b.path("native/macos/screen_recording_bridge.m"),
        .flags = macosNativeFlags(b, b),
    });
    exe.root_module.linkFramework("AVFoundation", .{});
    exe.root_module.linkFramework("CoreMedia", .{});
    exe.root_module.linkFramework("CoreVideo", .{});
    exe.root_module.linkFramework("Metal", .{});
    exe.root_module.linkFramework("CoreGraphics", .{});
    exe.root_module.linkFramework("Foundation", .{});
    exe.root_module.link_libc = true;
}

fn addMacOSWindowBridge(b: *std.Build, exe: *std.Build.Step.Compile) void {
    exe.root_module.addCSourceFile(.{
        .file = b.path("native/macos/window_bridge.m"),
        .flags = macosNativeFlags(b, b),
    });
    exe.root_module.linkFramework("Cocoa", .{});
    exe.root_module.linkFramework("Metal", .{});
    exe.root_module.linkFramework("QuartzCore", .{});
    exe.root_module.linkFramework("IOSurface", .{});
    exe.root_module.linkFramework("CoreVideo", .{});
    exe.root_module.linkFramework("UniformTypeIdentifiers", .{});
    exe.root_module.link_libc = true;
}

fn addMacOSMetalBridge(b: *std.Build, exe: *std.Build.Step.Compile) void {
    exe.root_module.addCSourceFile(.{
        .file = b.path("native/macos/metal_bridge.m"),
        .flags = macosNativeFlags(b, b),
    });
    exe.root_module.linkFramework("Metal", .{});
    exe.root_module.linkFramework("QuartzCore", .{});
    exe.root_module.linkFramework("Foundation", .{});
    exe.root_module.link_libc = true;
}

fn addCoreTextBridge(b: *std.Build, exe: *std.Build.Step.Compile) void {
    if (exe.rootModuleTarget().os.tag == .linux) {
        exe.root_module.addCSourceFile(.{ .file = b.path("native/linux/font_discovery.c"), .flags = &.{"-std=c11"} });
        exe.root_module.addCSourceFile(.{ .file = b.path("native/linux/text_layout.c"), .flags = &.{"-std=c11"} });
        exe.root_module.linkSystemLibrary("fontconfig", .{});
        addFreeTypeLibs(exe.root_module);
        exe.root_module.link_libc = true;
        return;
    }
    exe.root_module.addCSourceFile(.{
        .file = b.path("native/macos/coretext_bridge.m"),
        .flags = macosNativeFlags(b, b),
    });
    exe.root_module.linkFramework("CoreText", .{});
    exe.root_module.linkFramework("CoreGraphics", .{});
    exe.root_module.linkFramework("CoreFoundation", .{});
    exe.root_module.linkFramework("Foundation", .{});
    exe.root_module.link_libc = true;
}

fn addImageBridge(b: *std.Build, exe: *std.Build.Step.Compile) void {
    exe.root_module.addCSourceFile(.{
        .file = b.path("native/macos/image_bridge.m"),
        .flags = macosNativeFlags(b, b),
    });
    exe.root_module.linkFramework("ImageIO", .{});
    exe.root_module.linkFramework("CoreGraphics", .{});
    exe.root_module.linkFramework("CoreFoundation", .{});
    exe.root_module.linkFramework("Foundation", .{});
    exe.root_module.link_libc = true;
}

/// FreeType + HarfBuzz (Linux/Windows fallback; macOS uses CoreText)
fn addFreeTypeLibs(mod: *std.Build.Module) void {
    mod.linkSystemLibrary("freetype2", .{});
    mod.linkSystemLibrary("harfbuzz", .{});
    if (mod.resolved_target.?.result.os.tag == .linux) {
        mod.linkSystemLibrary("pangoft2", .{});
        mod.linkSystemLibrary("pangocairo", .{});
        mod.linkSystemLibrary("cairo", .{});
    }
}

/// Host translator output participates in Zig's cache and dependency graph.
/// Consumers can obtain the compiler via zenit_dependency.artifact("yix").
/// Import neighboring source files as named modules until directory mirroring and import
/// dependency files land in M2.
/// Repository-internal source file paths: when generating/checking twin files before build
/// (-Dyix-gen=write|check), include a dependency on that step so modules referencing the
/// output are automatically ordered after generation.
const YixTwins = struct {
    b: *std.Build,
    step: ?*std.Build.Step,

    paths: std.ArrayList([]const u8) = .empty,

    fn path(t: *YixTwins, sub: []const u8) std.Build.LazyPath {
        t.paths.append(t.b.allocator, sub) catch @panic("OOM");
        return t.b.path(sub);
    }

    fn attachDependencies(t: *YixTwins) void {
        const generation = t.step orelse return;
        var seen: std.AutoHashMap(*std.Build.Step, void) = .init(t.b.allocator);
        defer seen.deinit();
        for (t.b.top_level_steps.values()) |top| t.visit(&top.step, generation, &seen);
    }

    fn visit(t: *YixTwins, step: *std.Build.Step, generation: *std.Build.Step, seen: *std.AutoHashMap(*std.Build.Step, void)) void {
        const entry = seen.getOrPut(step) catch @panic("OOM");
        if (entry.found_existing) return;
        for (step.dependencies.items) |dep| t.visit(dep, generation, seen);
        const compile = step.cast(std.Build.Step.Compile) orelse return;
        for (compile.root_module.getGraph().modules) |mod| {
            const root = mod.root_source_file orelse continue;
            const source = switch (root) {
                .src_path => |sp| if (sp.owner == t.b) sp.sub_path else continue,
                else => continue,
            };
            for (t.paths.items) |path_| {
                if (buildPathEqual(source, path_)) {
                    step.dependOn(generation);
                    return;
                }
            }
        }
    }
};

/// .yix / .yss files and twins registered as step inputs; `zig build
/// --watch` reruns generation on source changes.
fn addYixInputs(b: *std.Build, run: *std.Build.Step.Run, root: []const u8) void {
    var dir = b.root.openDir(b.graph.io, root, .{ .iterate = true }) catch return;
    defer dir.close(b.graph.io);
    var walker = dir.walk(b.allocator) catch @panic("OOM");
    defer walker.deinit();
    while (walker.next(b.graph.io) catch null) |entry| {
        if (entry.kind != .file) continue;
        const source = std.mem.endsWith(u8, entry.basename, ".yix") or std.mem.endsWith(u8, entry.basename, ".yss");
        const twin = entry.basename[0] == '_' and (std.mem.endsWith(u8, entry.basename, ".yix.zig") or std.mem.endsWith(u8, entry.basename, ".yss.zig"));
        if (!source and !twin) continue;
        run.addFileInput(b.path(b.pathJoin(&.{ root, entry.path })));
    }
}

pub fn translateYix(b: *std.Build, compiler: *std.Build.Step.Compile, source: std.Build.LazyPath, output_name: []const u8) std.Build.LazyPath {
    const run = b.addRunArtifact(compiler);
    run.addFileArg(source);
    return run.addOutputFileArg(output_name);
}

fn wireReflection(b: *std.Build) void {
    const reflection = b.createModule(.{ .root_source_file = b.path("src/reflection.zig") });
    var seen: std.AutoHashMap(*std.Build.Module, void) = .init(b.allocator);
    defer seen.deinit();
    var headers: std.StringHashMap(*std.Build.Module) = .init(b.allocator);
    defer headers.deinit();
    const clock = b.createModule(.{ .root_source_file = b.path("src/time.zig") });
    const environment = b.createModule(.{ .root_source_file = b.path("src/environment.zig"), .link_libc = true });
    for (b.modules.values()) |mod| wireReflectionModule(b, mod, reflection, clock, environment, &headers, &seen);
    var steps: std.AutoHashMap(*std.Build.Step, void) = .init(b.allocator);
    defer steps.deinit();
    for (b.top_level_steps.values()) |top| wireReflectionStep(b, &top.step, reflection, clock, environment, &headers, &seen, &steps);
}

fn wireReflectionModule(b: *std.Build, root: *std.Build.Module, reflection: *std.Build.Module, clock: *std.Build.Module, environment: *std.Build.Module, headers: *std.StringHashMap(*std.Build.Module), seen: *std.AutoHashMap(*std.Build.Module, void)) void {
    const graph = root.getGraph();
    for (graph.modules) |mod| {
        const entry = seen.getOrPut(mod) catch @panic("OOM");
        if (entry.found_existing) continue;
        if (mod.owner == b and mod != reflection) {
            mod.addImport("zenit_reflection", reflection);
            if (mod != clock) mod.addImport("zenit_time", clock);
            if (mod != environment) mod.addImport("zenit_environment", environment);
            wireCHeaders(b, mod, headers);
        }
        mod.cached_graph = .{ .modules = &.{}, .names = &.{} };
    }
}

fn wireReflectionStep(b: *std.Build, step: *std.Build.Step, reflection: *std.Build.Module, clock: *std.Build.Module, environment: *std.Build.Module, headers: *std.StringHashMap(*std.Build.Module), seen: *std.AutoHashMap(*std.Build.Module, void), steps: *std.AutoHashMap(*std.Build.Step, void)) void {
    const entry = steps.getOrPut(step) catch @panic("OOM");
    if (entry.found_existing) return;
    for (step.dependencies.items) |dep| wireReflectionStep(b, dep, reflection, clock, environment, headers, seen, steps);
    if (step.cast(std.Build.Step.Compile)) |compile| wireReflectionModule(b, compile.root_module, reflection, clock, environment, headers, seen);
}

fn windowsStackReserve(existing: ?u64) u64 {
    return @max(existing orelse 0, 32 * 1024 * 1024);
}

test "Windows stack reserve preserves larger consumer settings" {
    try std.testing.expectEqual(@as(u64, 32 * 1024 * 1024), windowsStackReserve(null));
    try std.testing.expectEqual(@as(u64, 32 * 1024 * 1024), windowsStackReserve(16 * 1024 * 1024));
    try std.testing.expectEqual(@as(u64, 64 * 1024 * 1024), windowsStackReserve(64 * 1024 * 1024));
}

// Build.Module duplicates LazyPath with host-native separators. Match registered
// repository paths independently of the build host, including mixed separators.
fn buildPathEqual(actual: []const u8, registered: []const u8) bool {
    if (actual.len != registered.len) return false;
    for (actual, registered) |a, r| {
        if (a == r) continue;
        if ((a == '/' or a == '\\') and (r == '/' or r == '\\')) continue;
        return false;
    }
    return true;
}

test "build paths match Windows and POSIX module roots" {
    try std.testing.expect(buildPathEqual("src/ui/ui.zig", "src/ui/ui.zig"));
    try std.testing.expect(buildPathEqual("src\\ui\\ui.zig", "src/ui/ui.zig"));
    try std.testing.expect(buildPathEqual("src/ui\\components\\calendar/mod.zig", "src/ui/components/calendar/mod.zig"));
    try std.testing.expect(buildPathEqual("src/text/text.zig", "src\\text\\text.zig"));
    try std.testing.expect(!buildPathEqual("src/ui/tests_root.zig", "src/ui/ui.zig"));
    try std.testing.expect(!buildPathEqual("src/ui/ui.zig.bak", "src/ui/ui.zig"));
}

fn wireCHeaders(b: *std.Build, mod: *std.Build.Module, cache: *std.StringHashMap(*std.Build.Module)) void {
    const root = mod.root_source_file orelse return;
    const source = switch (root) {
        .src_path => |sp| sp.sub_path,
        else => return,
    };
    const target = mod.resolved_target orelse b.graph.host;
    const triple = target.query.zigTriple(b.allocator) catch @panic("OOM");
    if (buildPathEqual(source, "src/ui/ui.zig") or
        buildPathEqual(source, "src/ui/tests_root.zig") or
        buildPathEqual(source, "src/ui/bench_facade.zig") or
        buildPathEqual(source, "src/ui/components/calendar/mod.zig"))
    {
        const key = b.fmt("calendar-{s}", .{triple});
        if (cache.get(key)) |cached| {
            mod.addImport("calendar_time", cached);
            return;
        }
        const translated = b.addTranslateC(.{
            .root_source_file = b.path("native/c_headers/calendar_time.h"),
            .target = target,
            .optimize = .debug,
        });
        const c_module = translated.createModule();
        cache.put(key, c_module) catch @panic("OOM");
        mod.addImport("calendar_time", c_module);
    }
    if (buildPathEqual(source, "src/text/text.zig") and target.result.os.tag != .macos and target.result.os.tag != .windows) {
        const key = b.fmt("freetype-{s}", .{triple});
        if (cache.get(key)) |cached| {
            mod.addImport("text_freetype_c", cached);
            return;
        }
        const translated = b.addTranslateC(.{
            .root_source_file = b.path("native/c_headers/text_freetype.h"),
            .target = target,
            .optimize = .debug,
        });
        translated.linkSystemLibrary("freetype2", .{});
        translated.linkSystemLibrary("harfbuzz", .{});
        const c_module = translated.createModule();
        cache.put(key, c_module) catch @panic("OOM");
        mod.addImport("text_freetype_c", c_module);
    }
}
