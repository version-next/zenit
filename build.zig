const std = @import("std");
const macos_bundle = @import("src/system_sdk/bundle/macos_app.zig");

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
};

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
/// `zenit_app` module imports, compiles the five macOS ObjC bridges out of the
/// zenit package, and links the required system frameworks. No-op bridge/
/// framework linking on non-macOS targets (which are not yet supported at
/// runtime).
pub fn attach(zenit_dep: *std.Build.Dependency, exe: *std.Build.Step.Compile) void {
    attachWithOptions(zenit_dep, exe, .{});
}

/// `attach`, with an optional externally owned icon provider. One Zenit
/// dependency instance has one `ui` module, so all executables sharing that
/// instance must use the same provider. Separate applications naturally have
/// separate build graphs and may choose independently.
pub fn attachWithOptions(
    zenit_dep: *std.Build.Dependency,
    exe: *std.Build.Step.Compile,
    options: AttachOptions,
) void {
    const ui_module = zenit_dep.module("ui");
    if (options.icon_provider) |provider| {
        wireIconProvider(ui_module, zenit_dep.module("icon_ir"), provider);
    }

    exe.root_module.addImport("ui", ui_module);
    exe.root_module.addImport("zenit_app", zenit_dep.module("zenit_app"));
    addNativeLibs(zenit_dep, exe);
}

/// Just the native side of `attach` (bridges + frameworks), for consumers who
/// wire module imports themselves. Safe to call on any target; only macOS
/// links anything.
pub fn addNativeLibs(zenit_dep: *std.Build.Dependency, exe: *std.Build.Step.Compile) void {
    if (exe.rootModuleTarget().os.tag != .macos) return;
    const bridges = [_][]const u8{
        "native/macos/window_bridge.m",
        "native/macos/screen_recording_bridge.m",
        "native/macos/metal_bridge.m",
        "native/macos/coretext_bridge.m",
        "native/macos/image_bridge.m",
    };
    for (bridges) |src| exe.addCSourceFile(.{
        .file = zenit_dep.path(src),
        .flags = &.{"-fobjc-arc"},
    });
    const frameworks = [_][]const u8{
        "Cocoa",     "Metal",                  "QuartzCore",
        "CoreVideo", "UniformTypeIdentifiers", "Foundation",
        "CoreText",  "CoreGraphics",           "CoreFoundation",
        "ImageIO",   "AVFoundation",           "CoreMedia",
    };
    for (frameworks) |fw| exe.linkFramework(fw);
    exe.linkLibC();
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

/// Stable install location for Zenit's scenario UI 自动化工具集（bun 脚本 + schema）。
/// 所有 .ts 用相对 import，装到同一目录即可直接用。
pub const scenario_tooling_install_dir = "share/zenit/scenario";

/// Install Zenit 的 scenario 自动化工具集到消费者 zig-out/share/zenit/scenario/，
/// 使下游可直接 `bun zig-out/share/zenit/scenario/scenario_runner.ts <scenario.yaml>`。
/// 与 installHarnessClient 同类：只装开发者工具，harness RPC 仍需 `.@"test-mode" = true`。
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
/// 签名策略类型。消费方要按条件（如 -Drelease-sign 传没传）在 ad_hoc 与
/// developer_id 之间选时，需要能显式命名这个类型作为函数返回值。
pub const Signing = macos_bundle.Signing;
pub const DeveloperIdSigning = macos_bundle.DeveloperIdSigning;
pub const NotaryAuth = macos_bundle.NotaryAuth;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // E2E test harness flags
    const test_mode = b.option(bool, "test-mode", "Enable e2e test harness (file RPC server)") orelse false;
    const e2e_port = b.option(u16, "e2e-port", "E2E server port (used in default RPC dir name)") orelse 19816;

    // GPU 后端选择（C1）。`metal` 是生产后端；`null` 是无设备的确定性参考
    // 实现，用来证伪 `gpu.Backend.*` 抽象——只有第二个实现真能编译通过，
    // 才说明签名是 backend-neutral 而非焊死了 Metal 语义。编译期选择，
    // 不引入运行时分支。
    const gpu_backend = b.option(
        []const u8,
        "gpu-backend",
        "GPU backend: metal (default on macOS) or null (deterministic reference)",
    ) orelse "metal";
    if (!std.mem.eql(u8, gpu_backend, "metal") and !std.mem.eql(u8, gpu_backend, "null")) {
        std.debug.print("invalid -Dgpu-backend={s} (expected 'metal' or 'null')\n", .{gpu_backend});
        std.process.exit(1);
    }

    const build_opts = b.addOptions();
    build_opts.addOption(bool, "test_mode", test_mode);
    build_opts.addOption(u16, "e2e_port", e2e_port);
    build_opts.addOption([]const u8, "gpu_backend", gpu_backend);
    const build_options_module = build_opts.createModule();

    // ========================================================================
    // Modules（zenit framework 全部 9 个 + icon_ir 单文件）
    // ========================================================================

    const text_module = b.createModule(.{
        .root_source_file = b.path("src/text/text.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (target.result.os.tag != .macos) {
        addFreeTypeLibs(text_module);
    }

    const platform_module = b.createModule(.{
        .root_source_file = b.path("src/platform.zig"),
        .target = target,
        .optimize = optimize,
    });

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

    // 公开导出（b.addModule）而非私有：消费方做**业务自图标**时，自己的
    // A generated icon module needs `@import("icon_ir")`, and it must be the
    // exact same module instance used inside ui. Otherwise `icon_ir.Asset`
    // becomes a distinct type at the consumer boundary.
    // 自图标流程见 tools/gen_svg_assets.zig
    //（base_icon_id ≥ 2200 避开 0..16 与 1000.. 的 mask-cache key 段）。
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

    // 极简 svg 光栅化 module（root=src/render/svg.zig，仅依赖 std + icon_ir +
    // svg_safety，无 gpu/text/metal）。消费方：ui module（自定义位图光标
    // Cx.setCustomCursor）与 ui_core 测试 root（拉入 core/tests.zig → core.zig）。
    // gen_svg_assets 另建同款（见下方 gen 步骤）。
    // 公开导出（b.addModule）而非私有：消费方做**业务自图标**的离线生成器
    // 时必须复用**同一个** module 实例 —— 自建一份会让 src/render/ 下的
    // 文件同时落在两个 module 里（"file exists in modules" 编译错），与
    // icon_ir 的导出理由同款（类型/实例唯一性）。
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

    // Phase 5: i18n 基础（bidi UAX #9 + linebreak UAX #14 简化版）
    const i18n_module = b.createModule(.{
        .root_source_file = b.path("src/i18n/mod.zig"),
        .target = target,
        .optimize = optimize,
    });

    // wrap_map 的 precise 断点规则复用 i18n.linebreak（UAX #14 pair table +
    // isCJK），与渲染端 text_layout.findLineBreak 保持同源。
    text_core_module.addImport("i18n", i18n_module);

    // i18n 单测
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
        .optimize = .ReleaseSafe,
    });
    const bidi_conformance_i18n_module = b.createModule(.{
        .root_source_file = b.path("src/i18n/mod.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
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

    // 跨平台测试（macOS / Linux / Windows）
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

    // System SDK cross-target compile checks（不实跑，只确保编译过）
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
            .optimize = .Debug,
        });
        const cross_test_module = b.createModule(.{
            .root_source_file = b.path("src/system_sdk/system_sdk.zig"),
            .target = cross_target,
            .optimize = .Debug,
        });
        cross_test_module.addImport("platform", cross_platform_module);
        const cross_tests = b.addTest(.{
            .root_module = cross_test_module,
        });
        cross_check_step.dependOn(&cross_tests.step);
    }

    // Reactive system tests（不依赖 macOS 平台）
    const reactive_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ui/reactive.zig"),
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

    // text 模块的单测 target。
    //
    // ⚠ 在此之前 `src/text/*.zig` 里的 test 块**从未编译过** —— text 只被
    // createModule 成依赖,没有任何 addTest 指向它。font_catalog.zig 里那几条
    // "本机实测基线"断言写了却一直没跑;我给 familyWeights 加测试后做变异
    // 验证(故意改成返回固定 100~900 列表),测试**照样全绿**,才发现这个洞。
    // 教训与 harness_tests 那条注释同源:没有 addTest 的模块 = 测试是装饰品。
    // ⚠ root 必须直接指到 font_catalog.zig,不能指 text.zig:
    // text.zig 只是 `pub const font_catalog = @import(...)` 的再导出,而 Zig
    // **不会**递归收集被 import 文件里的 test 块(除非 refAllDecls)。
    // 指 text.zig 时 `run test` 3ms 就"成功"了 —— 一个 test 都没跑,
    // 变异体照样全绿。跑得太快本身就是没测到的信号。
    const text_test_module = b.createModule(.{
        .root_source_file = b.path("src/text/font_catalog.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (target.result.os.tag != .macos) addFreeTypeLibs(text_test_module);
    const text_tests = b.addTest(.{ .root_module = text_test_module });
    if (target.result.os.tag == .macos) {
        // font_catalog 走 CoreText bridge,不链就是一堆 undefined symbol。
        text_tests.addCSourceFile(.{
            .file = b.path("native/macos/coretext_bridge.m"),
            .flags = &.{"-fobjc-arc"},
        });
        for ([_][]const u8{
            "Foundation", "CoreText", "CoreGraphics", "CoreFoundation", "AppKit",
        }) |fw| text_tests.linkFramework(fw);
        text_tests.linkLibC();
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
    if (b.args) |args| run_evidence_validator.addArgs(args);
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
    if (b.args) |args| run_release_candidate_validator.addArgs(args);
    const release_candidate_validator_step = b.step(
        "release-candidate-validate",
        "Fail closed unless the complete clean-revision macOS candidate matrix is present",
    );
    release_candidate_validator_step.dependOn(&run_release_candidate_validator.step);

    // ========================================================================
    // macOS-only targets（Metal pipeline + native bridges）
    // ========================================================================
    if (target.result.os.tag == .macos) {
        const gpu_module = b.createModule(.{
            .root_source_file = b.path("src/gpu/gpu.zig"),
            .target = target,
            .optimize = optimize,
        });
        gpu_module.addImport("build_options", build_options_module);

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
        // svg 走 module 依赖而不是 render/ 目录内的相对导入：svg.zig 是
        // 独立 svg module 的根文件，同目录相对导入等于把一个文件塞进
        // 两个 module（"file exists in modules" 编译错）。gen 消费方复用
        // 同一实例后（下游应用的 gen-icons），这条依赖成了硬前提。
        render_module.addImport("svg", svg_raster_module);

        // `addModule` 而不是 `createModule` —— 让下游 consumer 通过
        // `dep.module("ui")` / `dep.module("zenit_app")` 取到。其它内部
        // module（gpu / render / system_sdk / text / ...）保持私有，
        // consumer 不该直接依赖它们。
        const ui_module = b.addModule("ui", .{
            .root_source_file = b.path("src/ui/ui.zig"),
            .target = target,
            .optimize = optimize,
        });
        ui_module.addImport("system_sdk", system_sdk_module);
        ui_module.addImport("icon_ir", icon_ir_module);
        ui_module.addImport("zenit_icons", icons_module);
        ui_module.addImport("zenit_system_icons", system_icons_module);
        ui_module.addImport("text_core", text_core_module);
        ui_module.addImport("trace", trace_module);
        ui_module.addImport("platform", platform_module);
        ui_module.addImport("i18n", i18n_module);
        // v0.5 §5: cx.shapeText 调 text.TextShaper.shape() 构 GlyphRun，
        // 让 ShapingCache 真正接管 ASCII-first 旧 measure 路径。需要 ui_module
        // 物理可见 text module（CoreText/HarfBuzz 桥），下游 ui_test /
        // ui_core_tests / bench / app 全 link target 同步注入 text + 链
        // CoreText bridge。
        ui_module.addImport("text", text_module);
        ui_module.addImport("svg_safety", svg_safety_module);
        // 自定义位图光标：ui/core.zig 用 svg.rasterize 把 SVG 光栅化成
        // RGBA 交给 system_sdk。
        ui_module.addImport("svg", svg_raster_module);

        // E2E test harness module (test_mode=true 时编入 app)
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

        // GPU 抽象测试
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

        // render 模块测试（2026-07-30 补：此前 src/render 的测试没接进任何
        // step，damage-rect prescan 等纯 CPU 侧测试从未运行过）
        // ⚠️ 独立 root module —— addCSourceFile/linkFramework 会转发到 root
        // module；复用 render_module 会把桥接 .m 重复注入 storybook 等 exe
        // （duplicate symbol）。
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
        // 与 render_module 同款 svg module 依赖（icon_renderer @import("svg")）
        render_test_module.addImport("svg", svg_raster_module);
        const render_tests = b.addTest(.{ .root_module = render_test_module });
        addCoreTextBridge(b, render_tests);
        render_tests.addCSourceFile(.{
            .file = b.path("native/macos/metal_bridge.m"),
            .flags = &.{"-fobjc-arc"},
        });
        render_tests.linkFramework("Metal");
        render_tests.linkFramework("QuartzCore");
        const run_render_tests = b.addRunArtifact(render_tests);
        const render_test_step = b.step("test-render", "Run render module tests");
        render_test_step.dependOn(&run_render_tests.step);

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
        metal_preflight.addCSourceFile(.{
            .file = b.path("native/macos/metal_bridge.m"),
            .flags = &.{"-fobjc-arc"},
        });
        metal_preflight.linkFramework("Metal");
        metal_preflight.linkFramework("QuartzCore");
        metal_preflight.linkFramework("Foundation");
        metal_preflight.linkFramework("CoreFoundation");
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
        metal_integration_tests.addCSourceFile(.{
            .file = b.path("native/macos/metal_bridge.m"),
            .flags = &.{"-fobjc-arc"},
        });
        metal_integration_tests.linkFramework("Metal");
        metal_integration_tests.linkFramework("QuartzCore");
        const run_metal_integration_tests = b.addRunArtifact(metal_integration_tests);
        run_metal_integration_tests.step.dependOn(&run_metal_preflight.step);
        const metal_integration_step = b.step("test-metal", "Run tests that require a live Metal device");
        metal_integration_step.dependOn(&run_metal_integration_tests.step);

        // UI tests（带 system_sdk + text_core + trace + icon_ir）
        const ui_test_module = b.createModule(.{
            .root_source_file = b.path("src/ui/ui.zig"),
            .target = target,
            .optimize = optimize,
        });
        ui_test_module.addImport("system_sdk", system_sdk_module);
        ui_test_module.addImport("icon_ir", icon_ir_module);
        ui_test_module.addImport("zenit_icons", icons_module);
        ui_test_module.addImport("zenit_system_icons", system_icons_module);
        ui_test_module.addImport("text_core", text_core_module);
        ui_test_module.addImport("trace", trace_module);
        ui_test_module.addImport("i18n", i18n_module);
        ui_test_module.addImport("platform", platform_module);
        ui_test_module.addImport("text", text_module); // v0.5 §5 GlyphRun pipeline
        ui_test_module.addImport("svg_safety", svg_safety_module);
        // 第161轮：`zig build test-ui -Dtest-filter=<子串>` 只跑名字含该子串的 test（全量一趟 ~10 min，
        // 定点调一个 test 不该每次都等全量）。不传 = 全量。
        const ui_test_filter = b.option([]const u8, "test-filter", "Only run test-ui tests whose name contains this substring");
        const ui_tests = b.addTest(.{
            .root_module = ui_test_module,
            .filters = if (ui_test_filter) |f| b.dupeStrings(&.{f}) else &.{},
        });
        // v0.5 §5: cx.shapeText 调 TextShaper → CoreText 桥；test target 也要链。
        addCoreTextBridge(b, ui_tests);
        const run_ui_tests = b.addRunArtifact(ui_tests);
        const ui_test_step = b.step("test-ui", "Run UI system tests");
        ui_test_step.dependOn(&run_ui_tests.step);

        // ui_core integration tests（src/ui/core/tests.zig）—— cx-mount 集成测试。
        // 历史遗留 orphan 文件（v0.4 重构时漏接 ui_core import），200 tests 从未编译。
        // task #161 阶段修复：建独立 test target 让 tests.zig 真编译。
        // root = src/ui/tests_root.zig，仅 `_ = @import("core/tests.zig")`；tests.zig
        // 改用相对路径访问 core.zig + components/。
        const ui_core_tests_root = b.createModule(.{
            .root_source_file = b.path("src/ui/tests_root.zig"),
            .target = target,
            .optimize = optimize,
        });
        ui_core_tests_root.addImport("system_sdk", system_sdk_module);
        ui_core_tests_root.addImport("icon_ir", icon_ir_module);
        ui_core_tests_root.addImport("zenit_icons", icons_module);
        ui_core_tests_root.addImport("zenit_system_icons", system_icons_module);
        ui_core_tests_root.addImport("text_core", text_core_module);
        ui_core_tests_root.addImport("trace", trace_module);
        ui_core_tests_root.addImport("i18n", i18n_module);
        ui_core_tests_root.addImport("platform", platform_module);
        ui_core_tests_root.addImport("text", text_module); // v0.5 §5 GlyphRun pipeline
        ui_core_tests_root.addImport("svg_safety", svg_safety_module);
        ui_core_tests_root.addImport("svg", svg_raster_module); // core.zig（经 tests.zig 拉入）需要
        const ui_core_tests = b.addTest(.{
            .root_module = ui_core_tests_root,
        });
        // v0.5 §5: cx.shapeText 调 TextShaper → CoreText 桥；test target 也要链。
        addCoreTextBridge(b, ui_core_tests);
        const run_ui_core_tests = b.addRunArtifact(ui_core_tests);
        const ui_core_tests_step = b.step("test-ui-core", "Run ui_core integration tests (src/ui/core/tests.zig)");
        ui_core_tests_step.dependOn(&run_ui_core_tests.step);

        // OOM transaction campaign is a named gate instead of an accidental
        // side effect of the broad suite. Each target enumerates allocator
        // failure points and asserts rollback/commit invariants at a distinct
        // production boundary.
        const allocation_reactive_module = b.createModule(.{
            .root_source_file = b.path("src/ui/reactive.zig"),
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
            .root_source_file = b.path("src/ui/ui.zig"),
            .target = target,
            .optimize = optimize,
        });
        allocation_ui_module.addImport("system_sdk", system_sdk_module);
        allocation_ui_module.addImport("icon_ir", icon_ir_module);
        allocation_ui_module.addImport("zenit_icons", icons_module);
        allocation_ui_module.addImport("zenit_system_icons", system_icons_module);
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
            .root_source_file = b.path("src/ui/tests_root.zig"),
            .target = target,
            .optimize = optimize,
        });
        allocation_core_module.addImport("system_sdk", system_sdk_module);
        allocation_core_module.addImport("icon_ir", icon_ir_module);
        allocation_core_module.addImport("zenit_icons", icons_module);
        allocation_core_module.addImport("zenit_system_icons", system_icons_module);
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

        // 帧计时环（GPU 性能门禁的统计量）。renderer.zig 整体会拉进 Metal/ObjC
        // 桥没法进普通 test target，故百分位逻辑独立在 timing_ring.zig ——
        // 单独建 target 才能保证门禁的数学**真的被测到**。
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

        // 进程级文本钩子归属栈（多 App 并存时关窗不拆别的窗口的测量钩子）。
        // runtime.zig 拉 Metal/ObjC 桥进不了普通 test target，故逻辑独立成文件。
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

        // Deterministic suite: must run without a live Metal device or
        // WindowServer. `test` remains the convenient local alias; `test-all`
        // adds the explicit live-device contract.
        // test_harness（file-RPC owner 锁等）—— 曾是 orphan（模块只被 app 引用，
        // 从无 addTest），http_server 的测试从未编译过。独立 target 接进 headless。
        // ⚠ 必须是**独立模块**，不能复用 test_harness_module：
        // addCoreTextBridge 走 addCSourceFile，而模块上的 C 源会**传递**给
        // 依赖它的 exe —— zenit_app 依赖 test_harness_module，于是
        // hello_button 等 exe 会把 coretext_bridge.m 链两遍，报 32 个
        // duplicate symbol。给测试单独建模块，C 源只挂在这条线上。
        const harness_test_module = b.createModule(.{
            .root_source_file = b.path("src/test_harness/mod.zig"),
            .target = target,
            .optimize = optimize,
        });
        harness_test_module.addImport("ui", ui_module);
        harness_test_module.addImport("build_options", build_options_module);
        // src/render/svg.zig 的 10 个 test 曾全是孤儿：svg_raster_module 被
        // render/ui 等多处 import（编译错误会暴露），但从无 addTest 以它为
        // root ⇒ 测试一次都没跑过。它是 1840 行的 SVG 解析器，处理**外部
        // 输入**，没有测试覆盖是发布风险。
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
        // command_executor.zig 的测试经 ui→text 拉进 CoreText 的 extern 符号；
        // 不链就是一堆 undefined symbol（它们因此当了很久的 orphan 测试）。
        addCoreTextBridge(b, harness_tests);
        const run_harness_tests = b.addRunArtifact(harness_tests);
        const harness_test_step = b.step("test-harness", "Run test_harness (file-RPC) tests");
        harness_test_step.dependOn(&run_harness_tests.step);

        const test_headless_step = b.step("test-headless", "Run deterministic tests (no live Metal device required)");
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
        // `test-text`（src/text/font_catalog.zig）此前只注册了自己的 step，
        // 从未挂进 test-headless，也没在 ci.yml 里单独调用 —— 11 个测试因此
        // 只有本地手动跑才会执行。这正是该 step 当初要修的「孤儿模块」问题
        // 的不完整修复。
        test_headless_step.dependOn(&run_text_tests.step);

        const test_step = b.step("test", "Alias for deterministic test-headless suite");
        test_step.dependOn(test_headless_step);

        // 原生 ObjC 桥测试（native/macos/tests/*_test.{m,zig}）。此前只有
        // scripts/test_native_*.sh 手动入口，不在任何 build step / CI 里——孤儿测试。
        // 刻意经脚本以独立进程编译：每个 *_test.m 都 #import 整个 window_bridge.m
        // 成单 TU，若挂到 build 图里的模块上，C/ObjC 源会传递给依赖它的 exe
        // （与 platform 模块已带的桥重复定义符号）。脚本里 zig test 用 -M 直接
        // 引源文件，不经 build.zig 的模块，天然隔离。
        // 不进 test-headless：它们要 macOS 会话 + Metal 设备（drag 测试会建
        // MetalView，input_pump 要 GUI 会话起 NSApplication），语义同 test-metal；
        // 而 test-headless 还会在 Null 后端子进程里再跑一遍。
        const test_native_step = b.step("test-native", "Run native macOS ObjC bridge tests (native/macos/tests)");
        const native_test_scripts = [_][]const u8{
            "scripts/test_native_clipboard.sh",
            "scripts/test_native_drag_events.sh",
            "scripts/test_native_global_events.sh",
            "scripts/test_native_menu_actions.sh",
            "scripts/test_native_text_events.sh",
            "scripts/test_native_input_pump.sh",
        };
        for (native_test_scripts) |script| {
            const run_native = b.addSystemCommand(&.{ "bash", script });
            run_native.setName(script);
            run_native.setCwd(b.path("."));
            // 脚本里的 zig test 用同一个 zig（CI 的 setup-zig 不在 /opt/zig）。
            run_native.setEnvironmentVariable("ZIG_BIN", b.graph.zig_exe);
            run_native.has_side_effects = true;
            test_native_step.dependOn(&run_native.step);
        }

        const test_all_step = b.step("test-all", "Run deterministic, live-device Metal and native bridge tests");
        test_all_step.dependOn(test_headless_step);
        test_all_step.dependOn(metal_integration_step);
        test_all_step.dependOn(test_native_step);

        // RHI 第二后端门禁（C1）。后端是全局 build option，无法在同一次
        // 构建里同时实例化两个，故用子进程再跑一遍 headless。
        // 意义不是"多跑一遍测试"，而是持续证伪 gpu.Backend 抽象：
        // 任何把 Metal 语义焊进渲染层的改动会在这里当场编译失败。
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

        // ====================================================================
        // Examples（6 个 zenit demo）
        // ====================================================================

        const ExampleSpec = struct {
            name: []const u8,
            display_name: []const u8,
            step_name: []const u8,
            step_desc: []const u8,
        };
        const examples = [_]ExampleSpec{
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
                .root_source_file = b.path(b.fmt("examples/{s}/main.zig", .{spec.name})),
                .target = target,
                .optimize = optimize,
            });
            example_mod.addImport("ui", ui_module);
            example_mod.addImport("zenit_app", app_module);

            const example_exe = b.addExecutable(.{
                .name = spec.name,
                .root_module = example_mod,
            });
            addMacOSNativeLibs(b, example_exe);

            const example_bundle = macos_bundle.bundleApp(b, .{
                .exe = example_exe,
                .display_name = spec.display_name,
                .bundle_id = b.fmt("com.zenit.{s}", .{spec.step_name}),
                .version = "0.1.0",
                .signing = .ad_hoc,
                .clear_quarantine = true,
            });

            const build_step = b.step(spec.step_name, spec.step_desc);
            build_step.dependOn(example_bundle.final_step);

            const run = b.addRunArtifact(example_exe);
            run.step.dependOn(&example_exe.step);
            const example_run_step_name = b.fmt("run-{s}", .{spec.step_name});
            const example_run_desc = b.fmt("Run {s} example", .{spec.name});
            const example_run_step = b.step(example_run_step_name, example_run_desc);
            example_run_step.dependOn(&run.step);
        }

        // ====================================================================
        // Bench (Phase 0) — perf 基线录入
        // 跑：zig build bench [-- filter] [-- json=path]
        // ====================================================================

        // v0.5-p3: facade 单一 module re-export 所有 bench 需要的类型，
        // 包括 Cx + reactive symbols + ui builders。
        // 必须放 src/ui/ 内部（zig 0.15 module strict path 禁止跨目录 import）。
        // 早期 (session 13) 曾用独立 reactive_bench_module，与 facade 的
        // core.zig 因相对 import 撞 "file in two modules"；现在 reactive 也
        // 经 facade re-export (core.zig 已 pub const SignalOwner = ...)，bench
        // main 通过 `zenit.SignalOwner` 访问，省掉独立 reactive module。
        const zenit_facade_bench_module = b.createModule(.{
            .root_source_file = b.path("src/ui/bench_facade.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        });
        // facade re-export Cx 需要这一坨 sub-import (与 ui_module 同构)
        zenit_facade_bench_module.addImport("system_sdk", system_sdk_module);
        zenit_facade_bench_module.addImport("icon_ir", icon_ir_module);
        zenit_facade_bench_module.addImport("zenit_icons", icons_module);
        zenit_facade_bench_module.addImport("zenit_system_icons", system_icons_module);
        zenit_facade_bench_module.addImport("text_core", text_core_module);
        zenit_facade_bench_module.addImport("trace", trace_module);
        zenit_facade_bench_module.addImport("platform", platform_module);
        zenit_facade_bench_module.addImport("i18n", i18n_module);
        zenit_facade_bench_module.addImport("text", text_module); // v0.5 §5 GlyphRun pipeline
        zenit_facade_bench_module.addImport("svg_safety", svg_safety_module);
        const resource_pool_bench_module = b.createModule(.{
            .root_source_file = b.path("src/gpu/resource_pool.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        });

        const bench_module = b.createModule(.{
            .root_source_file = b.path("src/bench/main.zig"),
            .target = target,
            .optimize = .ReleaseFast, // bench 永远用 ReleaseFast
        });
        bench_module.addImport("zenit", zenit_facade_bench_module);
        bench_module.addImport("resource_pool", resource_pool_bench_module);
        bench_module.addImport("i18n", i18n_module);

        const bench_exe = b.addExecutable(.{
            .name = "zenit_bench",
            .root_module = bench_module,
        });
        // v0.5-p3 frame-level bench: text_layout 通过 native CoreText 桥取
        // 字符宽度；ReleaseFast dead-code 仍保留对桥 symbol 的引用，必须给
        // bench exe 链 CoreText bridge 才能链通（与 ui_test target 一致）。
        addCoreTextBridge(b, bench_exe);
        const bench_install = b.addInstallArtifact(bench_exe, .{});
        const bench_run = b.addRunArtifact(bench_exe);
        bench_run.step.dependOn(&bench_install.step);
        if (b.args) |bench_args| bench_run.addArgs(bench_args);

        const bench_step = b.step("bench", "Run perf baselines (zig build bench [-- filter] [-- json=path])");
        bench_step.dependOn(&bench_run.step);
    }
}

// ============================================================================
// macOS native bridges
// ============================================================================

/// zenit 必需的 macOS native bridges：window + harness recording + metal +
/// coretext + image。
fn addMacOSNativeLibs(b: *std.Build, exe: *std.Build.Step.Compile) void {
    addMacOSWindowBridge(b, exe);
    addMacOSScreenRecordingBridge(b, exe);
    addMacOSMetalBridge(b, exe);
    addCoreTextBridge(b, exe);
    addImageBridge(b, exe);
}

fn addMacOSScreenRecordingBridge(b: *std.Build, exe: *std.Build.Step.Compile) void {
    exe.addCSourceFile(.{
        .file = b.path("native/macos/screen_recording_bridge.m"),
        .flags = &.{"-fobjc-arc"},
    });
    exe.linkFramework("AVFoundation");
    exe.linkFramework("CoreMedia");
    exe.linkFramework("CoreVideo");
    exe.linkFramework("Metal");
    exe.linkFramework("CoreGraphics");
    exe.linkFramework("Foundation");
    exe.linkLibC();
}

fn addMacOSWindowBridge(b: *std.Build, exe: *std.Build.Step.Compile) void {
    exe.addCSourceFile(.{
        .file = b.path("native/macos/window_bridge.m"),
        .flags = &.{"-fobjc-arc"},
    });
    exe.linkFramework("Cocoa");
    exe.linkFramework("Metal");
    exe.linkFramework("QuartzCore");
    exe.linkFramework("CoreVideo");
    exe.linkFramework("UniformTypeIdentifiers");
    exe.linkLibC();
}

fn addMacOSMetalBridge(b: *std.Build, exe: *std.Build.Step.Compile) void {
    exe.addCSourceFile(.{
        .file = b.path("native/macos/metal_bridge.m"),
        .flags = &.{"-fobjc-arc"},
    });
    exe.linkFramework("Metal");
    exe.linkFramework("QuartzCore");
    exe.linkFramework("Foundation");
    exe.linkLibC();
}

fn addCoreTextBridge(b: *std.Build, exe: *std.Build.Step.Compile) void {
    exe.addCSourceFile(.{
        .file = b.path("native/macos/coretext_bridge.m"),
        .flags = &.{"-fobjc-arc"},
    });
    exe.linkFramework("CoreText");
    exe.linkFramework("CoreGraphics");
    exe.linkFramework("CoreFoundation");
    exe.linkFramework("Foundation");
    exe.linkLibC();
}

fn addImageBridge(b: *std.Build, exe: *std.Build.Step.Compile) void {
    exe.addCSourceFile(.{
        .file = b.path("native/macos/image_bridge.m"),
        .flags = &.{"-fobjc-arc"},
    });
    exe.linkFramework("ImageIO");
    exe.linkFramework("CoreGraphics");
    exe.linkFramework("CoreFoundation");
    exe.linkFramework("Foundation");
    exe.linkLibC();
}

/// FreeType + HarfBuzz（Linux/Windows fallback；macOS 用 CoreText）
fn addFreeTypeLibs(mod: *std.Build.Module) void {
    mod.linkSystemLibrary("freetype2", .{});
    mod.linkSystemLibrary("harfbuzz", .{});
}
