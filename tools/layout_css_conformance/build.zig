const std = @import("std");

pub fn add(b: *std.Build, ui: *std.Build.Module, core_source: std.Build.LazyPath, bridge: anytype) void {
    const core = b.createModule(.{ .root_source_file = core_source, .target = ui.resolved_target, .optimize = ui.optimize });
    var imports = ui.import_table.iterator();
    while (imports.next()) |entry| core.addImport(entry.key_ptr.*, entry.value_ptr.*);
    const root = b.createModule(.{ .root_source_file = b.path("tools/layout_css_conformance/zenit.zig"), .target = ui.resolved_target, .optimize = ui.optimize });
    root.addImport("core", core);
    const exe = b.addExecutable(.{ .name = "layout-css-zenit", .root_module = root });
    bridge(b, exe);
    b.step("build-layout-css-conformance", "Build native layout oracle for offline browser replay")
        .dependOn(&b.addInstallArtifact(exe, .{}).step);
    const run = b.addSystemCommand(&.{ "node", "tools/layout_css_conformance/run.mjs", "--zenit" });
    run.addArtifactArg(exe);
    run.setCwd(b.path("."));
    run.has_side_effects = true;
    run.addPassthruArgs();
    b.step("layout-css-conformance", "Report Zenit/browser layout differences (LC1, no semantic gate)").dependOn(&run.step);
    // The test and executable share this module, including its native font sources.
    // Do not attach the bridge twice: that would duplicate CoreText symbols.
    const tests = b.addTest(.{ .root_module = root });
    const unit = b.addRunArtifact(tests);
    const js = b.addSystemCommand(&.{ "node", "--test", "tools/layout_css_conformance/conformance.test.mjs" });
    js.setCwd(b.path("."));
    const step = b.step("test-layout-css-conformance", "Test fixture parsing, CSS mapping and rectangle comparison");
    step.dependOn(&unit.step);
    step.dependOn(&js.step);
}
