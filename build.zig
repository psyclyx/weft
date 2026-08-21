const std = @import("std");

/// Which renderer to compile+link. Mutually exclusive: exactly one backend's
/// code and deps are pulled in. `skia` (default) links the C++ Skia shim and
/// libskia; `snail` links snail's own Vulkan pipeline + SPIR-V shaders. The
/// choice is surfaced to Zig as `build_options.renderer`, and `app/render.zig`
/// comptime-switches on it so the unselected backend is never analyzed.
const Renderer = enum { skia, snail };

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
    .{ .src = "src/guest/deny.zig", .import = "guest_deny_wasm", .install = false },
    .{ .src = "src/guest/demo_config.zig", .import = "guest_demo_config_wasm", .install = false },
    .{ .src = "src/guest/headtest.zig", .import = "guest_headtest_wasm", .install = false },
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
    .{ .src = "src/guest/lsp.zig", .import = "guest_lsp_wasm", .install = true },
    .{ .src = "src/guest/indent.zig", .import = "guest_indent_wasm", .install = true },
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
    .{ .src = "src/guest/snippets.zig", .import = "guest_snippets_wasm", .install = true },
    .{ .src = "src/guest/direnv.zig", .import = "guest_direnv_wasm", .install = true },
    .{ .src = "src/guest/llm.zig", .import = "guest_llm_wasm", .install = true },
    .{ .src = "src/guest/console.zig", .import = "guest_console_wasm", .install = true },
    .{ .src = "src/guest/repl.zig", .import = "guest_repl_wasm", .install = true },
    .{ .src = "src/guest/net.zig", .import = "guest_net_wasm", .install = true },
    .{ .src = "src/guest/http.zig", .import = "guest_http_wasm", .install = true },
    .{ .src = "src/guest/which_key.zig", .import = "guest_which_key_wasm", .install = true },
    .{ .src = "src/guest/dired.zig", .import = "guest_dired_wasm", .install = true },
    .{ .src = "src/guest/helix.zig", .import = "guest_helix_wasm", .install = true },
    .{ .src = "src/guest/emacs.zig", .import = "guest_emacs_wasm", .install = true },
    .{ .src = "src/guest/debug.zig", .import = "guest_debug_wasm", .install = true },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const renderer = b.option(Renderer, "renderer", "GPU renderer backend (skia|snail); default skia") orelse .skia;

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
    // consumes blobs + the reflection ABI through this module. Snail-renderer
    // only — a Skia build never analyzes snail_vk, so it must not pull the
    // shader compile either (mutual exclusivity, requirement 1).
    if (renderer == .snail) exe_mod.addImport("snail_shaders", snail_dep.module("snail-shaders-vk"));
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
    addSyntax(b, exe_mod, renderer);
    addWasm(b, exe_mod);
    addQuickjs(b, exe_mod);
    if (renderer == .skia) addSkia(b, exe_mod);

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

    // The weft app internals (core + gfx + app) exposed as ONE named module the
    // e2e harness imports by name (src/weft.zig barrel), so its files under
    // src/e2e/ reach the tree without `../` reach-arounds. Same deps those files
    // need, wired here; guests stay test-only (embedded into test_mod, not here).
    const weft_mod = b.createModule(.{
        .root_source_file = b.path("src/weft.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    weft_mod.addImport("snail", snail_dep.module("snail"));
    weft_mod.addImport("snail-raster", snail_dep.module("snail-raster"));
    weft_mod.addImport("stemma", stemma_dep.module("stemma"));
    weft_mod.addAnonymousImport("font_mono", .{
        .root_source_file = snail_dep.path("assets/DejaVuSansMono.ttf"),
    });
    weft_mod.linkSystemLibrary("fontconfig", .{});
    addSyntax(b, weft_mod, renderer);
    addWasm(b, weft_mod);
    embedGuests(b, weft_mod); // core's own wasm-membrane tests @embedFile the catalog
    addQuickjs(b, weft_mod);

    // `test_mod` (the `test` step) and `latency_mod` (the `e2e-latency` step,
    // below) are two SEPARATE module objects, wired IDENTICALLY through this
    // one function — see the note by `latency_mod` for why they must be
    // separate objects. Same doctrine as harness.zig's `press` delegating to
    // `pressTimed`: one implementation of the wiring, not two copies that can
    // quietly drift apart.
    configureTestModule(b, test_mod, snail_dep, stemma_dep, weft_mod, renderer);

    // The dispatch-latency instrument's record/compare switch (north-star-plan
    // W0a/C10 — src/e2e/latency_test.zig). `test_mod` — the module the plain
    // `test` step compiles — is HARDCODED to compare-only, always, regardless
    // of `-Drecord-latency`: it's a module OBJECT, shared verbatim by every
    // Step.Compile rooted at it, so wiring the live CLI flag into it would let
    // `zig build test -Drecord-latency=true` silently overwrite the committed
    // baseline as a side effect of an ordinary test run. The live flag is
    // wired only into `latency_mod` below, a separate module used exclusively
    // by the dedicated `e2e-latency` step.
    const compare_only_opts = b.addOptions();
    compare_only_opts.addOption(bool, "record", false);
    test_mod.addOptions("latency_options", compare_only_opts);

    // The same record/compare doctrine for the popup-layout golden gate
    // (rendering P2's guard — src/e2e/popup_layout_test.zig): `test_mod` is
    // HARDCODED to compare-only for the identical reason (a plain `zig build
    // test -Drecord-popup-layout=true` must never be able to overwrite the
    // committed goldens as a side effect of an ordinary run). The live flag
    // is wired only into `popup_layout_mod` below.
    //
    // The option's FIELD NAME is `record_popup_layout`, not `record` (unlike
    // `latency_options` above) — purely so the generated options SOURCE FILE
    // differs from `compare_only_opts`'s. `b.addOptions()` content-addresses
    // its emitted file; an identical `pub const record: bool = false;` body
    // would hash to the SAME generated file as the latency one, and Zig
    // refuses to let one physical file root two different named modules
    // ("file exists in modules 'latency_options' and 'popup_layout_options'").
    const compare_only_popup_opts = b.addOptions();
    compare_only_popup_opts.addOption(bool, "record_popup_layout", false);
    test_mod.addOptions("popup_layout_options", compare_only_popup_opts);

    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // The `weft` module owns the core/gfx/app files, so its own unit tests run in
    // a second test binary; the `test` step runs both.
    const weft_tests = b.addTest(.{ .root_module = weft_mod });
    const run_weft_tests = b.addRunArtifact(weft_tests);
    test_step.dependOn(&run_weft_tests.step);

    // A second copy of `test_mod`'s wiring — same `configureTestModule` call,
    // so it cannot drift — used ONLY by the `e2e-latency` step below.
    // `-Drecord-latency` is a COMPTIME option here, not a runtime env var: it
    // has to change this module's compiled output, or `zig build`'s artifact
    // caching would happily replay a stale cached run instead of re-executing
    // in the new mode.
    const record_latency = b.option(
        bool,
        "record-latency",
        "With `zig build e2e-latency`: record the dispatch-latency baseline (src/e2e/latency_baseline.zon) instead of comparing against it. No effect on the `test` step.",
    ) orelse false;
    const latency_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    configureTestModule(b, latency_mod, snail_dep, stemma_dep, weft_mod, renderer);
    const latency_opts = b.addOptions();
    latency_opts.addOption(bool, "record", record_latency);
    latency_mod.addOptions("latency_options", latency_opts);

    // A dedicated step for the latency instrument alone (the full `test` step
    // already runs it too, in compare mode, as part of the e2e suite) — a fast
    // way to iterate on it, and the documented way to re-record:
    //   zig build e2e-latency                          # compare against the baseline
    //   zig build e2e-latency -Drecord-latency=true     # (re-)record the baseline
    const latency_tests = b.addTest(.{ .root_module = latency_mod, .filters = &.{"e2e/latency"} });
    const run_latency_tests = b.addRunArtifact(latency_tests);
    const latency_step = b.step("e2e-latency", "Run (or, with -Drecord-latency=true, record) the dispatch-latency baseline");
    latency_step.dependOn(&run_latency_tests.step);

    // Same doctrine, third instrument: the popup-layout golden gate
    // (rendering P2's guard). A THIRD separate module object — not reused
    // from `latency_mod` — for the identical reason `latency_mod` isn't
    // `test_mod`: the record flag has to be baked into the compiled output,
    // and two instruments sharing one module would mean recording one
    // baseline silently forces a rebuild (and re-run) of the other under the
    // same flag, which is a surprising coupling neither instrument asked for.
    const record_popup_layout = b.option(
        bool,
        "record-popup-layout",
        "With `zig build e2e-popup-layout`: record the caret-popup layout goldens (src/e2e/popup_layout_baseline.zon) instead of comparing against them. No effect on the `test` step.",
    ) orelse false;
    const popup_layout_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    configureTestModule(b, popup_layout_mod, snail_dep, stemma_dep, weft_mod, renderer);
    const popup_layout_opts = b.addOptions();
    popup_layout_opts.addOption(bool, "record_popup_layout", record_popup_layout);
    popup_layout_mod.addOptions("popup_layout_options", popup_layout_opts);

    // A dedicated step for the popup-layout gate alone (the full `test` step
    // already runs it too, in compare mode) — the documented way to re-record
    // after a deliberate, EXPLAINED layout change:
    //   zig build e2e-popup-layout                                # compare
    //   zig build e2e-popup-layout -Drecord-popup-layout=true      # re-record
    //   zig fmt src/e2e/popup_layout_baseline.zon                  # then canonicalize it —
    //     `std.zon.stringify`'s raw output isn't always zig-fmt's chosen layout for
    //     deeply nested data (unlike the flatter `latency_baseline.zon`, which happens
    //     to already match); the `test`/`e2e-popup-layout` steps don't run `zig fmt`
    //     themselves, so a fresh recording needs this by hand before it's committed.
    const popup_layout_tests = b.addTest(.{ .root_module = popup_layout_mod, .filters = &.{"e2e/popup-layout"} });
    const run_popup_layout_tests = b.addRunArtifact(popup_layout_tests);
    const popup_layout_step = b.step("e2e-popup-layout", "Run (or, with -Drecord-popup-layout=true, record) the caret-popup layout goldens");
    popup_layout_step.dependOn(&run_popup_layout_tests.step);
}

/// Wire the shared test-module dependency set (snail/snail-raster/stemma/
/// embedded font/fontconfig/syntax/wasmtime/embedded guests/quickjs/weft)
/// onto `mod`. `test_mod` (the `test` step) and `latency_mod` (the
/// `e2e-latency` step) both call this — it's the ONLY place that wiring is
/// written, so the two binaries cannot drift apart the way two hand-copied
/// blocks eventually would. The one thing that may legitimately differ
/// between callers is added AFTER this returns: which `latency_options`
/// value they attach.
fn configureTestModule(
    b: *std.Build,
    mod: *std.Build.Module,
    snail_dep: *std.Build.Dependency,
    stemma_dep: *std.Build.Dependency,
    weft_mod: *std.Build.Module,
    renderer: Renderer,
) void {
    mod.addImport("snail", snail_dep.module("snail"));
    // CPU rasterizer — a display-free render-to-pixels harness for the
    // view (gfx/harness.zig), so layout/decoration output can be asserted
    // and dumped to an image without a compositor.
    mod.addImport("snail-raster", snail_dep.module("snail-raster"));
    mod.addImport("stemma", stemma_dep.module("stemma"));
    // Same embedded mono face the exe uses — lets layout tests prove the
    // monospace-as-degenerate-case parity (stop.x == margin + col*cell_w).
    mod.addAnonymousImport("font_mono", .{
        .root_source_file = snail_dep.path("assets/DejaVuSansMono.ttf"),
    });
    mod.linkSystemLibrary("fontconfig", .{}); // View tests resolve faces
    addSyntax(b, mod, renderer);
    addWasm(b, mod);
    embedGuests(b, mod);
    addQuickjs(b, mod);
    mod.addImport("weft", weft_mod);
}

/// Tree-sitter (milestone 7): the library links normally; grammar
/// packages contribute a runtime dlopen path (baked via build options)
/// and an embedded highlight query, both from pinned store paths.
/// Compile one guest plugin (src/guest/*.zig) to a `wasm32-freestanding`
/// reactor module — no `_start`, exported functions + memory via rdynamic —
/// so the host can instantiate it under wasmtime.
fn buildGuest(b: *std.Build, src: []const u8) *std.Build.Step.Compile {
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const guest_mod = b.createModule(.{
        .root_source_file = b.path(src),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    // src/guest/weft.zig comptime-verifies its hand-written externs against
    // core/membrane/contract_data.zig's signedness table (task W0a-D) — a
    // plain relative `@import("../core/membrane/contract_data.zig")` fails
    // ("import of file outside module path": each guest is its own module,
    // rooted at src/guest/, and Zig 0.16 won't let a relative import escape
    // that root). Wire it as a named import instead, same target as the
    // guest itself (contract_data.zig has zero host-only deps — no
    // wasmtime, no wasm_host — by design, so it compiles fine here too).
    guest_mod.addImport("membrane_contract_data", b.createModule(.{
        .root_source_file = b.path("src/core/membrane/contract_data.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    }));
    const guest = b.addExecutable(.{
        .name = std.fs.path.stem(src),
        .root_module = guest_mod,
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
    // JS plugins (config/plugins/*.js) — resident quickjs plugins (e.g. the ACP
    // agent client) — install verbatim beside the .wasm catalog, loadable by
    // name (`weft.plugin("acp.js")`).
    inline for (js_plugins) |name| {
        const inst = b.addInstallFileWithDir(b.path("config/plugins/" ++ name), .lib, "weft/plugins/" ++ name);
        b.getInstallStep().dependOn(&inst.step);
    }
}

/// JS plugins shipped in the reference catalog (config/plugins/*.js).
const js_plugins = [_][]const u8{ "acp.js", "dap.js" };

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

/// Skia (default renderer): compile the C++ shim (src/gfx/skia/shim.cpp) with
/// g++ against Skia's headers, then link the object + libskia + libstdc++ into
/// the Zig exe. Resolved via **pkg-config** (Skia ships a `skia.pc`) — no env
/// var; skia is a shell.nix buildInput, so its pkgconfig is on PKG_CONFIG_PATH,
/// the same idiom every other dep uses. g++ (not Zig's clang) builds the shim
/// so it resolves its own GNU libstdc++ ABI — which Skia's Ganesh init requires
/// (it hands Skia a std::function); only the C ABI in shim.h crosses to Zig.
fn addSkia(b: *std.Build, mod: *std.Build.Module) void {
    // Skia's include dir (`include/skia`) from its pkg-config.
    const cflags = b.run(&.{ "pkg-config", "--cflags-only-I", "skia" });
    // libstdc++'s real path — `zig cc`'s `-lstdc++` substitutes LLVM libc++
    // (missing the GNU symbols), so link the real .so positionally instead;
    // lld adds it as a DT_NEEDED, resolved at run time via LD_LIBRARY_PATH.
    const libstdcpp = std.mem.trim(u8, b.run(&.{ "g++", "-print-file-name=libstdc++.so" }), " \t\r\n");

    // Separate g++ compile → object; -fno-exceptions/-fno-rtti match how
    // nixpkgs builds Skia and keep the shim from pulling libgcc's unwinder
    // (_Unwind_Resume) into the Zig link.
    const cc = b.addSystemCommand(&.{ "g++", "-std=c++17", "-c", "-O2", "-fPIC", "-fno-rtti", "-fno-exceptions" });
    var it = std.mem.tokenizeAny(u8, cflags, " \t\r\n");
    while (it.next()) |tok| cc.addArg(b.dupe(tok));
    cc.addFileArg(b.path("src/gfx/skia/shim.cpp"));
    cc.addArg("-o");
    const obj = cc.addOutputFileArg("weft_skia_shim.o");
    mod.addObjectFile(obj);

    mod.linkSystemLibrary("skia", .{}); // -L/-lskia from pkg-config
    mod.addObjectFile(.{ .cwd_relative = libstdcpp });
}

fn addSyntax(b: *std.Build, mod: *std.Build.Module, renderer: Renderer) void {
    mod.linkSystemLibrary("tree-sitter", .{});
    const opts = b.addOptions();
    // The selected renderer, read by gfx/context.zig + app/render.zig to
    // comptime-switch backends (skia vs snail_vk). Shares the one
    // `build_options` module the grammar paths already ride on.
    opts.addOption(Renderer, "renderer", renderer);
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
