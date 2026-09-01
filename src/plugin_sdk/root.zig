//! `weft` (guest side) — the ABI a `.wasm` plugin sees, and the ONLY door it
//! has: every call here bottoms out in an `extern "weft"` host import (the
//! grant), scalars cross as i32/u32, and bulk bytes cross through the guest's
//! own linear memory — either the host reads `(ptr, len)` out of us (writes:
//! `edit`, `kvPut`) or fills a scratch buffer we hand it `(ptr, cap)` and
//! returns the length (reads: `slice`, `kvGet`, `path`). No host pointer ever
//! reaches the guest.
//!
//! **The doors live in `externs.zig`**, reached here as `e.wl_*`: 231
//! hand-written externs plus the comptime tripwire that holds them to
//! `membrane/root.zig`'s table, so neither half can drift from the other. This
//! file is the ERGONOMICS over them — the surface guest code actually calls.
//!
//! Everything public here is flat (`weft.slice`, `weft.edit`) because that is
//! the API 50 plugins are written against. Zig 0.16 removed `usingnamespace`,
//! so a namespace cannot be composed from several files without one
//! re-export line per declaration; splitting these 232 wrappers into topical
//! files would buy a smaller implementation and a 232-line catalogue to go
//! with it. The doors were worth separating because they cost NO re-exports
//! and are the security-relevant surface; the wrappers are not.
//!
//! Permission groups: A core (log), the describe-phase declarations
//! (declareCommand/requestPerm), B read-only (cursor/byteLen/slice/lineAt/
//! selection/path), C write (edit/register/jump), E admin (kv), plus echo. A
//! guest declares in `describe()`; the host cross-checks every
//! `register`/effect against that declaration (the perm handshake).

const std = @import("std");

/// A growable heap over the guest's wasm linear memory (grows via memory.grow).
/// Plugins that must hold data whose size the document dictates — a JSON-RPC
/// message, an escaped chunk — allocate here instead of a fixed buffer, so file
/// size is bounded by wasm memory (and streaming, for the unbounded cases), not
/// a compile-time constant. See [[completion-ux-roadmap]].
pub const allocator: std.mem.Allocator = std.heap.wasm_allocator;

/// The pure-data half of the membrane contract (core/membrane/
/// membrane/root.zig) — no wasmtime/wasm_host dependency, so it compiles
/// here under wasm32-freestanding same as the host side does. Used below
/// ONLY by the comptime verification block; the ergonomic wrappers don't
/// reference it.
/// The input boundary's vocabulary (input/root.zig) — the SAME `Posture`
/// enum the host resolves, imported as a named module for the same reason
/// `contract_data` is: a guest-side copy of a wire enum is exactly the drift
/// this membrane exists to prevent.
pub const Posture = @import("weft_input").Posture;

/// D2's schema language + marshaller (schema/root.zig), imported under the
/// SAME name a guest's own code uses to reach it directly for a build-time-
/// known slot's typed encode/decode (§3.3's build-time codegen arm is a
/// LATER step; every guest today, including this SDK's own ergonomic
/// wrappers below, uses this module's runtime interpreter directly — the
/// §3.3 fallback arm, always available with zero codegen).
pub const schema = @import("weft_schema");

/// Portable semantic values and their canonical codec. These are named build
/// modules under the wasm target too: a plugin can author scenes and targets,
/// but cannot import host runtime implementation files sideways.
pub const semantic = @import("weft_semantic");
pub const semantic_codec = @import("weft_scene_codec");
pub const fs = @import("weft_fs");
pub const fs_codec = @import("weft_fs_codec");

/// The raw host imports — the doors themselves. See `externs.zig`; the
/// wrappers below are the surface guest code actually calls.
const e = @import("externs.zig");

/// Shared scratch for host→guest byte returns. A read wrapper (`slice`,
/// `path`, `kvGet`) returns a slice INTO this buffer, valid until the next
/// read call — copy what must outlive that. 64 KiB covers a line/value; the
/// host truncates to `cap`, so an over-long read is clamped, never a
/// buffer overrun.
var scratch: [1 << 16]u8 = undefined;
/// A separate scratch for `completionPrefix`, so a provider can hold its
/// prefix while it walks the buffer through `slice` (which reuses `scratch`).
var prefix_scratch: [1 << 12]u8 = undefined;
/// A separate scratch for command-arg strings, so a handler can hold an arg
/// while it reads the buffer through `slice`.
var arg_scratch: [1 << 12]u8 = undefined;
/// A separate scratch for a command's declared ARGUMENT NAMES
/// (`commandArg`) — the third of the introspection trio, and it needs its own
/// so all three compose. A palette row is `commandName` + `commandSummary` +
/// the parameter shape at once; sharing `scratch` with `commandName` meant
/// rendering `<slot>` over the front of `explain-binding` and listing a row
/// called `slotain-binding` that nothing could ever run.
var param_scratch: [256]u8 = undefined;
/// A separate scratch for offer reasons and refusals, so a UI can hold an
/// offer's name and provider (in `scratch`/`arg_scratch`) while it reads why
/// that offer cannot run.
var intent_scratch: [1 << 10]u8 = undefined;

fn p(x: anytype) u32 {
    return @intCast(@intFromPtr(x));
}

pub const Range = struct { start: usize, end: usize };
pub const Level = enum(u32) { debug = 0, info = 1, warn = 2, err = 3 };
/// Mirrors abi.Perm's order (fs_read, fs_write, net, proc, timer).
pub const Perm = enum(u32) { fs_read = 0, fs_write = 1, net = 2, proc = 3, timer = 4, env = 5 };

// ── Group A: core ────────────────────────────────────────────────────
pub fn log(level: Level, msg: []const u8) void {
    e.wl_log(@intFromEnum(level), p(msg.ptr), @intCast(msg.len));
}

// ── Describe phase: up-front declarations (no authority) ──────────────
pub fn declareCommand(name: []const u8) void {
    e.wl_declare_command(p(name.ptr), @intCast(name.len));
}
/// Declare a command AND say what it takes and does — the form to use for any
/// command with arguments. `params` is a space-separated parameter list, each
/// name bare (required) or bracketed (optional), written exactly as a person
/// will read it back: `"host:port"`, `"port access"`, `"[preset]"`.
///
/// This is what makes a plugin command a first-class citizen: the palette
/// documents it and asks for its arguments, the `:` line hints its shape while
/// you type, and a refusal names what was missing. Without it a command is a
/// bare name — which is all a plugin could say before, and why `net-open` from
/// the palette used to dial nothing at all.
pub fn describeCommand(name: []const u8, params: []const u8, summary: []const u8) void {
    e.wl_declare_command_doc(
        p(name.ptr),
        @intCast(name.len),
        p(params.ptr),
        @intCast(params.len),
        p(summary.ptr),
        @intCast(summary.len),
    );
}
/// Declare a capability this plugin will provide (e.g. "edit/completion").
/// Cross-checked host-side against the matching `provide*` at init time.
pub fn declareCapability(name: []const u8) void {
    e.wl_declare_capability(p(name.ptr), @intCast(name.len));
}
pub fn requestPerm(perm: Perm) void {
    e.wl_request_perm(@intFromEnum(perm));
}

// ── The manifest: one command table, three generated exports ──────────
// `plugin.zig`'s doc says why. Three re-export lines is the whole cost of
// the split (Zig 0.16 has no `usingnamespace`), and this one is worth it:
// the generated dispatch is the only correct reading of `register`'s
// return value, and `thunk` is the only place a command argument is
// copied off the shared shim scratch before a handler can be handed it.
pub const CommandEntry = @import("plugin.zig").Entry;
pub const PluginHooks = @import("plugin.zig").Hooks;
pub const plugin = @import("plugin.zig").plugin;
pub const thunk = @import("plugin.zig").thunk;

// ── exec: an argv in, (status, stdout, stderr) out ────────────────────
// See `exec.zig` for what this replaces. `weft.plugin` exports `on_exec`,
// so a plugin supplies a continuation and never an async demux.
pub const ExecSpec = @import("exec.zig").Spec;
pub const ExecDone = @import("exec.zig").Done;
pub const ExecStream = @import("exec.zig").Stream;
pub const exec = @import("exec.zig").exec;
pub const execWith = @import("exec.zig").execWith;

// ── ask: a question with a continuation, not a pick id to demux ───────
// See `ask.zig`. `weft.plugin` exports `on_pick_accept`, routing the SDK's
// own ids here and everything else to the manifest's `pick` hook.
pub const AskSpec = @import("ask.zig").Spec;
pub const AskCandidate = @import("ask.zig").Candidate;
pub const Answer = @import("ask.zig").Answer;
pub const ask = @import("ask.zig").ask;
pub const askWith = @import("ask.zig").askWith;
pub const confirm = @import("ask.zig").confirm;
pub const confirmWith = @import("ask.zig").confirmWith;

// ── projection: publish a node tree; the host owns every offset ───────
// See `projection.zig`. This is the door that lets a tool plugin stop
// being 400 lines of offset bookkeeping — and, because nothing here
// takes or returns an offset, stop being able to act on a stale row.
pub const ProjectionNode = @import("projection.zig").Node;
pub const ProjectionBuilder = @import("projection.zig").Builder;
pub const project = @import("projection.zig").begin;
pub const projectionAtCursor = @import("projection.zig").atCursor;
pub const projectionToggleFold = @import("projection.zig").toggleFold;
pub const projectionSelectedLines = @import("projection.zig").selectedLines;

// ── Group B: read-only ───────────────────────────────────────────────
pub fn cursor() usize {
    return e.wl_cursor();
}
pub fn byteLen() usize {
    return e.wl_byte_len();
}
/// Capture an opaque witness for the active document's current CRDT frontier.
/// The handle carries no version bytes or ordering information; release it
/// when the equality check is no longer needed.
pub fn docSnapshot() ?u32 {
    const handle = e.wl_doc_snapshot();
    return if (handle < 0) null else @intCast(handle);
}
/// Test whether the witness still names the active buffer's exact causal
/// frontier. Missing, stale, or cross-buffer handles return false.
pub fn docSnapshotIsCurrent(handle: u32) bool {
    return e.wl_doc_snapshot_is_current(handle) != 0;
}
/// Release a document snapshot witness. Repeated release is harmless.
pub fn releaseDocSnapshot(handle: u32) void {
    e.wl_doc_snapshot_release(handle);
}
/// Bytes of `[start, end)` of the active document (clamped). Valid until the
/// next read call — copy to keep.
pub fn slice(start: usize, end: usize) []const u8 {
    const n = e.wl_slice(@intCast(start), @intCast(end), p(&scratch), scratch.len);
    return scratch[0..n];
}
/// `[start, end)` of the line containing `offset` (end before the newline).
pub fn lineAt(offset: usize) Range {
    var pair: [2]u32 = undefined;
    e.wl_line_at(@intCast(offset), p(&pair));
    return .{ .start = pair[0], .end = pair[1] };
}
/// The current selection range, or null.
pub fn selection() ?Range {
    var pair: [2]u32 = undefined;
    if (e.wl_selection(p(&pair)) == 0) return null;
    return .{ .start = pair[0], .end = pair[1] };
}
/// The active buffer's backing path, or null. Valid until the next read call.
pub fn path() ?[]const u8 {
    const n = e.wl_path(p(&scratch), scratch.len);
    if (n < 0) return null;
    return scratch[0..@intCast(n)];
}

// ── Group C: write (grade-gated host-side by the plugin's principal) ──
/// THE text-mutation door: replace `[r.start, r.end)` with `bytes`, authored
/// as this plugin's peer through the host's grade gate.
pub fn edit(r: Range, bytes: []const u8) void {
    e.wl_edit(@intCast(r.start), @intCast(r.end), p(bytes.ptr), @intCast(bytes.len));
}
/// CONTENT PRODUCTION door: draw a derived/streamed projection (a tool buffer's
/// listing, a transcript) into `[r.start, r.end)`. Distinct from `edit`: it
/// BYPASSES read-only (the text is output, regenerated from a model — not
/// user-editable) and authors as the plugin's own peer (not the user's undo).
/// Tool/model buffers render with this; `edit` is for interactive text.
pub fn render(r: Range, bytes: []const u8) void {
    e.wl_render(@intCast(r.start), @intCast(r.end), p(bytes.ptr), @intCast(bytes.len));
}
/// Like `edit`, but authored as the named `role=.agent` sub-peer `agent`
/// (e.g. "claude", "codex") instead of this plugin's own peer — so an agent
/// plugin's edits attribute per-agent and get their own selective-undo unit.
/// An empty `agent` falls back to the plugin peer. Grade-gated identically.
pub fn editAs(agent: []const u8, r: Range, bytes: []const u8) void {
    e.wl_edit_as(p(agent.ptr), @intCast(agent.len), @intCast(r.start), @intCast(r.end), p(bytes.ptr), @intCast(bytes.len));
}
/// Register a command (cross-checked against `describe`). Returns its id, the
/// value the host passes back to `on_command`.
pub fn register(name: []const u8) u32 {
    return e.wl_register(p(name.ptr), @intCast(name.len));
}
/// Place the live cursor at a byte offset (clamped).
pub fn jump(offset: usize) void {
    e.wl_jump(@intCast(offset));
}
/// vim-goggles: briefly flash the byte range `[start, end)` (e.g. the region a
/// yank just copied), a visual confirmation of what an operator affected.
pub fn flash(start: usize, end: usize) void {
    e.wl_flash(@intCast(start), @intCast(end));
}

// ── Styles (tool-buffer coloring): publish per-byte-range StyleClass spans over
// the ACTIVE buffer, painted by the view through the theme (same door as
// `edit` for which buffer it targets). `styleClear` first, then a `style` per
// classified range — the classic git/grep coloring pattern. Cleared with the
// buffer on close. Mirrors core.capability.StyleClass. ──
pub const StyleClass = enum(u32) {
    normal = 0,
    added = 1,
    removed = 2,
    header = 3,
    location = 4,
    emphasis = 5,
    muted = 6,
};

/// Drop the active buffer's style spans and re-baseline them to `.normal` over
/// the whole buffer — call before repopulating with `style`.
pub fn styleClear() void {
    e.wl_style_clear();
}
/// Paint `[start, end)` of the active buffer with `class` (clamped to the buffer;
/// a no-op if `styleClear` wasn't called first this round).
pub fn style(start: usize, end: usize, class: StyleClass) void {
    e.wl_style(@intCast(start), @intCast(end), @intFromEnum(class));
}

// ── Folding: hide byte ranges of the active buffer (rows collapse; vertical
// motion skips them). A general primitive — status/files/grep/outline plugins
// fold sections. `foldClear` then a `fold` per hidden range; republish on every
// re-render (offsets move). `start` should be just past a header line's newline
// so the header stays visible. ──
pub fn foldClear() void {
    e.wl_fold_clear();
}
/// Hide `[start, end)` — collapse those rows until the next `foldClear`.
pub fn fold(start: usize, end: usize) void {
    e.wl_fold(@intCast(start), @intCast(end));
}

/// How a decoration is placed beside the text (never in the document).
pub const DecoPlacement = enum(u32) { virtual_before = 1, virtual_after = 2, eol = 3, gutter = 4 };
/// Reclaim + empty the decorations layer (republish the full set after).
pub fn decorateClear() void {
    e.wl_decorate_clear();
}
/// Place a display-only decoration anchored at `anchor`: virtual text drawn
/// beside the line, colored by `role` (a styles-palette class). It is NEVER a
/// document byte — so `yy` never yanks it and it takes no commit. This is how a
/// projection shows metadata (files's perms/size/arrow/mark) off the text.
pub fn decorate(anchor: usize, placement: DecoPlacement, role: StyleClass, text: []const u8) void {
    e.wl_decorate(@intCast(anchor), @intFromEnum(placement), @intFromEnum(role), p(text.ptr), @intCast(text.len));
}

// ── Breakpoints (anchored on the document, not remembered here) ──────
//
// A breakpoint is a place, so the host holds it as an ANCHOR on the active
// document: an edit above it carries it along, and the line the DAP client
// re-arms at is derived from that anchor when it is needed. A guest that kept
// its own offsets would hold the second, staler copy — hence read-back
// (`breakpointOffsets`) rather than a guest-side table.

/// Toggle a breakpoint at `offset` in the active document. True if one is now
/// set there.
pub fn breakpointToggle(offset: usize) bool {
    return e.wl_breakpoint_toggle(@intCast(offset)) == 1;
}

/// Drop every breakpoint in the active document.
pub fn breakpointClear() void {
    e.wl_breakpoint_clear();
}

/// The active document's breakpoint offsets, as an "o1,o2,…" CSV at the
/// current head. Borrows `scratch` — valid until the next read call.
pub fn breakpointOffsets() []const u8 {
    const n = e.wl_breakpoint_offsets(p(&scratch), scratch.len);
    if (n <= 0) return "";
    return scratch[0..@intCast(n)];
}

// ── Annotation layers (the third-party decoration package, §11.7) ────
//
// `decorate` above paints the ACTIVE buffer, and only a projection's own
// plugin ever wants that. This is the other half: a named layer on an entry
// this plugin does NOT own, addressed by a captured reference rather than by
// focus, so a decorator can never follow the user into someone else's buffer.
// Every round is `begin` then a `span` per mark — the host stamps the entry
// revision at `begin`, and the paint DROPS (never rebases into a guess) the
// moment the entry is edited, until the next round. `close` takes this
// plugin's paint away and nothing else.

/// One entry's annotation layer, held open across calls.
pub const Annotations = struct {
    handle: u32,

    /// How an annotation span presents. `range` is a face over `[start, end)`;
    /// the rest are display-only decorations anchored at `start` (the same set
    /// `DecoPlacement` names for the active buffer).
    pub const Placement = enum(u32) { range = 0, virtual_before = 1, virtual_after = 2, eol = 3, gutter = 4 };

    /// Claim layer `name` on the entry with compact id `entry` (from
    /// `bufferId`). Null when the entry is unknown, holds no text, or `name`
    /// is a builtin feed this door refuses to hand over.
    pub fn open(entry: u32, name: []const u8) ?Annotations {
        const h = e.wl_annotate_open(entry, p(name.ptr), @intCast(name.len));
        return if (h < 0) null else .{ .handle = @intCast(h) };
    }

    /// Drop this layer: the paint goes, the entry is untouched.
    pub fn close(self: Annotations) void {
        e.wl_annotate_close(self.handle);
    }

    /// The decorated entry's byte length, or 0 once the entry is gone.
    pub fn byteLen(self: Annotations) usize {
        const n = e.wl_annotate_len(self.handle);
        return if (n < 0) 0 else @intCast(n);
    }

    /// Read `[start, end)` of the decorated entry into `buf`.
    pub fn read(self: Annotations, start: usize, end: usize, buf: []u8) []const u8 {
        const n = e.wl_annotate_read(self.handle, @intCast(start), @intCast(end), p(buf.ptr), @intCast(buf.len));
        return if (n <= 0) "" else buf[0..@intCast(n)];
    }

    /// Open a publish round against the entry's CURRENT revision, dropping
    /// the previous set. False once the entry is gone.
    pub fn begin(self: Annotations) bool {
        return e.wl_annotate_begin(self.handle) == 1;
    }

    /// One span in the open round, colored by `role` (a styles-palette class).
    /// `text` is the display string for a decoration placement, ignored by
    /// `.range`.
    pub fn span(self: Annotations, start: usize, end: usize, role: StyleClass, placement: Annotations.Placement, text: []const u8) void {
        e.wl_annotate_span(
            self.handle,
            @intCast(start),
            @intCast(end),
            @intFromEnum(role),
            @intFromEnum(placement),
            p(text.ptr),
            @intCast(text.len),
        );
    }
};

// ── Native editor surface + anchored ranges (motions/operators) ──────
pub const Dir = enum(u32) { back = 0, fwd = 1 };
pub const Kind = enum(u32) { char = 0, line = 1 };

/// The target offset one char (grapheme) or line from `from` in `dir`, without
/// moving the cursor. The native primitive a motion composes (design §6.1).
pub fn step(from: usize, dir: Dir, kind: Kind) usize {
    return e.wl_editor_step(@intCast(from), @intFromEnum(dir), @intFromEnum(kind));
}
/// Select `[r.start, r.end)` (mark at start, cursor at end).
pub fn setSelection(r: Range) void {
    e.wl_set_selection(@intCast(r.start), @intCast(r.end));
}

/// Anchor `[r.start, r.end)` in the active CRDT document and return an opaque
/// live-range handle. The document advances its endpoints through local and
/// merged edits; call `releaseRange` when retaining it across a callback.
pub fn anchorRange(r: Range) ?u32 {
    const h = e.wl_anchor_range(@intCast(r.start), @intCast(r.end));
    return if (h < 0) null else @intCast(h);
}
/// Return the anchored range `handle` as this command's borrowed result. The
/// live anchors remain document-owned across the synchronous command chain.
pub fn setResultRange(handle: u32) void {
    e.wl_set_result_range(handle);
}
/// Run `cmd` (a motion) and take its returned range as an opaque handle, or
/// null if it produced none. The handle is valid for the rest of this dispatch.
pub fn runRange(cmd: []const u8) ?u32 {
    const h = e.wl_run_range(p(cmd.ptr), @intCast(cmd.len));
    return if (h < 0) null else @intCast(h);
}
/// Resolve a live range handle to its current `[start, end)`, or null if its
/// buffer/resource no longer exists.
pub fn rangeEnds(handle: u32) ?Range {
    var pair: [2]u32 = undefined;
    if (e.wl_range_ends(handle, p(&pair)) < 0) return null;
    return .{ .start = pair[0], .end = pair[1] };
}
/// Keep a live range across later command dispatches. Pair a successful retain
/// with `releaseRange` in the interaction's terminal callback.
pub fn retainRange(handle: u32) bool {
    return e.wl_range_retain(handle) == 0;
}
/// Release a live range retained across callbacks. Idempotent.
pub fn releaseRange(handle: u32) void {
    e.wl_range_release(handle);
}
/// Run `cmd` (an operator) passing a range `handle` as its single arg.
pub fn runRangeArg(cmd: []const u8, handle: u32) void {
    e.wl_run_range_arg(p(cmd.ptr), @intCast(cmd.len), handle);
}
/// Import the `i`-th borrowed live-range argument as an opaque handle, or null.
pub fn argRange(i: usize) ?u32 {
    const h = e.wl_arg_range(@intCast(i));
    return if (h < 0) null else @intCast(h);
}
/// Replace the anchored range `handle` with `bytes`, authored as this plugin's
/// peer through the grade gate after resolving its current endpoints.
pub fn editRange(handle: u32, bytes: []const u8) void {
    e.wl_edit_range(handle, p(bytes.ptr), @intCast(bytes.len));
}

// ── Group E: admin (kv) ──────────────────────────────────────────────
/// This plugin's value for `key` (namespaced host-side), or null. Valid until
/// the next read call.
pub fn kvGet(key: []const u8) ?[]const u8 {
    const n = e.wl_kv_get(p(key.ptr), @intCast(key.len), p(&scratch), scratch.len);
    if (n < 0) return null;
    return scratch[0..@intCast(n)];
}
pub fn kvPut(key: []const u8, value: []const u8) void {
    e.wl_kv_put(p(key.ptr), @intCast(key.len), p(value.ptr), @intCast(value.len));
}

// ── Config data (weft.set): declarative tables that override a plugin's
// shipped defaults; read at init. Uses a DEDICATED buffer (never the shared
// `scratch`), so a plugin can hold its decoded config while walking the buffer
// via `slice`/`kvGet`. Framed as uvarint(count) then count×(uvarint(len) ++
// bytes) — the same LEB128 style the shim encodes; the decoder returns null on
// a short/truncated buffer rather than silently dropping tail records. ──
var config_scratch: [1 << 16]u8 = undefined;

fn getUv(cur: *[]const u8) ?u64 {
    var shift: u6 = 0;
    var v: u64 = 0;
    while (cur.len > 0) {
        const b = cur.*[0];
        cur.* = cur.*[1..];
        v |= @as(u64, b & 0x7f) << shift;
        if (b & 0x80 == 0) return v;
        if (shift >= 57) return null;
        shift += 7;
    }
    return null;
}

/// Iterates the records of a config list. `next` returns null when exhausted,
/// or on a malformed/truncated buffer (so a short read never yields a partial
/// record silently).
pub const ConfigIter = struct {
    cur: []const u8,
    remaining: u64,
    pub fn next(self: *ConfigIter) ?[]const u8 {
        if (self.remaining == 0) return null;
        const n = getUv(&self.cur) orelse {
            self.remaining = 0;
            return null;
        };
        if (n > self.cur.len) {
            self.remaining = 0;
            return null;
        }
        const rec = self.cur[0..@intCast(n)];
        self.cur = self.cur[@intCast(n)..];
        self.remaining -= 1;
        return rec;
    }
};

/// This plugin's config list for `key` (from `weft.set`), or null if unset. The
/// iterator borrows `config_scratch` — valid until the next config read; safe
/// to hold across `slice`/`kvGet` (its own buffer).
pub fn configList(key: []const u8) ?ConfigIter {
    const n = e.wl_config_get(p(key.ptr), @intCast(key.len), p(&config_scratch), config_scratch.len);
    if (n < 0) return null;
    var cur: []const u8 = config_scratch[0..@intCast(n)];
    const count = getUv(&cur) orelse return null;
    return .{ .cur = cur, .remaining = count };
}

/// This plugin's single config value for `key` (the first record of its list),
/// or "" if unset. Borrows `config_scratch` — valid until the next config read.
pub fn config(key: []const u8) []const u8 {
    var it = configList(key) orelse return "";
    return it.next() orelse "";
}

/// Show a transient status-line message.
pub fn echo(msg: []const u8) void {
    e.wl_echo(p(msg.ptr), @intCast(msg.len));
}

// ── Command args & result (valid only during an `on_command` call) ────
// Integers cross as i32 — the membrane's word, the same width the offset ABI
// (cursor/edit/slice) already uses. Command Values wider than i32 are outside
// the sandbox contract (no reference plugin's command passes one).

/// Number of args the command was invoked with.
pub fn argCount() usize {
    return e.wl_arg_count();
}
/// The `i`-th arg as an integer (0 if absent or not an integer).
pub fn argInt(i: usize) i32 {
    return e.wl_arg_int(@intCast(i));
}
/// The `i`-th arg as a string, or null if absent / not a string. Valid until
/// the next arg read (its own scratch — safe to hold across `slice`).
pub fn argStr(i: usize) ?[]const u8 {
    const n = e.wl_arg_str(@intCast(i), p(&arg_scratch), arg_scratch.len);
    if (n < 0) return null;
    return arg_scratch[0..@intCast(n)];
}
/// Set the command's integer return value.
pub fn setResultInt(n: i32) void {
    e.wl_set_result_int(n);
}
/// Set the command's string return value (copied host-side).
pub fn setResultStr(s: []const u8) void {
    e.wl_set_result_str(p(s.ptr), @intCast(s.len));
}

// ── Config surface (the local plane) ─────────────────────────────────
/// Bind `key` in keymap `mode` to `cmd` (late-bound; resolves at keypress).
pub fn bindKey(mode: []const u8, key: []const u8, cmd: []const u8) void {
    e.wl_bind_key(p(mode.ptr), @intCast(mode.len), p(key.ptr), @intCast(key.len), p(cmd.ptr), @intCast(cmd.len));
}
/// Bind `key` in keymap `mode` to a FIRST-APPLICABLE list (architecture
/// §10.2): `bindKeys("normal", "Return", &.{ "std.target.activate",
/// "vim-open-focused" })` runs the activation intention where the focus
/// offers one and the plugin's own command everywhere else. The grammar
/// authors the order; resolution happens at the keypress, against the focus.
/// Framed as the config surface frames `weft.bind`'s list — one wire shape
/// for one meaning. A list too long for the frame buffer binds nothing.
pub fn bindKeys(mode: []const u8, key: []const u8, cmds: []const []const u8) void {
    var buf: [512]u8 = undefined;
    const blob = frameList(&buf, cmds) orelse return;
    e.wl_bind_keys(p(mode.ptr), @intCast(mode.len), p(key.ptr), @intCast(key.len), p(blob.ptr), @intCast(blob.len));
}

/// Frame `records` as uvarint(count) then count×(uvarint(len) ++ bytes) — the
/// encoding `ConfigIter` reads. Null when `buf` cannot hold them.
fn frameList(buf: []u8, records: []const []const u8) ?[]const u8 {
    var n: usize = 0;
    if (!putUv(buf, &n, records.len)) return null;
    for (records) |rec| {
        if (!putUv(buf, &n, rec.len)) return null;
        if (n + rec.len > buf.len) return null;
        @memcpy(buf[n..][0..rec.len], rec);
        n += rec.len;
    }
    return buf[0..n];
}

fn putUv(buf: []u8, n: *usize, value: usize) bool {
    var v = value;
    while (true) {
        if (n.* == buf.len) return false;
        const byte: u8 = @intCast(v & 0x7f);
        v >>= 7;
        buf[n.*] = if (v == 0) byte else byte | 0x80;
        n.* += 1;
        if (v == 0) return true;
    }
}

/// Switch the active keymap mode.
pub fn setMode(mode: []const u8) void {
    e.wl_set_mode(p(mode.ptr), @intCast(mode.len));
}
/// `mode` falls back to `parent` for unbound keys (mode inheritance).
pub fn setFallback(mode: []const u8, parent: []const u8) void {
    e.wl_set_fallback(p(mode.ptr), @intCast(mode.len), p(parent.ptr), @intCast(parent.len));
}
/// DECLARE that `mode` commits text, running `cmd` on each commit (null
/// withdraws the declaration). Nothing is inherited: a mode that never
/// declares this cannot commit typed text, whatever it inherits BINDINGS
/// from — so a structural mode needs no opt-out.
pub fn textInput(mode: []const u8, cmd: ?[]const u8) void {
    if (cmd) |c| {
        e.wl_text_input(p(mode.ptr), @intCast(mode.len), p(c.ptr), @intCast(c.len), 1);
    } else {
        e.wl_text_input(p(mode.ptr), @intCast(mode.len), 0, 0, 0);
    }
}
/// Declare `mode` a menu/prefix mode (which-key shows its bindings).
pub fn menuMode(mode: []const u8) void {
    e.wl_menu_mode(p(mode.ptr), @intCast(mode.len));
}
/// Declare `mode` a RESTING mode — the base a buffer settles in: the editing base
/// (`normal`) or a tool projection (`files`, `output`, …). Leaving a buffer in a
/// transient sub-mode (visual/insert) remembers this instead of overshooting to
/// the root, so switching back doesn't strand you in an editing-less mode.
pub fn restingMode(mode: []const u8) void {
    e.wl_resting_mode(p(mode.ptr), @intCast(mode.len));
}
/// Leave a transient mode (insert/visual) back to the active buffer's RESTING
/// mode — its tool mode (files) if any, else the editing base. Use on Escape
/// instead of a hardcoded `setMode("normal")`, so a projection's keys stay live.
pub fn exitToResting() void {
    e.wl_exit_to_resting();
}
/// DECLARE the mode THIS GRAMMAR rests in for `posture` (architecture §10.4).
/// The grammar's half of the posture pair: an entry declares how it rests,
/// the grammar declares what that posture means in its own vocabulary, and
/// core stamps the pairing on entry switch. A grammar with one mode declares
/// the same mode for both; a grammar whose text resting mode COMMITS text
/// (emacs) must declare a separate structural one, or typing would leak into
/// a projection. Implies `restingMode`.
pub fn restingPosture(rests_in: Posture, mode: []const u8) void {
    e.wl_resting_posture(@intFromEnum(rests_in), p(mode.ptr), @intCast(mode.len));
}
/// How the addressed entry RESTS under input (§10.4) — the one read a
/// grammar needs. It asks the DECLARATION; no tool identity, mode name, or
/// view liveness crosses this boundary.
pub fn posture() Posture {
    return Posture.fromWire(e.wl_posture()) orelse .text;
}
/// DECLARE the addressed entry's posture as its presentation owner,
/// overriding the derivation. `capture` is paired: it stacks the declaration
/// it displaced, and the grammar's always-retained break-out
/// (`std.input.break-out`) restores it.
pub fn declarePosture(declared: Posture) void {
    e.wl_declare_posture(@intFromEnum(declared));
}
/// Declare `mode` a STICKY menu: stays open after a leaf key (flag-accumulating
/// transients) instead of one-shot auto-popping. Implies `menuMode`.
pub fn stickyMenu(mode: []const u8) void {
    e.wl_sticky_menu(p(mode.ptr), @intCast(mode.len));
}

/// A provider's context predicate — the ambient facts that must hold for it to
/// win. An absent field is "don't care". Mirrors core.action.When.
pub const When = struct {
    /// Keymap mode that must be active.
    mode: ?[]const u8 = null,
    /// Buffer language — the active buffer name's extension (`zig`, `py`).
    lang: ?[]const u8 = null,
    /// The active buffer's tool-backing name (a plugin projection: `files`) —
    /// a stable per-buffer signal, unlike `mode`. A projection scopes its
    /// `save`/etc. providers by this so they win in its buffer in any mode.
    tool: ?[]const u8 = null,
};

/// Register `cmd` as a provider for `action` under the predicate `when`, at
/// `prio` (higher wins; ties break toward the more specific `when`). Auto-
/// declares the action if `declareAction` hasn't run — a language plugin can
/// `provide("eval", .{ .lang = "zig" }, "zig-eval", 0)` and the key bound to
/// `eval` dispatches here in a .zig buffer, for free.
pub fn provide(action: []const u8, when: When, cmd: []const u8, prio: i32) void {
    const m = when.mode orelse "";
    const l = when.lang orelse "";
    const tl = when.tool orelse "";
    e.wl_provide(
        p(action.ptr),
        @intCast(action.len),
        p(m.ptr),
        @intCast(m.len),
        p(l.ptr),
        @intCast(l.len),
        p(tl.ptr),
        @intCast(tl.len),
        p(cmd.ptr),
        @intCast(cmd.len),
        prio,
    );
}
/// Invoke a command by name (no args), late-bound.
pub fn run(cmd: []const u8) void {
    e.wl_run(p(cmd.ptr), @intCast(cmd.len));
}
/// Invoke `cmd` with a single integer arg (e.g. buffer-switch).
pub fn runInt(cmd: []const u8, n: i32) void {
    e.wl_run_int(p(cmd.ptr), @intCast(cmd.len), n);
}
/// Invoke `cmd` with a single string arg (e.g. open <path>).
pub fn runStr(cmd: []const u8, s: []const u8) void {
    e.wl_run_str(p(cmd.ptr), @intCast(cmd.len), p(s.ptr), @intCast(s.len));
}
/// Invoke `cmd` with two string args (e.g. set-cursor <mode> <style>).
pub fn runStr2(cmd: []const u8, a: []const u8, b: []const u8) void {
    e.wl_run_str2(p(cmd.ptr), @intCast(cmd.len), p(a.ptr), @intCast(a.len), p(b.ptr), @intCast(b.len));
}
/// Invoke `cmd` with however many string args you have — for a caller whose
/// argument count is a RUNTIME fact (a command line being dispatched, an
/// argument list just filled in by prompting). `run`/`runStr`/`runStr2` are
/// the fixed-arity shorthands; this is the general door.
///
/// The host caps it at TWO arguments, the same width `runStr2` already has,
/// and that cap is a gate rather than a buffer size: `app/providers.zig`'s
/// census turns on no guest passing three. A wider call is refused out loud.
pub fn runArgs(cmd: []const u8, args: []const []const u8) void {
    // The host reads one flat vector of (ptr,len) pairs out of our memory,
    // so build it here rather than crossing the membrane once per argument.
    var vec: [4]u32 = undefined;
    const n = @min(args.len, vec.len / 2);
    for (args[0..n], 0..) |a, i| {
        vec[i * 2] = p(a.ptr);
        vec[i * 2 + 1] = @intCast(a.len);
    }
    e.wl_run_argv(p(cmd.ptr), @intCast(cmd.len), p(&vec), @intCast(n));
}

// ── Introspection (palettes/help/buffers) ────────────────────────────
pub fn commandCount() usize {
    return e.wl_command_count();
}
/// The `i`-th command's name (into `scratch`), or null for an empty slot.
pub fn commandName(i: usize) ?[]const u8 {
    const n = e.wl_command_name(@intCast(i), p(&scratch), scratch.len);
    if (n < 0) return null;
    return scratch[0..@intCast(n)];
}
/// The `i`-th command's summary (into `arg_scratch`, so it survives a paired
/// `commandName` read), or null.
pub fn commandSummary(i: usize) ?[]const u8 {
    const n = e.wl_command_summary(@intCast(i), p(&arg_scratch), arg_scratch.len);
    if (n < 0) return null;
    return arg_scratch[0..@intCast(n)];
}
/// How many arguments the `i`-th command declares, or null if unbound.
pub fn commandArity(i: usize) ?usize {
    const n = e.wl_command_arity(@intCast(i));
    if (n < 0) return null;
    return @intCast(n);
}
/// How many of them a caller must supply — optional arguments trail, so this
/// is where "ask me for the rest" is allowed to stop.
pub fn commandArityRequired(i: usize) ?usize {
    const n = e.wl_command_arity_required(@intCast(i));
    if (n < 0) return null;
    return @intCast(n);
}
/// The `i`-th command's `k`-th argument NAME (into `param_scratch`, so it
/// survives a paired `commandName`/`commandSummary` read), or null when there
/// is no such argument. Successive calls reuse it — copy each name out before
/// asking for the next.
pub fn commandArg(i: usize, k: usize) ?[]const u8 {
    const n = e.wl_command_arg(@intCast(i), @intCast(k), p(&param_scratch), param_scratch.len);
    if (n < 0) return null;
    return param_scratch[0..@intCast(n)];
}
// ── Live offers (what the FOCUSED context can do right now) ──────────
/// How many intentions the focused context offers. An intention nobody
/// offers is absent — absence is nonapplicable, not refused.
pub fn offerCount() usize {
    return e.wl_offer_count();
}
/// The `i`-th offered intention's name (into `scratch`).
pub fn offerName(i: usize) ?[]const u8 {
    const n = e.wl_offer_name(@intCast(i), p(&scratch), scratch.len);
    if (n < 0) return null;
    return scratch[0..@intCast(n)];
}
/// Who wins that offer (into `arg_scratch`, so it survives a paired
/// `offerName` read).
pub fn offerProvider(i: usize) ?[]const u8 {
    const n = e.wl_offer_provider(@intCast(i), p(&arg_scratch), arg_scratch.len);
    if (n < 0) return null;
    return arg_scratch[0..@intCast(n)];
}
/// Why the `i`-th offer cannot run right now (into `intent_scratch`), or
/// null when it can. Relevant but impossible — worth SHOWING, not hiding.
pub fn offerReason(i: usize) ?[]const u8 {
    const n = e.wl_offer_reason(@intCast(i), p(&intent_scratch), intent_scratch.len);
    if (n <= 0) return null;
    return intent_scratch[0..@intCast(n)];
}

/// What `invokeIntention` did. `unknown` is not a refusal: the name is no
/// intention, so the caller's other vocabulary (commands) still owns it.
pub const Invocation = union(enum) {
    invoked,
    /// Text to show the user; borrows `intent_scratch`.
    refused: []const u8,
    unknown,
};

/// Resolve `name` against the context as it is NOW and invoke the winner
/// through the effect door. Never a stored decision: a list built earlier
/// resolves again here, so a stale offer refuses instead of running.
pub fn invokeIntention(name: []const u8) Invocation {
    const n = e.wl_intent_invoke(p(name.ptr), @intCast(name.len), p(&intent_scratch), intent_scratch.len);
    if (n < 0) return .unknown;
    if (n == 0) return .invoked;
    return .{ .refused = intent_scratch[0..@intCast(n)] };
}

// ── Publishing THIS plugin's offers ──────────────────────────────────
/// Start the table this plugin offers about its own projection. `tool` is
/// that buffer's tool identity (`toolBacking`) — the offers apply there and
/// nowhere else; empty means every context. `revision` is the plugin's own
/// MODEL ordinal: bump it whenever the model the offers describe is
/// replaced, and an offer resolved against the old model dies at the effect
/// door instead of acting on a row that moved.
///
/// A table reaches the catalog whole or not at all: stage rows with `offer`,
/// then `offersCommit`.
pub fn offersBegin(tool: []const u8, revision: u32) void {
    _ = e.wl_offers_begin(p(tool.ptr), @intCast(tool.len), revision);
}
/// Stage one row: `intention` (a `plugin.<id>.<verb>` name) answered by
/// `cmd`, one of THIS plugin's own commands. `reason` empty is an enabled
/// offer; otherwise it is the stable code for why it cannot run here — a
/// fallback list then reports the obstacle instead of running its next arm,
/// and which-key explains the key without invoking anything.
pub fn offer(intention: []const u8, cmd: []const u8, reason: []const u8) void {
    _ = e.wl_offer(
        p(intention.ptr),
        @intCast(intention.len),
        p(cmd.ptr),
        @intCast(cmd.len),
        p(reason.ptr),
        @intCast(reason.len),
    );
}
/// Publish the staged rows as this plugin's whole offer set.
pub fn offersCommit() void {
    _ = e.wl_offers_commit();
}
/// Withdraw them: this plugin offers nothing right now. Absence is
/// nonapplicable — an empty table would still be a claim.
pub fn offersRetract() void {
    e.wl_offers_retract();
}

// ── Reading the keymap tables ────────────────────────────────────────
//
// The head-scoped which-key reads are `menuBinding*`. These two read the
// TABLES, with the mode named — which is the only way to answer "what key
// runs this command" for a mode you are not standing in.
//
// Both write into `out` (caller-owned, so a listing survives the next read)
// and answer null when it is too small, never a truncated listing.

/// Every mode with a binding table, newline-joined.
pub fn modeNames(out: []u8) ?[]const u8 {
    const n = e.wl_mode_names(p(out.ptr), @intCast(out.len));
    if (n < 0) return null;
    return out[0..@intCast(n)];
}

/// Mode `mode`'s bindings resolved through its fallback chain, one
/// `<key>\t<command>` per line. Walk it with `bindingRows`.
pub fn bindingTable(mode: []const u8, out: []u8) ?[]const u8 {
    const n = e.wl_binding_table(p(mode.ptr), @intCast(mode.len), p(out.ptr), @intCast(out.len));
    if (n < 0) return null;
    return out[0..@intCast(n)];
}

/// One row of `bindingTable`.
pub const BindingRow = struct { key: []const u8, command: []const u8 };

/// Split a `bindingTable` listing into rows. A line without a tab is skipped
/// rather than guessed at.
pub const BindingRows = struct {
    rest: []const u8,

    pub fn next(self: *BindingRows) ?BindingRow {
        while (self.rest.len > 0) {
            const nl = std.mem.indexOfScalar(u8, self.rest, '\n') orelse self.rest.len;
            const line = self.rest[0..nl];
            self.rest = if (nl == self.rest.len) self.rest[nl..] else self.rest[nl + 1 ..];
            const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
            return .{ .key = line[0..tab], .command = line[tab + 1 ..] };
        }
        return null;
    }
};

pub fn bindingRows(listing: []const u8) BindingRows {
    return .{ .rest = listing };
}

pub fn bufferCount() usize {
    return e.wl_buffer_count();
}
pub fn bufferId(i: usize) ?i32 {
    const id = e.wl_buffer_id(@intCast(i));
    return if (id < 0) null else id;
}
pub fn bufferName(i: usize) ?[]const u8 {
    const n = e.wl_buffer_name(@intCast(i), p(&scratch), scratch.len);
    if (n < 0) return null;
    return scratch[0..@intCast(n)];
}
pub fn bufferActive(i: usize) bool {
    return e.wl_buffer_active(@intCast(i)) != 0;
}
pub fn bufferReadOnly(i: usize) bool {
    return e.wl_buffer_readonly(@intCast(i)) != 0;
}
/// The `i`-th buffer's file backing, or null when nothing backs it (a
/// scratch, a projection, an entry holding no text). Lands in the shared read
/// scratch — copy it out before the next read call.
pub fn bufferPath(i: usize) ?[]const u8 {
    const n = e.wl_buffer_path(@intCast(i), p(&scratch), scratch.len);
    if (n < 0) return null;
    return scratch[0..@intCast(n)];
}
/// Whether the `i`-th buffer holds edits its file never received. Null when
/// unanswerable. A tool projection is never dirty — it has no file to write.
pub fn bufferDirty(i: usize) ?bool {
    const d = e.wl_buffer_dirty(@intCast(i));
    return if (d < 0) null else d != 0;
}
/// The `i`-th buffer's language (an extension sans dot), "" when it has none.
/// Shared read scratch.
pub fn bufferLang(i: usize) ?[]const u8 {
    const n = e.wl_buffer_lang(@intCast(i), p(&scratch), scratch.len);
    if (n < 0) return null;
    return scratch[0..@intCast(n)];
}
/// The `i`-th buffer's document length, or null when it holds no text.
pub fn bufferByteLen(i: usize) ?usize {
    const n = e.wl_buffer_byte_len(@intCast(i));
    return if (n < 0) null else @intCast(n);
}
/// The projection the `i`-th buffer represents (`files`, `git`), "" for a
/// plain entry. Shared read scratch.
pub fn bufferTool(i: usize) ?[]const u8 {
    const n = e.wl_buffer_tool(@intCast(i), p(&scratch), scratch.len);
    if (n < 0) return null;
    return scratch[0..@intCast(n)];
}

// ── Instanced tool buffers ───────────────────────────────────────────
//
// A tool that holds state (a REPL child, a console log, an LLM conversation)
// is instantiable: each instance owns a buffer, and its buffer NAME is its
// identity. Two instances therefore never share a sink, and a command routes
// to the instance whose buffer is focused. `out` must not alias the read
// scratch these helpers use — pass a caller-owned array.

/// The active buffer's display name, copied into `out` (so it survives the
/// next read call). Null if it does not fit or no buffer is active.
pub fn activeBufferName(out: []u8) ?[]const u8 {
    var i: usize = 0;
    while (i < bufferCount()) : (i += 1) {
        if (!bufferActive(i)) continue;
        const name = bufferName(i) orelse return null;
        if (name.len > out.len) return null;
        @memcpy(out[0..name.len], name);
        return out[0..name.len];
    }
    return null;
}

/// Whether a buffer is displayed under `name`.
pub fn bufferNamed(name: []const u8) bool {
    var i: usize = 0;
    while (i < bufferCount()) : (i += 1) {
        const other = bufferName(i) orelse continue;
        if (std.mem.eql(u8, other, name)) return true;
    }
    return false;
}

/// The instance-`n` buffer name for `base`: `*base*` at 1, `*base:n*` above.
pub fn instanceName(base: []const u8, n: u32, out: []u8) ?[]const u8 {
    const written = if (n <= 1)
        std.fmt.bufPrint(out, "*{s}*", .{base})
    else
        std.fmt.bufPrint(out, "*{s}:{d}*", .{ base, n });
    return written catch null;
}

/// The lowest instance ordinal of `base` no buffer holds — the identity a new
/// instance takes. The scan needs no ceiling: an ordinal is occupied only by a
/// buffer holding its name, buffers are finite, so by pigeonhole one of the
/// first `bufferCount() + 1` ordinals is always free. Null only when the name
/// itself does not fit, which is a property of `base`, not of how many
/// instances are running.
pub fn instanceOrdinal(base: []const u8) ?u32 {
    var name_buf: [128]u8 = undefined;
    var n: u32 = 1;
    while (true) : (n += 1) {
        const name = instanceName(base, n, &name_buf) orelse return null;
        if (!bufferNamed(name)) return n;
    }
}

/// A tool's live instances: `T` is what one instance must remember (a REPL
/// handle, a socket, a log). Every instantiable tool shares this table rather
/// than growing its own, so "which instance is this command about" has one
/// answer everywhere.
///
/// The table is a list of POINTERS with one heap allocation per instance, the
/// shape `core/Buffers.zig` settled on for the same reason: callers hold a
/// `*Slot` across calls (a draft names the entry it commits to, an http request
/// its connection), so an instance must keep its address while the table around
/// it grows. There is no cap — how many interpreters or repositories you may
/// have open at once was never a decision anybody made, and the guest heap
/// (`weft.allocator`, a real `@wasmMemoryGrow` heap) is what actually bounds it.
/// `open` is null ONLY when that heap refuses, and every caller says so.
pub fn Instances(comptime T: type) type {
    return struct {
        const Self = @This();
        const name_cap = 64;

        pub const Slot = struct {
            name_buf: [name_cap]u8,
            name_len: usize,
            opened: usize, // ordering, for `oldest`
            /// The place this instance was opened in (`weft.placeId`). A session
            /// is a NAMED thing LINKED to a place, not a thing keyed BY one --
            /// so two interpreters can share a project and one server can
            /// serve two. Compared, never interpreted.
            place: i32,
            value: T,

            pub fn name(self: *const Slot) []const u8 {
                return self.name_buf[0..self.name_len];
            }
        };

        slots: std.ArrayList(*Slot) = .empty,
        /// The instance a command falls back to — a POINTER, so it survives the
        /// list growing under it, which an index would not.
        recent: ?*Slot = null,
        opens: usize = 0,

        /// Mint the next instance of `base` (`*base*`, `*base:2*`, …) and open
        /// its buffer. `value` is uninitialized: the caller fills it from
        /// `slot.name()` (a session must be started against its own buffer),
        /// and `close`s the slot if that fails. Null when the guest heap cannot
        /// hold another instance, or when the instance name does not fit.
        pub fn open(self: *Self, base: []const u8) ?*Slot {
            var name_buf: [name_cap]u8 = undefined;
            const ordinal = instanceOrdinal(base) orelse return null;
            const name = instanceName(base, ordinal, &name_buf) orelse return null;
            self.slots.ensureUnusedCapacity(allocator, 1) catch return null;
            const slot = allocator.create(Slot) catch return null;
            runStr("buffer-create", name);
            self.opens += 1;
            slot.* = .{
                .name_buf = undefined,
                .name_len = name.len,
                .opened = self.opens,
                .place = placeId(),
                .value = undefined,
            };
            @memcpy(slot.name_buf[0..name.len], name);
            self.slots.appendAssumeCapacity(slot);
            self.recent = slot;
            return slot;
        }

        /// The instance opened longest ago — what a tool retires to make room
        /// when its instances are one-shot (a request, not a session).
        pub fn oldest(self: *Self) ?*Slot {
            var found: ?*Slot = null;
            for (self.slots.items) |slot| {
                if (found == null or slot.opened < found.?.opened) found = slot;
            }
            return found;
        }

        /// The instance this command is about, most-specific link first: the
        /// one owning the focused buffer, else one opened in THIS PLACE, else
        /// the most recent — echoed as `label: *name*`, so a command run from
        /// elsewhere never silently drives an instance the user cannot see.
        ///
        /// The middle rung is what makes instances project-aware. Without it,
        /// running a tool from a file in one project drove whichever instance
        /// happened to be most recent — routinely another project's, since
        /// "most recent" tracks the last thing you touched anywhere. With it, a
        /// second project gets its own instance and keeps it, and neither
        /// captures the other. Emacs learned this the same way: `sesman`
        /// exists because CIDER and friends each grew a session table keyed the
        /// wrong way first.
        pub fn current(self: *Self, label: []const u8) ?*Slot {
            var name_buf: [name_cap]u8 = undefined;
            if (activeBufferName(&name_buf)) |active| {
                for (self.slots.items) |slot| {
                    if (std.mem.eql(u8, slot.name(), active)) {
                        self.recent = slot;
                        return slot;
                    }
                }
            }
            const here = placeId();
            for (self.slots.items) |slot| {
                if (slot.place != here) continue;
                self.recent = slot;
                var place_msg: [name_cap + 32]u8 = undefined;
                echo(std.fmt.bufPrint(&place_msg, "{s}: {s}", .{ label, slot.name() }) catch return slot);
                return slot;
            }
            const slot = self.recent orelse return null;
            var msg: [name_cap + 32]u8 = undefined;
            echo(std.fmt.bufPrint(&msg, "{s}: {s}", .{ label, slot.name() }) catch return slot);
            return slot;
        }

        /// Retire an instance. Its buffer outlives it — the log stays readable.
        pub fn close(self: *Self, slot: *Slot) void {
            for (self.slots.items, 0..) |live, i| {
                if (live != slot) continue;
                _ = self.slots.orderedRemove(i);
                if (self.recent == slot) self.recent = if (self.slots.items.len > 0) self.slots.items[0] else null;
                allocator.destroy(slot);
                return;
            }
        }
    };
}

// ── Fuzzy pick (open one incrementally; accept → on_pick_accept) ──────
/// Begin a pick with `prompt`; `pick_id` is the guest's tag for its accept
/// logic (dispatched to `on_pick_accept`).
pub fn pickBegin(prompt: []const u8, pick_id: u32) void {
    e.wl_pick_begin(p(prompt.ptr), @intCast(prompt.len), pick_id);
}
/// Let the pick being built accept what was TYPED as well as a listed row —
/// the accept then arrives as `PickOutcome.input`. Call between `pickBegin`
/// and `pickEnd`; every `pickBegin` resets it, so it is per-pick.
pub fn pickFreeText() void {
    e.wl_pick_free_text(1);
}
/// Declare what KIND of pick this is — `"file"`, `"buffer"`, `"command"`.
/// Uninterpreted: it is handed to annotators and to nothing else.
///
/// **A pick that does not call this is never annotated.** That is the opt-in.
/// Say nothing for anything an outsider has no business decorating — a
/// destructive confirmation, an agent permission prompt. Consumed at open, so
/// it is per-pick and never a leftover of the last one.
pub fn pickCategory(category: []const u8) void {
    e.wl_pick_category(p(category.ptr), @intCast(category.len));
}
/// Add one item: `text` matches/accepts, `doc` is display-only.
pub fn pickAdd(text: []const u8, doc: []const u8) void {
    e.wl_pick_add(p(text.ptr), @intCast(text.len), p(doc.ptr), @intCast(doc.len));
}
/// Add one item ABOUT the `i`-th open buffer. The candidate carries that
/// buffer's identity, read back as `PickCandidate.buffer` — so the accept
/// never has to index a parallel table or parse its own label, and a buffer
/// closed while the picker was open reads back as null instead of as
/// whatever took its slot.
pub fn pickAddBuffer(text: []const u8, doc: []const u8, i: usize) void {
    e.wl_pick_add_buffer(p(text.ptr), @intCast(text.len), p(doc.ptr), @intCast(doc.len), @intCast(i));
}
/// Open the accumulated pick.
pub fn pickEnd() void {
    e.wl_pick_end();
}
/// Open a fuzzy FILE picker rooted at `root` (native recursive finder);
/// accept dispatches to `on_pick_accept` with the chosen path.
pub fn openFilePick(prompt: []const u8, root: []const u8, pick_id: u32) void {
    e.wl_open_file_pick(p(prompt.ptr), @intCast(prompt.len), p(root.ptr), @intCast(root.len), pick_id);
}

// ── Surface (retained overlay: build begin→row→span…→end, then close) ────
/// Where a surface docks. Mirrors core.surface.Placement. `caret` is begun
/// through `surfaceCaret`, not `surfaceBegin` — see its doc.
pub const Placement = enum(u32) { bottom = 0, corner = 1, center = 2, caret = 3 };
/// A span's semantic color role. Mirrors core.surface.Role — the theme resolves
/// each to a real color, so a colorscheme restyles the surface for free.
/// `annotation` is a dimmed side note (rendering P2 — see doc/rendering.md).
pub const Role = enum(u32) { normal = 0, accent = 1, group = 2, leaf = 3, effect = 4, muted = 5, annotation = 6 };

/// Begin (re)building this plugin's overlay at `placement` (`bottom`/
/// `corner`/`center` — a `caret` popup begins with `surfaceCaret` instead,
/// since it also needs the anchor offset). Not shown until `surfaceEnd`; the
/// previously-drawn surface stays live until then.
pub fn surfaceBegin(placement: Placement) void {
    e.wl_surface_begin(@intFromEnum(placement));
}
/// Begin (re)building a CARET-anchored overlay — placed at `offset` (a
/// document byte offset) instead of a corner/center/bottom dock; core lays
/// it out just below (or, flipped, above) the caret's screen line, clamped
/// into the viewport. The `lsp` plugin's hover popup uses this so its box
/// tracks the caret, the same generic `drawCaretSurface` renderer the
/// picker's own completion list draws through (rendering P2 — see
/// doc/rendering.md).
pub fn surfaceCaret(offset: usize) void {
    e.wl_surface_caret(@intCast(offset));
}
/// Start a new row.
pub fn surfaceRow() void {
    e.wl_surface_row();
}
/// Append a styled span to the current row.
pub fn surfaceSpan(text: []const u8, role: Role) void {
    e.wl_surface_span(p(text.ptr), @intCast(text.len), @intFromEnum(role));
}
/// Commit the built rows and show the surface. `selected` highlights a row
/// (a picker/files cursor), or -1 for none.
pub fn surfaceEnd(selected: i32) void {
    e.wl_surface_end(selected);
}
/// Hide the surface (done with it).
pub fn surfaceClose() void {
    e.wl_surface_close();
}

// ── Menu bindings (for a which-key-style overlay): enumerate the CURRENT menu
// mode's table. Valid during on_menu(open). key → scratch, cmd → arg_scratch,
// so a caller can hold both of one binding at once. ──
pub fn menuBindingCount() usize {
    const n = e.wl_menu_binding_count();
    return if (n < 0) 0 else @intCast(n);
}
pub fn menuBindingKey(i: usize) []const u8 {
    const n = e.wl_menu_binding_key(@intCast(i), p(&scratch), scratch.len);
    return if (n < 0) "" else scratch[0..@intCast(n)];
}
pub fn menuBindingCmd(i: usize) []const u8 {
    const n = e.wl_menu_binding_cmd(@intCast(i), p(&arg_scratch), arg_scratch.len);
    return if (n < 0) "" else arg_scratch[0..@intCast(n)];
}
/// Whether the `i`-th binding opens a submenu (a group) vs a leaf command.
pub fn menuBindingIsGroup(i: usize) bool {
    return e.wl_menu_binding_is_group(@intCast(i)) != 0;
}

/// Their own scratch, so a hint row can hold key, command, intention and note
/// at once.
var hint_scratch: [128]u8 = undefined;
var hint_note_scratch: [128]u8 = undefined;

/// What a binding whose arms name INTENTIONS would actually do here, asked of
/// the host's resolver. Describing only — reading this runs nothing.
pub const MenuIntent = struct {
    /// The dotted intention name of the arm that would win (or that reports
    /// the obstacle).
    name: []const u8,
    /// The provider that would run it, or — when `!ready` — why it cannot.
    note: []const u8,
    ready: bool,
};

/// The `i`-th binding's intention explanation, or null when no intention arm
/// explains it (a plain command binding, or nothing offers one).
pub fn menuBindingIntent(i: usize) ?MenuIntent {
    const status = e.wl_menu_binding_intent_status(@intCast(i));
    if (status <= 0) return null;
    const n = e.wl_menu_binding_intent(@intCast(i), p(&hint_scratch), hint_scratch.len);
    if (n < 0) return null;
    const m = e.wl_menu_binding_intent_note(@intCast(i), p(&hint_note_scratch), hint_note_scratch.len);
    return .{
        .name = hint_scratch[0..@intCast(n)],
        .note = if (m < 0) "" else hint_note_scratch[0..@intCast(m)],
        .ready = status == 1,
    };
}

pub const PickMatch = struct { start: usize, span: usize };
pub const PickCandidate = struct {
    /// Stable add-order identity within this pick, including duplicate text.
    index: usize,
    /// Owned accepted candidate presentation; released by `PickOutcome.deinit`.
    text: []const u8,
    /// Owned query which produced `match`; released by `PickOutcome.deinit`.
    query: []const u8,
    /// Candidate-relative byte evidence. Resolving it to a document or other
    /// target remains the source plugin's policy.
    match: PickMatch,
    /// The live id of the buffer this candidate NAMED (`pickAddBuffer`), or
    /// null: the row carried no buffer key, or the buffer it named closed
    /// while the picker was open. Null is a refusal, never a guess.
    buffer: ?u32,
};
pub const PickOutcome = union(enum) {
    cancelled,
    input: []const u8,
    candidate: PickCandidate,

    pub fn deinit(self: *PickOutcome, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .cancelled => {},
            .input => |input| gpa.free(input),
            .candidate => |candidate| {
                gpa.free(candidate.text);
                gpa.free(candidate.query);
            },
        }
        self.* = .cancelled;
    }
};

/// One coherent, immutable outcome for the current `on_pick_accept` callback.
/// Returns null outside that callback. Accepted bytes are exact owned copies;
/// the caller must `deinit` the result. The two-pass host read refuses a short
/// destination instead of silently truncating a candidate or its query.
pub fn pickOutcome(gpa: std.mem.Allocator) (std.mem.Allocator.Error || error{InvalidPickOutcome})!?PickOutcome {
    return switch (e.wl_pick_outcome_kind()) {
        0 => .cancelled,
        1 => blk: {
            break :blk .{ .input = try readPickOutcomeBytes(gpa, e.wl_pick_outcome_text) };
        },
        2 => blk: {
            const text = try readPickOutcomeBytes(gpa, e.wl_pick_outcome_text);
            errdefer gpa.free(text);
            const accepted_query = try readPickOutcomeBytes(gpa, e.wl_pick_outcome_query);
            const index = e.wl_pick_outcome_index();
            const start = e.wl_pick_outcome_match_start();
            const span = e.wl_pick_outcome_match_span();
            if (index < 0 or start < 0 or span < 0) {
                gpa.free(accepted_query);
                return error.InvalidPickOutcome;
            }
            const buffer = e.wl_pick_outcome_buffer();
            break :blk .{ .candidate = .{
                .index = @intCast(index),
                .text = text,
                .query = accepted_query,
                .match = .{ .start = @intCast(start), .span = @intCast(span) },
                .buffer = if (buffer < 0) null else @intCast(buffer),
            } };
        },
        else => null,
    };
}

fn readPickOutcomeBytes(
    gpa: std.mem.Allocator,
    comptime read: fn (out_ptr: u32, out_cap: u32) callconv(.c) i32,
) (std.mem.Allocator.Error || error{InvalidPickOutcome})![]u8 {
    const needed = read(0, 0);
    if (needed < 0) return error.InvalidPickOutcome;
    const bytes = try gpa.alloc(u8, @intCast(needed));
    errdefer gpa.free(bytes);
    const written = read(p(bytes.ptr), @intCast(bytes.len));
    if (written != needed) return error.InvalidPickOutcome;
    return bytes;
}

// ── Completion provider (the sel/completion domain) ──────────────────
// The host→guest data-gather membrane: the plugin registers a provider in
// `init` with `provideCompletion`, then the host calls the guest's exported
// `on_complete(session)` per request. The guest OWNS that session's answer: it
// offers items with `capsItem` and flushes them with `capsCommit`, or gives up
// with `capsDecline`. It may answer DURING on_complete (a sync source) or LATER
// off a poll (async — stash the `session`, commit when your data lands).

/// A rich completion candidate. `text` inserts/matches; `label` is the display
/// string (defaults to text when empty); `detail` is a right-aligned annotation
/// (a type/signature); `documentation` feeds the info popup; `kind` is the LSP
/// `CompletionItemKind` number (0 = unknown); `rank` orders within this source.
pub const Completion = struct {
    text: []const u8,
    label: []const u8 = &.{},
    detail: []const u8 = &.{},
    documentation: []const u8 = &.{},
    kind: u8 = 0,
    rank: i32 = 0,
};

/// Register this plugin as an `edit/completion` provider (declared as the
/// matching capability). Read-only — results race + merge-rank with everyone
/// else's.
pub fn provideCompletion() void {
    e.wl_provide_completion();
}
/// The current completion request's query prefix (valid for the duration of
/// `on_complete`). Its own scratch — safe to hold while calling `slice`. An
/// async source must copy it before deferring.
pub fn completionPrefix() []const u8 {
    const n = e.wl_completion_prefix(p(&prefix_scratch), prefix_scratch.len);
    return prefix_scratch[0..n];
}
/// Offer one candidate for `session` (accretes into a batch flushed by commit).
pub fn capsItem(session: u32, it: Completion) void {
    e.wl_caps_item(
        @bitCast(session),
        p(it.text.ptr),
        @intCast(it.text.len),
        p(it.label.ptr),
        @intCast(it.label.len),
        p(it.detail.ptr),
        @intCast(it.detail.len),
        @bitCast(@as(u32, it.kind)),
        p(it.documentation.ptr),
        @intCast(it.documentation.len),
        it.rank,
    );
}
/// Flush this source's offered items into `session` as one answer.
pub fn capsCommit(session: u32) void {
    e.wl_caps_commit(@bitCast(session));
}
/// Answer `session` with nothing (unsupported / no results / dead).
pub fn capsDecline(session: u32) void {
    e.wl_caps_decline(@bitCast(session));
}

// ── Activation (the buffer taking focus; valid during on_activate) ────
/// The path of the buffer that just took focus (into `scratch`). Empty for an
/// unbacked/scratch buffer. Call from an exported `on_activate` fn.
pub fn activatePath() []const u8 {
    const n = e.wl_activate_path(p(&scratch), scratch.len);
    return scratch[0..@intCast(n)];
}

// ── Structural read + subbuffers ─────────────────────────────────────
pub const Node = struct { kind: []const u8, start: usize, end: usize };

/// The smallest named tree-sitter node covering `offset` (kind + span), or
/// null when the buffer has no grammar / no node. Kind is in `scratch`.
pub fn nodeAt(offset: usize) ?Node {
    var span: [2]u32 = undefined;
    const n = e.wl_node_at(@intCast(offset), p(&scratch), scratch.len, p(&span));
    if (n < 0) return null;
    return .{ .kind = scratch[0..@intCast(n)], .start = span[0], .end = span[1] };
}

/// The smallest named tree-sitter node STRICTLY enclosing `[r.start, r.end)`
/// — repeat to grow a selection to the next scope. Kind is in `scratch`.
pub fn nodeEnclosing(r: Range) ?Node {
    var span: [2]u32 = undefined;
    const n = e.wl_node_enclosing(@intCast(r.start), @intCast(r.end), p(&scratch), scratch.len, p(&span));
    if (n < 0) return null;
    return .{ .kind = scratch[0..@intCast(n)], .start = span[0], .end = span[1] };
}

pub const Capture = struct { name: []const u8, start: usize, end: usize };
/// Run a tree-sitter query (`.scm`) over `[r.start, r.end)`; returns the
/// capture count, read back with `queryCapture(i)`. 0 if no grammar/error.
pub fn query(scm: []const u8, r: Range) usize {
    const n = e.wl_query(p(scm.ptr), @intCast(scm.len), @intCast(r.start), @intCast(r.end));
    return if (n < 0) 0 else @intCast(n);
}
/// The `i`-th capture of the last `query`/`nodeChildren` (name/kind into
/// `scratch`), or null.
pub fn queryCapture(i: usize) ?Capture {
    var span: [2]u32 = undefined;
    const n = e.wl_query_capture(@intCast(i), p(&scratch), scratch.len, p(&span));
    if (n < 0) return null;
    return .{ .name = scratch[0..@intCast(n)], .start = span[0], .end = span[1] };
}
/// The named children of the smallest node at `off` (structural descent);
/// returns the count, read back with `queryCapture(i)`. 0 if none/no grammar.
pub fn nodeChildren(off: usize) usize {
    const n = e.wl_node_children(@intCast(off));
    return if (n < 0) 0 else @intCast(n);
}

/// Claim `[start, end)` as a subbuffer (an anchored range with its own facts)
/// on the active document. Returns an opaque handle, or null if unavailable.
pub fn claimSubbuffer(start: usize, end: usize) ?u32 {
    const h = e.wl_claim_subbuffer(@intCast(start), @intCast(end));
    return if (h < 0) null else @intCast(h);
}
/// Attach a fact (`key` = `value`) to a claimed subbuffer.
pub fn subbufferPutFact(handle: u32, key: []const u8, value: []const u8) void {
    e.wl_subbuffer_put_fact(handle, p(key.ptr), @intCast(key.len), p(value.ptr), @intCast(value.len));
}
var subfact_scratch: [512]u8 = undefined;

/// Mark the active buffer as this plugin's tool projection (its content is
/// plugin-regenerated). A save then resolves the `save` action to a provider
/// this plugin registers for `When{ .tool = "<name>" }` — no core special-case.
pub fn toolBacking(name: []const u8) void {
    e.wl_tool_backing(p(name.ptr), @intCast(name.len));
}

// ── Register / kill (core, shared by every editor) ───────────────────
/// A private scratch for `registerText`, so a paste can hold the register bytes
/// while it reads the buffer through `slice`/`lineAt` (which reuse `scratch`).
var reg_scratch: [1 << 16]u8 = undefined;

/// Yank `[start, end)` into the shared register: captures the bytes, the
/// `linewise` flag, AND the facts of any subbuffer the range overlaps (a
/// projection row's hidden id), so a later `pasteAt` can ferry them. This is
/// the one door an editor's yank/delete calls — identity-ferrying is core, not
/// per-editor, so `dd`→`p` moves an id across editors and buffers alike.
pub fn yankRange(start: usize, end: usize, linewise: bool) void {
    yankRangeIn(0, start, end, linewise);
}
pub fn yankRangeIn(name: u8, start: usize, end: usize, linewise: bool) void {
    e.wl_yank_range(@intCast(start), @intCast(end), @intFromBool(linewise), name);
}
/// The register bytes (into a private scratch, valid until the next call) — for
/// an editor to build its paste. Charwise callers can insert these directly.
pub fn registerText() []const u8 {
    return registerTextIn(0);
}
pub fn registerTextIn(name: u8) []const u8 {
    const n = e.wl_register_text(p(&reg_scratch), reg_scratch.len, name);
    return reg_scratch[0..@intCast(n)];
}
pub fn registerLinewiseIn(name: u8) bool {
    return e.wl_register_linewise(name) != 0;
}
/// Re-stamp any ferried id-spans over register text ALREADY inserted at `base`
/// (call right after inserting `registerText()`). Turns `dd`→`p` into a MOVE;
/// a plain insert with no call — or a register with no payloads — creates none.
pub fn pasteAt(base: usize) void {
    pasteAtIn(0, base);
}
pub fn pasteAtIn(name: u8, base: usize) void {
    e.wl_paste_at(@intCast(base), name);
}

// ── Generic semantic views ────────────────────────────────────────────

/// Attach a retained semantic view to this head. NodeId is canonically split
/// into two wasm32 words; the explicit presence bit keeps an absent preference
/// distinct from any raw u64 value.
pub fn semanticViewFocus(ref: semantic.view.Ref, preferred: ?semantic.scene.NodeId) bool {
    const wire = ref.toWire();
    const raw: u64 = if (preferred) |node| @intFromEnum(node) else 0;
    const low: u32 = @truncate(raw);
    const high: u32 = @truncate(raw >> 32);
    return e.wl_semantic_view_focus(wire.authority, wire.slot, wire.generation, low, high, @intFromBool(preferred != null)) != 0;
}

/// Open a bounded head-local interaction definition using the canonical
/// scene codec. The host owns the decoded descriptor and returns a typed ref.
pub fn semanticInteractionOpen(definition: semantic.interaction.Definition) SemanticPublishError!semantic.interaction.Ref {
    const payload = try semantic_codec.encodeInteraction(allocator, definition);
    defer allocator.free(payload);
    var out: [12]u8 = undefined;
    if (e.wl_semantic_interaction_open(p(payload.ptr), @intCast(payload.len), p(&out), out.len) != 1) return error.Rejected;
    return readSemanticHandle(semantic.interaction.Ref, &out);
}

/// Close only the currently active interaction named by this typed ref.
pub fn semanticInteractionClose(ref: semantic.interaction.Ref) bool {
    const wire = ref.toWire();
    return e.wl_semantic_interaction_close(wire.authority, wire.slot, wire.generation) != 0;
}

pub const SemanticActionResult = enum(i32) {
    unavailable = 0,
    handled = 1,
    transfer_stored = 2,
    interaction_opened = 3,
    target_opened = 4,
    focus_changed = 5,
    relation_opened = 6,
    working_target_changed = 7,
    failed = -1,
    _,
};

pub fn semanticAction(action: []const u8) SemanticActionResult {
    return semanticActionIn(action, 0);
}
pub fn semanticActionIn(action: []const u8, slot: u8) SemanticActionResult {
    return @enumFromInt(e.wl_semantic_action(p(action.ptr), @intCast(action.len), slot));
}

/// Register this plugin as the single provider for scenes it owns. Core routes
/// by retained view ownership; the guest callback remains tool-defined.
pub fn semanticActionProvider() bool {
    return e.wl_semantic_action_provider() == 1;
}

pub const SemanticActionResponse = enum(u32) {
    declined = 0,
    handled = 1,
    transfer = 2,
    interaction = 3,
    open_target = 4,
    focus = 5,
    open_relation = 6,
    set_working_target = 7,
};

/// Read the request available only during `on_semantic_action()`.
pub fn semanticActionCurrent(gpa: std.mem.Allocator) (semantic_codec.Error || error{Rejected})!semantic_codec.action.OwnedRequest {
    const raw_len = e.wl_semantic_action_request_len();
    if (raw_len <= 0) return error.Rejected;
    const len: usize = @intCast(raw_len);
    const bytes = try gpa.alloc(u8, len);
    defer gpa.free(bytes);
    if (e.wl_semantic_action_request(p(bytes.ptr), @intCast(bytes.len)) != raw_len) return error.Rejected;
    return semantic_codec.action.decodeRequest(gpa, bytes);
}

fn semanticActionRespondEmpty(kind: SemanticActionResponse) bool {
    return e.wl_semantic_action_respond(@intFromEnum(kind), 0, 0) == 1;
}

pub fn semanticActionDecline() bool {
    return semanticActionRespondEmpty(.declined);
}

pub fn semanticActionHandled() bool {
    return semanticActionRespondEmpty(.handled);
}

pub fn semanticActionTransfer(item: semantic.transfer.Item) SemanticPublishError!void {
    const payload = try semantic_codec.transfer.encode(allocator, item);
    defer allocator.free(payload);
    if (e.wl_semantic_action_respond(@intFromEnum(SemanticActionResponse.transfer), p(payload.ptr), @intCast(payload.len)) != 1)
        return error.Rejected;
}

pub fn semanticActionInteraction(definition: semantic.interaction.Definition) SemanticPublishError!void {
    const payload = try semantic_codec.interaction.encode(allocator, definition);
    defer allocator.free(payload);
    if (e.wl_semantic_action_respond(@intFromEnum(SemanticActionResponse.interaction), p(payload.ptr), @intCast(payload.len)) != 1)
        return error.Rejected;
}

/// Ask core to resolve and admit one typed located target. Handler choice and
/// view ownership remain host policy; the guest supplies only this portable
/// request value.
pub fn semanticActionOpenTarget(located: semantic.target.Located) SemanticPublishError!void {
    const payload = try semantic_codec.encodeLocatedTarget(allocator, located);
    defer allocator.free(payload);
    if (e.wl_semantic_action_respond(@intFromEnum(SemanticActionResponse.open_target), p(payload.ptr), @intCast(payload.len)) != 1)
        return error.Rejected;
}

/// Ask core to move the dispatching head to another stable node in the same
/// retained view. The host validates membership before changing head state.
pub fn semanticActionFocus(node: semantic.scene.NodeId) bool {
    const raw: u64 = @intFromEnum(node);
    if (raw == 0) return false;
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, raw, .little);
    return e.wl_semantic_action_respond(@intFromEnum(SemanticActionResponse.focus), p(&bytes), bytes.len) == 1;
}

/// Ask core to resolve a named relation from an exact source target and open
/// the admitted destination. Handler choice remains host policy.
pub fn semanticActionOpenRelation(request: semantic.action.RelationRequest) SemanticPublishError!void {
    const payload = try semantic_codec.action.encodeRelation(allocator, request);
    defer allocator.free(payload);
    if (e.wl_semantic_action_respond(@intFromEnum(SemanticActionResponse.open_relation), p(payload.ptr), @intCast(payload.len)) != 1)
        return error.Rejected;
}

/// Ask core to make one exact whole target the dispatching head's working
/// container. No process cwd or provider path crosses this boundary.
pub fn semanticActionSetWorkingTarget(located: semantic.target.Located) SemanticPublishError!void {
    const payload = try semantic_codec.encodeLocatedTarget(allocator, located);
    defer allocator.free(payload);
    if (e.wl_semantic_action_respond(@intFromEnum(SemanticActionResponse.set_working_target), p(payload.ptr), @intCast(payload.len)) != 1)
        return error.Rejected;
}

pub const SemanticPublishError = semantic_codec.Error || error{Rejected};

pub const SemanticTargetDescribeError = semantic_codec.Error || error{Rejected};

fn readSemanticHandle(comptime Ref: type, bytes: *const [12]u8) SemanticPublishError!Ref {
    const wire: semantic.handle.Wire = .{
        .authority = std.mem.readInt(u32, bytes[0..4], .little),
        .slot = std.mem.readInt(u32, bytes[4..8], .little),
        .generation = std.mem.readInt(u32, bytes[8..12], .little),
    };
    if (wire.generation == 0) return error.Rejected;
    return Ref.fromWire(wire);
}

/// Publish a resource descriptor. Paths and schemes remain ordinary target
/// facts; target-handler plugins, not this SDK, decide what can open them.
pub fn semanticTargetPublish(definition: semantic.target.Definition) SemanticPublishError!semantic.target.Ref {
    const payload = try semantic_codec.encodeTarget(allocator, definition);
    defer allocator.free(payload);
    var out: [12]u8 = undefined;
    if (e.wl_semantic_target_publish(p(payload.ptr), @intCast(payload.len), p(&out), out.len) != 1) return error.Rejected;
    return readSemanticHandle(semantic.target.Ref, &out);
}

pub fn semanticTargetReplace(ref: semantic.target.Ref, definition: semantic.target.Definition) SemanticPublishError!void {
    const payload = try semantic_codec.encodeTarget(allocator, definition);
    defer allocator.free(payload);
    const wire = ref.toWire();
    if (e.wl_semantic_target_replace(wire.authority, wire.slot, wire.generation, p(payload.ptr), @intCast(payload.len)) != 1)
        return error.Rejected;
}

pub fn semanticTargetClose(ref: semantic.target.Ref) bool {
    const wire = ref.toWire();
    return e.wl_semantic_target_close(wire.authority, wire.slot, wire.generation) != 0;
}

/// Read a live target descriptor as one canonical, owned snapshot. The host
/// validates the authority/generation before encoding; the guest validates
/// that the returned descriptor still names the requested generation and has
/// a non-zero revision. A replacement racing the length/copy pair fails
/// closed rather than returning an ambiguous partial value.
pub fn semanticTargetDescribe(ref: semantic.target.Ref, gpa: std.mem.Allocator) SemanticTargetDescribeError!semantic_codec.target.OwnedDescriptor {
    const wire = ref.toWire();
    const raw_len = e.wl_semantic_target_describe_len(wire.authority, wire.slot, wire.generation);
    if (raw_len <= 0) return error.Rejected;
    const len: usize = @intCast(raw_len);
    if (len > semantic_codec.Limits.max_payload_bytes) return error.LimitExceeded;
    const bytes = try gpa.alloc(u8, len);
    defer gpa.free(bytes);
    const written = e.wl_semantic_target_describe(wire.authority, wire.slot, wire.generation, p(bytes.ptr), @intCast(bytes.len));
    if (written != raw_len) return error.Rejected;
    var descriptor = try semantic_codec.target.decodeDescriptor(gpa, bytes);
    errdefer descriptor.deinit();
    if (!descriptor.value.ref.eql(ref) or descriptor.value.revision == 0) return error.Rejected;
    return descriptor;
}

// ── Generic target-handler callbacks ─────────────────────────────────
// Handler registration deliberately has a guest-local phantom type. The
// target-runtime registry is a host implementation detail and is not imported
// into the guest module; only this stable three-word wire identity crosses the
// membrane.
pub const SemanticTargetHandlerTag = struct {};
pub const SemanticTargetHandlerRef = semantic.handle.Handle(SemanticTargetHandlerTag);
pub const TargetHandlerRef = SemanticTargetHandlerRef;

/// Errors a probe may report to the host. A probe that cannot handle a target
/// should normally use `semanticTargetHandlerProbeNone`; these errors are for
/// a provider that did recognize the target domain but cannot answer it.
pub const SemanticTargetProbeError = error{ Unavailable, InvalidTarget, Failed };

/// Errors an open may report after a successful probe. `StaleTarget` is
/// intentionally distinct from `Unavailable`: the host can refresh and retry
/// the former, while the latter is a provider-level absence.
pub const SemanticTargetOpenError = error{ StaleTarget, Unavailable, Rejected, Failed };

pub const SemanticTargetHandlerError = SemanticPublishError;

/// Register one stable handler token. `token` is returned to the callback
/// export, while `id` is metadata used by host diagnostics and resolution.
/// The returned reference is portable across heads and files instances, but
/// only this plugin may close it.
pub fn semanticTargetHandlerRegister(token: u32, id: []const u8) SemanticTargetHandlerError!SemanticTargetHandlerRef {
    if (id.len == 0) return error.InvalidData;
    if (id.len > semantic_codec.Limits.max_string_bytes) return error.LimitExceeded;
    var out: [12]u8 = undefined;
    if (e.wl_semantic_target_handler_register(token, p(id.ptr), @intCast(id.len), p(&out), out.len) != 1)
        return error.Rejected;
    return readSemanticHandle(SemanticTargetHandlerRef, &out);
}

/// Remove a handler registration. The host invalidates the generation even if
/// a later plugin instance reuses the same slot.
pub fn semanticTargetHandlerClose(ref: SemanticTargetHandlerRef) bool {
    const wire = ref.toWire();
    return e.wl_semantic_target_handler_close(wire.authority, wire.slot, wire.generation) != 0;
}

/// Read and own the canonical request available only during
/// `on_semantic_target_probe` or `on_semantic_target_open`. The host supplies
/// one bounded payload; callers must use the returned codec-owned value's
/// `deinit` before returning from the callback.
fn semanticTargetHandlerRequest(gpa: std.mem.Allocator) (semantic_codec.Error || error{Rejected})![]u8 {
    const raw_len = e.wl_semantic_target_handler_request_len();
    if (raw_len <= 0) return error.Rejected;
    const len: usize = @intCast(raw_len);
    if (len > semantic_codec.Limits.max_payload_bytes) return error.LimitExceeded;
    const bytes = try gpa.alloc(u8, len);
    errdefer gpa.free(bytes);
    if (e.wl_semantic_target_handler_request(p(bytes.ptr), @intCast(bytes.len)) != raw_len)
        return error.Rejected;
    return bytes;
}

/// Decode the descriptor currently being probed. The returned descriptor owns
/// all strings/facts through its arena; call `deinit` after answering.
pub fn semanticTargetHandlerCurrentDescriptor(gpa: std.mem.Allocator) (semantic_codec.Error || error{Rejected})!semantic_codec.target.OwnedDescriptor {
    const bytes = try semanticTargetHandlerRequest(gpa);
    defer gpa.free(bytes);
    return semantic_codec.target.decodeDescriptor(gpa, bytes);
}

/// Decode the located target currently being opened. The returned value owns
/// all location payloads through its arena; call `deinit` after answering.
pub fn semanticTargetHandlerCurrentLocated(gpa: std.mem.Allocator) (semantic_codec.Error || error{Rejected})!semantic_codec.target.OwnedLocated {
    const bytes = try semanticTargetHandlerRequest(gpa);
    defer gpa.free(bytes);
    return semantic_codec.target.decodeLocated(gpa, bytes);
}

/// Resolve the probe response codes without exposing transport integers to a
/// plugin. The host accepts one response for each callback and rejects all
/// subsequent answers.
pub fn semanticTargetHandlerProbeNone() bool {
    return e.wl_semantic_target_handler_probe_respond(0) == 1;
}

pub fn semanticTargetHandlerProbeMatch(match: semantic.target.Match) bool {
    return e.wl_semantic_target_handler_probe_respond(1 + @as(u32, @intFromEnum(match))) == 1;
}

pub fn semanticTargetHandlerProbeError(err: SemanticTargetProbeError) bool {
    const code: u32 = switch (err) {
        error.Unavailable => 5,
        error.InvalidTarget => 6,
        error.Failed => 7,
    };
    return e.wl_semantic_target_handler_probe_respond(code) == 1;
}

/// Answer an open with a retained semantic view. The host validates the view
/// owner and target relationship before returning it to the resolver.
pub fn semanticTargetHandlerOpenView(view: semantic.view.Ref) bool {
    if (view.generation == 0) return false;
    const wire = view.toWire();
    return e.wl_semantic_target_handler_open_respond(0, wire.authority, wire.slot, wire.generation) == 1;
}

/// Answer an open with a newly provisioned view. The host settles this view
/// through `on_semantic_target_settle`; rejection means the plugin must undo
/// every resource created for the attempted open.
pub fn semanticTargetHandlerOpenProvisional(view: semantic.view.Ref) bool {
    if (view.generation == 0) return false;
    const wire = view.toWire();
    return e.wl_semantic_target_handler_open_respond(5, wire.authority, wire.slot, wire.generation) == 1;
}

pub fn semanticTargetHandlerOpenError(err: SemanticTargetOpenError) bool {
    const code: u32 = switch (err) {
        error.StaleTarget => 1,
        error.Unavailable => 2,
        error.Rejected => 3,
        error.Failed => 4,
    };
    return e.wl_semantic_target_handler_open_respond(code, 0, 0, 0) == 1;
}

// ── Generic relation-provider callbacks ───────────────────────────────
// Relation provider references are guest-local phantom handles. The host
// registry implementation and filesystem mechanisms never cross this API.
pub const SemanticRelationProviderTag = struct {};
pub const SemanticRelationProviderRef = semantic.handle.Handle(SemanticRelationProviderTag);
pub const RelationProviderRef = SemanticRelationProviderRef;

pub const SemanticRelationProviderError = SemanticPublishError;
pub const SemanticRelationQueryError = error{ Unavailable, InvalidRelation, StaleTarget, Failed };

pub fn semanticRelationProviderRegister(token: u32, id: []const u8) SemanticRelationProviderError!SemanticRelationProviderRef {
    if (id.len == 0) return error.InvalidData;
    if (id.len > semantic_codec.Limits.max_string_bytes) return error.LimitExceeded;
    var out: [12]u8 = undefined;
    if (e.wl_semantic_relation_provider_register(token, p(id.ptr), @intCast(id.len), p(&out), out.len) != 1)
        return error.Rejected;
    return readSemanticHandle(SemanticRelationProviderRef, &out);
}

pub fn semanticRelationProviderClose(ref: SemanticRelationProviderRef) bool {
    const wire = ref.toWire();
    return e.wl_semantic_relation_provider_close(wire.authority, wire.slot, wire.generation) != 0;
}

/// Read the query available only during `on_semantic_relation_query(token)`.
pub fn semanticRelationCurrentQuery(gpa: std.mem.Allocator) (semantic_codec.Error || error{Rejected})!semantic_codec.action.OwnedRelation {
    const raw_len = e.wl_semantic_relation_request_len();
    if (raw_len <= 0) return error.Rejected;
    const len: usize = @intCast(raw_len);
    if (len > semantic_codec.Limits.max_payload_bytes) return error.LimitExceeded;
    const bytes = try gpa.alloc(u8, len);
    defer gpa.free(bytes);
    if (e.wl_semantic_relation_request(p(bytes.ptr), @intCast(bytes.len)) != raw_len) return error.Rejected;
    return semantic_codec.action.decodeRelation(gpa, bytes);
}

pub fn semanticRelationRespondNone() bool {
    return e.wl_semantic_relation_respond(0, 0, 0) == 1;
}

/// Return only the located destination. The host supplies the exact relation
/// name from the query and validates target liveness before callers can open
/// it, so a guest cannot rename an edge in its response.
pub fn semanticRelationRespondTarget(target: semantic.target.Located) SemanticRelationProviderError!void {
    const payload = try semantic_codec.target.encodeLocated(allocator, target);
    defer allocator.free(payload);
    if (e.wl_semantic_relation_respond(1, p(payload.ptr), @intCast(payload.len)) != 1)
        return error.Rejected;
}

pub fn semanticRelationRespondError(err: SemanticRelationQueryError) bool {
    const kind: u32 = switch (err) {
        error.Unavailable => 2,
        error.InvalidRelation => 3,
        error.StaleTarget => 4,
        error.Failed => 5,
    };
    return e.wl_semantic_relation_respond(kind, 0, 0) == 1;
}

/// Publish a retained scene. A null target is represented canonically by an
/// all-zero wire tuple and cannot be confused with a live generation.
pub fn semanticViewPublish(root: semantic.scene.Node, target: ?semantic.target.Ref, revision: u32) SemanticPublishError!semantic.view.Ref {
    const payload = try semantic_codec.encodeScene(allocator, root);
    defer allocator.free(payload);
    const target_wire: semantic.handle.Wire = if (target) |ref| ref.toWire() else .{ .authority = 0, .slot = 0, .generation = 0 };
    var out: [12]u8 = undefined;
    if (e.wl_semantic_view_publish(
        p(payload.ptr),
        @intCast(payload.len),
        target_wire.authority,
        target_wire.slot,
        target_wire.generation,
        revision,
        p(&out),
        out.len,
    ) != 1) return error.Rejected;
    return readSemanticHandle(semantic.view.Ref, &out);
}

pub fn semanticViewReplace(ref: semantic.view.Ref, revision: u32, root: semantic.scene.Node) SemanticPublishError!void {
    const payload = try semantic_codec.encodeScene(allocator, root);
    defer allocator.free(payload);
    const wire = ref.toWire();
    if (e.wl_semantic_view_replace(wire.authority, wire.slot, wire.generation, revision, p(payload.ptr), @intCast(payload.len)) != 1)
        return error.Rejected;
}

pub fn semanticViewClose(ref: semantic.view.Ref) bool {
    const wire = ref.toWire();
    return e.wl_semantic_view_close(wire.authority, wire.slot, wire.generation) != 0;
}

pub const SemanticFieldSnapshot = struct {
    revision: []const u8,
    bytes: []const u8,
    selection: SemanticFieldSelection,
    read_only: bool = false,
    single_line: bool = false,
};

pub const SemanticFieldSelection = struct {
    anchor: u32,
    caret: u32,
};

fn semanticFieldFlags(snapshot: SemanticFieldSnapshot) u32 {
    return @as(u32, @intFromBool(snapshot.read_only)) |
        (@as(u32, @intFromBool(snapshot.single_line)) << 1);
}

pub fn semanticFieldRegister(token: u32, snapshot: SemanticFieldSnapshot) SemanticPublishError!semantic.scene.FieldRef {
    var out: [12]u8 = undefined;
    if (e.wl_semantic_field_register(
        token,
        p(snapshot.revision.ptr),
        @intCast(snapshot.revision.len),
        p(snapshot.bytes.ptr),
        @intCast(snapshot.bytes.len),
        snapshot.selection.anchor,
        snapshot.selection.caret,
        semanticFieldFlags(snapshot),
        p(&out),
        out.len,
    ) != 1) return error.Rejected;
    return readSemanticHandle(semantic.scene.FieldRef, &out);
}

pub fn semanticFieldUpdate(ref: semantic.scene.FieldRef, snapshot: SemanticFieldSnapshot) SemanticPublishError!void {
    const wire = ref.toWire();
    if (e.wl_semantic_field_update(
        wire.authority,
        wire.slot,
        wire.generation,
        p(snapshot.revision.ptr),
        @intCast(snapshot.revision.len),
        p(snapshot.bytes.ptr),
        @intCast(snapshot.bytes.len),
        snapshot.selection.anchor,
        snapshot.selection.caret,
        semanticFieldFlags(snapshot),
    ) != 1) return error.Rejected;
}

pub fn semanticFieldClose(ref: semantic.scene.FieldRef) bool {
    const wire = ref.toWire();
    return e.wl_semantic_field_close(wire.authority, wire.slot, wire.generation) != 0;
}

pub const SemanticFieldEdit = struct {
    storage_allocator: std.mem.Allocator,
    expected_revision: []u8,
    start: u32,
    end: u32,
    replacement: []u8,
    selection_after: ?SemanticFieldSelection,

    pub fn deinit(self: *SemanticFieldEdit) void {
        self.storage_allocator.free(self.replacement);
        self.storage_allocator.free(self.expected_revision);
        self.* = undefined;
    }
};

/// Read the request available only during `on_semantic_field_edit(token)`.
/// The returned bytes are owned by `gpa`; call `deinit` after updating or
/// rejecting the field in provider code.
pub fn semanticFieldCurrentEdit(gpa: std.mem.Allocator) (std.mem.Allocator.Error || error{Rejected})!SemanticFieldEdit {
    var meta: [28]u8 = undefined;
    if (e.wl_semantic_field_edit_meta(p(&meta), meta.len) != meta.len) return error.Rejected;
    const start = std.mem.readInt(u32, meta[0..4], .little);
    const end = std.mem.readInt(u32, meta[4..8], .little);
    const revision_len = std.mem.readInt(u32, meta[8..12], .little);
    const replacement_len = std.mem.readInt(u32, meta[12..16], .little);
    const has_selection = std.mem.readInt(u32, meta[16..20], .little);
    if (has_selection > 1) return error.Rejected;
    const revision = try gpa.alloc(u8, revision_len);
    errdefer gpa.free(revision);
    const replacement = try gpa.alloc(u8, replacement_len);
    errdefer gpa.free(replacement);
    if (e.wl_semantic_field_edit_revision(p(revision.ptr), revision_len) != revision_len or
        (replacement_len != 0 and e.wl_semantic_field_edit_replacement(p(replacement.ptr), replacement_len) != replacement_len))
        return error.Rejected;
    return .{
        .storage_allocator = gpa,
        .expected_revision = revision,
        .start = start,
        .end = end,
        .replacement = replacement,
        .selection_after = if (has_selection == 1) .{
            .anchor = std.mem.readInt(u32, meta[20..24], .little),
            .caret = std.mem.readInt(u32, meta[24..28], .little),
        } else null,
    };
}

// ── Effects (perm-gated) ─────────────────────────────────────────────
/// Run `cmd` in a shell off the frame thread; insert its stdout at the cursor
/// when it finishes, resolved through its CRDT identity. Perms: proc + timer
/// (declared in `describe`).
pub fn shellInsert(cmd: []const u8) void {
    e.wl_shell_insert(p(cmd.ptr), @intCast(cmd.len));
}

// ── Interactive REPL sessions (persistent child + comint buffer) ──────
/// Start a persistent REPL running `cmd` under a shell, streaming its output
/// into buffer `name`. Returns a session handle, or null. Perms: proc + timer.
pub fn replStart(cmd: []const u8, name: []const u8) ?u32 {
    const h = e.wl_repl_start(p(cmd.ptr), @intCast(cmd.len), p(name.ptr), @intCast(name.len));
    return if (h < 0) null else @intCast(h);
}
/// Write a line to a REPL session's stdin (a newline is appended if absent).
pub fn replSend(handle: u32, line: []const u8) void {
    e.wl_repl_send(handle, p(line.ptr), @intCast(line.len));
}
/// Terminate a REPL session.
pub fn replQuit(handle: u32) void {
    e.wl_repl_quit(handle);
}

/// Spawn a persistent subprocess whose stdout comes BACK to the guest (via
/// `procRead`), for an in-guest protocol client. Returns a handle, or null.
pub fn procSpawn(cmd: []const u8) ?u32 {
    const h = e.wl_proc_spawn(p(cmd.ptr), @intCast(cmd.len));
    return if (h < 0) null else @intCast(h);
}
/// Write bytes to the subprocess's stdin.
pub fn procSend(handle: u32, bytes: []const u8) void {
    e.wl_proc_send(handle, p(bytes.ptr), @intCast(bytes.len));
}
/// Drain up to `out.len` buffered stdout bytes; returns the slice read (may be
/// empty). Valid until the next call.
pub fn procRead(handle: u32, out: []u8) []u8 {
    const n = e.wl_proc_read(handle, p(out.ptr), @intCast(out.len));
    return if (n <= 0) out[0..0] else out[0..@intCast(n)];
}
/// Kill the subprocess (its handle stays reserved).
pub fn procClose(handle: u32) void {
    e.wl_proc_close(handle);
}
/// WHERE this dispatch runs, as an absolute directory (`doc/place.md`) — the
/// project a file belongs to, the pinned working target, or the editor's own
/// directory when the dispatch is about nothing more specific.
///
/// **EMPTY means the place has no local directory** (a peer or a container that
/// went away), and a caller that needs one must DECLINE rather than substitute
/// the editor's launch directory: acting in the wrong project while reporting
/// success is the bug the retired process-directory shim used to cause.
///
/// Uses the shared scratch — copy it before the next read call.
/// A dense opaque id for the place this dispatch is in. Compare it with
/// another `placeId()`; never interpret the number, and never persist it (it
/// is stable for this run only).
pub fn placeId() i32 {
    return e.wl_place_id();
}

/// Publish this plugin's environment overlay for the place this dispatch is
/// in: NUL-separated `KEY=VALUE` records. Returns the new revision, or -1.
/// Perm: env -- distinct from proc, because an overlay governs every
/// subprocess ANY plugin runs at that place, not just your own.
pub fn envPublish(vars: []const u8) i32 {
    return e.wl_env_publish(p(vars.ptr), @intCast(vars.len));
}

pub fn placeRoot() []const u8 {
    const n = e.wl_place_root(p(&scratch), scratch.len);
    return if (n <= 0) "" else scratch[0..@intCast(n)];
}

/// What `rel` IS *inside* this dispatch's place — the marker query
/// (`doc/place.md` §4.2). Same four answers as `fsExists`, and NO permission:
/// it reveals strictly less than `placeRoot`, which already hands you the
/// directory, and it cannot escape the place (the host resolves it beneath the
/// place root with `openat2(RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS)`).
///
/// This is what "is this project a git repository", "is there an `.envrc`
/// here", "is a rebase mid-flight" ask, and it is the reason neither `git` nor
/// `project` holds `fs_read` any more: probing for machinery inside your own
/// content never needed a grant over the whole filesystem.
///
/// An absolute `rel`, a `..` that leaves the place, a symlink pointing out of
/// it, and a place with no local directory all answer `.none` — the door
/// describes what the place contains, and nothing else. Touches no scratch, so
/// a borrowed `path()`/`placeRoot()` slice stays valid across a call.
pub fn placeHas(rel: []const u8) FsKind {
    return switch (e.wl_place_has(p(rel.ptr), @intCast(rel.len))) {
        1 => .file,
        2 => .dir,
        3 => .other,
        else => .none,
    };
}

/// A buffer path named absolutely within its place, into `out`.
///
/// The two doors answer different spellings of the same file. `wl_path` gives
/// the path AS SPELLED — absolute, or relative to the directory the editor was
/// launched in — while `placeRoot` gives a directory the file is INSIDE. Join
/// them naively and the components both spellings share get counted twice:
/// `weft proj/x.zig`, launched above `proj`, is `<…>/proj` + `proj/x.zig`.
///
/// So the join drops the leading components of `spelled` that `root` already
/// ends with, longest overlap first — the file is inside the root by
/// construction, so the deepest shared spelling is the one the launch directory
/// produced. Absolute paths pass through untouched; an empty `root` yields ""
/// so a caller DECLINES rather than inventing a base.
///
/// Pure, and here rather than in each plugin: this shim is the one party that
/// knows the contract of both doors, and two guests open-coding the same join
/// is exactly how they drift apart.
pub fn placePath(root: []const u8, spelled: []const u8, out: []u8) []const u8 {
    if (spelled.len > 0 and spelled[0] == '/') return std.fmt.bufPrint(out, "{s}", .{spelled}) catch "";
    if (root.len == 0) return "";
    var start: usize = 0;
    var cut: usize = 0;
    while (std.mem.indexOfScalarPos(u8, spelled, start, '/')) |slash| {
        const head = spelled[0..slash];
        if (root.len > head.len and
            root[root.len - head.len - 1] == '/' and
            std.mem.eql(u8, root[root.len - head.len ..], head)) cut = slash + 1;
        start = slash + 1;
    }
    return std.fmt.bufPrint(out, "{s}/{s}", .{ root, spelled[cut..] }) catch "";
}

// ── net.connect (TCP / TLS) — perm net ───────────────────────────────
/// Dial `hostport`, streaming the socket into buffer `name`. If `sni` is
/// non-empty, run TLS verifying that host name. Returns a handle, or null.
pub fn netConnect(hostport: []const u8, name: []const u8, sni: []const u8) ?u32 {
    const h = e.wl_net_connect(p(hostport.ptr), @intCast(hostport.len), p(name.ptr), @intCast(name.len), p(sni.ptr), @intCast(sni.len));
    return if (h < 0) null else @intCast(h);
}
/// Send bytes on a connection.
pub fn netSend(handle: u32, bytes: []const u8) void {
    e.wl_net_send(handle, p(bytes.ptr), @intCast(bytes.len));
}
/// Close a connection.
pub fn netClose(handle: u32) void {
    e.wl_net_close(handle);
}

/// Run `cmd` off the frame thread and replace the scratch buffer named `name`
/// (found or created NOW, then held by identity) with its stdout — tool output
/// → a buffer (git status, grep, compile). `token` is opaque to the host and
/// comes back as `on_fill_token` when the output lands, so a plugin with
/// several fills in flight knows which one finished; the entry is bound for
/// that call, so reads/edits/styles mean it rather than whatever is focused.
/// Pass 0 when nothing needs to run afterwards. Perms: proc + timer.
pub fn procToBuffer(cmd: []const u8, name: []const u8, token: u32) void {
    e.wl_proc_to_buffer(p(cmd.ptr), @intCast(cmd.len), p(name.ptr), @intCast(name.len), token);
}
/// Like `procToBuffer` but APPENDS the output — a console/comint log.
pub fn procAppendBuffer(cmd: []const u8, name: []const u8, token: u32) void {
    e.wl_proc_append_buffer(p(cmd.ptr), @intCast(cmd.len), p(name.ptr), @intCast(name.len), token);
}

/// `procToBuffer` for a command that needs its input as a FILE. The host
/// writes `input` to a temp path IT chooses, substitutes that path for every
/// `{}` in `cmd`, runs it, fills `name` with stdout (token → `on_fill_token`,
/// exactly as `procToBuffer`), and deletes the temp whether the command
/// succeeded or failed.
///
/// The path is never spelled here, so a plugin that only needs to hand a
/// subprocess bytes on disk — `git apply {}`, `git commit -F '{}'`,
/// `llm < {}` — needs NO `fs_write`: it cannot choose where the bytes land and
/// cannot leave them there. Perms: proc + timer, the same as `procToBuffer`.
///
/// `cmd` is yours to compose, so keep `{}` reserved: any other `{}` in the
/// string (a path with braces in it, say) is substituted too.
pub fn procSpool(cmd: []const u8, input: []const u8, name: []const u8, token: u32) void {
    e.wl_proc_spool(p(cmd.ptr), @intCast(cmd.len), p(input.ptr), @intCast(input.len), p(name.ptr), @intCast(name.len), token);
}

/// Filter `[r.start, r.end)` through `cmd` (a `{}` placeholder gets a temp file
/// the range is written to, transformed in place, and read back) and replace
/// the range with the result — formatters and vim `!`-filters. Async, CRDT-
/// anchored, and authored as this plugin's peer. Perms: proc + timer.
pub fn procFilter(cmd: []const u8, r: Range) void {
    e.wl_proc_filter(p(cmd.ptr), @intCast(cmd.len), @intCast(r.start), @intCast(r.end));
}

// ── fs (perm-gated fs_read / fs_write) — local, cwd-relative ──────────
// A missing perm never reaches these as -1/null: the host traps the call
// outright (doc/contextual-workspace-architecture.md §13.5), so a plugin that hasn't
// requested the perm never even gets back here. The degrade values below are
// for legitimate misses (not found / too big / not a directory) only.
/// Read a file into `scratch` (valid until the next read call), or null (not
/// found / too big). Perm: fs_read.
pub fn fsRead(fpath: []const u8) ?[]const u8 {
    const n = e.wl_fs_read(p(fpath.ptr), @intCast(fpath.len), p(&scratch), scratch.len);
    if (n < 0) return null;
    return scratch[0..@intCast(n)];
}
/// What `fpath` is, without reading it. Perm: fs_read.
///
/// NOT the door for "is there a `.git` here": that is `placeHas`, which needs
/// no grant and cannot leave the place. This one takes a path anywhere the
/// grant reaches, which is why the two plugins that used to climb with it
/// (`git`, `project`) no longer hold `fs_read` at all (`doc/place.md` §4.2).
pub const FsKind = enum(i32) { none = 0, file = 1, dir = 2, other = 3 };
pub fn fsExists(fpath: []const u8) FsKind {
    const k = e.wl_fs_exists(p(fpath.ptr), @intCast(fpath.len));
    return switch (k) {
        1 => .file,
        2 => .dir,
        3 => .other,
        else => .none, // 0 absent
    };
}
/// What `fsStat` answers — `fsExists`'s kind plus the facts a lister wants.
/// RAW: `mode` is permission bits, `mtime_ns` is nanoseconds since the epoch.
/// Formatting them ("12.4K", "2h ago") is the caller's job, deliberately: the
/// membrane carries facts, never a rendering.
pub const FsStat = struct {
    kind: FsKind = .none,
    mode: u32 = 0,
    size: u64 = 0,
    mtime_ns: i64 = 0,
    nlink: u32 = 0,

    pub const absent: FsStat = .{};
};

/// A path's metadata, under the same grant bounds as `fsRead`. Perm: fs_read.
/// An absent path answers `.absent` (kind `.none`), not null — only a
/// REFUSAL is exceptional, and a refusal traps rather than returning.
pub fn fsStat(fpath: []const u8) FsStat {
    var rec: [32]u8 = undefined;
    const n = e.wl_fs_stat(p(fpath.ptr), @intCast(fpath.len), p(&rec), rec.len);
    if (n != rec.len) return .absent;
    return .{
        .kind = switch (std.mem.readInt(u32, rec[0..4], .little)) {
            1 => .file,
            2 => .dir,
            3 => .other,
            else => .none,
        },
        .mode = std.mem.readInt(u32, rec[4..8], .little),
        .size = std.mem.readInt(u64, rec[8..16], .little),
        .mtime_ns = std.mem.readInt(i64, rec[16..24], .little),
        .nlink = std.mem.readInt(u32, rec[24..28], .little),
    };
}

/// Replace a file with `bytes`. Perm: fs_write. Returns success.
pub fn fsWrite(fpath: []const u8, bytes: []const u8) bool {
    return e.wl_fs_write(p(fpath.ptr), @intCast(fpath.len), p(bytes.ptr), @intCast(bytes.len)) == 0;
}
/// Append `bytes` to a file (created if absent). Perm: fs_write. Returns success.
pub fn fsAppend(fpath: []const u8, bytes: []const u8) bool {
    return e.wl_fs_append(p(fpath.ptr), @intCast(fpath.len), p(bytes.ptr), @intCast(bytes.len)) == 0;
}
/// List a directory at `authority` (locus): "here" for the local fs; a peer/
/// shell authority once the collab transport is wired. Entries newline-joined,
/// directories with a trailing `/`, into `scratch` (valid until the next read).
/// null = unresolved authority / not a directory. Perm: fs_read.
pub fn fsList(authority: []const u8, dir: []const u8) ?[]const u8 {
    const n = e.wl_fs_list(p(authority.ptr), @intCast(authority.len), p(dir.ptr), @intCast(dir.len), p(&scratch), scratch.len);
    if (n < 0) return null;
    return scratch[0..@intCast(n)];
}

/// Typed status returned by the target-scoped filesystem membrane.  A
/// non-negative host result is an encoded response length; these values are
/// only used internally by the retrying wrappers below.
pub const SemanticFsError = fs_codec.Error || semantic_codec.Error || error{
    Unavailable,
    StaleTarget,
    Unsupported,
    InvalidTarget,
    Failed,
};

fn semanticFsError(code: i32) SemanticFsError!void {
    switch (code) {
        -1 => return error.Unavailable,
        -2 => return error.StaleTarget,
        -3 => return error.Unsupported,
        -4 => return error.InvalidTarget,
        -5 => return error.Failed,
        else => if (code < 0) return error.Failed,
    }
}

fn semanticFsRevisionLow(revision: u64) u32 {
    return @intCast(revision & 0xffff_ffff);
}

fn semanticFsRevisionHigh(revision: u64) u32 {
    return @intCast(revision >> 32);
}

/// Publish an observed direct child directory as a new independently confined
/// semantic target. The request carries only the live parent target and
/// guarded entry identity; the host re-reads the provider name and derives a
/// new root, so neither a raw root capability nor a filename is trusted from
/// guest memory.
pub fn semanticFsPublishChildDirectory(
    gpa: std.mem.Allocator,
    parent: semantic.target.Located,
    entry: fs.contract.EntryRef,
    revision: fs.contract.Revision,
) SemanticFsError!semantic.target.Located {
    return semanticFsPublishChild(.directory, gpa, parent, entry, revision);
}

/// Publish an observed direct child regular file as an ordinary semantic
/// target. The guest supplies the same guarded provider identity used for a
/// directory child; it never supplies a path, root capability, or target
/// facts. Which plugin, if any, handles the resulting target is independent.
pub fn semanticFsPublishChildFile(
    gpa: std.mem.Allocator,
    parent: semantic.target.Located,
    entry: fs.contract.EntryRef,
    revision: fs.contract.Revision,
) SemanticFsError!semantic.target.Located {
    return semanticFsPublishChild(.file, gpa, parent, entry, revision);
}

const SemanticFsChildKind = enum { directory, file };

fn semanticFsPublishChild(
    comptime kind: SemanticFsChildKind,
    gpa: std.mem.Allocator,
    parent: semantic.target.Located,
    entry: fs.contract.EntryRef,
    revision: fs.contract.Revision,
) SemanticFsError!semantic.target.Located {
    const request = try fs_codec.child_directory.encode(gpa, .{
        .parent = parent,
        .entry = entry,
        .revision = revision,
    });
    defer gpa.free(request);
    var output: [64]u8 = undefined;
    const result = switch (kind) {
        .directory => e.wl_semantic_fs_publish_child_directory(p(request.ptr), @intCast(request.len), p(&output), output.len),
        .file => e.wl_semantic_fs_publish_child_file(p(request.ptr), @intCast(request.len), p(&output), output.len),
    };
    try semanticFsError(result);
    const result_len: usize = @intCast(result);
    if (result_len > output.len) return error.Failed;
    var located = try semantic_codec.target.decodeLocated(gpa, output[0..result_len]);
    defer located.deinit();
    switch (located.value.location) {
        .whole => {},
        else => return error.InvalidTarget,
    }
    return located.value;
}

/// Query provider policy for the exact target revision.  The result is
/// descriptive only: the host re-authorizes every filesystem operation, so a
/// capability bit can never be used as an ambient root or operation grant.
pub fn semanticFsCapabilities(
    gpa: std.mem.Allocator,
    target: semantic.target.Ref,
    revision: u64,
) SemanticFsError!fs.contract.Capabilities {
    const wire = target.toWire();
    var capacity: usize = 64;
    while (true) {
        if (capacity > fs_codec.Limits.max_payload_bytes) capacity = fs_codec.Limits.max_payload_bytes;
        const bytes = try gpa.alloc(u8, capacity);
        defer gpa.free(bytes);
        const result = e.wl_semantic_fs_capabilities(
            wire.authority,
            wire.slot,
            wire.generation,
            semanticFsRevisionLow(revision),
            semanticFsRevisionHigh(revision),
            p(bytes.ptr),
            @intCast(bytes.len),
        );
        if (result == -6) {
            if (capacity == fs_codec.Limits.max_payload_bytes) return error.LimitExceeded;
            capacity = @min(capacity * 2, fs_codec.Limits.max_payload_bytes);
            continue;
        }
        try semanticFsError(result);
        const result_len: usize = @intCast(result);
        if (result_len > bytes.len) return error.Failed;
        return fs_codec.decodeCapabilities(gpa, bytes[0..result_len]);
    }
}

/// List the exact directory attachment of a live target revision.  The
/// response buffer grows only up to the codec's canonical payload limit, so
/// callers do not need to expose a fixed-size files scratch area.
pub fn semanticFsList(gpa: std.mem.Allocator, target: semantic.target.Ref, revision: u64) SemanticFsError!fs_codec.OwnedListing {
    const wire = target.toWire();
    var capacity: usize = 4096;
    while (true) {
        if (capacity > fs_codec.Limits.max_payload_bytes) capacity = fs_codec.Limits.max_payload_bytes;
        const bytes = try gpa.alloc(u8, capacity);
        defer gpa.free(bytes);
        const result = e.wl_semantic_fs_list(wire.authority, wire.slot, wire.generation, semanticFsRevisionLow(revision), semanticFsRevisionHigh(revision), p(bytes.ptr), @intCast(bytes.len));
        if (result == -6) {
            if (capacity == fs_codec.Limits.max_payload_bytes) return error.LimitExceeded;
            capacity = @min(capacity * 2, fs_codec.Limits.max_payload_bytes);
            continue;
        }
        try semanticFsError(result);
        const result_len: usize = @intCast(result);
        if (result_len > bytes.len) return error.Failed;
        return fs_codec.decodeListing(gpa, bytes[0..result_len]);
    }
}

/// Apply a canonical typed plan against the exact target revision.  Cross-root
/// sources are rejected by the host until a provider supplies an explicit
/// durable lease; this wrapper therefore carries no ambient root capability.
pub fn semanticFsApply(gpa: std.mem.Allocator, target: semantic.target.Ref, revision: u64, effect_plan: fs.contract.Plan) SemanticFsError!fs_codec.OwnedApplyReport {
    const plan_bytes = try fs_codec.encodePlan(gpa, effect_plan);
    defer gpa.free(plan_bytes);
    const wire = target.toWire();
    var capacity: usize = 4096;
    while (true) {
        if (capacity > fs_codec.Limits.max_payload_bytes) capacity = fs_codec.Limits.max_payload_bytes;
        const bytes = try gpa.alloc(u8, capacity);
        defer gpa.free(bytes);
        const result = e.wl_semantic_fs_apply(wire.authority, wire.slot, wire.generation, semanticFsRevisionLow(revision), semanticFsRevisionHigh(revision), p(plan_bytes.ptr), @intCast(plan_bytes.len), p(bytes.ptr), @intCast(bytes.len));
        if (result == -6) {
            if (capacity == fs_codec.Limits.max_payload_bytes) return error.LimitExceeded;
            capacity = @min(capacity * 2, fs_codec.Limits.max_payload_bytes);
            continue;
        }
        try semanticFsError(result);
        const result_len: usize = @intCast(result);
        if (result_len > bytes.len) return error.Failed;
        return fs_codec.decodeApplyReport(gpa, bytes[0..result_len]);
    }
}

pub const SemanticTransferError = SemanticFsError || error{InvalidAttachment};

fn semanticTransferError(code: i32) SemanticTransferError!void {
    switch (code) {
        -1 => return error.Unavailable,
        -2 => return error.StaleTarget,
        -3 => return error.Unsupported,
        -4 => return error.InvalidAttachment,
        -5 => return error.Failed,
        -6 => return error.LimitExceeded,
        else => if (code < 0) return error.Failed,
    }
}

/// Materialize an authorized filesystem entry for use by a semantic
/// transfer. The result carries an owner-scoped wire identifier and the
/// provider lease source it may name in a plan; neither is an ambient
/// filesystem capability without host-side registry authorization.
pub const SemanticTransferCapture = struct {
    attachment: semantic.transfer.Attachment,
    source: fs.contract.LeaseSource,
};

pub fn semanticTransferCapture(
    target: semantic.target.Ref,
    target_revision: u64,
    source: fs.contract.EntrySource,
) SemanticTransferError!SemanticTransferCapture {
    const target_wire = target.toWire();
    var out: [36]u8 = undefined;
    const result = e.wl_semantic_transfer_capture(
        target_wire.authority,
        target_wire.slot,
        target_wire.generation,
        semanticFsRevisionLow(target_revision),
        semanticFsRevisionHigh(target_revision),
        @intFromEnum(source.root.authority),
        source.root.slot,
        source.root.generation,
        @intFromEnum(source.ref.authority),
        source.ref.slot,
        source.ref.generation,
        p(source.revision.token.ptr),
        @intCast(source.revision.token.len),
        p(&out),
        out.len,
    );
    try semanticTransferError(result);
    if (result != out.len) return error.Failed;
    return .{
        .attachment = semantic.transfer.Attachment.fromWire(.{
            .authority = std.mem.readInt(u32, out[0..4], .little),
            .slot = std.mem.readInt(u32, out[4..8], .little),
            .generation = std.mem.readInt(u32, out[8..12], .little),
        }),
        .source = .{
            .root = .{
                .authority = @enumFromInt(std.mem.readInt(u32, out[12..16], .little)),
                .slot = std.mem.readInt(u32, out[16..20], .little),
                .generation = std.mem.readInt(u32, out[20..24], .little),
            },
            .ref = .{
                .authority = @enumFromInt(std.mem.readInt(u32, out[24..28], .little)),
                .slot = std.mem.readInt(u32, out[28..32], .little),
                .generation = std.mem.readInt(u32, out[32..36], .little),
            },
        },
    };
}

// ── D2: generic, schema-directed slots (doc/d2-schema-payloads.md §6) ────
// A third-party plugin declares a NOVEL slot with a NOVEL result shape —
// core has no type for it, ever. `slotDeclare` ships the schema TREE as its
// canonical blob (`schema.canonicalizeSchema` — the same module the host
// runs, `weft_schema` above); `slotBind` registers a provider; `payloadPush`
// answers a fired session with schema-encoded bytes the host restamps and a
// consumer decodes with `schema.decodeCursor` — none of which core
// recompiles for.

pub const SlotShape = enum(u32) { query = 0, feed = 1, action = 2, value = 3 };
pub const SlotComposition = enum(u32) { first_wins = 0, ordered_union = 1, merge_ranked = 2 };
pub const SlotTier = enum(u32) { core = 0, imported = 1, plugin = 2, config = 3, transient = 4 };

/// Runtime-declare a slot (`wl_slot_declare`) — no core recompile, no core
/// type: `sch` crosses as its own canonical blob.
pub fn slotDeclare(name: []const u8, shape: SlotShape, composition: SlotComposition, sch: *const schema.Schema) void {
    const blob = schema.canonicalizeSchema(allocator, sch) catch return;
    defer allocator.free(blob);
    e.wl_slot_declare(p(name.ptr), @intCast(name.len), @intFromEnum(shape), @intFromEnum(composition), p(blob.ptr), @intCast(blob.len));
}

/// A single-axis predicate for `slotBind` — the wire micro-format
/// `wasm_host/slot.zig`'s `parsePredicate` decodes (see that file's module
/// doc for why this is deliberately not a full self-hosted `facts.Predicate`
/// yet — a disclosed, bounded simplification, not the end state).
/// THE predicate — the host's own `facts.Predicate`, not a guest mirror of a
/// subset of it.
///
/// There used to be two narrower spellings on this side of the membrane: a
/// `SlotPredicate` union of five cases for `slotBind`, and a `When` struct of
/// three optional strings for `provide`. Neither could express a disjunction,
/// a glob, a tag, or a locality, so a provider whose interest was any of those
/// carried the test inside itself — and interest the host cannot see is
/// interest the host cannot route, gate, or explain.
///
/// One type, shared as a module (`weft_facts`) exactly as `weft_input` and
/// `weft_membrane` are, for exactly the same reason: it is imported by core
/// AND compiled into every guest, so it may never acquire a host-only
/// dependency. `std` is its only import.
pub const Predicate = @import("weft_facts").Predicate;
pub const Facts = @import("weft_facts").Facts;
pub const Locality = @import("weft_facts").Locality;

/// Bind a provider for an already-declared slot (`wl_slot_bind`).
pub fn slotBind(name: []const u8, pred: Predicate, tier: SlotTier, priority: i32) void {
    // Encoded by the SAME function the host decodes with (`weft_facts`), so
    // there is no format for the two sides to disagree about. The old path
    // hand-rolled a four-tag blob here and a four-tag parser there; a
    // combinator was unrepresentable, so a provider that needed one filtered
    // inside itself and the host never learned what it was interested in.
    const bytes = @import("weft_facts").encode(allocator, pred) catch return;
    defer allocator.free(bytes);
    e.wl_slot_bind(p(name.ptr), @intCast(name.len), p(bytes.ptr), @intCast(bytes.len), @intFromEnum(tier), priority);
}

/// Push one schema-encoded payload for a fired `session` (`wl_payload_push`).
/// `version` is this plugin's `SchemaRef` for the slot (§2.3) — the host
/// never trusts a `range`-marked field's claimed version either way (it
/// restamps those unconditionally); this is metadata for future skew
/// detection, not currently checked (see `wasm_host/slot.zig`'s doc).
pub fn payloadPush(session: u32, version: u32, sch: *const schema.Schema, value: schema.Value) void {
    const bytes = schema.encode(allocator, sch, value) catch return;
    defer allocator.free(bytes);
    e.wl_payload_push(@bitCast(session), version, p(bytes.ptr), @intCast(bytes.len));
}

var slot_scratch: [1 << 16]u8 = undefined;

/// The fired session's schema-encoded REQUEST payload (`wl_payload_read`),
/// into a private scratch — empty if there is none. Valid until the next call.
pub fn payloadRead(session: u32) []const u8 {
    const n = e.wl_payload_read(@bitCast(session), p(&slot_scratch), slot_scratch.len);
    if (n < 0) return &.{};
    return slot_scratch[0..@intCast(n)];
}

// ── Consuming a slot: the other half of declare/bind ──────────────────
/// A live question you asked of every plugin that answers `slot` here.
///
/// This is what makes a plugin a CONSUMER and not only a provider. Before
/// it, a guest could `slotDeclare`/`slotBind`/`payloadPush` — answer the
/// host — but had no way to ask its own question, so plugin-to-plugin
/// composition could only be spelled as an untyped `run("some-command")`
/// with strings in and strings out. A `Fire` is the typed form: the slot's
/// declared schema is the contract, the CONTEXT decides who answers, and
/// results arrive with the provider that gave them.
///
/// The context is NOT yours to choose. The host resolves eligibility
/// against the facts of the entry you are dispatching in — the same facts a
/// keystroke's intention resolves against — so you cannot ask "as" a mode
/// or language you are not in, and every position in every answer is
/// restamped against the host's own version.
///
/// `deinit` when done; a forgotten session lives until this plugin unloads.
pub const Fire = struct {
    session: u32,

    /// Ask `slot`, carrying `request` (schema-encoded, may be empty). Null
    /// when nothing answers that question here — an undeclared slot, one
    /// with no schema, and one no eligible provider binds are all the same
    /// ordinary answer: nobody is offering.
    pub fn open(slot_name: []const u8, request: []const u8) ?Fire {
        const id = e.wl_slot_fire(p(slot_name.ptr), @intCast(slot_name.len), p(request.ptr), @intCast(request.len));
        if (id < 0) return null;
        return .{ .session = @bitCast(id) };
    }

    /// Encode `value` against `sch` and ask with it — the typed spelling of
    /// `open`, for a slot whose request side has a shape.
    pub fn openWith(slot_name: []const u8, sch: *const schema.Schema, value: schema.Value) ?Fire {
        const bytes = schema.encode(allocator, sch, value) catch return null;
        defer allocator.free(bytes);
        return open(slot_name, bytes);
    }

    /// How many answers have landed so far.
    pub fn count(self: Fire) usize {
        const n = e.wl_slot_result_count(@bitCast(self.session));
        return if (n < 0) 0 else @intCast(n);
    }

    /// True once every provider that matched has answered or declined. A
    /// race whose providers all answer synchronously is already done when
    /// `open` returns; poll this from `on_poll` for the ones that defer.
    pub fn done(self: Fire) bool {
        return e.wl_slot_done(@bitCast(self.session)) == 1;
    }

    /// Answer `i`'s schema-encoded payload, into a private scratch —
    /// decode it with `weft.schema` against the slot's own schema. Valid
    /// until the next `result`/`provider`/`payloadRead` call.
    pub fn result(self: Fire, i: usize) ?[]const u8 {
        const n = e.wl_slot_result(@bitCast(self.session), @intCast(i), p(&slot_scratch), slot_scratch.len);
        if (n < 0) return null;
        return slot_scratch[0..@intCast(n)];
    }

    /// WHO answered `i`. Attribution is data you are given, not something
    /// to infer from the payload.
    pub fn provider(self: Fire, i: usize) ?[]const u8 {
        const n = e.wl_slot_result_provider(@bitCast(self.session), @intCast(i), p(&provider_scratch), provider_scratch.len);
        if (n < 0) return null;
        return provider_scratch[0..@intCast(n)];
    }

    pub fn deinit(self: Fire) void {
        e.wl_slot_finish(@bitCast(self.session));
    }
};

/// Separate from `slot_scratch` so a caller can hold a payload and its
/// provider name at the same time — the obvious thing to want, and a shared
/// buffer would silently give you the same bytes twice.
var provider_scratch: [256]u8 = undefined;
