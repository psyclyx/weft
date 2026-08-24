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

/// Compiler-enforced subsystem boundaries. Cross-module code imports these
/// names; relative imports are reserved for implementation files beneath the
/// corresponding module root.
const ArchitectureModules = struct {
    wire: *std.Build.Module,
    schema: *std.Build.Module,
    semantic: *std.Build.Module,
    scene_codec: *std.Build.Module,
    fs: *std.Build.Module,
    fs_codec: *std.Build.Module,
    fs_runtime: *std.Build.Module,
    view_runtime: *std.Build.Module,
    target_runtime: *std.Build.Module,
    plugin_semantic: *std.Build.Module,
};

fn createArchitectureModules(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) ArchitectureModules {
    const wire = b.createModule(.{
        .root_source_file = b.path("src/core/wire.zig"),
        .target = target,
        .optimize = optimize,
    });
    const schema = b.createModule(.{
        .root_source_file = b.path("src/core/schema.zig"),
        .target = target,
        .optimize = optimize,
    });
    schema.addImport("weft_wire", wire);
    const semantic = b.createModule(.{
        .root_source_file = b.path("src/semantic_model/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    semantic.addImport("weft_schema", schema);
    const scene_codec = b.createModule(.{
        .root_source_file = b.path("src/scene_codec/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    scene_codec.addImport("weft_semantic", semantic);
    scene_codec.addImport("weft_schema", schema);
    const fs = b.createModule(.{
        .root_source_file = b.path("src/fs/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    fs.addImport("weft_semantic", semantic);
    const fs_codec = b.createModule(.{
        .root_source_file = b.path("src/fs_codec/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    fs_codec.addImport("weft_semantic", semantic);
    fs_codec.addImport("weft_fs", fs);
    const fs_runtime = b.createModule(.{
        .root_source_file = b.path("src/fs_runtime/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    fs_runtime.addImport("weft_semantic", semantic);
    fs_runtime.addImport("weft_fs", fs);
    const view_runtime = b.createModule(.{
        .root_source_file = b.path("src/view_runtime/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    view_runtime.addImport("weft_semantic", semantic);
    const target_runtime = b.createModule(.{
        .root_source_file = b.path("src/target_runtime/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    target_runtime.addImport("weft_semantic", semantic);
    // Filesystem publication composes two independent named interfaces: the
    // target registry owns descriptive identity, while the filesystem router
    // owns executable authority. Neither contract reaches through the other.
    fs_runtime.addImport("weft_target_runtime", target_runtime);
    const plugin_semantic = b.createModule(.{
        .root_source_file = b.path("src/plugin_semantic/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    plugin_semantic.addImport("weft_semantic", semantic);
    plugin_semantic.addImport("weft_view_runtime", view_runtime);
    plugin_semantic.addImport("weft_target_runtime", target_runtime);
    plugin_semantic.addImport("weft_scene_codec", scene_codec);
    return .{
        .wire = wire,
        .schema = schema,
        .semantic = semantic,
        .scene_codec = scene_codec,
        .fs = fs,
        .fs_codec = fs_codec,
        .fs_runtime = fs_runtime,
        .view_runtime = view_runtime,
        .target_runtime = target_runtime,
        .plugin_semantic = plugin_semantic,
    };
}

fn addArchitectureImports(mod: *std.Build.Module, architecture: ArchitectureModules) void {
    mod.addImport("weft_wire", architecture.wire);
    mod.addImport("weft_schema", architecture.schema);
    mod.addImport("weft_semantic", architecture.semantic);
    mod.addImport("weft_scene_codec", architecture.scene_codec);
    mod.addImport("weft_fs", architecture.fs);
    mod.addImport("weft_fs_codec", architecture.fs_codec);
    mod.addImport("weft_fs_runtime", architecture.fs_runtime);
    mod.addImport("weft_view_runtime", architecture.view_runtime);
    mod.addImport("weft_target_runtime", architecture.target_runtime);
    mod.addImport("weft_plugin_semantic", architecture.plugin_semantic);
}

const guests = [_]Guest{
    .{ .src = "src/guest/hello.zig", .import = "guest_hello_wasm", .install = false },
    .{ .src = "src/guest/plugin.zig", .import = "guest_plugin_wasm", .install = false },
    .{ .src = "src/guest/rogue.zig", .import = "guest_rogue_wasm", .install = false },
    .{ .src = "src/guest/deny.zig", .import = "guest_deny_wasm", .install = false },
    .{ .src = "src/guest/demo_config.zig", .import = "guest_demo_config_wasm", .install = false },
    .{ .src = "src/guest/headtest.zig", .import = "guest_headtest_wasm", .install = false },
    .{ .src = "src/guest/fs_limit.zig", .import = "guest_fs_limit_wasm", .install = false },
    // D2's worked example (doc/d2-schema-payloads.md §6) — a third-party
    // slot the wasm-membrane suite proves end to end; never shipped.
    .{ .src = "src/guest/badge.zig", .import = "guest_badge_wasm", .install = false },
    .{ .src = "src/guest/semantic_fixture.zig", .import = "guest_semantic_wasm", .install = false },
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

    const snail_opt = depOrOverride(b, "snail", "NPINS_OVERRIDE_SNAIL", .{ .target = target, .optimize = optimize });
    const stemma_opt = depOrOverride(b, "stemma", "NPINS_OVERRIDE_STEMMA", .{ .target = target, .optimize = optimize });
    // Both queried before unwrapping so a first-ever build discovers every
    // missing fetch in one round rather than one per re-run.
    const snail_dep = snail_opt orelse return;
    const stemma_dep = stemma_opt orelse return;
    const architecture = createArchitectureModules(b, target, optimize);
    // The app imports one stable platform-provider facade. Provider mechanism
    // is selected here; portable modules and plugins never import it.
    const fs_platform = b.createModule(.{
        .root_source_file = b.path(if (target.result.os.tag == .linux)
            "src/fs_linux/root.zig"
        else
            "src/fs_unavailable/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    fs_platform.addImport("weft_fs", architecture.fs);

    // ── Desktop (Wayland) executable ──
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addArchitectureImports(exe_mod, architecture);
    exe_mod.addImport("weft_fs_platform", fs_platform);
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
    addArchitectureImports(weft_mod, architecture);
    weft_mod.addImport("weft_fs_platform", fs_platform);
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

    // task #23 — READ THIS BEFORE treating `failed command: .../test
    // --listen=-` as a failure. It can print on a run where every test
    // PASSED (`Build Summary: ...; N/N tests passed`, exit 0) — it is not,
    // by itself, a build-protocol bug or a flake to chase. Root-caused by
    // reading Zig 0.16's build runner (lib/zig/compiler/build_runner.zig
    // `makeStep`, lib/zig/std/Build/Step/Run.zig `evalZigTest`):
    //
    //   1. A `--listen=-` test binary signals "no more tests" by finishing
    //      its last test and EXITING — which closes its stdout. The build
    //      runner's protocol reader sees that as `EndOfStream` (`no_poll`
    //      in `evalZigTest`) — THE SAME event a genuine mid-test crash
    //      produces. It disambiguates the two by checking `tests_done &&
    //      exited==0` afterward, but EITHER WAY it captures whatever the
    //      child wrote to its real stderr into `result_stderr` first,
    //      unconditionally.
    //   2. `makeStep` then prints that step's captured stderr + this
    //      `failed command:` line whenever `result_stderr.len > 0` — the
    //      comment there is literally "no matter the result" — regardless
    //      of whether the step went on to succeed.
    //   3. This suite's tests legitimately log at `.warn` to real stderr as
    //      their OWN assertion mechanism (wasm guest-trap / capability-
    //      denial fixtures — see `wasm.zig`'s `checkErr`/`checkTrap` and
    //      task #8's crash-observability doctrine below). That's expected,
    //      wanted test content, not a bug to silence — so `result_stderr`
    //      is routinely non-empty on an all-green run, and step 2 fires.
    //
    // Net: this text is cosmetic noise, not a signal. THE RELIABLE SIGNAL
    // is the process exit code (0 = every step + test genuinely passed —
    // `Step.make` only returns `error.MakeFailed`, which is what actually
    // fails the build, when `test_results.isSuccess()` is false, i.e. a
    // real `fail_count`/`crash_count`/`timeout_count`). Run `zig build test
    // --summary all` to also print the reassuring "N/N tests passed" line
    // alongside the noise (the default `--summary` is `failures`, which
    // prints NOTHING on a clean pass — so a noisy-but-green run shows only
    // the alarming half by default). A REAL failure looks different: it
    // additionally prints `error: 'test name' failed: ...` with a stack
    // trace (or `N errors were logged.` for an unexpected `.err` log)
    // BEFORE the `failed command:` line — that block's presence, not the
    // `failed command:` line, is what to act on.
    //
    // Neither `--summary` nor `--test-timeout` (the closest built-in lever
    // for a hung test) can be defaulted from here: both are `zig build`
    // CLI flags parsed by the build runner before `build()` runs, and
    // `std.Build.Step.Run` exposes no per-step field for either — verified
    // against this Zig's std/Build/Step/Run.zig and compiler/build_runner.zig.
    // So this can't be engineered away from build.zig; it's documented
    // here instead, at the one place a reader hits it.
    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // Portable contract gate: deliberately separate from the application
    // suite so these roots cannot acquire app/platform dependencies unnoticed.
    const contract_step = b.step("test-contract", "Run portable schema/semantic/filesystem contract tests");
    inline for (.{ architecture.wire, architecture.schema, architecture.semantic, architecture.scene_codec, architecture.fs, architecture.fs_codec, architecture.fs_runtime, architecture.view_runtime, architecture.target_runtime, architecture.plugin_semantic }) |contract_mod| {
        const contract_tests = b.addTest(.{ .root_module = contract_mod });
        const run_contract_tests = b.addRunArtifact(contract_tests);
        contract_step.dependOn(&run_contract_tests.step);
    }

    // Compile-only Darwin choke point. Platform-neutral facades are analyzed
    // for the next supported host without trying to run a foreign artifact;
    // the Linux provider is created only in the native `.linux` branch below.
    const darwin_target = b.resolveTargetQuery(.{ .cpu_arch = .aarch64, .os_tag = .macos });
    const darwin_architecture = createArchitectureModules(b, darwin_target, optimize);
    const darwin_gate_mod = b.createModule(.{
        .root_source_file = b.path("src/tests/darwin_architecture_gate.zig"),
        .target = darwin_target,
        .optimize = optimize,
    });
    addArchitectureImports(darwin_gate_mod, darwin_architecture);
    const darwin_gate = b.addObject(.{
        .name = "weft-darwin-architecture",
        .root_module = darwin_gate_mod,
    });
    const darwin_step = b.step("check-darwin-architecture", "Compile portable architecture modules for aarch64-macos");
    darwin_step.dependOn(&darwin_gate.step);
    contract_step.dependOn(&darwin_gate.step);

    const fs_fake = b.createModule(.{
        .root_source_file = b.path("src/fs_fake/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    fs_fake.addImport("weft_fs", architecture.fs);
    const fs_fake_tests = b.addTest(.{ .root_module = fs_fake });
    const run_fs_fake_tests = b.addRunArtifact(fs_fake_tests);
    contract_step.dependOn(&run_fs_fake_tests.step);

    // Dired's draft/reconcile model is a plugin-local pure module. It sees
    // only the named generic semantic/filesystem contracts; the existing dired
    // guest is intentionally not wired to this draft yet.
    const dired_facade = b.createModule(.{
        .root_source_file = b.path("src/plugins/dired/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const dired_model = b.createModule(.{
        .root_source_file = b.path("src/plugins/dired/model.zig"),
        .target = target,
        .optimize = optimize,
    });
    const dired_projection = b.createModule(.{
        .root_source_file = b.path("src/plugins/dired/projection.zig"),
        .target = target,
        .optimize = optimize,
    });
    const dired_actions = b.createModule(.{
        .root_source_file = b.path("src/plugins/dired/actions.zig"),
        .target = target,
        .optimize = optimize,
    });
    const dired_session = b.createModule(.{
        .root_source_file = b.path("src/plugins/dired/session.zig"),
        .target = target,
        .optimize = optimize,
    });
    dired_projection.addImport("weft_dired_model", dired_model);
    dired_actions.addImport("weft_dired_model", dired_model);
    dired_actions.addImport("weft_dired_projection", dired_projection);
    dired_session.addImport("weft_dired_model", dired_model);
    dired_session.addImport("weft_dired_projection", dired_projection);
    dired_session.addImport("weft_dired_actions", dired_actions);
    dired_session.addImport("weft_fs_runtime", architecture.fs_runtime);
    dired_session.addImport("weft_view_runtime", architecture.view_runtime);
    dired_session.addImport("weft_target_runtime", architecture.target_runtime);
    dired_facade.addImport("weft_dired_model", dired_model);
    dired_facade.addImport("weft_dired_projection", dired_projection);
    dired_facade.addImport("weft_dired_actions", dired_actions);
    dired_facade.addImport("weft_dired_session", dired_session);
    const dired_model_step = b.step("test-dired-model", "Run the pure dired model and semantic projection tests");
    inline for (.{ dired_facade, dired_model, dired_projection, dired_actions, dired_session }) |dired_module| {
        dired_module.addImport("weft_semantic", architecture.semantic);
        dired_module.addImport("weft_fs", architecture.fs);
        const dired_tests = b.addTest(.{ .root_module = dired_module });
        const run_dired_tests = b.addRunArtifact(dired_tests);
        dired_model_step.dependOn(&run_dired_tests.step);
        test_step.dependOn(&run_dired_tests.step);
    }

    const fs_runtime_tests = b.addTest(.{ .root_module = architecture.fs_runtime });
    const run_fs_runtime_tests = b.addRunArtifact(fs_runtime_tests);
    const fs_runtime_step = b.step("test-fs-runtime", "Run filesystem provider routing tests");
    fs_runtime_step.dependOn(&run_fs_runtime_tests.step);
    contract_step.dependOn(&run_fs_runtime_tests.step);

    const fs_linux_step = b.step("test-fs-linux", "Run the Linux filesystem provider tests");
    if (target.result.os.tag == .linux) {
        const fs_linux_tests = b.addTest(.{ .root_module = fs_platform });
        const run_fs_linux_tests = b.addRunArtifact(fs_linux_tests);
        fs_linux_step.dependOn(&run_fs_linux_tests.step);
        contract_step.dependOn(&run_fs_linux_tests.step);
        test_step.dependOn(&run_fs_linux_tests.step);
    }

    // The `weft` module owns the core/gfx/app files, so its own unit tests run in
    // a second test binary; the `test` step runs both. The two binaries run as
    // sibling, unordered dependencies of `test_step` — Zig's build runner is
    // free to run them CONCURRENTLY (subject to `-j`/available job slots), so
    // don't assume serial execution when reasoning about timing-sensitive tests
    // (e.g. e2e/latency_test.zig) run under `test_mod`.
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

    // task #8's deny-vs-crash channel split (src/e2e/trap_kinds_main.zig):
    // a PLAIN EXECUTABLE, not `addTest`, deliberately — this is the one
    // place a real guest crash is allowed to log `.err` without failing
    // `zig build test` (Zig 0.16's default test runner fails the whole
    // suite on any `.err` log; this repo has no per-test downgrade shim).
    // Reuses `weft_mod` directly (it already carries `addWasm`, so
    // `src/e2e/trap_kinds_main.zig` reaches `weft.core.wasm` unmodified) —
    // no `configureTestModule` needed here since this isn't a test binary
    // and touches none of snail/stemma/fonts/syntax.
    const trap_kinds_mod = b.createModule(.{
        .root_source_file = b.path("src/e2e/trap_kinds_main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    trap_kinds_mod.addImport("weft", weft_mod);
    const trap_kinds_exe = b.addExecutable(.{ .name = "e2e-trap-kinds", .root_module = trap_kinds_mod });
    const run_trap_kinds = b.addRunArtifact(trap_kinds_exe);
    const trap_kinds_step = b.step("e2e-trap-kinds", "Prove task #8's deny-vs-crash channel split: a native guest fault logs .err, a host-raised deny logs .warn and never .err");
    trap_kinds_step.dependOn(&run_trap_kinds.step);
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
    // The guest SDK is a real named module. Plugin roots import `weft` and
    // cannot reach sideways into the SDK implementation by relative path.
    // src/guest/weft.zig comptime-verifies its hand-written externs against
    // core/membrane/contract_data.zig's signedness table (task W0a-D) — a
    // plain relative `@import("../core/membrane/contract_data.zig")` fails
    // ("import of file outside module path": each guest is its own module,
    // rooted at src/guest/, and Zig 0.16 won't let a relative import escape
    // that root). Wire it as a named import instead, same target as the
    // guest itself (contract_data.zig has zero host-only deps — no
    // wasmtime, no wasm_host — by design, so it compiles fine here too).
    const contract_data = b.createModule(.{
        .root_source_file = b.path("src/core/membrane/contract_data.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    // D2 (doc/d2-schema-payloads.md §3.2/§3.3): the guest SDK imports the
    // IDENTICAL core/schema.zig the host does — same zero-host-dependency
    // posture as contract_data.zig above, same reason it needs a named
    // import rather than a relative `../core/schema.zig` reach-around (each
    // guest is its own module rooted at src/guest/). This is what makes a
    // guest's own `parseSchema`/`decodeCursor`/`canonicalizeSchema` calls
    // (weft.zig's `schemaEncode`/`slotBind` ergonomic wrappers) the SAME
    // implementation the host runs, not a second one.
    const schema = b.createModule(.{
        .root_source_file = b.path("src/core/schema.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    const wire = b.createModule(.{
        .root_source_file = b.path("src/core/wire.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    schema.addImport("weft_wire", wire);
    const guest_sdk = b.createModule(.{
        .root_source_file = b.path("src/guest/weft.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    guest_sdk.addImport("membrane_contract_data", contract_data);
    guest_sdk.addImport("weft_schema", schema);
    const semantic = b.createModule(.{
        .root_source_file = b.path("src/semantic_model/root.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    semantic.addImport("weft_schema", schema);
    const fs = b.createModule(.{
        .root_source_file = b.path("src/fs/root.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    fs.addImport("weft_semantic", semantic);
    const fs_codec = b.createModule(.{
        .root_source_file = b.path("src/fs_codec/root.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    fs_codec.addImport("weft_semantic", semantic);
    fs_codec.addImport("weft_fs", fs);
    const scene_codec = b.createModule(.{
        .root_source_file = b.path("src/scene_codec/root.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    scene_codec.addImport("weft_semantic", semantic);
    scene_codec.addImport("weft_schema", schema);
    guest_sdk.addImport("weft_semantic", semantic);
    guest_sdk.addImport("weft_scene_codec", scene_codec);
    guest_sdk.addImport("weft_fs", fs);
    guest_sdk.addImport("weft_fs_codec", fs_codec);
    guest_mod.addImport("weft", guest_sdk);
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

/// Resolve an internal-library dependency: the GitHub release pin by
/// default (a standalone clone builds with no monorepo around it), or the
/// zon `<name>_local` path twin when NPINS_OVERRIDE_<NAME> is set — the
/// same variable npins honors on the nix side, so one switch flips both
/// layers. Zon path deps are static, so the override's VALUE can't choose
/// an arbitrary path: it must name the fixed monorepo location, and a
/// mismatch is a hard error rather than a silently ignored setting.
/// Returns null only when the selected pin still needs fetching (the build
/// runner fetches and re-runs).
fn depOrOverride(
    b: *std.Build,
    comptime name: []const u8,
    comptime env_var: []const u8,
    args: anytype,
) ?*std.Build.Dependency {
    const override = b.graph.environ_map.get(env_var) orelse
        return b.lazyDependency(name, args);
    const fixed = "../../lib/" ++ name;
    const want = std.fs.path.resolve(b.allocator, &.{ b.build_root.path orelse ".", fixed }) catch
        @panic("resolve " ++ fixed);
    // resolve() is lexical (no cwd access): a relative override is resolved
    // against the build root, so `NPINS_OVERRIDE_X=../../lib/x` from the
    // weft checkout means the same thing it means to the zon manifest.
    const got = std.fs.path.resolve(b.allocator, &.{ b.build_root.path orelse ".", override }) catch
        @panic("resolve override");
    if (!std.mem.eql(u8, want, got)) std.debug.panic(
        "{s}={s}: zon path deps are static, so the override must name the monorepo twin {s} ({s}); point it there or unset it",
        .{ env_var, override, fixed, want },
    );
    return b.lazyDependency(name ++ "_local", args);
}
