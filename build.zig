const std = @import("std");
const Scanner = @import("wayland").Scanner;

const release_version: std.SemanticVersion = .{ .major = 0, .minor = 2, .patch = 0 };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const version = versionString(b);

    // D-Bus backs session-bus notifications, xdg-desktop-portal link/file
    // opening, GTK theme-change signals, and systemd transient-scope cgroup
    // isolation. All of it already degrades gracefully at runtime when no
    // session bus is present (see App.zig's dbus_connection handling), so
    // this option lets minimal/embedded Wayland builds drop the libdbus-1
    // headers and linkage entirely instead of just failing to connect.
    const enable_dbus = b.option(
        bool,
        "dbus",
        "Enable D-Bus desktop integration: notifications, xdg-desktop-portal, systemd cgroup isolation (default: true)",
    ) orelse true;

    const scanner = Scanner.create(b, .{});
    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    scanner.addSystemProtocol("stable/viewporter/viewporter.xml");
    scanner.addSystemProtocol("stable/tablet/tablet-v2.xml");
    scanner.addSystemProtocol("staging/xdg-activation/xdg-activation-v1.xml");
    scanner.addSystemProtocol("staging/fractional-scale/fractional-scale-v1.xml");
    scanner.addSystemProtocol("staging/cursor-shape/cursor-shape-v1.xml");
    scanner.addSystemProtocol("staging/xdg-system-bell/xdg-system-bell-v1.xml");
    scanner.addSystemProtocol("staging/xdg-toplevel-icon/xdg-toplevel-icon-v1.xml");
    scanner.addSystemProtocol("staging/ext-background-effect/ext-background-effect-v1.xml");
    scanner.addSystemProtocol("unstable/xdg-decoration/xdg-decoration-unstable-v1.xml");
    scanner.addSystemProtocol("unstable/primary-selection/primary-selection-unstable-v1.xml");
    scanner.addSystemProtocol("unstable/text-input/text-input-unstable-v3.xml");
    // Generate against current stable protocol definitions. Runtime binding
    // still negotiates the compositor-advertised version, and Window keeps
    // fallbacks for every optional/versioned feature it uses.
    scanner.generate("wl_compositor", 7);
    scanner.generate("wl_output", 4);
    scanner.generate("wl_shm", 2);
    scanner.generate("wl_seat", 10);
    scanner.generate("xdg_wm_base", 7);
    scanner.generate("xdg_activation_v1", 1);
    scanner.generate("wp_viewporter", 1);
    scanner.generate("wp_fractional_scale_manager_v1", 1);
    scanner.generate("wp_cursor_shape_manager_v1", 2);
    scanner.generate("xdg_system_bell_v1", 1);
    scanner.generate("xdg_toplevel_icon_manager_v1", 1);
    scanner.generate("ext_background_effect_manager_v1", 1);
    scanner.generate("zxdg_decoration_manager_v1", 2);
    scanner.generate("wl_data_device_manager", 4);
    scanner.generate("zwp_primary_selection_device_manager_v1", 1);
    scanner.generate("zwp_text_input_manager_v3", 1);
    const wayland_mod = b.createModule(.{ .root_source_file = scanner.result });

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);
    build_options.addOption(bool, "enable_dbus", enable_dbus);
    root_module.addOptions("build_options", build_options);
    root_module.addImport("wayland", wayland_mod);
    root_module.linkSystemLibrary("wayland-client", .{});
    root_module.linkSystemLibrary("wayland-cursor", .{});

    const ghostty_dep = b.lazyDependency("ghostty", .{
        .target = target,
        .optimize = optimize,
    });

    // Font stack: fontconfig (discovery) + FreeType (rasterization) +
    // HarfBuzz (shaping) + stb image helpers, imported through one
    // translated C header.
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_c.linkSystemLibrary("fontconfig", .{});
    translate_c.linkSystemLibrary("freetype2", .{});
    translate_c.linkSystemLibrary("harfbuzz", .{});
    translate_c.linkSystemLibrary("xkbcommon", .{});
    if (enable_dbus) {
        translate_c.linkSystemLibrary("dbus-1", .{});
        // Tells src/c.h to include dbus/dbus.h; kept out of the C translation
        // unit entirely when disabled so libdbus-1's headers aren't required.
        translate_c.defineCMacroRaw("MONSTAR_ENABLE_DBUS=1");
    }
    root_module.addImport("c", translate_c.createModule());

    if (b.lazyDependency("z2d", .{
        .target = target,
        .optimize = optimize,
    })) |dep| {
        root_module.addImport("z2d", dep.module("z2d"));
    }

    if (ghostty_dep) |dep| {
        const ghostty_vt = dep.module("ghostty-vt");
        root_module.addImport("ghostty-vt", ghostty_vt);
        // ghostty-vt reaches these files indirectly, and Zig cannot assign one
        // source file to two modules. Compile cache copies keep one upstream
        // definition while making the terminfo package importable here.
        const terminfo_files = b.addWriteFiles();
        _ = terminfo_files.addCopyFile(dep.path("src/terminfo/Source.zig"), "Source.zig");
        _ = terminfo_files.addCopyFile(dep.path("src/terminfo/ghostty.zig"), "ghostty.zig");
        root_module.addImport("ghostty-terminfo", b.createModule(.{
            .root_source_file = terminfo_files.addCopyFile(dep.path("src/terminfo/main.zig"), "main.zig"),
            .target = target,
            .optimize = optimize,
        }));
        root_module.addImport(
            "uucode",
            ghostty_vt.import_table.get("uucode") orelse
                @panic("ghostty-vt does not provide uucode"),
        );
    }

    const exe = b.addExecutable(.{
        .name = "monstar",
        .root_module = root_module,
        .version = std.SemanticVersion.parse(version) catch unreachable,
        // uucode's generated tables crash the x86_64 self-hosted backend on
        // Zig 0.16. Ghostty uses LLVM for the same reason.
        .use_llvm = true,
    });
    root_module.addCSourceFile(.{ .file = b.path("vendor/stb_image_resize.c") });
    root_module.addCSourceFile(.{ .file = b.path("vendor/stb_image.c") });

    b.installArtifact(exe);
    b.installFile("dist/dev.rockorager.monstar.desktop", "share/applications/dev.rockorager.monstar.desktop");
    b.installFile("dist/dev.rockorager.monstar.svg", "share/icons/hicolor/scalable/apps/dev.rockorager.monstar.svg");
    b.installFile("dist/monstar.1", "share/man/man1/monstar.1");
    b.installFile("dist/monstar.5", "share/man/man5/monstar.5");
    if (b.lazyDependency("iterm2_themes", .{})) |themes| {
        b.installDirectory(.{
            .source_dir = themes.path(""),
            .install_dir = .{ .custom = "share" },
            .install_subdir = "monstar/themes",
            .exclude_extensions = &.{".md"},
        });
    }

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.setEnvironmentVariable(
        "MONSTAR_RESOURCES_DIR",
        b.getInstallPath(.prefix, "share/monstar"),
    );
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run unit tests");
    const exe_tests = b.addTest(.{
        .root_module = root_module,
        .use_llvm = true,
    });
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);

    const fmt_step = b.step("fmt", "Check code formatting");
    const fmt_check = b.addFmt(.{ .paths = &.{ "src", "build.zig", "build.zig.zon" }, .check = true });
    fmt_step.dependOn(&fmt_check.step);
    test_step.dependOn(fmt_step);
}

fn versionString(b: *std.Build) []const u8 {
    const release = b.fmt("{f}", .{release_version});
    var code: u8 = undefined;
    const raw = b.runAllowFail(&.{
        "git",
        "-C",
        b.build_root.path orelse ".",
        "describe",
        "--tags",
        "--long",
        "--dirty",
        "--always",
        "--match",
        "v[0-9]*",
    }, &code, .ignore) catch return release;
    const description = std.mem.trim(u8, raw, " \r\n");
    if (description.len == 0) return release;

    const dirty = std.mem.endsWith(u8, description, "-dirty");
    const clean = if (dirty) description[0 .. description.len - "-dirty".len] else description;
    if (!std.mem.startsWith(u8, clean, "v")) {
        const count_raw = b.runAllowFail(&.{
            "git",
            "-C",
            b.build_root.path orelse ".",
            "rev-list",
            "--count",
            "HEAD",
        }, &code, .ignore) catch return release;
        const count = std.mem.trim(u8, count_raw, " \r\n");
        _ = std.fmt.parseInt(usize, count, 10) catch return release;
        return developmentVersion(b, release, count, clean, dirty);
    }

    const hash_sep = std.mem.lastIndexOfScalar(u8, clean, '-') orelse
        std.process.fatal("unexpected git describe output: {s}", .{description});
    const before_hash = clean[0..hash_sep];
    const distance_sep = std.mem.lastIndexOfScalar(u8, before_hash, '-') orelse
        std.process.fatal("unexpected git describe output: {s}", .{description});
    const tag = before_hash[0..distance_sep];
    const distance = before_hash[distance_sep + 1 ..];
    const hash = clean[hash_sep + 1 ..];
    if (hash.len < 2 or hash[0] != 'g')
        std.process.fatal("unexpected git describe output: {s}", .{description});

    const tagged_version = std.SemanticVersion.parse(tag[1..]) catch
        std.process.fatal("version tag is not semantic: {s}", .{tag});
    const commit_count = std.fmt.parseInt(usize, distance, 10) catch
        std.process.fatal("unexpected git describe output: {s}", .{description});
    if (commit_count == 0) {
        if (release_version.order(tagged_version) != .eq)
            std.process.fatal("release version {s} does not match tag {s}", .{ release, tag });
        if (!dirty) return release;
    } else if (release_version.order(tagged_version) != .gt) {
        std.process.fatal("release version {s} must be newer than tag {s}", .{ release, tag });
    }
    return developmentVersion(b, release, distance, hash[1..], dirty);
}

fn developmentVersion(
    b: *std.Build,
    release: []const u8,
    distance: []const u8,
    hash: []const u8,
    dirty: bool,
) []const u8 {
    return if (dirty)
        b.fmt("{s}-dev.{s}+g{s}.dirty", .{ release, distance, hash })
    else
        b.fmt("{s}-dev.{s}+g{s}", .{ release, distance, hash });
}
