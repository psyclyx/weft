//! weft.zig (guest side) — the ABI a `.wasm` plugin sees, mirroring the
//! in-process `abi.Abi` surface (src/core/abi.zig) one-for-one so the SAME
//! plugin logic reads identically whether it links in-process or crosses the
//! sandbox membrane. Only the transport differs: every call here is an
//! `extern "weft"` host import (the grant), scalars cross as i32/u32, and
//! bulk bytes cross through the guest's own linear memory — either the host
//! reads `(ptr, len)` out of us (writes: `edit`, `kvPut`) or fills a scratch
//! buffer we hand it `(ptr, cap)` and returns the length (reads: `slice`,
//! `kvGet`, `path`). No host pointer ever reaches the guest.
//!
//! Permission groups match abi.zig: A core (log), the describe-phase
//! declarations (declareCommand/requestPerm), B read-only (cursor/byteLen/
//! slice/lineAt/selection/path), C write (edit/register/jump), E admin (kv),
//! plus echo. A guest declares in `describe()`; the host cross-checks every
//! `register`/effect against that declaration (the perm handshake).

// ── Raw host imports (the grants). Named `wl_*` to keep the ergonomic
// wrappers below as the surface guest code actually calls. ──
extern "weft" fn wl_log(level: u32, ptr: u32, len: u32) void;
extern "weft" fn wl_declare_command(ptr: u32, len: u32) void;
extern "weft" fn wl_declare_capability(ptr: u32, len: u32) void;
extern "weft" fn wl_request_perm(perm: u32) void;
extern "weft" fn wl_cursor() u32;
extern "weft" fn wl_byte_len() u32;
extern "weft" fn wl_slice(start: u32, end: u32, out_ptr: u32, out_cap: u32) u32;
extern "weft" fn wl_line_at(offset: u32, out_ptr: u32) void;
extern "weft" fn wl_selection(out_ptr: u32) u32;
extern "weft" fn wl_path(out_ptr: u32, out_cap: u32) i32;
extern "weft" fn wl_edit(start: u32, end: u32, ptr: u32, len: u32) void;
extern "weft" fn wl_register(ptr: u32, len: u32) u32;
extern "weft" fn wl_jump(offset: u32) void;
// Native `editor` surface + stamped ranges ([FIX 1/3]). A range crosses as an
// opaque u32 handle into a host-side table (the version token stays host-side).
extern "weft" fn wl_editor_step(from: u32, dir: u32, kind: u32) u32;
extern "weft" fn wl_set_selection(start: u32, end: u32) void;
extern "weft" fn wl_stamp_range(start: u32, end: u32) i32;
extern "weft" fn wl_set_result_range(handle: u32) void;
extern "weft" fn wl_run_range(ptr: u32, len: u32) i32;
extern "weft" fn wl_range_ends(handle: u32, out_ptr: u32) i32;
extern "weft" fn wl_run_range_arg(ptr: u32, len: u32, handle: u32) void;
extern "weft" fn wl_arg_range(i: u32) i32;
extern "weft" fn wl_edit_range(handle: u32, ptr: u32, len: u32) void;
extern "weft" fn wl_kv_get(kptr: u32, klen: u32, out_ptr: u32, out_cap: u32) i32;
extern "weft" fn wl_kv_put(kptr: u32, klen: u32, vptr: u32, vlen: u32) void;
extern "weft" fn wl_echo(ptr: u32, len: u32) void;
// Command args (readable during on_command) + result (set during it).
extern "weft" fn wl_arg_count() u32;
extern "weft" fn wl_arg_int(i: u32) i32;
extern "weft" fn wl_arg_str(i: u32, out_ptr: u32, out_cap: u32) i32;
extern "weft" fn wl_set_result_int(n: i32) void;
extern "weft" fn wl_set_result_str(ptr: u32, len: u32) void;
// Config surface (the local plane — bindings/modes, as init.fnl did).
extern "weft" fn wl_bind_key(m: u32, ml: u32, k: u32, kl: u32, c: u32, cl: u32) void;
extern "weft" fn wl_set_mode(ptr: u32, len: u32) void;
extern "weft" fn wl_set_fallback(m: u32, ml: u32, par: u32, pl: u32) void;
extern "weft" fn wl_text_input(m: u32, ml: u32, c: u32, cl: u32, has: u32) void;
extern "weft" fn wl_menu_mode(ptr: u32, len: u32) void;
extern "weft" fn wl_run(ptr: u32, len: u32) void;
extern "weft" fn wl_run_int(ptr: u32, len: u32, n: i32) void;
extern "weft" fn wl_run_str(ptr: u32, len: u32, s: u32, sl: u32) void;
extern "weft" fn wl_run_str2(ptr: u32, len: u32, a: u32, al: u32, b: u32, bl: u32) void;
// Introspection (palettes/help/buffers pickers).
extern "weft" fn wl_command_count() u32;
extern "weft" fn wl_command_name(i: u32, out_ptr: u32, out_cap: u32) i32;
extern "weft" fn wl_command_summary(i: u32, out_ptr: u32, out_cap: u32) i32;
extern "weft" fn wl_buffer_count() u32;
extern "weft" fn wl_buffer_id(i: u32) i32;
extern "weft" fn wl_buffer_name(i: u32, out_ptr: u32, out_cap: u32) i32;
extern "weft" fn wl_buffer_active(i: u32) u32;
extern "weft" fn wl_buffer_readonly(i: u32) u32;
// Fuzzy pick (built incrementally, then opened; accept dispatches back to the
// guest's on_pick_accept export).
extern "weft" fn wl_pick_begin(prompt_ptr: u32, prompt_len: u32, pick_id: u32) void;
extern "weft" fn wl_pick_add(t: u32, tl: u32, d: u32, dl: u32) void;
extern "weft" fn wl_pick_end() void;
extern "weft" fn wl_open_file_pick(prompt_ptr: u32, prompt_len: u32, root_ptr: u32, root_len: u32, pick_id: u32) void;
extern "weft" fn wl_pick_choice(out_ptr: u32, out_cap: u32) i32;
extern "weft" fn wl_provide_completion() void;
extern "weft" fn wl_completion_prefix(out_ptr: u32, out_cap: u32) u32;
extern "weft" fn wl_push_completion(ptr: u32, len: u32) void;
// Structural (tree-sitter) read + subbuffers.
extern "weft" fn wl_node_at(offset: u32, kind_out: u32, kind_cap: u32, span_out: u32) i32;
extern "weft" fn wl_node_enclosing(start: u32, end: u32, kind_out: u32, kind_cap: u32, span_out: u32) i32;
extern "weft" fn wl_query(scm_ptr: u32, scm_len: u32, start: u32, end: u32) i32;
extern "weft" fn wl_query_capture(i: u32, name_out: u32, name_cap: u32, span_out: u32) i32;
extern "weft" fn wl_node_children(off: u32) i32;
extern "weft" fn wl_claim_subbuffer(start: u32, end: u32) i32;
extern "weft" fn wl_subbuffer_put_fact(handle: u32, k: u32, kl: u32, v: u32, vl: u32) void;
extern "weft" fn wl_shell_insert(ptr: u32, len: u32) void;

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

fn p(x: anytype) u32 {
    return @intCast(@intFromPtr(x));
}

pub const Range = struct { start: usize, end: usize };
pub const Level = enum(u32) { debug = 0, info = 1, warn = 2, err = 3 };
/// Mirrors abi.Perm's order (fs_read, fs_write, net, proc, timer).
pub const Perm = enum(u32) { fs_read = 0, fs_write = 1, net = 2, proc = 3, timer = 4 };

// ── Group A: core ────────────────────────────────────────────────────
pub fn log(level: Level, msg: []const u8) void {
    wl_log(@intFromEnum(level), p(msg.ptr), @intCast(msg.len));
}

// ── Describe phase: up-front declarations (no authority) ──────────────
pub fn declareCommand(name: []const u8) void {
    wl_declare_command(p(name.ptr), @intCast(name.len));
}
/// Declare a capability this plugin will provide (e.g. "edit/completion").
/// Cross-checked host-side against the matching `provide*` at init time.
pub fn declareCapability(name: []const u8) void {
    wl_declare_capability(p(name.ptr), @intCast(name.len));
}
pub fn requestPerm(perm: Perm) void {
    wl_request_perm(@intFromEnum(perm));
}

// ── Group B: read-only ───────────────────────────────────────────────
pub fn cursor() usize {
    return wl_cursor();
}
pub fn byteLen() usize {
    return wl_byte_len();
}
/// Bytes of `[start, end)` of the active document (clamped). Valid until the
/// next read call — copy to keep.
pub fn slice(start: usize, end: usize) []const u8 {
    const n = wl_slice(@intCast(start), @intCast(end), p(&scratch), scratch.len);
    return scratch[0..n];
}
/// `[start, end)` of the line containing `offset` (end before the newline).
pub fn lineAt(offset: usize) Range {
    var pair: [2]u32 = undefined;
    wl_line_at(@intCast(offset), p(&pair));
    return .{ .start = pair[0], .end = pair[1] };
}
/// The current selection range, or null.
pub fn selection() ?Range {
    var pair: [2]u32 = undefined;
    if (wl_selection(p(&pair)) == 0) return null;
    return .{ .start = pair[0], .end = pair[1] };
}
/// The active buffer's backing path, or null. Valid until the next read call.
pub fn path() ?[]const u8 {
    const n = wl_path(p(&scratch), scratch.len);
    if (n < 0) return null;
    return scratch[0..@intCast(n)];
}

// ── Group C: write (grade-gated host-side by the plugin's principal) ──
/// THE text-mutation door: replace `[r.start, r.end)` with `bytes`, authored
/// as this plugin's peer through the host's grade gate.
pub fn edit(r: Range, bytes: []const u8) void {
    wl_edit(@intCast(r.start), @intCast(r.end), p(bytes.ptr), @intCast(bytes.len));
}
/// Register a command (cross-checked against `describe`). Returns its id, the
/// value the host passes back to `on_command`.
pub fn register(name: []const u8) u32 {
    return wl_register(p(name.ptr), @intCast(name.len));
}
/// Place the live cursor at a byte offset (clamped).
pub fn jump(offset: usize) void {
    wl_jump(@intCast(offset));
}

// ── Native editor surface + stamped ranges (motions/operators) ────────
pub const Dir = enum(u32) { back = 0, fwd = 1 };
pub const Kind = enum(u32) { char = 0, line = 1 };

/// The target offset one char (grapheme) or line from `from` in `dir`, without
/// moving the cursor. The native primitive a motion composes (design §6.1).
pub fn step(from: usize, dir: Dir, kind: Kind) usize {
    return wl_editor_step(@intCast(from), @intFromEnum(dir), @intFromEnum(kind));
}
/// Select `[r.start, r.end)` (mark at start, cursor at end).
pub fn setSelection(r: Range) void {
    wl_set_selection(@intCast(r.start), @intCast(r.end));
}

/// Stamp `[r.start, r.end)` at the current version → an opaque range handle
/// (valid for this dispatch), or null on failure. The one way to build a range.
pub fn stampRange(r: Range) ?u32 {
    const h = wl_stamp_range(@intCast(r.start), @intCast(r.end));
    return if (h < 0) null else @intCast(h);
}
/// Return the stamped range `handle` as this command's result (the motion
/// contract): an operator awaiting it via `runRange` gets a version-stamped
/// range, never a bare offset.
pub fn setResultRange(handle: u32) void {
    wl_set_result_range(handle);
}
/// Run `cmd` (a motion) and take its returned range as an opaque handle, or
/// null if it produced none. The handle is valid for the rest of this dispatch.
pub fn runRange(cmd: []const u8) ?u32 {
    const h = wl_run_range(p(cmd.ptr), @intCast(cmd.len));
    return if (h < 0) null else @intCast(h);
}
/// Resolve a range handle to its current `[start, end)`, or null if stale.
pub fn rangeEnds(handle: u32) ?Range {
    var pair: [2]u32 = undefined;
    if (wl_range_ends(handle, p(&pair)) < 0) return null;
    return .{ .start = pair[0], .end = pair[1] };
}
/// Run `cmd` (an operator) passing a range `handle` as its single arg.
pub fn runRangeArg(cmd: []const u8, handle: u32) void {
    wl_run_range_arg(p(cmd.ptr), @intCast(cmd.len), handle);
}
/// The `i`-th arg as a stamped-range handle, or null if it is not a range.
pub fn argRange(i: usize) ?u32 {
    const h = wl_arg_range(@intCast(i));
    return if (h < 0) null else @intCast(h);
}
/// Replace the stamped range `handle` with `bytes`, authored as this plugin's
/// peer through the grade gate (rebased to head first).
pub fn editRange(handle: u32, bytes: []const u8) void {
    wl_edit_range(handle, p(bytes.ptr), @intCast(bytes.len));
}

// ── Group E: admin (kv) ──────────────────────────────────────────────
/// This plugin's value for `key` (namespaced host-side), or null. Valid until
/// the next read call.
pub fn kvGet(key: []const u8) ?[]const u8 {
    const n = wl_kv_get(p(key.ptr), @intCast(key.len), p(&scratch), scratch.len);
    if (n < 0) return null;
    return scratch[0..@intCast(n)];
}
pub fn kvPut(key: []const u8, value: []const u8) void {
    wl_kv_put(p(key.ptr), @intCast(key.len), p(value.ptr), @intCast(value.len));
}

/// Show a transient status-line message.
pub fn echo(msg: []const u8) void {
    wl_echo(p(msg.ptr), @intCast(msg.len));
}

// ── Command args & result (valid only during an `on_command` call) ────
// Integers cross as i32 — the membrane's word, the same width the offset ABI
// (cursor/edit/slice) already uses. Command Values wider than i32 are outside
// the sandbox contract (no catalog command passes one).

/// Number of args the command was invoked with.
pub fn argCount() usize {
    return wl_arg_count();
}
/// The `i`-th arg as an integer (0 if absent or not an integer).
pub fn argInt(i: usize) i32 {
    return wl_arg_int(@intCast(i));
}
/// The `i`-th arg as a string, or null if absent / not a string. Valid until
/// the next arg read (its own scratch — safe to hold across `slice`).
pub fn argStr(i: usize) ?[]const u8 {
    const n = wl_arg_str(@intCast(i), p(&arg_scratch), arg_scratch.len);
    if (n < 0) return null;
    return arg_scratch[0..@intCast(n)];
}
/// Set the command's integer return value.
pub fn setResultInt(n: i32) void {
    wl_set_result_int(n);
}
/// Set the command's string return value (copied host-side).
pub fn setResultStr(s: []const u8) void {
    wl_set_result_str(p(s.ptr), @intCast(s.len));
}

// ── Config surface (the local plane) ─────────────────────────────────
/// Bind `key` in keymap `mode` to `cmd` (late-bound; resolves at keypress).
pub fn bindKey(mode: []const u8, key: []const u8, cmd: []const u8) void {
    wl_bind_key(p(mode.ptr), @intCast(mode.len), p(key.ptr), @intCast(key.len), p(cmd.ptr), @intCast(cmd.len));
}
/// Switch the active keymap mode.
pub fn setMode(mode: []const u8) void {
    wl_set_mode(p(mode.ptr), @intCast(mode.len));
}
/// `mode` falls back to `parent` for unbound keys (mode inheritance).
pub fn setFallback(mode: []const u8, parent: []const u8) void {
    wl_set_fallback(p(mode.ptr), @intCast(mode.len), p(parent.ptr), @intCast(parent.len));
}
/// Set (or clear, with null) the command unbound printable input runs in
/// `mode` — the modal posture (normal mode swallows text).
pub fn textInput(mode: []const u8, cmd: ?[]const u8) void {
    if (cmd) |c| {
        wl_text_input(p(mode.ptr), @intCast(mode.len), p(c.ptr), @intCast(c.len), 1);
    } else {
        wl_text_input(p(mode.ptr), @intCast(mode.len), 0, 0, 0);
    }
}
/// Declare `mode` a menu/prefix mode (which-key shows its bindings).
pub fn menuMode(mode: []const u8) void {
    wl_menu_mode(p(mode.ptr), @intCast(mode.len));
}
/// Invoke a command by name (no args), late-bound.
pub fn run(cmd: []const u8) void {
    wl_run(p(cmd.ptr), @intCast(cmd.len));
}
/// Invoke `cmd` with a single integer arg (e.g. buffer-switch).
pub fn runInt(cmd: []const u8, n: i32) void {
    wl_run_int(p(cmd.ptr), @intCast(cmd.len), n);
}
/// Invoke `cmd` with a single string arg (e.g. open <path>).
pub fn runStr(cmd: []const u8, s: []const u8) void {
    wl_run_str(p(cmd.ptr), @intCast(cmd.len), p(s.ptr), @intCast(s.len));
}
/// Invoke `cmd` with two string args (e.g. set-cursor <mode> <style>).
pub fn runStr2(cmd: []const u8, a: []const u8, b: []const u8) void {
    wl_run_str2(p(cmd.ptr), @intCast(cmd.len), p(a.ptr), @intCast(a.len), p(b.ptr), @intCast(b.len));
}

// ── Introspection (palettes/help/buffers) ────────────────────────────
pub fn commandCount() usize {
    return wl_command_count();
}
/// The `i`-th command's name (into `scratch`), or null for an empty slot.
pub fn commandName(i: usize) ?[]const u8 {
    const n = wl_command_name(@intCast(i), p(&scratch), scratch.len);
    if (n < 0) return null;
    return scratch[0..@intCast(n)];
}
/// The `i`-th command's summary (into `arg_scratch`, so it survives a paired
/// `commandName` read), or null.
pub fn commandSummary(i: usize) ?[]const u8 {
    const n = wl_command_summary(@intCast(i), p(&arg_scratch), arg_scratch.len);
    if (n < 0) return null;
    return arg_scratch[0..@intCast(n)];
}
pub fn bufferCount() usize {
    return wl_buffer_count();
}
pub fn bufferId(i: usize) ?i32 {
    const id = wl_buffer_id(@intCast(i));
    return if (id < 0) null else id;
}
pub fn bufferName(i: usize) ?[]const u8 {
    const n = wl_buffer_name(@intCast(i), p(&scratch), scratch.len);
    if (n < 0) return null;
    return scratch[0..@intCast(n)];
}
pub fn bufferActive(i: usize) bool {
    return wl_buffer_active(@intCast(i)) != 0;
}
pub fn bufferReadOnly(i: usize) bool {
    return wl_buffer_readonly(@intCast(i)) != 0;
}

// ── Fuzzy pick (open one incrementally; accept → on_pick_accept) ──────
/// Begin a pick with `prompt`; `pick_id` is the guest's tag for its accept
/// logic (dispatched to `on_pick_accept`).
pub fn pickBegin(prompt: []const u8, pick_id: u32) void {
    wl_pick_begin(p(prompt.ptr), @intCast(prompt.len), pick_id);
}
/// Add one item: `text` matches/accepts, `doc` is display-only.
pub fn pickAdd(text: []const u8, doc: []const u8) void {
    wl_pick_add(p(text.ptr), @intCast(text.len), p(doc.ptr), @intCast(doc.len));
}
/// Open the accumulated pick.
pub fn pickEnd() void {
    wl_pick_end();
}
/// Open a fuzzy FILE picker rooted at `root` (native recursive finder);
/// accept dispatches to `on_pick_accept` with the chosen path.
pub fn openFilePick(prompt: []const u8, root: []const u8, pick_id: u32) void {
    wl_open_file_pick(p(prompt.ptr), @intCast(prompt.len), p(root.ptr), @intCast(root.len), pick_id);
}
/// The accepted choice (valid during `on_pick_accept`), into `scratch`.
pub fn pickChoice() []const u8 {
    const n = wl_pick_choice(p(&scratch), scratch.len);
    return scratch[0..@intCast(n)];
}

// ── Completion provider (the sel/completion domain) ──────────────────
// The host→guest data-gather membrane: the plugin registers a provider in
// `init` with `provideCompletion`, then the host calls the guest's exported
// `on_complete` per request; inside it the guest reads the query with
// `completionPrefix` and appends candidates with `pushCompletion`.

/// Register this plugin as an `edit/completion` provider (declared as the
/// matching capability). Read-only — results race + merge-rank with everyone
/// else's, exactly like the in-process provider.
pub fn provideCompletion() void {
    wl_provide_completion();
}
/// The current completion request's query prefix (valid for the duration of
/// `on_complete`). Its own scratch — safe to hold while calling `slice`.
pub fn completionPrefix() []const u8 {
    const n = wl_completion_prefix(p(&prefix_scratch), prefix_scratch.len);
    return prefix_scratch[0..n];
}
/// Offer `text` as a completion candidate for the current request.
pub fn pushCompletion(text: []const u8) void {
    wl_push_completion(p(text.ptr), @intCast(text.len));
}

// ── Structural read + subbuffers ─────────────────────────────────────
pub const Node = struct { kind: []const u8, start: usize, end: usize };

/// The smallest named tree-sitter node covering `offset` (kind + span), or
/// null when the buffer has no grammar / no node. Kind is in `scratch`.
pub fn nodeAt(offset: usize) ?Node {
    var span: [2]u32 = undefined;
    const n = wl_node_at(@intCast(offset), p(&scratch), scratch.len, p(&span));
    if (n < 0) return null;
    return .{ .kind = scratch[0..@intCast(n)], .start = span[0], .end = span[1] };
}

/// The smallest named tree-sitter node STRICTLY enclosing `[r.start, r.end)`
/// — repeat to grow a selection to the next scope. Kind is in `scratch`.
pub fn nodeEnclosing(r: Range) ?Node {
    var span: [2]u32 = undefined;
    const n = wl_node_enclosing(@intCast(r.start), @intCast(r.end), p(&scratch), scratch.len, p(&span));
    if (n < 0) return null;
    return .{ .kind = scratch[0..@intCast(n)], .start = span[0], .end = span[1] };
}

pub const Capture = struct { name: []const u8, start: usize, end: usize };
/// Run a tree-sitter query (`.scm`) over `[r.start, r.end)`; returns the
/// capture count, read back with `queryCapture(i)`. 0 if no grammar/error.
pub fn query(scm: []const u8, r: Range) usize {
    const n = wl_query(p(scm.ptr), @intCast(scm.len), @intCast(r.start), @intCast(r.end));
    return if (n < 0) 0 else @intCast(n);
}
/// The `i`-th capture of the last `query`/`nodeChildren` (name/kind into
/// `scratch`), or null.
pub fn queryCapture(i: usize) ?Capture {
    var span: [2]u32 = undefined;
    const n = wl_query_capture(@intCast(i), p(&scratch), scratch.len, p(&span));
    if (n < 0) return null;
    return .{ .name = scratch[0..@intCast(n)], .start = span[0], .end = span[1] };
}
/// The named children of the smallest node at `off` (structural descent);
/// returns the count, read back with `queryCapture(i)`. 0 if none/no grammar.
pub fn nodeChildren(off: usize) usize {
    const n = wl_node_children(@intCast(off));
    return if (n < 0) 0 else @intCast(n);
}

/// Claim `[start, end)` as a subbuffer (an anchored range with its own facts)
/// on the active document. Returns an opaque handle, or null if unavailable.
pub fn claimSubbuffer(start: usize, end: usize) ?u32 {
    const h = wl_claim_subbuffer(@intCast(start), @intCast(end));
    return if (h < 0) null else @intCast(h);
}
/// Attach a fact (`key` = `value`) to a claimed subbuffer.
pub fn subbufferPutFact(handle: u32, key: []const u8, value: []const u8) void {
    wl_subbuffer_put_fact(handle, p(key.ptr), @intCast(key.len), p(value.ptr), @intCast(value.len));
}

// ── Effects (perm-gated) ─────────────────────────────────────────────
/// Run `cmd` in a shell off the frame thread; insert its stdout at the cursor
/// when it finishes, rebased. Perms: proc + timer (declared in `describe`).
pub fn shellInsert(cmd: []const u8) void {
    wl_shell_insert(p(cmd.ptr), @intCast(cmd.len));
}
