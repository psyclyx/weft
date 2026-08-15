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
    addScripting(b, exe_mod);
    addSyntax(b, exe_mod);

    const exe = b.addExecutable(.{
        .name = "scion",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    // ── Headless host agent ──
    // Dep-graph enforcement is structural: this module gets stemma and
    // libc only. Importing snail/wayland/vulkan/lua/tree-sitter code
    // from src/agent.zig fails to resolve — the build IS the check.
    const agent_mod = b.createModule(.{
        .root_source_file = b.path("src/agent.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    agent_mod.addImport("stemma", stemma_dep.module("stemma"));
    const agent = b.addExecutable(.{
        .name = "scion-agent",
        .root_module = agent_mod,
    });
    b.installArtifact(agent);

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
    addScripting(b, test_mod);
    addSyntax(b, test_mod);
    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}

/// Lua 5.4 + the embedded fennel compiler (milestone 5). The fennel.lua
/// path comes from the nix shell (pinned package) — hermetic without a
/// vendored copy.
fn addScripting(b: *std.Build, mod: *std.Build.Module) void {
    mod.linkSystemLibrary("lua", .{});
    const fennel = b.graph.environ_map.get("SCION_FENNEL_LUA") orelse
        @panic("SCION_FENNEL_LUA not set — build inside the nix shell");
    mod.addAnonymousImport("fennel.lua", .{
        .root_source_file = .{ .cwd_relative = fennel },
    });
}

/// Tree-sitter (milestone 7): the library links normally; grammar
/// packages contribute a runtime dlopen path (baked via build options)
/// and an embedded highlight query, both from pinned store paths.
fn addSyntax(b: *std.Build, mod: *std.Build.Module) void {
    mod.linkSystemLibrary("tree-sitter", .{});
    const opts = b.addOptions();
    const grammars = [_]struct {
        env: []const u8,
        opt: []const u8,
        import: []const u8,
        /// In-repo query for grammar packages that ship none.
        local_query: ?[]const u8 = null,
    }{
        .{ .env = "SCION_TS_ZIG", .opt = "ts_zig", .import = "ts_zig_highlights" },
        .{
            .env = "SCION_TS_FENNEL",
            .opt = "ts_fennel",
            .import = "ts_fennel_highlights",
            .local_query = "assets/fennel-highlights.scm",
        },
        .{ .env = "SCION_TS_LUA", .opt = "ts_lua", .import = "ts_lua_highlights" },
        .{ .env = "SCION_TS_NIX", .opt = "ts_nix", .import = "ts_nix_highlights" },
    };
    inline for (grammars) |g| {
        const dir = b.graph.environ_map.get(g.env) orelse
            @panic(g.env ++ " not set — build inside the nix shell");
        opts.addOption([]const u8, g.opt, dir);
        const query: std.Build.LazyPath = if (g.local_query) |lq|
            b.path(lq)
        else
            .{ .cwd_relative = b.pathJoin(&.{ dir, "queries", "highlights.scm" }) };
        mod.addAnonymousImport(g.import, .{ .root_source_file = query });
    }
    mod.addOptions("build_options", opts);
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
