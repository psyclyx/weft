//! §19's demolition checklist (doc/contextual-workspace-architecture.md) made
//! EXECUTABLE: absence assertions over the real source tree, not aspiration in
//! a doc comment. Walks `src/` by absolute path — `demolition_options.repo_root`
//! is threaded in from build.zig, since the test binary's cwd is not
//! guaranteed to be the repo root — and grep-equivalent scans every file for
//! the patterns doc §19 wants gone. Each failure names its own file/line, so a
//! regression is self-diagnosing, not a mystery the next reader has to grep
//! for by hand. Kept to plain substring/line scans (fast, no AST) — matching
//! the treefmt-hook precedent of a lint gate that is cheap enough to run on
//! every `zig build test`.
//!
//! Gated here, one bullet each: `semanticActive` branches; domain keymaps or
//! locked tool modes (the `lockedMode` machinery); async routing by buffer
//! name; unhandled keys becoming text (`Feed.text`); compulsory editor
//! storage; cross-plugin private command dependencies; persisted
//! `dired`/`magit` terminology.
//!
//! STANDING, with what each awaits: provider-authored literal keys and domain
//! keymaps (git still binds its own `git` mode — awaits git's move to
//! intentions and postures); core-owned Vim dot-repeat (`Head.DotRepeat` —
//! awaits a grammar-owned recorder, since core dispatch is what sees the
//! rest points it records); semantic-action-to-string-command trampolines
//! (ten action names have no standard intention yet); read-only-as-type
//! compensation (`Buffers.Buffer.read_only` survives as an operation
//! distinction, not a type — awaits the posture work that would carry it);
//! view-owner-exclusive dispatch, row-index identity, silent fixed caps,
//! authority divergence, unselected presence/diagnostics, opaque tunnels, and
//! provider-supplied grant labels — all BEHAVIOURAL, gated by their own e2e
//! tests rather than by a source scan, and named here so the split is
//! deliberate rather than forgotten.

const std = @import("std");
const t = std.testing;
const demolition_options = @import("demolition_options");
const h = @import("harness.zig");
const Keymap = h.core.Keymap;
const Buffers = h.core.Buffers;

/// Whole-line, case-insensitive substrings that must never appear in `src/`
/// (doc §19: "persisted `dired` or `magit` terminology" — the plugin rename
/// and the illustrative-comment rename both landed, so this is now a durable
/// gate, not a one-time sweep).
const banned_terms = [_][]const u8{ "dired", "magit" };

/// Spellings of the retired process-directory door, with the reason each is
/// gone (`doc/place.md`). `wl_cwd` answered `getcwd()` — one value fixed at
/// launch, revealed unconditionally to every guest — so a plugin's effects
/// landed where the EDITOR was started rather than where the interaction was.
/// `wl_place_root` replaced it: the dispatching place's directory, and zero
/// bytes when that place has none locally, so a guest declines instead of
/// silently acting in the launch directory.
///
/// Both the door and its shim wrapper are named, because either one growing
/// back would restore the whole class. `std.Io.Dir.cwd()` — a directory
/// HANDLE, host-side — is untouched and deliberately not matched here.
const retired_process_cwd = [_]struct { spelling: []const u8, reason: []const u8 }{
    .{ .spelling = "wl_cwd", .reason = "the process-directory membrane door is retired — use wl_place_root (doc/place.md)" },
    .{ .spelling = "weft.cwd(", .reason = "the process-directory guest shim is retired — use weft.placeRoot() (doc/place.md)" },
};

const Violation = struct {
    path: []const u8,
    line: usize,
    reason: []const u8,
};

const Scan = struct {
    gpa: std.mem.Allocator,
    violations: std.ArrayList(Violation) = .empty,
    /// Every `fn semanticActive` DEFINITION site found (not call sites —
    /// `weft.semanticActive()` callers are fine; a second, unauthorized
    /// definition duplicating the guest ABI shim's is not).
    semantic_active_defs: std.ArrayList(Violation) = .empty,

    fn record(self: *Scan, path: []const u8, line: usize, reason: []const u8) !void {
        try self.violations.append(self.gpa, .{
            .path = try self.gpa.dupe(u8, path),
            .line = line,
            .reason = reason,
        });
    }
};

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// Best-effort function name a `fn` declaration line introduces — enough for
/// the `findByName` async-delivery check below (this codebase's functions are
/// not nested, so a linear "last fn seen" tracker is grep-equivalent, not an
/// approximation of one).
fn fnNameOf(line: []const u8) ?[]const u8 {
    const idx = std.mem.indexOf(u8, line, "fn ") orelse return null;
    // Reject matches that are part of a longer identifier ("anyfn ").
    if (idx > 0) {
        const prev = line[idx - 1];
        if (std.ascii.isAlphanumeric(prev) or prev == '_') return null;
    }
    var start = idx + 3;
    while (start < line.len and line[start] == ' ') start += 1;
    var end = start;
    while (end < line.len and line[end] != '(' and line[end] != ' ') end += 1;
    if (end == start) return null;
    return line[start..end];
}

/// The plugin id a source file may speak for. A plugin OWNS a directory, so
/// every file under `src/plugins/git/` is `git`, however many it grows;
/// a fixture is a single file under `src/plugin_fixtures/`. Null for host
/// code, which is not a plugin and may name any of them.
fn pluginIdOf(rel_path: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, rel_path, "src/plugins/")) {
        const rest = rel_path["src/plugins/".len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
        return rest[0..slash];
    }
    if (std.mem.startsWith(u8, rel_path, "src/plugin_fixtures/")) {
        const rest = rel_path["src/plugin_fixtures/".len..];
        return rest[0 .. std.mem.lastIndexOfScalar(u8, rest, '.') orelse return null];
    }
    return null;
}

/// A shared plugin library (`src/plugin_lib/<name>/`). It has no plugin id
/// at all: it is code SEVERAL plugins compile, so naming any one consumer's
/// private `plugin.<id>.*` surface is the coupling a library exists to avoid
/// — a stricter rule than a plugin's ("your own and no one else's"), because
/// a library has no "own".
fn isPluginLibrary(rel_path: []const u8) bool {
    return std.mem.startsWith(u8, rel_path, "src/plugin_lib/");
}

/// The `plugin.<id>.` name a line depends on, if any — the §5.1 grammar's
/// own marker for another provider's private surface.
fn pluginNameIn(line: []const u8) ?[]const u8 {
    const marker = "\"plugin.";
    const at = std.mem.indexOf(u8, line, marker) orelse return null;
    const rest = line[at + marker.len ..];
    const dot = std.mem.indexOfScalar(u8, rest, '.') orelse return null;
    return rest[0..dot];
}

fn scanFile(scan: *Scan, rel_path: []const u8, contents: []const u8) !void {
    var current_fn: []const u8 = "";
    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        line_no += 1;

        if (fnNameOf(line)) |name| current_fn = name;

        for (banned_terms) |term| {
            if (containsIgnoreCase(line, term))
                try scan.record(rel_path, line_no, "persisted dired/magit terminology (doc §19)");
        }

        for (retired_process_cwd) |gone| {
            if (std.mem.indexOf(u8, line, gone.spelling) != null)
                try scan.record(rel_path, line_no, gone.reason);
        }

        if (std.mem.indexOf(u8, line, "fn semanticActive") != null) {
            try scan.semantic_active_defs.append(scan.gpa, .{
                .path = try scan.gpa.dupe(u8, rel_path),
                .line = line_no,
                .reason = "semanticActive definition",
            });
        }

        // §19's "`semanticActive` branches", at the site that mattered: a
        // grammar picking its RESTING state by asking whether a semantic view
        // is live (the survivor deleted from vim.zig). Resting comes from the
        // entry's declared posture now (§10.4, `weft.posture()`/
        // `weft.exitToResting`) — asking a view instead is the mode-leak
        // class growing back. Calling `semanticActive` for what it means
        // (dispatching a structured action, `guest/ex.zig`) stays fine; what
        // this refuses is the FORK between it and a mode change.
        if (std.mem.indexOf(u8, line, "semanticActive") != null and
            (std.mem.indexOf(u8, line, "setMode") != null or
                std.mem.indexOf(u8, line, "exitToResting") != null or
                std.mem.indexOf(u8, line, "restingMode") != null))
            try scan.record(rel_path, line_no, "resting-mode restoration forked on semanticActive (doc §19; read the declared posture instead — §10.4)");

        if (containsIgnoreCase(line, "lockedmode"))
            try scan.record(rel_path, line_no, "lockedMode call site (the Keymap machinery is deleted — doc §19 'locked tool modes')");

        if (std.mem.indexOf(u8, line, "findByName(") != null and containsIgnoreCase(current_fn, "deliver"))
            try scan.record(rel_path, line_no, "findByName on an async delivery path (resolve the captured ref instead)");

        // Doc §19 "cross-plugin private command dependencies": a plugin may
        // name its OWN `plugin.<id>.*` surface and no one else's; a shared
        // library may name none, having no own.
        if (pluginNameIn(line)) |named| {
            if (isPluginLibrary(rel_path)) {
                try scan.record(rel_path, line_no, "a plugin LIBRARY names a plugin's private command — shared code must not couple to one consumer (doc §19)");
            } else if (pluginIdOf(rel_path)) |owner| {
                if (!std.mem.eql(u8, named, owner))
                    try scan.record(rel_path, line_no, "depends on another plugin's private command name (doc §19)");
            }
        }
    }
}

test "demolition: §19 checklist absences hold over src/" {
    const gpa = t.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const src_path = try std.fs.path.join(gpa, &.{ demolition_options.repo_root, "src" });
    defer gpa.free(src_path);
    var src_dir = try std.Io.Dir.openDirAbsolute(io, src_path, .{ .iterate = true });
    defer src_dir.close(io);

    var scan: Scan = .{ .gpa = gpa };
    defer {
        for (scan.violations.items) |v| gpa.free(v.path);
        scan.violations.deinit(gpa);
        for (scan.semantic_active_defs.items) |v| gpa.free(v.path);
        scan.semantic_active_defs.deinit(gpa);
    }

    var walker = try src_dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        // This file itself names every banned pattern as a string literal —
        // it is the checker, not checked content.
        if (std.mem.eql(u8, entry.path, "e2e/demolition_test.zig")) continue;
        const contents = entry.dir.readFileAlloc(io, entry.basename, gpa, .limited(4 << 20)) catch |err| switch (err) {
            error.IsDir => continue,
            else => return err,
        };
        defer gpa.free(contents);
        const rel_path = try std.fmt.allocPrint(gpa, "src/{s}", .{entry.path});
        defer gpa.free(rel_path);
        try scanFile(&scan, rel_path, contents);
    }

    // `semanticActive` (doc §19: "`semanticActive` branches") has exactly one
    // definition site left: the guest ABI shim (src/plugin_sdk/root.zig). Anything
    // else means a second implementation snuck back in, bypassing the shim.
    if (scan.semantic_active_defs.items.len != 1 or
        !std.mem.eql(u8, scan.semantic_active_defs.items[0].path, "src/plugin_sdk/root.zig"))
    {
        for (scan.semantic_active_defs.items) |v|
            std.debug.print("demolition: unexpected semanticActive definition at {s}:{d}\n", .{ v.path, v.line });
        try t.expect(false);
    }

    for (scan.violations.items) |v|
        std.debug.print("demolition: {s}:{d}: {s}\n", .{ v.path, v.line, v.reason });
    try t.expectEqual(@as(usize, 0), scan.violations.items.len);

    // The `.text` self-insert branch `Keymap.Feed` used to carry is already
    // dead — assert it STAYS dead at the type level (doc §19), not merely
    // absent from a switch someone could silently reintroduce.
    inline for (@typeInfo(Keymap.Feed).@"union".fields) |field| {
        try t.expect(!std.mem.eql(u8, field.name, "text"));
    }

    // Doc §19 "compulsory editor storage in workspace entries": an entry's
    // editor is OPTIONAL at the type level, so an entry that holds no text
    // cannot be made to carry a dummy one to satisfy the field.
    inline for (@typeInfo(Buffers.Buffer).@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, "editor"))
            try t.expect(@typeInfo(field.type) == .optional);
    }
}

// ── A JS plugin is not a different kind of plugin (doc/place.md §4.1a) ──

// `quickjs.wasm` IS a wasm plugin, so a JS plugin is code running inside a
// wasm guest and must not be able to do anything a wasm guest cannot. Today
// that is not structural: `membrane/qjs_contract.zig` is a self-described
// THIRD surface, its own imports bound onto quickjs.wasm's linker beside the
// `wl_*` doors, with its own handlers and gates.
//
// Two hand-maintained membranes drift, and the drift is not hypothetical:
// `qjs_proc_spawn` carried a `cwd` argument `wl_proc_spawn` never had, which
// is exactly the local-first spelling `doc/place.md` exists to remove. This
// gate is what would have caught it.
//
// The rule, and why it is scoped the way it is: a `qjs_*` door in the
// **plugin** group that shares a name with a `wl_*` door is the SAME door
// reached two ways, so it must have the same arity. The **config** group is
// a genuinely different surface — the config DSL, a distinct role with its
// own trust tier — and several of its names collide with `wl_*` doors while
// meaning something else entirely (`qjs_semantic_action` DECLARES a command;
// `wl_semantic_action` INVOKES one). Those are exempt, and the collisions are
// recorded here rather than silently tolerated.
test "demolition: plugin-plane JS doors match their wasm twins exactly" {
    const qjs = h.core.membrane.qjs;
    const wl = h.core.membrane.wl;

    var twins_checked: usize = 0;
    for (qjs.imports) |q| {
        if (q.group != .plugin) continue;
        // `qjs_foo` is the twin of `wl_foo`.
        for (wl.imports) |w| {
            if (!std.mem.eql(u8, w.name[3..], q.name[4..])) continue;
            twins_checked += 1;
            if (w.params.len != q.params.len or w.results.len != q.results.len) {
                std.debug.print(
                    "\nplugin-plane door '{s}' differs between the two membranes: " ++
                        "wl_{s} takes {d}->{d}, qjs_{s} takes {d}->{d}.\n" ++
                        "A JS plugin runs inside quickjs.wasm; it must not reach a door " ++
                        "shaped differently from the one every other guest gets. " ++
                        "Resolve toward the NARROWER door (doc/place.md §4.1a).\n",
                    .{
                        q.name,      w.name[3..],  w.params.len,  w.results.len,
                        q.name[4..], q.params.len, q.results.len,
                    },
                );
                return error.JsPlaneDivergedFromWasmPlane;
            }
            break;
        }
    }

    // If this drops to zero the gate has stopped checking anything — a rename
    // on either side would otherwise silently disable it.
    try t.expect(twins_checked >= 5);
}

// Matching arity is a tripwire, not the property. The property is that the two
// planes reach ONE implementation, so a difference between them has nowhere to
// live. For the proc surface — the door the `cwd` drift actually happened on —
// that is now true by construction: `wasm_host/proc.zig` holds four bodies,
// `contract.zig` binds them as `wl_proc_*` through `wasmDoor`, `quickjs.zig`
// binds the SAME bodies as `qjs_proc_*` through `jsDoor`, and neither
// trampoline generator does anything but cast `data` and spell a denial.
//
// This gate proves that by FUNCTION POINTER, against the tables each membrane
// actually binds from — so replacing one plane's handler with a hand-written
// body of the right shape fails here, which is exactly what a divergence looks
// like on its first commit.
test "demolition: the plugin-plane proc doors are ONE body reached two ways" {
    const proc_doors = h.core.wasm_host.proc_doors;
    const wl_bound = h.core.membrane.wl_bound;
    const quickjs = h.core.quickjs;

    inline for (proc_doors.doors) |d| {
        const HostFn = @TypeOf(d.wl);

        // 1. The `wl_*` handler is the trampoline generated from THIS door's
        //    shared body and gate — nothing hand-written can sit here.
        try t.expectEqual(proc_doors.wasmDoor(d.body, d.wl_gate), d.wl);

        // 2. …and it is what the wasm membrane actually binds for `wl_<name>`.
        var wl_handler: ?HostFn = null;
        for (wl_bound.imports) |entry| {
            if (std.mem.eql(u8, entry.name, "wl_" ++ d.name)) wl_handler = entry.handler;
        }
        try t.expectEqual(@as(?HostFn, d.wl), wl_handler);

        // 3. The `qjs_*` handler the JS membrane binds runs the SAME body,
        //    through the resident plane's own trampoline. If someone gives the
        //    JS plane its own `proc_spawn` again — with a `cwd` argument, say —
        //    this is the assertion that fails.
        var qjs_handler: ?HostFn = null;
        inline for (quickjs.plugin_handlers) |entry| {
            if (comptime std.mem.eql(u8, entry.name, "qjs_" ++ d.name)) qjs_handler = entry.handler;
        }
        try t.expectEqual(@as(?HostFn, quickjs.jsDoor(d.body, d.qjs_gate)), qjs_handler);

        // 4. The two transports' possession checks agree — except where the
        //    table says otherwise, and it may only say otherwise for the two
        //    doors whose remainder is named in `proc.zig`'s `doors` doc
        //    (`qjs_proc_send`/`qjs_proc_read` re-check `proc` on every call;
        //    their `wl_*` twins can't until `contract_data.zig`, which is under
        //    concurrent edit, gets `.perm = .proc`). A NEW asymmetry has to
        //    add itself to this list to compile past here.
        const named_remainder = comptime std.mem.eql(u8, d.name, "proc_send") or
            std.mem.eql(u8, d.name, "proc_read");
        if (d.wl_gate != d.qjs_gate and !named_remainder) {
            std.debug.print(
                "\nplugin-plane door '{s}' is gated differently on the two planes " ++
                    "(wl {s}, qjs {s}) and is not one of the two recorded remainders.\n" ++
                    "A JS plugin runs inside quickjs.wasm; resolve toward the NARROWER " ++
                    "gate, or record the blocker (doc/place.md §4.1a).\n",
                .{
                    d.name,
                    if (d.wl_gate) |p| p.label() else "ungated",
                    if (d.qjs_gate) |p| p.label() else "ungated",
                },
            );
            return error.JsPlaneDivergedFromWasmPlane;
        }
        // …and the other direction, the way `contract.zig`'s `perm_gated` does
        // it: a remainder that has been CLOSED must stop being excused here,
        // or the next real divergence on that door slips through the
        // exception someone forgot to delete.
        if (named_remainder and d.wl_gate == d.qjs_gate) {
            std.debug.print(
                "\nplugin-plane door '{s}' is now gated identically on both planes — " ++
                    "delete it from this test's `named_remainder` list and from the " ++
                    "remainder note on `wasm_host/proc.zig`'s `doors` (doc/place.md §4.1a).\n",
                .{d.name},
            );
            return error.StaleDivergenceException;
        }
    }
}

// The same proof, for the READ surface. `wasm_host/edit.zig`'s `read_doors`
// hold one body each; `wl_cursor`/`wl_slice`/… bind them through `wasmDoor`
// and `qjs_cursor`/`qjs_slice`/… bind the SAME ones through `jsDoor`.
//
// This is what "a JS plugin is not second-class" has to mean concretely: not
// that someone wrote JS-shaped equivalents, but that there is one body and two
// casts, so the planes cannot describe the buffer differently. Before these
// doors existed a JS plugin had `weft.lineText()` and nothing else — a narrower
// answer to a question `lineAt` + `slice` already answered, invented because
// the real door was out of reach.
test "demolition: the plugin-plane read doors are ONE body reached two ways" {
    const edit_doors = h.core.wasm_host.edit_doors;
    const wl_bound = h.core.membrane.wl_bound;
    const quickjs = h.core.quickjs;

    inline for (edit_doors.read_doors) |d| {
        const HostFn = @TypeOf(d.wl);

        // The `wl_*` handler is this door's own generated trampoline…
        try t.expectEqual(edit_doors.wasmDoor(d.body), d.wl);

        // …it is what the wasm membrane actually binds…
        var wl_handler: ?HostFn = null;
        for (wl_bound.imports) |entry| {
            if (std.mem.eql(u8, entry.name, "wl_" ++ d.name)) wl_handler = entry.handler;
        }
        try t.expectEqual(@as(?HostFn, d.wl), wl_handler);

        // …and the JS plane binds the same body through its own trampoline.
        // These doors are ungated on BOTH planes, and that is not an omission:
        // reading the entry your own command is dispatching in carries no
        // authority. If one plane grows a gate the other lacks, the pointers
        // stop matching here.
        var qjs_handler: ?HostFn = null;
        inline for (quickjs.plugin_handlers) |entry| {
            if (comptime std.mem.eql(u8, entry.name, "qjs_" ++ d.name)) qjs_handler = entry.handler;
        }
        try t.expectEqual(@as(?HostFn, quickjs.jsDoor(d.body, null)), qjs_handler);
    }
}
