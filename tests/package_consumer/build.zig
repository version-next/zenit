const std = @import("std");
const zenit = @import("zenit");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_mode = b.option(bool, "test-mode", "Enable the Zenit automation harness") orelse false;
    const e2e_port = b.option(u16, "e2e-port", "Zenit Harness RPC directory suffix") orelse 19816;
    const external_icons = b.option(bool, "external-icons", "Exercise external icon-provider injection") orelse false;
    const icon_set = b.option([]const u8, "icon-set", "Forward Zenit's built-in icon provider") orelse "lucide";

    const zenit_dep = b.dependency("zenit", .{
        .target = target,
        .optimize = optimize,
        .@"test-mode" = test_mode,
        .@"e2e-port" = e2e_port,
        .@"icon-set" = icon_set,
    });
    const consumer_options = b.addOptions();
    consumer_options.addOption(bool, "external_icons", external_icons);
    consumer_options.addOption([]const u8, "icon_set", icon_set);

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_module.addOptions("consumer_options", consumer_options);

    const exe = b.addExecutable(.{
        .name = "zenit_package_consumer",
        .root_module = root_module,
    });
    if (external_icons) {
        const icons_dep = b.dependency("zenit_icons_untitled", .{
            .target = target,
            .optimize = optimize,
        });
        zenit.attachWithOptions(zenit_dep, exe, .{
            .icon_provider = .{
                .icons = icons_dep.module("icons"),
                .system_icons = icons_dep.module("system_icons"),
            },
        });
    } else {
        zenit.attach(zenit_dep, exe);
    }
    zenit.installHarnessClient(b, zenit_dep);
    b.installArtifact(exe);
}
