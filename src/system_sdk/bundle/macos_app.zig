/// macOS .app bundle 构建 helper
///
/// 调用方（任意 build.zig）：
///
///   const macos_bundle = @import("system_sdk/bundle/macos_app.zig");
///
///   // 1) 装 .app（开发期 ad-hoc 签名）
///   const result = macos_bundle.bundleApp(b, .{
///       .exe = my_exe,
///       .display_name = "My App",
///       .bundle_id = "com.acme.myapp",
///       .signing = .ad_hoc,
///   });
///
///   // 2) 分发版（Developer ID 签 + entitlements + hardened runtime）
///   _ = macos_bundle.bundleApp(b, .{
///       .exe = my_exe,
///       .display_name = "My App",
///       .bundle_id = "com.acme.myapp",
///       .signing = .{ .developer_id = .{
///           .identity = "Developer ID Application: ACME Corp (TEAM12345)",
///           .entitlements = b.path("macos/MyApp.entitlements"),
///       }},
///   });
///
///   // 3) 公证（独立 step，因为是网络 + 几分钟的事，不该堵在 build 主路径上）
///   const notarize_step = macos_bundle.notarizeBundle(b, .{
///       .bundle_path = result.bundle_path,
///       .keychain_profile = "AC_PASSWORD",  // 见 notarytool store-credentials
///   });
///   notarize_step.dependOn(result.final_step);
///   _ = b.step("notarize", "Submit .app to Apple notarization service")
///       .dependOn(notarize_step);
///
/// 产物路径：<install_path>/<display_name>.app
const std = @import("std");
const info_plist_mod = @import("info_plist.zig");

pub const FileType = info_plist_mod.FileType;

/// 资源拷贝项，src 是源文件，dst 是 Resources/ 内的相对路径
pub const ResourceCopy = struct {
    src: std.Build.LazyPath,
    /// 相对于 bundle 的 Contents/Resources/ 目录。
    /// 例如 dst = "fonts/Inter.ttf" -> Contents/Resources/fonts/Inter.ttf
    dst: []const u8,
};

/// Developer ID 签名配置，用于分发到外部用户。
/// 签名后的 .app 还需要走 notarizeBundle() 经过 Apple 公证才能默认免警告打开。
pub const DeveloperIdSigning = struct {
    /// `codesign --sign` 接受的标识。可以是：
    ///   - 完整字符串："Developer ID Application: ACME Corp (TEAM12345)"
    ///   - Team ID："TEAM12345"（codesign 自动选最匹配证书）
    ///   - 证书 SHA-1：40 位 hex
    /// 使用前须确保本机 keychain 里有该证书 + 私钥。
    identity: []const u8,
    /// Entitlements .plist 路径。如果开了 hardened runtime，
    /// 通常需要至少声明 com.apple.security.cs.* 系列 entitlements。
    /// null = 不传 --entitlements 参数（仅适合极简场景）。
    entitlements: ?std.Build.LazyPath = null,
    /// 启用 hardened runtime, Apple 公证强制要求。默认 true。
    hardened_runtime: bool = true,
    /// 加 secure timestamp, Apple 公证强制要求。默认 true。
    /// 需要 codesign 进程能联网。CI 离线时关掉这个，但产物就过不了 notarize。
    timestamp: bool = true,
    /// 是否在 codesign 时加 --deep（递归签 Frameworks/ Plugins/ 等）。默认 true。
    /// 注意：Apple 已经标记 --deep 为 deprecated，但对 zenit 这种简单 .app
    /// 没有嵌套 framework 的情况依然好使。
    deep: bool = true,
};

pub const Signing = union(enum) {
    /// 不签名，产物会被 macOS Gatekeeper 拦。
    none,
    /// Ad-hoc 签名，开发期常用。本机能跑；分发到别人电脑上仍会被 Gatekeeper 拦
    /// 除非用户右键 Open。`codesign --sign -`
    ad_hoc,
    /// Developer ID 签名，用于分发到外部用户。需要 Apple Developer 账号 + keychain 里有证书。
    /// 仍需走 notarizeBundle() 公证才能默认免警告打开。
    developer_id: DeveloperIdSigning,
};

pub const BundleSpec = struct {
    /// 已构建好的可执行文件，bundleApp 会把它装到 Contents/MacOS/<executable>
    exe: *std.Build.Step.Compile,
    /// 应用显示名（会决定 .app 目录名 + Info.plist 的 CFBundle{Display,}Name）
    display_name: []const u8,
    /// 反向 DNS bundle id
    bundle_id: []const u8,
    /// .app/Contents/MacOS/<executable> 的文件名。默认等于 exe.name。
    executable: ?[]const u8 = null,
    version: []const u8 = "0.1.0",
    /// 4 字符 OSType。决定 PkgInfo 内容 "APPL<signature>" 和 CFBundleSignature。
    /// 默认 "????"，无 signature 是合法的。
    signature: []const u8 = "????",
    min_macos: []const u8 = "12.0",
    /// 图标文件（.icns）。可选，不传则不带图标（使用系统默认）。
    icon: ?std.Build.LazyPath = null,
    category: []const u8 = "public.app-category.utilities",
    copyright: ?[]const u8 = null,
    /// 文件类型注册（CFBundleDocumentTypes + UT*TypeDeclarations）
    file_types: []const FileType = &.{},
    /// 额外资源（字体、图片等），都装到 Contents/Resources/<dst>
    resources: []const ResourceCopy = &.{},
    /// NSAppTransportSecurity.NSAllowsArbitraryLoads，默认 false
    allow_arbitrary_loads: bool = false,
    disable_min_frame_duration: bool = true,
    auto_graphics_switching: bool = true,
    high_resolution: bool = true,
    /// 签名策略
    signing: Signing = .ad_hoc,
    /// 是否清理 quarantine 属性。开发期建议 true（避免 LaunchServices 拒绝资源）。
    clear_quarantine: bool = true,
};

pub const BundleResult = struct {
    /// 最终 step（用户用 `app_step.dependOn(result.final_step)` 把 bundle 接入自己的 build graph）
    final_step: *std.Build.Step,
    /// .app 目录绝对路径（用于后续的额外步骤，如 dmg 打包 / notarize）
    bundle_path: []const u8,
};

/// 主入口，构建一个 macOS .app bundle，返回最终 step。
pub fn bundleApp(b: *std.Build, spec: BundleSpec) BundleResult {
    const exe_name = spec.executable orelse spec.exe.name;
    const bundle_dirname = b.fmt("{s}.app", .{spec.display_name});
    const contents_rel = b.fmt("{s}/Contents", .{bundle_dirname});
    const macos_rel = b.fmt("{s}/MacOS", .{contents_rel});
    const resources_rel = b.fmt("{s}/Resources", .{contents_rel});

    // 1) 装 exe 到 Contents/MacOS/<executable>
    const install_exe = b.addInstallArtifact(spec.exe, .{
        .dest_dir = .{ .override = .{ .custom = macos_rel } },
    });

    // 2) 渲染 Info.plist
    const plist_xml = info_plist_mod.render(b.allocator, .{
        .display_name = spec.display_name,
        .bundle_id = spec.bundle_id,
        .executable = exe_name,
        .version = spec.version,
        .signature = spec.signature,
        .min_macos = spec.min_macos,
        .icon_file = if (spec.icon != null) iconStem(b, spec.icon.?) else null,
        .category = spec.category,
        .copyright = spec.copyright,
        .file_types = spec.file_types,
        .allow_arbitrary_loads = spec.allow_arbitrary_loads,
        .disable_min_frame_duration = spec.disable_min_frame_duration,
        .auto_graphics_switching = spec.auto_graphics_switching,
        .high_resolution = spec.high_resolution,
    }) catch @panic("OOM rendering Info.plist");

    const plist_wf = b.addWriteFiles();
    const plist_path = plist_wf.add("Info.plist", plist_xml);
    const install_plist = b.addInstallFile(plist_path, b.fmt("{s}/Info.plist", .{contents_rel}));

    // 3) PkgInfo（8 字节："APPL" + 4字符 signature）
    const pkginfo_content = b.fmt("APPL{s}", .{spec.signature});
    const pkginfo_wf = b.addWriteFiles();
    const pkginfo_path = pkginfo_wf.add("PkgInfo", pkginfo_content);
    const install_pkginfo = b.addInstallFile(pkginfo_path, b.fmt("{s}/PkgInfo", .{contents_rel}));

    // 4) 图标（如果有）
    var resource_steps = std.ArrayList(*std.Build.Step){};
    resource_steps.append(b.allocator, &install_exe.step) catch @panic("OOM");
    resource_steps.append(b.allocator, &install_plist.step) catch @panic("OOM");
    resource_steps.append(b.allocator, &install_pkginfo.step) catch @panic("OOM");

    if (spec.icon) |icon_path| {
        const icon_filename = iconBasename(b, icon_path);
        const install_icon = b.addInstallFile(
            icon_path,
            b.fmt("{s}/{s}", .{ resources_rel, icon_filename }),
        );
        resource_steps.append(b.allocator, &install_icon.step) catch @panic("OOM");
    }

    // 5) 额外资源
    for (spec.resources) |res| {
        const install_res = b.addInstallFile(
            res.src,
            b.fmt("{s}/{s}", .{ resources_rel, res.dst }),
        );
        resource_steps.append(b.allocator, &install_res.step) catch @panic("OOM");
    }

    const bundle_abs = b.fmt("{s}/{s}", .{ b.install_path, bundle_dirname });

    var last_step: *std.Build.Step = blk: {
        const agg = b.allocator.create(std.Build.Step) catch @panic("OOM");
        agg.* = std.Build.Step.init(.{
            .id = .custom,
            .name = b.fmt("bundle-installs-{s}", .{spec.display_name}),
            .owner = b,
            .makeFn = noopMake,
        });
        for (resource_steps.items) |s| agg.dependOn(s);
        break :blk agg;
    };

    if (spec.clear_quarantine) {
        const xattr = b.addSystemCommand(&.{ "xattr", "-dr", "com.apple.quarantine" });
        xattr.addArg(bundle_abs);
        xattr.step.dependOn(last_step);
        last_step = &xattr.step;
    }

    switch (spec.signing) {
        .none => {},
        .ad_hoc => {
            const codesign = b.addSystemCommand(&.{ "codesign", "--force", "--sign", "-", "--deep" });
            codesign.addArg(bundle_abs);
            codesign.step.dependOn(last_step);
            last_step = &codesign.step;
        },
        .developer_id => |cfg| {
            const codesign = b.addSystemCommand(&.{ "codesign", "--force", "--sign" });
            codesign.addArg(cfg.identity);
            if (cfg.deep) codesign.addArg("--deep");
            if (cfg.hardened_runtime) {
                codesign.addArg("--options");
                codesign.addArg("runtime");
            }
            if (cfg.timestamp) codesign.addArg("--timestamp");
            if (cfg.entitlements) |ent| {
                codesign.addArg("--entitlements");
                codesign.addFileArg(ent);
            }
            codesign.addArg(bundle_abs);
            codesign.step.dependOn(last_step);
            last_step = &codesign.step;
        },
    }

    return .{
        .final_step = last_step,
        .bundle_path = bundle_abs,
    };
}

// ============================================================================
// Notarization
// ============================================================================

/// 公证认证方式，必须二选一。
pub const NotaryAuth = union(enum) {
    /// 推荐，用 `xcrun notarytool store-credentials <profile> --apple-id ... --team-id ...
    ///                                                       --password <app_specific_pwd>`
    /// 把凭据存进 keychain 后，这里只引用 profile name。
    keychain_profile: []const u8,
    /// 直接传 Apple ID + team ID + app-specific password。
    /// **不推荐**，密码在命令行里裸奔，会被 ps / shell history 抓到。CI 时考虑把
    /// password 放环境变量然后从那里读。
    inline_credentials: struct {
        apple_id: []const u8,
        team_id: []const u8,
        password: []const u8,
    },
};

pub const NotarizeSpec = struct {
    /// 来自 bundleApp 返回的 BundleResult.bundle_path
    bundle_path: []const u8,
    /// 产出「已签名、可提交」的那个 step，通常是 bundleApp 的 final_step，
    /// 或调用方在其之后自己接的重签 step。
    ///
    /// **必须传**，否则 zip 与签名之间没有依赖边：Zig 可以在签名完成前就打包，
    /// 也可以在 staple 之后重新跑一次签名，把票据连同签名一起覆盖掉。
    /// 症状是 staple 报 `Record not found`，公证明明 Accepted，
    /// 但磁盘上那份 app 的 cdhash 已经和上传时不是同一个了。
    /// （只把 notarizeBundle 的返回 step dependOn 签名步骤是不够的：
    /// 那只约束了链尾，管不住链首的 zip。）
    depends_on: ?*std.Build.Step = null,
    /// Apple Developer 账号凭据
    auth: NotaryAuth,
    /// 公证完成后是否 staple 票据进 .app（这样离线分发也能验证）。默认 true。
    staple: bool = true,
    /// notarytool submit 默认是异步的。这里强制 --wait（最多 2 小时），
    /// 失败时 step 会失败。CI 友好。默认 true。
    wait: bool = true,
};

/// 提交 .app 到 Apple 公证服务，返回最终 step。
/// 调用方需要自己挂到 build graph：
///   const step = b.step("notarize", "...");
///   step.dependOn(notarizeBundle(b, ...));
///   notarize_inner_step.dependOn(bundle_result.final_step);  // 先 bundle 再 notarize
pub fn notarizeBundle(b: *std.Build, spec: NotarizeSpec) *std.Build.Step {
    // 1) 把 .app 打成 .zip, Apple notarytool 接 zip 或 dmg/pkg，对裸 .app 不收。
    const zip_path = b.fmt("{s}.zip", .{spec.bundle_path});
    const zip_cmd = b.addSystemCommand(&.{ "ditto", "-c", "-k", "--keepParent" });
    zip_cmd.addArg(spec.bundle_path);
    zip_cmd.addArg(zip_path);
    // 打包必须排在签名之后，见 NotarizeSpec.depends_on。
    if (spec.depends_on) |dep| zip_cmd.step.dependOn(dep);

    // 2) 提交公证
    const submit_cmd = b.addSystemCommand(&.{ "xcrun", "notarytool", "submit" });
    submit_cmd.addArg(zip_path);
    switch (spec.auth) {
        .keychain_profile => |profile| {
            submit_cmd.addArg("--keychain-profile");
            submit_cmd.addArg(profile);
        },
        .inline_credentials => |creds| {
            submit_cmd.addArg("--apple-id");
            submit_cmd.addArg(creds.apple_id);
            submit_cmd.addArg("--team-id");
            submit_cmd.addArg(creds.team_id);
            submit_cmd.addArg("--password");
            submit_cmd.addArg(creds.password);
        },
    }
    if (spec.wait) submit_cmd.addArg("--wait");
    submit_cmd.step.dependOn(&zip_cmd.step);

    var last: *std.Build.Step = &submit_cmd.step;

    // 3) Staple 公证票据进 .app
    if (spec.staple) {
        const staple_cmd = b.addSystemCommand(&.{ "xcrun", "stapler", "staple" });
        staple_cmd.addArg(spec.bundle_path);
        staple_cmd.step.dependOn(last);
        last = &staple_cmd.step;

        // 验证 staple 成功（spctl 检查 Gatekeeper 视角）
        const verify_cmd = b.addSystemCommand(&.{ "spctl", "--assess", "--verbose=2", "--type", "execute" });
        verify_cmd.addArg(spec.bundle_path);
        verify_cmd.step.dependOn(last);
        last = &verify_cmd.step;
    }

    return last;
}

fn noopMake(_: *std.Build.Step, _: std.Build.Step.MakeOptions) anyerror!void {}

/// 从 LazyPath 抽出文件名（"icon.icns" 等）。仅支持 b.path() 形态。
fn iconBasename(b: *std.Build, lp: std.Build.LazyPath) []const u8 {
    const full = lp.getPath2(b, null);
    const slash = std.mem.lastIndexOfScalar(u8, full, '/');
    return if (slash) |i| full[i + 1 ..] else full;
}

/// 抽出图标文件名（不含扩展），用于 CFBundleIconFile。
fn iconStem(b: *std.Build, lp: std.Build.LazyPath) []const u8 {
    const base = iconBasename(b, lp);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.');
    return if (dot) |i| base[0..i] else base;
}
