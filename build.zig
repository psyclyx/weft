const std = @import("std");

/// One wasm guest: a shipped plugin (`src/plugins/<name>/root.zig`) or a test
/// fixture (`src/plugin_fixtures/<name>.zig`).
///
/// `install` plugins are the shippable reference set: built to `.wasm` and
/// installed to `lib/weft/plugins/<name>.wasm` as external artifacts a user
/// loads with `--plugin` — NOT baked into the binary. weft itself ships
/// modeless. The non-`install` guests are fixtures (a bare hello, a
/// perm-violating rogue, a demo config) exercised only by the wasm-membrane
/// suite, embedded into the test module below.
///
/// THE DIRECTORY IS THE BOUNDARY. A plugin is a directory, not a file, so it
/// can grow implementation files without any of them becoming reachable from
/// a sibling: each guest module is rooted at its OWN directory, and Zig
/// refuses a relative import that escapes a module root. Shared code is a
/// LIBRARY (`src/plugin_lib/<name>/`) named in `libraries` below — a build
/// graph edge, never ambient source access.
const Guest = struct {
    /// The plugin's name — its directory, its installed artifact
    /// (`lib/weft/plugins/<name>.wasm`), and the name a config's
    /// `weft.plugin(name)` resolves.
    name: []const u8,
    import: []const u8,
    install: bool,
    /// Plugin libraries this guest may import, by name. Anything not listed
    /// is not on its import path at all.
    libraries: []const Library = &.{},

    /// Where this guest's root source lives. Plugins own a directory;
    /// fixtures are single files (they exist to be minimal).
    fn root(self: Guest) []const u8 {
        return if (self.install)
            "src/plugins/" ++ self.name ++ "/root.zig"
        else
            "src/plugin_fixtures/" ++ self.name ++ ".zig";
    }
};

/// The shared plugin libraries (`src/plugin_lib/<name>/root.zig`). Each is a
/// NAMED module a guest gets only by declaring it: `prompt` is the one
/// read-a-line minibuffer, `invoke` is the one "run a command, asking for the
/// arguments you left out", `ex` is vim's and helix's command line, `output`
/// is the tool-buffer surface `run`/`make`/`grep` share, `jsonrpc` is the
/// framing under `lsp`, `files` is the portable draft model + its sandbox
/// adapter.
const Library = enum {
    prompt,
    invoke,
    ex,
    jsonrpc,
    output,
    files,
    annotate,

    /// The import name a guest spells. One place, so a library cannot be
    /// reached under two names.
    fn importName(self: Library) []const u8 {
        return switch (self) {
            .prompt => "weft_prompt",
            .invoke => "weft_invoke",
            .ex => "weft_ex",
            .jsonrpc => "weft_jsonrpc",
            .output => "weft_output",
            .files => "weft_files",
            .annotate => "weft_annotate",
        };
    }

    /// Libraries a library itself needs. `ex` is a command-line: a parser
    /// plus a prompt, and the prompt half is the same one git and lsp use —
    /// it does not get a private copy just because it got there first. It
    /// reaches the registry through `invoke` for the same reason: the palette
    /// asks for a missing argument the same way, and there is one of those.
    fn deps(self: Library) []const Library {
        return switch (self) {
            .invoke => &.{.prompt},
            .ex => &.{ .prompt, .invoke },
            else => &.{},
        };
    }
};

/// Compiler-enforced subsystem boundaries. Cross-module code imports these
/// names; relative imports are reserved for implementation files beneath the
/// corresponding module root.
const ArchitectureModules = struct {
    wire: *std.Build.Module,
    schema: *std.Build.Module,
    input: *std.Build.Module,
    membrane: *std.Build.Module,
    semantic: *std.Build.Module,
    scene_codec: *std.Build.Module,
    fs: *std.Build.Module,
    fs_codec: *std.Build.Module,
    fs_runtime: *std.Build.Module,
    fs_remote: *std.Build.Module,
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
        .root_source_file = b.path("src/wire/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const schema = b.createModule(.{
        .root_source_file = b.path("src/schema/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    schema.addImport("weft_wire", wire);
    // The input boundary's vocabulary and the wasm membrane's pure ABI table.
    // Both are imported by core AND compiled into every wasm32 guest, so
    // neither may acquire a host-only dependency; giving each its own module
    // root is what keeps that true by construction rather than by review.
    const input = b.createModule(.{
        .root_source_file = b.path("src/input/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const membrane = b.createModule(.{
        .root_source_file = b.path("src/membrane/root.zig"),
        .target = target,
        .optimize = optimize,
    });
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
    const fs_remote = b.createModule(.{
        .root_source_file = b.path("src/fs_remote/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    fs_remote.addImport("weft_semantic", semantic);
    fs_remote.addImport("weft_fs", fs);
    fs_remote.addImport("weft_fs_codec", fs_codec);
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
        .input = input,
        .membrane = membrane,
        .semantic = semantic,
        .scene_codec = scene_codec,
        .fs = fs,
        .fs_codec = fs_codec,
        .fs_runtime = fs_runtime,
        .fs_remote = fs_remote,
        .view_runtime = view_runtime,
        .target_runtime = target_runtime,
        .plugin_semantic = plugin_semantic,
    };
}

/// One plugin's module graph, composed strictly over public architecture
/// contracts. Keeping this separate makes the build itself reject accidental
/// plugin-to-app or plugin-to-provider reach-through.
const FilesPortableModules = struct {
    model: *std.Build.Module,
    workspace: *std.Build.Module,
    projection: *std.Build.Module,
    actions: *std.Build.Module,
    facade: *std.Build.Module,
};

fn createFilesPortableModules(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    semantic: *std.Build.Module,
    fs: *std.Build.Module,
) FilesPortableModules {
    const model = b.createModule(.{
        .root_source_file = b.path("src/plugin_lib/files/model.zig"),
        .target = target,
        .optimize = optimize,
    });
    const projection = b.createModule(.{
        .root_source_file = b.path("src/plugin_lib/files/projection.zig"),
        .target = target,
        .optimize = optimize,
    });
    const workspace = b.createModule(.{
        .root_source_file = b.path("src/plugin_lib/files/workspace.zig"),
        .target = target,
        .optimize = optimize,
    });
    const actions = b.createModule(.{
        .root_source_file = b.path("src/plugin_lib/files/actions.zig"),
        .target = target,
        .optimize = optimize,
    });
    const facade = b.createModule(.{
        .root_source_file = b.path("src/plugin_lib/files/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    inline for (.{ model, workspace, projection, actions }) |module| {
        module.addImport("weft_semantic", semantic);
        module.addImport("weft_fs", fs);
    }
    workspace.addImport("weft_files_model", model);
    projection.addImport("weft_files_model", model);
    actions.addImport("weft_files_model", model);
    actions.addImport("weft_files_projection", projection);
    facade.addImport("weft_files_model", model);
    facade.addImport("weft_files_workspace", workspace);
    facade.addImport("weft_files_projection", projection);
    facade.addImport("weft_files_actions", actions);
    return .{
        .model = model,
        .workspace = workspace,
        .projection = projection,
        .actions = actions,
        .facade = facade,
    };
}

/// The `files` library's SANDBOX ADAPTER — the half that needs the guest SDK,
/// which is why it is a second named module rather than a decl of the facade
/// (`createFilesPortableModules` builds only the portable four, which
/// deliberately have no SDK dependency).
///
/// It is built for two different targets — the wasm32 guest and the darwin
/// compile-only gate — and was previously written out at both sites with
/// hand-copied imports. That made the darwin gate, whose whole job is catching
/// portability drift, depend on a second copy of the wiring it was meant to
/// check. One function, two callers.
fn filesGuestAdapter(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    guest_sdk: *std.Build.Module,
    facade: *std.Build.Module,
) *std.Build.Module {
    const adapter = b.createModule(.{
        .root_source_file = b.path("src/plugin_lib/files/adapter.zig"),
        .target = target,
        .optimize = optimize,
    });
    adapter.addImport("weft", guest_sdk);
    adapter.addImport("weft_files", facade);
    return adapter;
}

fn addArchitectureImports(mod: *std.Build.Module, architecture: ArchitectureModules) void {
    mod.addImport("weft_wire", architecture.wire);
    mod.addImport("weft_schema", architecture.schema);
    mod.addImport("weft_input", architecture.input);
    mod.addImport("weft_membrane", architecture.membrane);
    mod.addImport("weft_semantic", architecture.semantic);
    mod.addImport("weft_scene_codec", architecture.scene_codec);
    mod.addImport("weft_fs", architecture.fs);
    mod.addImport("weft_fs_codec", architecture.fs_codec);
    mod.addImport("weft_fs_runtime", architecture.fs_runtime);
    mod.addImport("weft_fs_remote", architecture.fs_remote);
    mod.addImport("weft_view_runtime", architecture.view_runtime);
    mod.addImport("weft_target_runtime", architecture.target_runtime);
    mod.addImport("weft_plugin_semantic", architecture.plugin_semantic);
}

const guests = [_]Guest{
    // ── Fixtures (src/plugin_fixtures/) — never shipped ──────────────────
    .{ .name = "hello", .import = "guest_hello_wasm", .install = false },
    .{ .name = "plugin", .import = "guest_plugin_wasm", .install = false },
    .{ .name = "rogue", .import = "guest_rogue_wasm", .install = false },
    .{ .name = "deny", .import = "guest_deny_wasm", .install = false },
    .{ .name = "demo_config", .import = "guest_demo_config_wasm", .install = false },
    .{ .name = "headtest", .import = "guest_headtest_wasm", .install = false },
    // The Files conformance gate's fixture (src/e2e/grammar_test.zig): a
    // synthetic third-party input grammar binding only standard protocol
    // intentions (doc/configuration.md §5.1).
    .{ .name = "gramtest", .import = "guest_gramtest_wasm", .install = false },
    .{ .name = "fs_limit", .import = "guest_fs_limit_wasm", .install = false },
    // A permless guest that hands the session/stream doors handles it never
    // got — including the sign-bit word that used to reach a bare `@intCast`
    // to `usize` and take the HOST down (`core/handles.zig`'s `Slots.at`).
    .{ .name = "hostile_handle", .import = "guest_hostile_handle_wasm", .install = false },
    // The `wl_proc_spool` gate's guest: proc+timer only, so the door's promise
    // ("a subprocess gets a real file, the guest gets no fs perm") is proven by
    // a guest that genuinely holds none.
    .{ .name = "spool", .import = "guest_spool_wasm", .install = false },
    // D2's worked example (doc/d2-schema-payloads.md §6) — a third-party
    // slot the wasm-membrane suite proves end to end.
    .{ .name = "badge", .import = "guest_badge_wasm", .install = false },
    // …and the CONSUMER half: a separate guest that FIRES `ui/badge` and
    // decodes the answer, proving plugin-to-plugin typed composition with
    // no core type, no shared source, and no build edge between the two.
    .{ .name = "badge_consumer", .import = "guest_badge_consumer_wasm", .install = false },
    // §11.7's worked example — a third-party decorator of entries it does not
    // own, proven end to end by the wasm-membrane suite.
    .{ .name = "marks", .import = "guest_marks_wasm", .install = false },
    .{ .name = "semantic_fixture", .import = "guest_semantic_wasm", .install = false },
    .{ .name = "semantic_fs_fixture", .import = "guest_semantic_fs_wasm", .install = false },
    .{ .name = "files_semantic_fixture", .import = "guest_files_semantic_wasm", .install = false, .libraries = &.{.files} },

    // ── Shipped plugins (src/plugins/<name>/) ────────────────────────────
    .{ .name = "edit", .import = "guest_edit_wasm", .install = true },
    .{ .name = "complete", .import = "guest_complete_wasm", .install = true },
    .{ .name = "project", .import = "guest_project_wasm", .install = true },
    .{ .name = "palette", .import = "guest_palette_wasm", .install = true, .libraries = &.{.invoke} },
    .{ .name = "structural", .import = "guest_structural_wasm", .install = true },
    .{ .name = "ts", .import = "guest_ts_wasm", .install = true },
    .{ .name = "region", .import = "guest_region_wasm", .install = true },
    .{ .name = "shell", .import = "guest_shell_wasm", .install = true },
    .{ .name = "motions", .import = "guest_motions_wasm", .install = true },
    .{ .name = "textobjects", .import = "guest_textobjects_wasm", .install = true },
    .{ .name = "operators", .import = "guest_operators_wasm", .install = true },
    .{ .name = "vim", .import = "guest_vim_wasm", .install = true, .libraries = &.{.ex} },
    .{ .name = "comment", .import = "guest_comment_wasm", .install = true },
    .{ .name = "lsp", .import = "guest_lsp_wasm", .install = true, .libraries = &.{ .jsonrpc, .prompt, .annotate } },
    .{ .name = "indent", .import = "guest_indent_wasm", .install = true },
    .{ .name = "whitespace", .import = "guest_whitespace_wasm", .install = true },
    .{ .name = "numbers", .import = "guest_numbers_wasm", .install = true },
    .{ .name = "autopair", .import = "guest_autopair_wasm", .install = true },
    .{ .name = "consult", .import = "guest_consult_wasm", .install = true },
    .{ .name = "git", .import = "guest_git_wasm", .install = true, .libraries = &.{.prompt} },
    .{ .name = "grep", .import = "guest_grep_wasm", .install = true, .libraries = &.{.output} },
    .{ .name = "run", .import = "guest_run_wasm", .install = true, .libraries = &.{.output} },
    .{ .name = "make", .import = "guest_make_wasm", .install = true, .libraries = &.{.output} },
    .{ .name = "notes", .import = "guest_notes_wasm", .install = true },
    .{ .name = "fmt", .import = "guest_fmt_wasm", .install = true },
    .{ .name = "buffers", .import = "guest_buffers_wasm", .install = true },
    .{ .name = "windows", .import = "guest_windows_wasm", .install = true },
    .{ .name = "modes", .import = "guest_modes_wasm", .install = true },
    .{ .name = "snippets", .import = "guest_snippets_wasm", .install = true },
    .{ .name = "direnv", .import = "guest_direnv_wasm", .install = true },
    .{ .name = "llm", .import = "guest_llm_wasm", .install = true },
    .{ .name = "console", .import = "guest_console_wasm", .install = true },
    .{ .name = "repl", .import = "guest_repl_wasm", .install = true },
    .{ .name = "net", .import = "guest_net_wasm", .install = true },
    .{ .name = "http", .import = "guest_http_wasm", .install = true },
    .{ .name = "which_key", .import = "guest_which_key_wasm", .install = true },
    // Pick-row annotations (doc/marginalia.md): binds `ui/pick-annotate` and
    // answers with a note per row. No commands, no core privilege.
    .{ .name = "marginalia", .import = "guest_marginalia_wasm", .install = true, .libraries = &.{.annotate} },
    .{ .name = "files", .import = "guest_files_wasm", .install = true, .libraries = &.{.files} },
    .{ .name = "helix", .import = "guest_helix_wasm", .install = true, .libraries = &.{.ex} },
    .{ .name = "emacs", .import = "guest_emacs_wasm", .install = true },
    .{ .name = "debug", .import = "guest_debug_wasm", .install = true },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const stemma_opt = depOrOverride(b, "stemma", "NPINS_OVERRIDE_STEMMA", .{ .target = target, .optimize = optimize });
    const stemma_dep = stemma_opt orelse return;
    // Pinned, portable fallback bytes supplied by the build environment. Face
    // family resolution is a separate named provider below, selected by target;
    // a Darwin provider can replace fontconfig without changing `weft_text`,
    // the view, or this deterministic default.
    const mono_font_file = b.graph.environ_map.get("WEFT_DEFAULT_MONO") orelse
        @panic("WEFT_DEFAULT_MONO not set — build inside the nix shell");
    const mono_font: std.Build.LazyPath = .{ .cwd_relative = mono_font_file };
    const font_provider_contract = b.createModule(.{
        .root_source_file = b.path("src/font_provider/contract.zig"),
        .target = target,
        .optimize = optimize,
    });
    const font_provider_impl = b.createModule(.{
        .root_source_file = b.path(if (target.result.os.tag == .linux)
            "src/font_provider/fontconfig.zig"
        else
            "src/font_provider/unavailable.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = target.result.os.tag == .linux,
    });
    font_provider_impl.addImport("contract", font_provider_contract);
    if (target.result.os.tag == .linux)
        font_provider_impl.linkSystemLibrary("fontconfig", .{});
    const font_provider_mod = b.createModule(.{
        .root_source_file = b.path("src/font_provider/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    font_provider_mod.addImport("contract", font_provider_contract);
    font_provider_mod.addImport("implementation", font_provider_impl);
    font_provider_mod.addAnonymousImport("font_mono", .{ .root_source_file = mono_font });
    const scene_mod = b.createModule(.{
        .root_source_file = b.path("src/scene/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    // The Skia binding is a named module, not a `root.zig` reached by relative
    // path: it decodes the renderer-neutral scene and owns no editor or
    // platform policy, so nothing above it should be able to reach it except
    // by declaring the edge. `addSkia` (below) still contributes the compiled
    // shim + link inputs to whichever binary consumes this.
    const skia_mod = b.createModule(.{
        .root_source_file = b.path("src/skia/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    skia_mod.addImport("weft_scene", scene_mod);
    // The compiled C++ shim rides with the module that DECLARES these externs,
    // so it enters a link exactly once no matter how many modules import it.
    // Attaching it per-consumer instead gives duplicate symbol definitions.
    addSkia(b, skia_mod);
    const text_mod = b.createModule(.{
        .root_source_file = b.path("src/text/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    text_mod.linkSystemLibrary("harfbuzz", .{});
    text_mod.addAnonymousImport("font_mono", .{
        .root_source_file = mono_font,
    });
    const architecture = createArchitectureModules(b, target, optimize);
    // Application-wake policy is deliberately a dependency-free module. The
    // concrete app adapter supplies phases; this build edge makes it
    // impossible for sequencing policy to reach into core, gfx, plugins, or a
    // platform implementation.
    // The pure phase-order + caret-blink policy. Its type is `Lifecycle`, and
    // now so are its directory and module name — it was `src/application/`
    // beside `src/app/application.zig`, its own concrete host, with the field
    // reading `lifecycle: application.Lifecycle`.
    const lifecycle_mod = b.createModule(.{
        .root_source_file = b.path("src/lifecycle/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const files_modules = createFilesPortableModules(
        b,
        target,
        optimize,
        architecture.semantic,
        architecture.fs,
    );
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

    // The window/input/present seam (src/platform/root.zig's `assertPlatform`
    // contract plus the one implementation compiled in). It depends on nothing
    // in this tree — not core, not gfx, not app — and this module edge is what
    // keeps that true: a platform that reaches up into the editor cannot be
    // written, it fails to compile.
    const platform_mod = b.createModule(.{
        .root_source_file = b.path("src/platform/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    platform_mod.linkSystemLibrary("wayland-client", .{});
    platform_mod.linkSystemLibrary("xkbcommon", .{});
    platform_mod.linkSystemLibrary("vulkan", .{});
    addWaylandProtocols(b, platform_mod);

    // ONE Vulkan C import for the whole program. src/vk/root.zig's own doc
    // comment states the invariant — "every module must use these types:
    // separate @cImport blocks of the same header produce distinct opaque Zig
    // types" — and a named module is the only way to keep it once gfx and app
    // are separate modules, since a file shared by relative import would
    // otherwise be compiled into each of them independently, producing exactly
    // the incompatible types it warns about.
    const vk_mod = b.createModule(.{
        .root_source_file = b.path("src/vk/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    vk_mod.linkSystemLibrary("vulkan", .{});

    // The editor kernel. It is graphics-free by construction now, not by
    // convention: `weft_core` is given no scene, text, font, skia, gfx, app or
    // platform edge, so `core/Head.zig`'s standing instruction — "core ... must
    // not depend on gfx/window_layout.zig" — is a compile error rather than a
    // comment somebody has to keep honouring.
    const core_mod = b.createModule(.{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addArchitectureImports(core_mod, architecture);
    core_mod.addImport("weft_fs_platform", fs_platform);
    core_mod.addImport("stemma", stemma_dep.module("stemma"));
    addSyntax(b, core_mod);
    addWasm(b, core_mod);
    addQuickjs(b, core_mod);

    // The editor's view layer, above core. What is genuinely below core —
    // scene/text/font_provider/skia — is already separate; what is left here
    // reads buffers, panes and heads, so it gets `weft_core` and the app does
    // not get to reach past it into `view/`.
    const gfx_mod = b.createModule(.{
        .root_source_file = b.path("src/gfx/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    gfx_mod.addImport("weft_core", core_mod);
    gfx_mod.addImport("weft_vk", vk_mod);
    gfx_mod.addImport("weft_scene", scene_mod);
    gfx_mod.addImport("weft_skia", skia_mod);
    gfx_mod.addImport("weft_text", text_mod);
    gfx_mod.addImport("weft_font_provider", font_provider_mod);
    gfx_mod.addImport("weft_semantic", architecture.semantic);
    gfx_mod.addImport("weft_view_runtime", architecture.view_runtime);
    gfx_mod.addImport("stemma", stemma_dep.module("stemma"));
    gfx_mod.linkSystemLibrary("vulkan", .{});

    // The editor assembled — the only layer that knows core AND gfx AND
    // platform, which is why it is the top of the enforced graph. Nothing below
    // is given an edge to it, so `core -> app` (which existed, as one test) is
    // now `error: import of file outside module path`.
    const app_mod = b.createModule(.{
        .root_source_file = b.path("src/app/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // The dependency set the app tree needs, named once so the shipped binary
    // and the tested one cannot be wired differently by accident. See
    // `configureAppModule` — `app_mod` takes the same set, because main.zig and
    // weft.zig are thin roots over it.
    const app_deps: AppDeps = .{
        .architecture = architecture,
        .core = core_mod,
        .app = app_mod,
        .gfx = gfx_mod,
        .vk = vk_mod,
        .platform = platform_mod,
        .fs_platform = fs_platform,
        .font_provider = font_provider_mod,
        .scene = scene_mod,
        .skia = skia_mod,
        .text = text_mod,
        .lifecycle = lifecycle_mod,
        .stemma = stemma_dep.module("stemma"),
    };

    // ── Desktop (Wayland) executable ──
    configureAppModule(b, app_mod, app_deps);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    configureAppModule(b, exe_mod, app_deps);
    // The compositor link and the generated protocol glue now ride on
    // `weft_platform`, which is where the code that uses them lives. Runtime
    // font-family resolution is owned by `weft_font_provider`.

    const exe = b.addExecutable(.{
        .name = "weft",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    // The reference plugins ship as external `.wasm` under lib/weft/plugins/,
    // not embedded — weft's binary carries none of them. Load one with e.g.
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
    // Platform-free logic tests and dependency smoke tests; no display server
    // required.
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
    configureAppModule(b, weft_mod, app_deps);
    // What only the test-facing module has. Resident JS plugins are data
    // dependencies of the full headless editor too: route them through the
    // module graph, because the E2E config loader must not reach out of `src/`
    // to impersonate the installed plugins.
    weft_mod.addAnonymousImport("dap_js", .{
        .root_source_file = b.path("config/plugins/dap.js"),
    });
    weft_mod.addAnonymousImport("acp_js", .{
        .root_source_file = b.path("config/plugins/acp.js"),
    });
    embedGuests(b, weft_mod); // core's own wasm-membrane tests @embedFile the guests

    // `test_mod` (the `test` step) and `instrument_mod` (the `e2e-latency` /
    // `e2e-popup-layout` steps, below) are two SEPARATE module objects, wired
    // IDENTICALLY through this one function — see the note by `instrument_mod`
    // for why they must be separate objects. Same doctrine as harness.zig's
    // `press` delegating to `pressTimed`: one implementation of the wiring, not
    // two copies that can quietly drift apart.
    configureTestModule(b, test_mod, stemma_dep, weft_mod);

    // The dispatch-latency instrument's record/compare switch
    // (doc/cwa-prior-docs-audit.md §5 — src/e2e/latency_test.zig).
    // `test_mod` — the module the plain `test` step compiles — is HARDCODED to
    // compare-only, always, regardless of `-Drecord-latency`: it's a module
    // OBJECT, shared verbatim by every Step.Compile rooted at it, so wiring
    // the live CLI flag into it would let `zig build test
    // -Drecord-latency=true` silently overwrite the committed baseline as a
    // side effect of an ordinary test run. The live flag is wired only into
    // `instrument_mod` below, a separate module the `test` step never builds.
    const compare_only_opts = b.addOptions();
    compare_only_opts.addOption(bool, "record", false);
    // `test_mod` runs this instrument in a process that has already executed
    // ~159 other e2e tests, so what it measures there is that process's
    // accumulated allocator and cache state, not dispatch: the SAME code that
    // measures ~37us in a fresh process measures ~176us of real CPU work after
    // the suite has run. Comparing that against a baseline recorded by the
    // FILTERED `e2e-latency` binary (fresh process, this test only) is a
    // category error, and it is where this gate's intermittent failures came
    // from. The measurement still runs here -- the code path stays exercised --
    // but only the isolated binary may hold it to the baseline. `test_step`
    // depends on `e2e-latency`, so `zig build test` still gates it, honestly.
    compare_only_opts.addOption(bool, "isolated", false);
    test_mod.addOptions("latency_options", compare_only_opts);

    // The same record/compare doctrine for the popup-layout golden gate
    // (rendering P2's guard — src/e2e/popup_layout_test.zig): `test_mod` is
    // HARDCODED to compare-only for the identical reason (a plain `zig build
    // test -Drecord-popup-layout=true` must never be able to overwrite the
    // committed goldens as a side effect of an ordinary run). The live flag
    // is wired only into `instrument_mod` below.
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

    // §19's demolition checklist as an executable test (src/e2e/demolition_test.zig):
    // it walks the SOURCE TREE by absolute path (the test binary's cwd is not
    // guaranteed to be the repo root), so that path is threaded in here rather
    // than assumed at runtime.
    const demolition_opts = b.addOptions();
    demolition_opts.addOption([]const u8, "repo_root", b.build_root.path orelse ".");
    test_mod.addOptions("demolition_options", demolition_opts);

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
    // A green gate leaves a fresh zig-out: install rides along.
    test_step.dependOn(b.getInstallStep());
    test_step.dependOn(&run_tests.step);
    const lifecycle_tests = b.addTest(.{ .root_module = lifecycle_mod });
    const run_lifecycle_tests = b.addRunArtifact(lifecycle_tests);
    test_step.dependOn(&run_lifecycle_tests.step);
    // A module owns its own tests. Before `weft_platform` was a module its
    // seam test rode along in the `weft` binary; a module's tests do not run
    // just because a dependent references it, so this is the edge that keeps
    // it in the gate.
    const platform_tests = b.addTest(.{ .root_module = platform_mod });
    test_step.dependOn(&b.addRunArtifact(platform_tests).step);
    // Core's own suite — the ABI property tests plus the whole wasm-membrane
    // suite — was running inside the `weft` binary because core was compiled
    // into it. It is a module now, so it gets its own binary, and it needs the
    // embedded guests its membrane tests @embedFile.
    const core_tests_mod = b.createModule(.{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addArchitectureImports(core_tests_mod, architecture);
    core_tests_mod.addImport("weft_fs_platform", fs_platform);
    core_tests_mod.addImport("stemma", stemma_dep.module("stemma"));
    addSyntax(b, core_tests_mod);
    addWasm(b, core_tests_mod);
    addQuickjs(b, core_tests_mod);
    embedGuests(b, core_tests_mod);
    const core_tests = b.addTest(.{ .root_module = core_tests_mod });
    test_step.dependOn(&b.addRunArtifact(core_tests).step);
    const gfx_tests = b.addTest(.{ .root_module = gfx_mod });
    test_step.dependOn(&b.addRunArtifact(gfx_tests).step);
    // app/config_load.zig's tests @embedFile the guests, as core's do.
    embedGuests(b, app_mod);
    const app_tests = b.addTest(.{ .root_module = app_mod });
    test_step.dependOn(&b.addRunArtifact(app_tests).step);
    // `weft_scene` (6 tests) and `weft_text` (4) have been named modules since
    // before this refactor and never had a test binary — src/weft.zig's
    // `_ = scene; _ = text_engine;` looked like coverage but a module's tests
    // do not run in a dependent's binary, so they had never executed at all.
    inline for (.{ scene_mod, text_mod }) |graphics_mod| {
        const graphics_tests = b.addTest(.{ .root_module = graphics_mod });
        test_step.dependOn(&b.addRunArtifact(graphics_tests).step);
    }

    // A focused entry point for the whole-app spine narrative.  Keeping the
    // filter in the build graph makes the opt-in video command reproducible:
    // it cannot accidentally run another Project test and reuse the requested
    // output path.  The ordinary `test` step above remains the full suite.
    const demo_tests = b.addTest(.{ .root_module = test_mod, .filters = &.{"e2e/spine"} });
    const run_demo_tests = b.addRunArtifact(demo_tests);

    const demo_step = b.step("e2e-demo", "Run the whole-app spine narrative (optionally record WEFT_E2E_VIDEO)");
    demo_step.dependOn(&run_demo_tests.step);

    // Portable contract gate: deliberately separate from the application
    // suite so these roots cannot acquire app/platform dependencies unnoticed.
    const contract_step = b.step("test-contract", "Run portable schema/semantic/filesystem contract tests");
    contract_step.dependOn(&run_lifecycle_tests.step);
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
    const darwin_files_modules = createFilesPortableModules(
        b,
        darwin_target,
        optimize,
        darwin_architecture.semantic,
        darwin_architecture.fs,
    );
    const darwin_guest_sdk = b.createModule(.{
        .root_source_file = b.path("src/plugin_sdk/root.zig"),
        .target = darwin_target,
        .optimize = optimize,
    });
    // `input` and `membrane` come from the architecture factory now, so the
    // darwin gate analyzes the SAME roots the host does instead of a pair of
    // hand-made copies that could drift from it.
    darwin_guest_sdk.addImport("weft_membrane", darwin_architecture.membrane);
    darwin_guest_sdk.addImport("weft_input", darwin_architecture.input);
    darwin_guest_sdk.addImport("weft_schema", darwin_architecture.schema);
    darwin_guest_sdk.addImport("weft_semantic", darwin_architecture.semantic);
    darwin_guest_sdk.addImport("weft_scene_codec", darwin_architecture.scene_codec);
    darwin_guest_sdk.addImport("weft_fs", darwin_architecture.fs);
    darwin_guest_sdk.addImport("weft_fs_codec", darwin_architecture.fs_codec);
    const darwin_files_guest = filesGuestAdapter(b, darwin_target, optimize, darwin_guest_sdk, darwin_files_modules.facade);
    const darwin_gate_mod = b.createModule(.{
        .root_source_file = b.path("src/tests/darwin_architecture_gate.zig"),
        .target = darwin_target,
        .optimize = optimize,
    });
    addArchitectureImports(darwin_gate_mod, darwin_architecture);
    darwin_gate_mod.addImport("weft_files", darwin_files_modules.facade);
    darwin_gate_mod.addImport("weft_files_workspace", darwin_files_modules.workspace);
    darwin_gate_mod.addImport("weft_files_guest", darwin_files_guest);
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

    const files_model_step = b.step("test-files-model", "Run the pure files model and semantic projection tests");
    inline for (.{
        files_modules.facade,
        files_modules.model,
        files_modules.workspace,
        files_modules.projection,
        files_modules.actions,
    }) |files_module| {
        files_module.addImport("weft_semantic", architecture.semantic);
        files_module.addImport("weft_fs", architecture.fs);
        const files_tests = b.addTest(.{ .root_module = files_module });
        const run_files_tests = b.addRunArtifact(files_tests);
        files_model_step.dependOn(&run_files_tests.step);
        test_step.dependOn(&run_files_tests.step);
    }

    const fs_runtime_tests = b.addTest(.{ .root_module = architecture.fs_runtime });
    const run_fs_runtime_tests = b.addRunArtifact(fs_runtime_tests);
    const fs_runtime_step = b.step("test-fs-runtime", "Run filesystem provider routing tests");
    fs_runtime_step.dependOn(&run_fs_runtime_tests.step);
    contract_step.dependOn(&run_fs_runtime_tests.step);

    const fs_remote_tests = b.addTest(.{ .root_module = architecture.fs_remote });
    const run_fs_remote_tests = b.addRunArtifact(fs_remote_tests);
    const fs_remote_step = b.step("test-fs-remote", "Run transport-neutral remote filesystem provider tests");
    fs_remote_step.dependOn(&run_fs_remote_tests.step);
    contract_step.dependOn(&run_fs_remote_tests.step);
    test_step.dependOn(&run_fs_remote_tests.step);

    const fs_linux_step = b.step("test-fs-linux", "Run the Linux filesystem provider tests");
    if (target.result.os.tag == .linux) {
        const fs_linux_tests = b.addTest(.{ .root_module = fs_platform });
        const run_fs_linux_tests = b.addRunArtifact(fs_linux_tests);
        fs_linux_step.dependOn(&run_fs_linux_tests.step);
        contract_step.dependOn(&run_fs_linux_tests.step);
        test_step.dependOn(&run_fs_linux_tests.step);
    }

    // The `weft` module owns the core/gfx/app files, so its own unit tests run in
    // a second test binary; the `test` step runs both. Every sibling of
    // `run_tests` runs CONCURRENTLY with it by default — `runAlone` at the end
    // of this function orders `run_tests` after all of them, because it carries
    // the wall-clock latency instrument.
    const weft_tests = b.addTest(.{ .root_module = weft_mod });
    const run_weft_tests = b.addRunArtifact(weft_tests);

    test_step.dependOn(&run_weft_tests.step);

    // A guest library with no wasm import environment (plugin_lib/output/targets.zig
    // — the row → location table `run`/`make`/`grep` navigate by) compiles for
    // the host too, so its logic is tested natively rather than only through a
    // plugin.
    const guest_pure = b.createModule(.{
        .root_source_file = b.path("src/plugin_lib/output/targets.zig"),
        .target = target,
        .optimize = optimize,
    });
    const guest_pure_tests = b.addTest(.{ .root_module = guest_pure });
    test_step.dependOn(&b.addRunArtifact(guest_pure_tests).step);

    // ── The recordable instruments ──
    // The dispatch-latency baseline and the popup-layout goldens share ONE
    // module object, and so one compiled binary: a second copy of `test_mod`'s
    // wiring, made by the same `configureTestModule` call so it cannot drift.
    // Both `-Drecord-*` flags are COMPTIME options here, not runtime env vars:
    // a record flag has to change the compiled output, or `zig build`'s
    // artifact caching would happily replay a stale cached run instead of
    // re-executing in the new mode.
    //
    // What keeps a baseline un-overwritable from `zig build test` is a property
    // of the module GRAPH, not of how many modules there are: the `test` step
    // builds nothing rooted here, and `test_mod` above carries its own
    // hardcoded compare-only options, so `zig build test -Drecord-latency=true`
    // still cannot reach a recording path. Sharing costs one visible coupling —
    // recording either baseline rebuilds the other instrument, which then
    // re-runs in COMPARE mode — a re-comparison, never a second overwrite.
    const record_latency = b.option(
        bool,
        "record-latency",
        "With `zig build e2e-latency`: record the dispatch-latency baseline (src/e2e/latency_baseline.zon) instead of comparing against it. No effect on the `test` step.",
    ) orelse false;
    const record_popup_layout = b.option(
        bool,
        "record-popup-layout",
        "With `zig build e2e-popup-layout`: record the caret-popup layout goldens (src/e2e/popup_layout_baseline.zon) instead of comparing against them. No effect on the `test` step.",
    ) orelse false;
    const instrument_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    configureTestModule(b, instrument_mod, stemma_dep, weft_mod);
    const latency_opts = b.addOptions();
    latency_opts.addOption(bool, "record", record_latency);
    latency_opts.addOption(bool, "isolated", true);
    instrument_mod.addOptions("latency_options", latency_opts);
    const popup_layout_opts = b.addOptions();
    popup_layout_opts.addOption(bool, "record_popup_layout", record_popup_layout);
    instrument_mod.addOptions("popup_layout_options", popup_layout_opts);

    // Dedicated entry points for the instruments (the full `test` step already
    // runs both, in compare mode, as part of the e2e suite) — a fast way to
    // iterate on one, and the documented way to re-record:
    //   zig build e2e-latency                                     # compare against the baseline
    //   zig build e2e-latency -Drecord-latency=true               # (re-)record the baseline
    //   zig build e2e-popup-layout                                # compare
    //   zig build e2e-popup-layout -Drecord-popup-layout=true     # re-record
    //   zig fmt src/e2e/popup_layout_baseline.zon                 # then canonicalize it —
    //     `std.zon.stringify`'s raw output isn't always zig-fmt's chosen layout for
    //     deeply nested data (unlike the flatter `latency_baseline.zon`, which happens
    //     to already match); the `test`/`e2e-popup-layout` steps don't run `zig fmt`
    //     themselves, so a fresh recording needs this by hand before it's committed.
    const instrument_tests = b.addTest(.{
        .root_module = instrument_mod,
        .filters = &.{ "e2e/latency", "e2e/popup-layout" },
    });
    const latency_step = b.step("e2e-latency", "Run (or, with -Drecord-latency=true, record) the dispatch-latency baseline");
    latency_step.dependOn(&runInstrument(b, instrument_tests, "latency").step);
    const popup_layout_step = b.step("e2e-popup-layout", "Run (or, with -Drecord-popup-layout=true, record) the caret-popup layout goldens");
    popup_layout_step.dependOn(&runInstrument(b, instrument_tests, "popup-layout").step);

    // task #8's deny-vs-crash channel split (src/e2e/trap_kinds_main.zig):
    // a PLAIN EXECUTABLE, not `addTest`, deliberately — this is the one
    // place a real guest crash is allowed to log `.err` without failing
    // `zig build test` (Zig 0.16's default test runner fails the whole
    // suite on any `.err` log; this repo has no per-test downgrade shim).
    // Reuses `weft_mod` directly (it already carries `addWasm`, so
    // `src/e2e/trap_kinds_main.zig` reaches `weft.core.wasm` unmodified) —
    // no `configureTestModule` needed here since this isn't a test binary
    // and touches none of the editor's text, scene, font, or syntax modules.
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
    // Nothing in `test` RUNS this binary (the whole point is that it's allowed
    // to log `.err`), but nothing built it either, so it sat un-compiled and
    // rotted — `zig build e2e-trap-kinds` failed to compile at all until this
    // branch. COMPILING it is in the gate; running it stays opt-in.
    test_step.dependOn(&trap_kinds_exe.step);

    // LAST in `build()` so it sees every sibling `test_step` will ever have.
    runAlone(test_step, &run_tests.step);

    // The real latency gate, ordered AFTER `runAlone` on purpose: the copy of
    // the instrument inside the big e2e binary measures without asserting (see
    // `compare_only_opts`), because by then that process has run ~159 other
    // tests and is measuring its own accumulated allocator and cache state --
    // the same code costs ~37us in a fresh process and ~176us there. The
    // isolated binary is the one held to the baseline, and it runs dead last,
    // after even `run_tests`, so it has the box to itself the way `runAlone`
    // already gives `run_tests`. Adding this BEFORE `runAlone` would instead
    // make `run_tests` wait on it, which is the wrong order and, once
    // `latency_step` also depends on `run_tests`, a cycle.
    latency_step.dependOn(&run_tests.step);
    test_step.dependOn(latency_step);
}

/// Order `last` after every OTHER direct dependency of `step`, so it has the
/// machine to itself when it runs.
///
/// `zig build test` runs its steps in parallel, and `run_tests` carries the
/// keystroke-latency instrument (src/e2e/latency_test.zig) — microsecond
/// wall-clock samples compared against a baseline recorded on an idle box.
/// Measured beside a sibling test binary it measures the SIBLING: the `action`
/// category, whose baseline p95 is 4.2us, has been observed at 25us — six times
/// its threshold — purely from a concurrent suite, which reports the machine as
/// a regression. Wall-clock is the right unit (it is what a typist feels), so
/// the fix is to stop sharing the box rather than to measure something else.
///
/// Taken from the step's own dependency list rather than a hand-kept one, so a
/// test binary added later is serialized too without anyone remembering to.
fn runAlone(step: *std.Build.Step, last: *std.Build.Step) void {
    for (step.dependencies.items) |dep| {
        if (dep != last) last.dependOn(dep);
    }
}

/// Run the shared instrument binary for ONE instrument; the others skip
/// themselves (src/e2e/instrument.zig). Each name is a distinct Run step over
/// the same artifact, so selecting one costs a run, not a compilation.
fn runInstrument(b: *std.Build, tests: *std.Build.Step.Compile, name: []const u8) *std.Build.Step.Run {
    const run = b.addRunArtifact(tests);
    run.setEnvironmentVariable("WEFT_INSTRUMENT", name);

    return run;
}

/// Point a test binary at the compiled-module (`.cwasm`) cache every test
/// binary shares — a stable directory under the project cache root, so the
/// wasm guests and the quickjs runtime compile once per content hash
/// instead of once per binary per run (see `wasm.zig`'s `Engine.cache_dir`). The
/// path is made absolute here: the e2e Project harness chdirs into a tmpdir
/// mid-suite, so a cwd-relative one would scatter and vanish with it.
/// Wire the shared test-module dependency set (stemma/syntax/wasmtime/embedded
/// guests/quickjs/weft) onto `mod`. `test_mod` (the `test` step) and
/// `instrument_mod` (the instrument steps) both call this — it's the ONLY place
/// that wiring is written, so the two binaries cannot drift apart the way two
/// hand-copied blocks eventually would. The one thing that may legitimately
/// differ between callers is added AFTER this returns: which
/// `latency_options`/`popup_layout_options` values they attach.
/// Everything the app tree needs, gathered once so `configureAppModule` takes
/// one argument instead of eight positional modules a caller could transpose.
const AppDeps = struct {
    architecture: ArchitectureModules,
    core: *std.Build.Module,
    app: *std.Build.Module,
    gfx: *std.Build.Module,
    vk: *std.Build.Module,
    platform: *std.Build.Module,
    fs_platform: *std.Build.Module,
    font_provider: *std.Build.Module,
    scene: *std.Build.Module,
    skia: *std.Build.Module,
    text: *std.Build.Module,
    lifecycle: *std.Build.Module,
    stemma: *std.Build.Module,
};

/// Wire the app tree (src/core + src/gfx + src/app) onto `mod`.
///
/// `exe_mod` (the shipped binary, rooted at src/main.zig) and `weft_mod` (the
/// same source exposed to the e2e suite, rooted at src/weft.zig) are two module
/// OBJECTS over ONE tree. Anything wired to one and not the other is, by
/// definition, a difference between what ships and what is tested — so this is
/// the ONLY place that wiring is written. Same doctrine as
/// `configureTestModule` below; this is the pair where drift costs the most,
/// and it had already started (the JS plugins reached `weft_mod` and not the
/// exe).
///
/// What legitimately differs stays at the two call sites, where it is visible:
/// the exe links a Wayland compositor + xkbcommon, and the test module embeds
/// the wasm guests and the resident JS plugins.
fn configureAppModule(b: *std.Build, mod: *std.Build.Module, deps: AppDeps) void {
    addArchitectureImports(mod, deps.architecture);
    mod.addImport("weft_core", deps.core);
    if (mod != deps.app) mod.addImport("weft_app", deps.app);
    mod.addImport("weft_gfx", deps.gfx);
    mod.addImport("weft_vk", deps.vk);
    mod.addImport("weft_platform", deps.platform);
    mod.addImport("weft_fs_platform", deps.fs_platform);
    mod.addImport("weft_font_provider", deps.font_provider);
    mod.addImport("weft_scene", deps.scene);
    mod.addImport("weft_skia", deps.skia);
    mod.addImport("weft_text", deps.text);
    mod.addImport("weft_lifecycle", deps.lifecycle);
    mod.addImport("stemma", deps.stemma);
    // Both binaries render through ordinary Vulkan images; the authoritative
    // E2E renderer deliberately has no WSI, compositor, or platform-input
    // dependency, which is why this is shared and the compositor link is not.
    mod.linkSystemLibrary("vulkan", .{});
    addSyntax(b, mod);
    addWasm(b, mod);
    addQuickjs(b, mod);
}

fn configureTestModule(
    b: *std.Build,
    mod: *std.Build.Module,
    stemma_dep: *std.Build.Dependency,
    weft_mod: *std.Build.Module,
) void {
    mod.addImport("stemma", stemma_dep.module("stemma"));
    addSyntax(b, mod);
    addWasm(b, mod);
    embedGuests(b, mod);
    addQuickjs(b, mod);
    mod.addImport("weft", weft_mod);
}

/// Tree-sitter (milestone 7): the library links normally; grammar
/// packages contribute a runtime dlopen path (baked via build options)
/// and an embedded highlight query, both from pinned store paths.
/// One plugin library, wired with the SDK and its own declared library
/// dependencies (`Library.deps`) and nothing else. A fresh module per
/// consuming guest, because each guest is a separate wasm compilation with
/// its own linear memory — a library's module-level state is per-consumer by
/// construction, never shared behind anyone's back. Within ONE guest it is
/// memoized (`cache`): two libraries wanting the same third want the same
/// module, and a duplicate would not compile.
fn libraryModule(
    b: *std.Build,
    comptime lib: Library,
    wasm_target: std.Build.ResolvedTarget,
    guest_sdk: *std.Build.Module,
    semantic: *std.Build.Module,
    fs: *std.Build.Module,
    /// `files` also hands its consumer the sandbox adapter, a second named
    /// module rather than a decl of the facade (it needs the SDK; the
    /// portable half deliberately does not).
    consumer: *std.Build.Module,
    /// This guest's library modules so far, indexed by `Library`.
    cache: []?*std.Build.Module,
) *std.Build.Module {
    if (cache[@intFromEnum(lib)]) |existing| return existing;
    if (lib == .files) {
        const files = createFilesPortableModules(b, wasm_target, .ReleaseSmall, semantic, fs);
        const adapter = filesGuestAdapter(b, wasm_target, .ReleaseSmall, guest_sdk, files.facade);
        consumer.addImport("weft_files_adapter", adapter);
        cache[@intFromEnum(lib)] = files.facade;
        return files.facade;
    }
    const mod = b.createModule(.{
        .root_source_file = b.path("src/plugin_lib/" ++ @tagName(lib) ++ "/root.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    mod.addImport("weft", guest_sdk);
    // Cached BEFORE the dependency walk: a library reached again from inside
    // its own subtree gets this module, not a second one.
    cache[@intFromEnum(lib)] = mod;
    inline for (comptime lib.deps()) |dep| {
        mod.addImport(comptime dep.importName(), libraryModule(b, dep, wasm_target, guest_sdk, semantic, fs, mod, cache));
    }
    return mod;
}

/// Compile one guest (a plugin's `src/plugins/<name>/root.zig`, or a
/// fixture) to a `wasm32-freestanding` reactor module — no `_start`,
/// exported functions + memory via rdynamic — so the host can instantiate it
/// under wasmtime.
///
/// `comptime guest_spec` because a guest's name IS its path and its artifact
/// name: both are built by comptime concatenation, in `Guest.root` and in
/// `installPlugins`, from the one string in the table.
fn buildGuest(b: *std.Build, comptime guest_spec: Guest) *std.Build.Step.Compile {
    const src = comptime guest_spec.root();
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const guest_mod = b.createModule(.{
        .root_source_file = b.path(src),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    // The guest SDK is a real named module. Plugin roots import `weft` and
    // cannot reach sideways into the SDK implementation by relative path.
    // src/plugin_sdk/root.zig comptime-verifies its hand-written externs
    // against membrane/root.zig's signedness table (task
    // W0a-D) — a plain relative `@import("../membrane/root.zig")`
    // fails ("import of file outside module path": each guest is its own
    // module, rooted at its own directory, and Zig 0.16 won't let a relative
    // import escape that root). Wire it as a named import instead, same
    // target as the guest itself (membrane/root.zig has zero host-only deps —
    // no wasmtime, no wasm_host — by design, so it compiles fine here too).
    const contract_data = b.createModule(.{
        .root_source_file = b.path("src/membrane/root.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    // D2 (doc/d2-schema-payloads.md §3.2/§3.3): the guest SDK imports the
    // IDENTICAL schema/root.zig the host does — same zero-host-dependency
    // posture as membrane/root.zig above, same reason it needs a named
    // import rather than a relative `../schema/root.zig` reach-around (each
    // guest is its own module rooted at its own directory). This is what
    // makes a guest's own `parseSchema`/`decodeCursor`/`canonicalizeSchema`
    // calls (the SDK's `schemaEncode`/`slotBind` ergonomic wrappers) the SAME
    // implementation the host runs, not a second one.
    const schema = b.createModule(.{
        .root_source_file = b.path("src/schema/root.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    const wire = b.createModule(.{
        .root_source_file = b.path("src/wire/root.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    schema.addImport("weft_wire", wire);
    const guest_sdk = b.createModule(.{
        .root_source_file = b.path("src/plugin_sdk/root.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    const input = b.createModule(.{
        .root_source_file = b.path("src/input/root.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    guest_sdk.addImport("weft_membrane", contract_data);
    guest_sdk.addImport("weft_input", input);
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
    // Plugin libraries: ONE edge per name this guest declared, and nothing
    // else on its import path. A library it did not ask for is not merely
    // discouraged — it is absent, so "plugin A quietly reached into plugin
    // B's implementation" cannot be written.
    // ONE module per library per guest: a library reached twice (`ex` wants
    // `prompt` directly, and again through `invoke`) is the same module both
    // times. Zig refuses a file that belongs to two modules of one
    // compilation, so this memo is what lets libraries depend on each other
    // at all rather than only on the SDK.
    var lib_cache: [@typeInfo(Library).@"enum".fields.len]?*std.Build.Module = @splat(null);
    inline for (guest_spec.libraries) |lib| {
        const mod = libraryModule(b, lib, wasm_target, guest_sdk, semantic, fs, guest_mod, &lib_cache);
        guest_mod.addImport(comptime lib.importName(), mod);
    }
    const guest = b.addExecutable(.{
        .name = guest_spec.name,
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
        const guest = buildGuest(b, g);
        mod.addAnonymousImport(g.import, .{ .root_source_file = guest.getEmittedBin() });
    }
}

/// Install the reference plugins as external `.wasm` artifacts under
/// `lib/weft/plugins/`. These are what a user loads with `--plugin`; weft
/// carries no plugins in-process.
fn installPlugins(b: *std.Build) void {
    @setEvalBranchQuota(10_000); // the guest list grows; comptime path per entry
    inline for (guests) |g| {
        if (!g.install) continue;
        const guest = buildGuest(b, g);
        const inst = b.addInstallFileWithDir(guest.getEmittedBin(), .lib, "weft/plugins/" ++ g.name ++ ".wasm");
        b.getInstallStep().dependOn(&inst.step);
    }
    // JS plugins (config/plugins/*.js) — resident quickjs plugins (e.g. the ACP
    // agent client) — install verbatim beside the .wasm plugins, loadable by
    // name (`weft.plugin("acp.js")`).
    inline for (js_plugins) |name| {
        const inst = b.addInstallFileWithDir(b.path("config/plugins/" ++ name), .lib, "weft/plugins/" ++ name);
        b.getInstallStep().dependOn(&inst.step);
    }
}

/// JS plugins shipped in the reference set (config/plugins/*.js).
const js_plugins = [_][]const u8{ "acp.js", "dap.js" };

/// QuickJS-ng compiled to a `wasm32-wasi` reactor (milestone 5 / 06B): the
/// runtime behind user `config.js`. We invoke the same `zig cc` that builds
/// weft on the pinned quickjs-ng source (`WEFT_QUICKJS_NG_SRC`, an unpacked
/// srcOnly tree) plus our embedding shim (src/core/quickjs/weft_qjs.c), following
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
    cc.addFileArg(b.path("src/core/quickjs/weft_qjs.c"));
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
///
/// Also the single place the two BUILD-BAKED HOST DIRECTORIES are wired
/// (`addHostTestDirs` below). They live here, not at their own call sites,
/// because this function is already called on exactly — and only — the
/// module set that compiles `src/core/` (`exe_mod`, `weft_mod`, and
/// `configureTestModule`'s `test_mod`/`instrument_mod`). One call site
/// cannot drift out of sync with another the way three hand-copied ones
/// eventually would.
fn addWasm(b: *std.Build, mod: *std.Build.Module) void {
    const dev = b.graph.environ_map.get("WEFT_WASMTIME_DEV") orelse
        @panic("WEFT_WASMTIME_DEV not set — build inside the nix shell");
    const lib = b.graph.environ_map.get("WEFT_WASMTIME_LIB") orelse
        @panic("WEFT_WASMTIME_LIB not set — build inside the nix shell");
    mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ dev, "include" }) });
    mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ lib, "lib" }) });
    mod.linkSystemLibrary("wasmtime", .{});
    addHostTestDirs(b, mod);
}

/// The directories a TEST BUILD is allowed to touch, comptime-baked under the
/// project cache root so a bare-run test binary provably cannot reach the
/// user's real cache or state. Each consumer prunes its user-environment
/// branch behind `if (builtin.is_test)`, so these options are the only paths
/// a test artifact can resolve:
///
///   - `module_cache_options.test_dir` — compiled `.cwasm` images
///     (`core/wasm.zig`'s `Engine.cacheDir`).
///   - `kv_state_options.test_dir` — the persisted plugin kv store
///     (`core/kv_file.zig`'s `stateDir`).
///
/// Both are made ABSOLUTE here: the e2e Project harness chdirs into a tmpdir
/// mid-suite, so a cwd-relative path would scatter and vanish with it.
fn addHostTestDirs(b: *std.Build, mod: *std.Build.Module) void {
    const dirs = .{
        .{ .import = "module_cache_options", .sub = "weft-cwasm" },
        .{ .import = "kv_state_options", .sub = "weft-kv" },
    };
    inline for (dirs) |d| {
        const path = b.cache_root.join(b.allocator, &.{d.sub}) catch @panic("OOM");
        const opts = b.addOptions();
        opts.addOption([]const u8, "test_dir", if (std.fs.path.isAbsolute(path)) path else b.pathFromRoot(path));
        mod.addOptions(d.import, opts);
    }
}

/// Skia (default renderer): compile the C++ shim (src/skia/shim.cpp) with
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
    cc.addFileArg(b.path("src/skia/shim.cpp"));
    cc.addArg("-o");
    const obj = cc.addOutputFileArg("weft_skia_shim.o");
    mod.addObjectFile(obj);

    mod.linkSystemLibrary("skia", .{}); // -L/-lskia from pkg-config
    mod.addObjectFile(.{ .cwd_relative = libstdcpp });
}

/// Built once and shared by every module `addSyntax` touches. It must be ONE
/// object: `b.addOptions()` content-addresses its emitted file, so three
/// separate-but-identical option sets are three names for one physical file,
/// and Zig refuses to let one file root two named modules ("file exists in
/// modules 'build_options' and 'build_options0'"). The same hazard the
/// `popup_layout_options` comment above describes, reached from the other
/// direction — there the fix was to make the content differ, here it is to
/// stop duplicating it.
var syntax_options: ?*std.Build.Module = null;

fn addSyntax(b: *std.Build, mod: *std.Build.Module) void {
    mod.linkSystemLibrary("tree-sitter", .{});
    const opts = syntax_options orelse blk: {
        const o = b.addOptions();
        // The DEFAULT grammar search path, and nothing else about grammars.
        // The build does not know which languages exist — that set lives in
        // the directory this points at and in the config that asks for them,
        // so adding a language never touches Zig source or this file. `main`
        // still prefers `WEFT_GRAMMAR_PATH` from the environment at runtime;
        // this is only what a build inside the nix shell falls back to.
        o.addOption([]const u8, "grammar_path", b.graph.environ_map.get("WEFT_GRAMMAR_PATH") orelse
            @panic("WEFT_GRAMMAR_PATH not set — build inside the nix shell"));
        // `createModule` once, not `addOptions` per module: `addOptions` wraps
        // the options in a FRESH module every call, which is what puts two
        // module names on one content-addressed file.
        const m = o.createModule();
        syntax_options = m;
        break :blk m;
    };
    mod.addImport("build_options", opts);
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
