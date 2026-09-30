//! Minimal zenit consumer build.zig (Zig 0.15+).
//!
//! zenit ships its build wiring as a public API: `@import("zenit")` resolves
//! the dependency's build.zig, and `zenit.attach(dep, exe)` adds the `ui` /
//! `zenit_app` module imports, compiles the five macOS ObjC bridges out of
//! the package, and links the system frameworks.
//!
//! Prefer the helper. If you want to see (or customize) exactly what gets
//! linked, read `attach` / `addNativeLibs` in zenit's build.zig — it is the
//! same ~20 lines this template used to hand-roll.
const std = @import("std");
const zenit = @import("zenit");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_mode = b.option(bool, "test-mode", "Enable the Zenit automation harness") orelse false;
    const e2e_port = b.option(u16, "e2e-port", "Zenit Harness RPC directory suffix") orelse 19816;

    const zenit_dep = b.dependency("zenit", .{
        .target = target,
        .optimize = optimize,
        // Dependency build options are isolated in Zig. Forward these
        // explicitly so `zig build -Dtest-mode=true` reaches Zenit.
        .@"test-mode" = test_mode,
        .@"e2e-port" = e2e_port,
    });

    const exe = b.addExecutable(.{
        .name = "myapp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    zenit.attach(zenit_dep, exe);
    zenit.installHarnessClient(b, zenit_dep);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Optional: `zig build app` packages a double-clickable .app bundle.
    if (target.result.os.tag == .macos) {
        const bundled = zenit.bundleApp(b, .{
            .exe = exe,
            .display_name = "My App",
            .bundle_id = "com.example.myapp",
            .version = "0.1.0",
            .signing = .ad_hoc,
        });
        const app_step = b.step("app", "Build the .app bundle");
        app_step.dependOn(bundled.final_step);
    }
}
