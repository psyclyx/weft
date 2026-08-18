const std = @import("std");

/// The reference wasm guest plugins (src/guest/*.zig). `install` plugins are
/// the shippable reference catalog: built to `.wasm` and installed to
/// `lib/weft/plugins/` as external artifacts a user loads with `--plugin` —
/// NOT baked into the binary. weft itself ships modeless. The non-`install`
/// guests are test fixtures (a bare hello, a perm-violating rogue, a demo
/// config) exercised only by the wasm-membrane suite, embedded into the test
/// module below.
const Guest = struct { src: []const u8, import: []const u8, install: bool };
const guests = [_]Guest{
    .{ .src = "src/guest/hello.zig", .import = "guest_hello_wasm", .install = false },
    .{ .src = "src/guest/plugin.zig", .import = "guest_plugin_wasm", .install = false },
    .{ .src = "src/guest/rogue.zig", .import = "guest_rogue_wasm", .install = false },
    .{ .src = "src/guest/demo_config.zig", .import = "guest_demo_config_wasm", .install = false },
    .{ .src = "src/guest/edit.zig", .import = "guest_edit_wasm", .install = true },
    .{ .src = "src/guest/complete.zig", .import = "guest_complete_wasm", .install = true },
    .{ .src = "src/guest/project.zig", .import = "guest_project_wasm", .install = true },
    .{ .src = "src/guest/palette.zig", .import = "guest_palette_wasm", .install = true },
    .{ .src = "src/guest/structural.zig", .import = "guest_structural_wasm", .install = true },
    .{ .src = "src/guest/ts.zig", .import = "guest_ts_wasm", .install = true },
    .{ .src = "src/guest/region.zig", .import = "guest_region_wasm", .install = true },
    .{ .src = "src/guest/shell.zig", .import = "guest_shell_wasm", .install = true },
    .{ .src = "src/guest/motions.zig", .import = "guest_motions_wasm", .install = true },
    .{ .src = "src/guest/textobjects.zig", .import = "guest_textobjects_wasm", .install = true },
    .{ .src = "src/guest/operators.zig", .import = "guest_operators_wasm", .install = true },
    .{ .src = "src/guest/vim.zig", .import = "guest_vim_wasm", .install = true },
    .{ .src = "src/guest/comment.zig", .import = "guest_comment_wasm", .install = true },
    .{ .src = "src/guest/whitespace.zig", .import = "guest_whitespace_wasm", .install = true },
    .{ .src = "src/guest/numbers.zig", .import = "guest_numbers_wasm", .install = true },
    .{ .src = "src/guest/autopair.zig", .import = "guest_autopair_wasm", .install = true },
    .{ .src = "src/guest/consult.zig", .import = "guest_consult_wasm", .install = true },
    .{ .src = "src/guest/git.zig", .import = "guest_git_wasm", .install = true },
    .{ .src = "src/guest/grep.zig", .import = "guest_grep_wasm", .install = true },
    .{ .src = "src/guest/run.zig", .import = "guest_run_wasm", .install = true },
    .{ .src = "src/guest/make.zig", .import = "guest_make_wasm", .install = true },
    .{ .src = "src/guest/notes.zig", .import = "guest_notes_wasm", .install = true },
    .{ .src = "src/guest/fmt.zig", .import = "guest_fmt_wasm", .install = true },
    .{ .src = "src/guest/buffers.zig", .import = "guest_buffers_wasm", .install = true },
    .{ .src = "src/guest/windows.zig", .import = "guest_windows_wasm", .install = true },
    .{ .src = "src/guest/modes.zig", .import = "guest_modes_wasm", .install = true },
};

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
    // SPIR-V-only shader scope: slangc runs inside snail's build; weft
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
    // Runtime font-family resolution (sans/mono, weight, slant). System
    // fonts, not pinned — see src/gfx/fonts.zig.
    exe_mod.linkSystemLibrary("fontconfig", .{});
    addWaylandProtocols(b, exe_mod);
    addSyntax(b, exe_mod);
    addWasm(b, exe_mod);
    addQuickjs(b, exe_mod);

    const exe = b.addExecutable(.{
        .name = "weft",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    // The reference plugins ship as external `.wasm` under lib/weft/plugins/,
    // not embedded — weft's binary carries no catalog. Load one with e.g.
    // `--plugin zig-out/lib/weft/plugins/vim.wasm`.
    installPlugins(b);

    // The former weft-agent is folded into `weft --headless`
    // (src/headless.zig): one binary, every weft a peer. The old
    // build-time dep-graph isolation went with it — headless.zig's
    // discipline is that it imports core/ only, reviewed not enforced.

    const run_step = b.step("run", "Run weft");
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
    // CPU rasterizer — a display-free render-to-pixels harness for the
    // view (gfx/harness.zig), so layout/decoration output can be asserted
    // and dumped to an image without a compositor.
    test_mod.addImport("snail-raster", snail_dep.module("snail-raster"));
    test_mod.addImport("stemma", stemma_dep.module("stemma"));
    // Same embedded mono face the exe uses — lets layout tests prove the
    // monospace-as-degenerate-case parity (stop.x == margin + col*cell_w).
    test_mod.addAnonymousImport("font_mono", .{
        .root_source_file = snail_dep.path("assets/DejaVuSansMono.ttf"),
    });
    test_mod.linkSystemLibrary("fontconfig", .{}); // View tests resolve faces
    addSyntax(b, test_mod);
    addWasm(b, test_mod);
    embedGuests(b, test_mod);
    addQuickjs(b, test_mod);
    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}

/// Tree-sitter (milestone 7): the library links normally; grammar
/// packages contribute a runtime dlopen path (baked via build options)
/// and an embedded highlight query, both from pinned store paths.
/// Compile one guest plugin (src/guest/*.zig) to a `wasm32-freestanding`
/// reactor module — no `_start`, exported functions + memory via rdynamic —
/// so the host can instantiate it under wasmtime.
fn buildGuest(b: *std.Build, src: []const u8) *std.Build.Step.Compile {
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const guest = b.addExecutable(.{
        .name = std.fs.path.stem(src),
        .root_module = b.createModule(.{
            .root_source_file = b.path(src),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
        }),
    });
    guest.entry = .disabled; // reactor: called through exports, not _start
    guest.rdynamic = true; // export the `export fn`s + memory
    return guest;
}

/// Embed every guest's `.wasm` bytes into a module. Used only by the test
/// module: the wasm-membrane suite loads the reference plugins and the perm
/// fixtures from `@embedFile`. The shipped binary embeds none of them.
fn embedGuests(b: *std.Build, mod: *std.Build.Module) void {
    inline for (guests) |g| {
        const guest = buildGuest(b, g.src);
        mod.addAnonymousImport(g.import, .{ .root_source_file = guest.getEmittedBin() });
    }
}

/// Install the reference plugins as external `.wasm` artifacts under
/// `lib/weft/plugins/`. These are what a user loads with `--plugin`; weft
/// carries no catalog in-process.
fn installPlugins(b: *std.Build) void {
    @setEvalBranchQuota(10_000); // the guest list grows; comptime `stem` per entry
    inline for (guests) |g| {
        if (!g.install) continue;
        const guest = buildGuest(b, g.src);
        const name = comptime std.fs.path.stem(g.src);
        const inst = b.addInstallFileWithDir(guest.getEmittedBin(), .lib, "weft/plugins/" ++ name ++ ".wasm");
        b.getInstallStep().dependOn(&inst.step);
    }
}

/// QuickJS-ng compiled to a `wasm32-wasi` reactor (milestone 5 / 06B): the
/// runtime behind user `config.js`. We invoke the same `zig cc` that builds
/// weft on the pinned quickjs-ng source (`WEFT_QUICKJS_NG_SRC`, an unpacked
/// srcOnly tree) plus our embedding shim (src/quickjs/weft_qjs.c), following
/// quickjs-ng's own WASI recipe, and embed the resulting module. Reactor
/// model: exports `weft_eval`/`malloc`/`free`/`memory`, imports only
/// `wasi_snapshot_preview1` (the host provides those through wasmtime).
fn addQuickjs(b: *std.Build, host_mod: *std.Build.Module) void {
    const ng = b.graph.environ_map.get("WEFT_QUICKJS_NG_SRC") orelse
        @panic("WEFT_QUICKJS_NG_SRC not set — build inside the nix shell");
    const cc = b.addSystemCommand(&.{
        b.graph.zig_exe,           "cc",
        "-target",                 "wasm32-wasi",
        "-mexec-model=reactor",    "-Os",
        "-D_GNU_SOURCE",           "-D_WASI_EMULATED_PROCESS_CLOCKS",
        "-D_WASI_EMULATED_SIGNAL",
    });
    cc.addArg(b.fmt("-I{s}", .{ng}));
    // The engine core (quickjs-ng's `qjs` library sources).
    inline for (.{ "dtoa.c", "libregexp.c", "libunicode.c", "quickjs.c" }) |f| {
        cc.addArg(b.pathJoin(&.{ ng, f }));
    }
    // Our embedding shim (tracked — rebuilds when it changes).
    cc.addFileArg(b.path("src/quickjs/weft_qjs.c"));
    cc.addArgs(&.{
        "-lwasi-emulated-process-clocks",
        "-lwasi-emulated-signal",
        "-Wl,--export=weft_eval",
        "-Wl,--export=malloc",
        "-Wl,--export=free",
        "-o",
    });
    const out = cc.addOutputFileArg("quickjs.wasm");
    host_mod.addAnonymousImport("quickjs_wasm", .{ .root_source_file = out });
}

/// Wasmtime C embedding API (milestone 5): the plugin sandbox runtime.
/// Wasmtime ships no pkg-config, so — like the grammar packages — we take
/// the dev (headers) and lib (libwasmtime.so) store paths from the nix shell
/// and wire them explicitly, then link the library.
fn addWasm(b: *std.Build, mod: *std.Build.Module) void {
    const dev = b.graph.environ_map.get("WEFT_WASMTIME_DEV") orelse
        @panic("WEFT_WASMTIME_DEV not set — build inside the nix shell");
    const lib = b.graph.environ_map.get("WEFT_WASMTIME_LIB") orelse
        @panic("WEFT_WASMTIME_LIB not set — build inside the nix shell");
    mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ dev, "include" }) });
    mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ lib, "lib" }) });
    mod.linkSystemLibrary("wasmtime", .{});
}

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
        .{ .env = "WEFT_TS_ZIG", .opt = "ts_zig", .import = "ts_zig_highlights" },
        .{
            .env = "WEFT_TS_FENNEL",
            .opt = "ts_fennel",
            .import = "ts_fennel_highlights",
            .local_query = "assets/fennel-highlights.scm",
        },
        .{ .env = "WEFT_TS_LUA", .opt = "ts_lua", .import = "ts_lua_highlights" },
        .{ .env = "WEFT_TS_NIX", .opt = "ts_nix", .import = "ts_nix_highlights" },
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
