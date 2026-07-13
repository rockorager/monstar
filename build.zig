const std = @import("std");
const Scanner = @import("wayland").Scanner;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const scanner = Scanner.create(b, .{});
    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    scanner.addSystemProtocol("stable/viewporter/viewporter.xml");
    scanner.addSystemProtocol("stable/tablet/tablet-v2.xml");
    scanner.addSystemProtocol("staging/xdg-activation/xdg-activation-v1.xml");
    scanner.addSystemProtocol("staging/fractional-scale/fractional-scale-v1.xml");
    scanner.addSystemProtocol("staging/cursor-shape/cursor-shape-v1.xml");
    scanner.addSystemProtocol("staging/xdg-system-bell/xdg-system-bell-v1.xml");
    scanner.addSystemProtocol("staging/xdg-toplevel-icon/xdg-toplevel-icon-v1.xml");
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
    translate_c.linkSystemLibrary("dbus-1", .{});
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
        root_module.addImport(
            "uucode",
            ghostty_vt.import_table.get("uucode") orelse
                @panic("ghostty-vt does not provide uucode"),
        );
    }

    const exe = b.addExecutable(.{
        .name = "monstar",
        .root_module = root_module,
        // uucode's generated tables crash the x86_64 self-hosted backend on
        // Zig 0.16. Ghostty uses LLVM for the same reason.
        .use_llvm = true,
    });
    root_module.addCSourceFile(.{ .file = b.path("vendor/stb_image_resize.c") });
    root_module.addCSourceFile(.{ .file = b.path("vendor/stb_image.c") });

    b.installArtifact(exe);
    b.installFile("dist/dev.rockorager.monstar.desktop", "share/applications/dev.rockorager.monstar.desktop");
    b.installFile("dist/dev.rockorager.monstar.svg", "share/icons/hicolor/scalable/apps/dev.rockorager.monstar.svg");
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
