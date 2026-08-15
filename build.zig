const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const snail_dep = b.dependency("snail", .{ .target = target, .optimize = optimize });
    const stemma_dep = b.dependency("stemma", .{ .target = target, .optimize = optimize });

    // ── Desktop (Wayland) executable ──
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("snail", snail_dep.module("snail"));
    // SPIR-V-only shader scope: slangc runs inside snail's build; scion
    // consumes blobs + the reflection ABI through this module.
    exe_mod.addImport("snail_shaders", snail_dep.module("snail-shaders-vk"));
    exe_mod.addImport("stemma", stemma_dep.module("stemma"));
    // Default monospace face, embedded from snail's asset set (DejaVu:
    // free license, full box-drawing coverage). `--font` overrides.
    exe_mod.addAnonymousImport("font_mono", .{
        .root_source_file = snail_dep.path("assets/DejaVuSansMono.ttf"),
    });
    exe_mod.linkSystemLibrary("wayland-client", .{});
    exe_mod.linkSystemLibrary("xkbcommon", .{});
    exe_mod.linkSystemLibrary("vulkan", .{});
    addWaylandProtocols(b, exe_mod);

    const exe = b.addExecutable(.{
        .name = "scion",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run scion");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    // ── Tests ──
    // Platform-free logic tests (input queue etc.) plus dependency smoke
    // tests proving the snail/stemma wiring; no display server required.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addImport("snail", snail_dep.module("snail"));
    test_mod.addImport("stemma", stemma_dep.module("stemma"));
    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}

/// Generate the xdg-shell client glue with wayland-scanner and add it to
/// the module: header for @cImport, private code compiled in.
fn addWaylandProtocols(b: *std.Build, mod: *std.Build.Module) void {
    const pkgdatadir_raw = b.run(&.{ "pkg-config", "--variable=pkgdatadir", "wayland-protocols" });
    const pkgdatadir = std.mem.trim(u8, pkgdatadir_raw, " \t\r\n");
    const xdg_shell_xml = std.Build.LazyPath{
        .cwd_relative = b.pathJoin(&.{ pkgdatadir, "stable", "xdg-shell", "xdg-shell.xml" }),
    };

    const gen_header = b.addSystemCommand(&.{ "wayland-scanner", "client-header" });
    gen_header.addFileArg(xdg_shell_xml);
    const header = gen_header.addOutputFileArg("xdg-shell-client-protocol.h");

    const gen_code = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
    gen_code.addFileArg(xdg_shell_xml);
    const code = gen_code.addOutputFileArg("xdg-shell-client-protocol.c");

    mod.addIncludePath(header.dirname());
    mod.addCSourceFile(.{ .file = code });
}
