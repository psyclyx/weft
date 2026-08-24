//! dired — a directory editor given the "magit treatment": a MODEL rendered into
//! a foldable, read-only `*dired*` buffer, a `.wasm` plugin over `proc` + its own
//! keymap mode. One gather command (`ls -l` for the root + every EXPANDED dir,
//! each block sentinel-marked with its path) runs via `procToBuffer`; the raw
//! output lands in the buffer, the host fires `on_fill`, and we PARSE it into a
//! directory TREE then RE-RENDER that tree as pretty, colored, foldable text over
//! the same buffer (`edit` + `styleClear`/`style` + `foldClear`/`fold`). Because
//! only we ever write the buffer, the parallel node table (each Entry's
//! `[start,end)` byte range) is never stale — "the entry under point" is the
//! Entry whose range contains `weft.cursor()`, the pattern `git.zig`/`consult.zig`
//! use.
//!
//! Directories expand INLINE: expanding a dir gathers its children and splices
//! them into the model at depth+1 right under the node (a real tree). Expand
//! state (and a collapsed-but-gathered "folded" posture) and marks PERSIST across
//! refreshes by path, in bounded sets. Every file operation (mkdir/rename/copy/
//! delete/shell) shells out via `proc` then re-gathers in ONE shell command so
//! the buffer reflects the result (the `stageThenRefresh` discipline); delete is
//! gated behind a y/n confirm. The locus routing survives: `dired` lists local
//! (`ls` via proc → the rich tree), `dired-peer` lists a peer's shared root flat
//! via `fsListAsync` (the old behavior — no proc reaches a remote fs).
//!
//! An editable posture (mini.files) overlays this: `dired-edit` snapshots the
//! tree and re-renders `*dired*` as a simple editable projection; the user renames/
//! creates/deletes/moves by editing lines; `dired-reconcile` diffs the edited text
//! against the snapshot and PRINTS the inferred ops into `*dired-plan*`. This first
//! cut is a DRY RUN — it computes + previews only, NEVER executing a file op (that,
//! behind a confirm, is a deliberately-separate later pass).
//!
//! perms `{proc, timer, fs_read, fs_write}` — proc runs `ls`/the ops, fs_read for
//! the peer listing, fs_write is unused today but reserved for temp-file ops.

const std = @import("std");
const weft = @import("weft");

// ── Caps (freestanding: no allocator, bounded static state; degrade loud) ──
const MAX_ENTRIES = 1024; // visible tree nodes
const MAX_EXPANDED = 256; // gathered dir paths (children fetched)
const MAX_FOLDED = 256; // collapsed-but-gathered dirs (hidden, not re-fetched)
const MAX_MARKED = 256; // marked paths (op targets)
const MAX_BLOCKS = MAX_EXPANDED + 2; // one ls block per gathered dir (+ root)
const NAME_CAP = 256;
const PATH_CAP = 512;
const RAW_CAP = 1 << 18; // 256 KiB of raw ls output (paged in via `slice`)
const RENDER_CAP = 1 << 18; // the pretty projection
const CMD_CAP = 1 << 16; // the composed gather / mutation shell command
const DEPTH_CAP = 32; // guard the parse recursion (nested expands)

const dired_buf = "*dired*";
const input_buf = "*dired-input*";
/// The dry-run reconcile PREVIEW target (mini.files-style editable buffer). We
/// only ever COMPUTE + PRINT the inferred file ops here — nothing is executed
/// (execution + confirmation is a deliberately-separate later pass).
const plan_buf = "*dired-plan*";
/// The gather sentinel: `printf` emits `\x1e\x1e<dirpath>\n` before each dir's
/// `ls` block, so we can split the combined output and key each block to its dir.
/// We repaint from the parse, so the markers never reach the user's eyes.
const MARK = "\x1e\x1e";

/// The directory currently listed (the tree root; entry paths are cwd-relative,
/// so shell ops and the next `ls` run against them directly).
var cwd_buf: [PATH_CAP]u8 = undefined;
var cwd_len: usize = 0;
/// Locus: local ("here", the rich proc tree) vs the connected peer's shared root
/// (flat `fsListAsync`, the old behavior — a proc can't reach a remote fs).
var peer_mode: bool = false;
/// Show dotfiles (`ls -lA` vs `ls -l`) — a global toggle affecting the gather.
var show_hidden: bool = false;

fn cwd() []const u8 {
    return cwd_buf[0..cwd_len];
}
fn setCwd(path: []const u8) void {
    cwd_len = @min(path.len, cwd_buf.len);
    @memcpy(cwd_buf[0..cwd_len], path[0..cwd_len]);
}

// ── The model ───────────────────────────────────────────────────────────────
const Kind = enum(u8) { dir, file, exe, symlink };

const Entry = struct {
    name: [NAME_CAP]u8 = undefined,
    nlen: usize = 0,
    /// Full path, cwd-relative (what ops and the next `ls` name).
    path: [PATH_CAP]u8 = undefined,
    plen: usize = 0,
    /// A symlink's target (`ls -l` "name -> target"), display-only.
    link: [PATH_CAP]u8 = undefined,
    llen: usize = 0,
    kind: Kind = .file,
    depth: usize = 0,
    // Rich `ls -l` columns (empty when a listing lacked them).
    perms: [12]u8 = undefined,
    permslen: usize = 0,
    size: [16]u8 = undefined,
    sizelen: usize = 0,
    date: [24]u8 = undefined,
    datelen: usize = 0,
    marked: bool = false,
    // Rendered byte ranges (recorded each render): the whole line `[r_start,r_end)`
    // (r_end == the next line's start), the offset the name begins at (so styling
    // colors just the name), and `body` == just past this line (a dir's fold start).
    r_start: usize = 0,
    r_end: usize = 0,
    name_r: usize = 0,
    body: usize = 0,
    fn pathS(self: *const Entry) []const u8 {
        return self.path[0..self.plen];
    }
    fn nameS(self: *const Entry) []const u8 {
        return self.name[0..self.nlen];
    }
};

var entries: [MAX_ENTRIES]Entry = undefined;
var entry_count: usize = 0;

var raw: [RAW_CAP]u8 = undefined;
var raw_len: usize = 0;
var render_buf: [RENDER_CAP]u8 = undefined;
var out: usize = 0;
var cmd_buf: [CMD_CAP]u8 = undefined;
/// Scratch for building a mutation string before it's chained with the gather.
var op_buf: [1 << 14]u8 = undefined;

// ── Bounded path sets (expand / fold / mark state; persist across gathers) ──
fn PathSet(comptime N: usize) type {
    return struct {
        const Self = @This();
        paths: [N][PATH_CAP]u8 = undefined,
        lens: [N]usize = undefined,
        count: usize = 0,
        overflow: bool = false,
        fn index(self: *const Self, pth: []const u8) ?usize {
            var i: usize = 0;
            while (i < self.count) : (i += 1) {
                if (std.mem.eql(u8, self.paths[i][0..self.lens[i]], pth)) return i;
            }
            return null;
        }
        fn has(self: *const Self, pth: []const u8) bool {
            return self.index(pth) != null;
        }
        /// Add `pth` (idempotent). Returns false + flags overflow if the set is
        /// full — degrade loud, never silently drop.
        fn add(self: *Self, pth: []const u8) bool {
            if (self.index(pth) != null) return true;
            if (self.count >= N) {
                self.overflow = true;
                return false;
            }
            const n = @min(pth.len, PATH_CAP);
            @memcpy(self.paths[self.count][0..n], pth[0..n]);
            self.lens[self.count] = n;
            self.count += 1;
            return true;
        }
        fn remove(self: *Self, pth: []const u8) void {
            const i = self.index(pth) orelse return;
            self.count -= 1; // swap-remove (order doesn't matter)
            self.paths[i] = self.paths[self.count];
            self.lens[i] = self.lens[self.count];
        }
        fn clear(self: *Self) void {
            self.count = 0;
            self.overflow = false;
        }
    };
}

var expanded: PathSet(MAX_EXPANDED) = .{};
var folded: PathSet(MAX_FOLDED) = .{};
var marked: PathSet(MAX_MARKED) = .{};

// ── Cursor restoration across a re-gather: capture the path of the node under
// point before a mutation and re-find it in the fresh model (so point tracks the
// entry even when it moved), else the clamped offset, else home. ──
var restore_cursor = false;
var pending_cursor: usize = 0;
var home_off: usize = 0;
var restore_path: [PATH_CAP]u8 = undefined;
var restore_plen: usize = 0;

var dropped_entries = false;
var truncated_raw = false;
var truncated_cmd = false;

// ── The `*dired-input*` single-line prompt (mkdir/rename/copy/shell) ─────────
const InputAction = enum(u8) { none, mkdir, rename, copy, shell };
var input_action: InputAction = .none;
/// Source captured BEFORE the prompt opens (rename/copy) — the input buffer is a
/// different buffer, so `nodeAt(cursor)` no longer resolves the dired target.
var op_src: [PATH_CAP]u8 = undefined;
var op_src_len: usize = 0;
/// Pre-quoted ` 'f1' 'f2' …` target suffix captured for the shell (`!`) verb.
var op_args: [1 << 12]u8 = undefined;
var op_args_len: usize = 0;
/// The command staged behind the y/n `dired-confirm` menu (a delete, or a whole
/// reconcile plan). `commit_pending` distinguishes a save-reconcile confirm (No
/// returns to editing) from a delete confirm (No returns to the view).
var confirm_cmd: [CMD_CAP]u8 = undefined;
var confirm_len: usize = 0;
var commit_pending: bool = false;

// ── Editable-buffer file management (mini.files) ─────────────────────────────
// The *dired* buffer is ALWAYS an editable name tree (metadata is decoration).
// You rename/create/delete/move by editing it; `save` (dired-commit) diffs the
// edited text against a SNAPSHOT of the gathered tree — matching by hidden id —
// and applies the inferred ops behind a confirm.

/// A snapshot row: the original tree entry we diff the edited buffer against.
/// Identity in this first cut is heuristic (path + position/parent); precise
/// identity via hidden per-line ids is deferred to the execution pass.
const Snap = struct {
    path: [PATH_CAP]u8 = undefined,
    plen: usize = 0,
    is_dir: bool = false,
    depth: usize = 0,
    matched: bool = false, // consumed by an edited line (unchanged/rename/move)
    deleted: bool = false, // no surviving edited line ⇒ inferred DELETE
    fn pathS(self: *const Snap) []const u8 {
        return self.path[0..self.plen];
    }
};
var snap: [MAX_ENTRIES]Snap = undefined;
var snap_count: usize = 0;

/// The inferred category of an edited line after the diff.
const EditCat = enum(u8) { unchanged, rename_to, move_to, create, copy };
/// One parsed line of the edited buffer (indent→depth, name→path, trailing `/`).
const EditLine = struct {
    path: [PATH_CAP]u8 = undefined,
    plen: usize = 0,
    is_dir: bool = false,
    depth: usize = 0,
    matched: bool = false,
    cat: EditCat = .unchanged,
    partner: usize = 0, // snap index for rename_to/move_to/copy
    /// The hidden id read off this row's id-span: the ORIGINAL path of the entry
    /// it came from (survives rename via anchor rebase, survives dd→p via the
    /// register ferry). Empty ⇒ a typed/new line with no identity ⇒ a create.
    oid: [PATH_CAP]u8 = undefined,
    oidlen: usize = 0,
    fn pathS(self: *const EditLine) []const u8 {
        return self.path[0..self.plen];
    }
};
var elines: [MAX_ENTRIES]EditLine = undefined;
var el_count: usize = 0;
var el_overflow: bool = false;

// Indent→parent-chain reconstruction scratch (module-level: DEPTH_CAP×PATH_CAP
// would blow the wasm stack as a local). `ep_path[d]` is the last line seen at
// depth d — a depth-(d+1) child hangs off it.
var ep_path: [DEPTH_CAP][PATH_CAP]u8 = undefined;
var ep_len: [DEPTH_CAP]usize = undefined;
var ep_have: [DEPTH_CAP]bool = undefined;

// ── Commands ──────────────────────────────────────────────────────────────
const Cmd = struct { name: []const u8, handler: *const fn () void };
const cmds = [_]Cmd{
    .{ .name = "dired", .handler = openLocal },
    .{ .name = "dired-peer", .handler = openPeer },
    .{ .name = "dired-refresh", .handler = refresh },
    .{ .name = "dired-up", .handler = up },
    .{ .name = "dired-open", .handler = openEntry },
    .{ .name = "dired-toggle-fold", .handler = toggleFold },
    .{ .name = "dired-toggle-hidden", .handler = toggleHidden },
    // Marks.
    .{ .name = "dired-mark", .handler = mark },
    .{ .name = "dired-unmark", .handler = unmark },
    .{ .name = "dired-unmark-all", .handler = unmarkAll },
    .{ .name = "dired-toggle-marks", .handler = toggleMarks },
    // File operations.
    .{ .name = "dired-mkdir", .handler = diredMkdir },
    .{ .name = "dired-rename", .handler = diredRename },
    .{ .name = "dired-copy", .handler = diredCopy },
    .{ .name = "dired-delete", .handler = diredDelete },
    .{ .name = "dired-shell", .handler = diredShell },
    // The *dired* buffer is ALWAYS an editable name tree; SAVING it (`:w`/C-s,
    // via the `save` action scoped to this tool projection) reconciles the edits
    // against the gather snapshot and APPLIES the file ops behind a confirm.
    .{ .name = "dired-commit", .handler = diredCommit },
    // The input prompt + the delete confirm.
    .{ .name = "dired-input-finish", .handler = inputFinish },
    .{ .name = "dired-input-abort", .handler = inputAbort },
    .{ .name = "dired-input-resume", .handler = inputResume },
    .{ .name = "dired-confirm-yes", .handler = confirmYes },
    .{ .name = "dired-confirm-no", .handler = confirmNo },
    // Internal: the deferred half of `noteDrops` (task #19 item 4) — not a
    // user-facing verb, invoked only via `weft.run` from `on_fill`.
    .{ .name = "dired-note-drops-deliver", .handler = diredNoteDropsDeliver },
};

export fn describe() void {
    for (cmds) |c| weft.declareCommand(c.name);
    weft.requestPerm(.proc);
    weft.requestPerm(.timer);
    weft.requestPerm(.fs_read);
    weft.requestPerm(.fs_write);
}
export fn init() void {
    for (cmds) |c| _ = weft.register(c.name);
    // dired is ONE always-editable buffer: its text is the name tree, metadata
    // is decoration. It FALLS BACK to vim `normal`, so you rename by editing a
    // name, create with `o`, delete with `dd`, move with `dd`+`p` (the register
    // ferries the row's hidden id) — all in place — and `:w` reconciles. Only a
    // few view keys override vim: fold-aware j/k, Tab (fold), Return (open dir/
    // file), g (refresh), q (back). (After an insert, vim's Escape lands in plain
    // `normal`, so the override keys sleep until you re-enter dired — but `:w`
    // still saves, because the reconcile is scoped to the tool identity, not a
    // mode.)
    weft.setFallback("dired", "normal");
    weft.restingMode("dired"); // *dired* rests in dired, not the normal it falls back to
    weft.bindKey("dired", "j", "cursor-down"); // fold-aware in core
    weft.bindKey("dired", "k", "cursor-up");
    weft.bindKey("dired", "Down", "cursor-down");
    weft.bindKey("dired", "Up", "cursor-up");
    weft.bindKey("dired", "Tab", "dired-toggle-fold");
    weft.bindKey("dired", "Return", "dired-open");
    weft.bindKey("dired", "g", "dired-refresh");
    weft.bindKey("dired", "q", "buffer-back");
    // Saving the projection reconciles it: `save` is an ACTION, provided here for
    // THIS tool projection, so `:w`/C-s resolve to `dired-commit` in a *dired*
    // buffer (in any mode). No core knows dired; the file-write default handles
    // every other buffer.
    weft.declareAction("save");
    weft.provide("save", .{ .tool = "dired" }, "dired-commit", 10);

    // The prompt buffer is EDITABLE: fall back to `default` for text + editing,
    // then a C-c prefix (finish/abort/resume) — the git-input shape.
    weft.setFallback("dired-input", "default");
    weft.bindKey("dired-input", "C-c", "dired-input-menu");
    weft.menuMode("dired-input-menu");
    weft.bindKey("dired-input-menu", "C-c", "dired-input-finish");
    weft.bindKey("dired-input-menu", "C-k", "dired-input-abort");
    weft.bindKey("dired-input-menu", "Escape", "dired-input-resume");
    weft.bindKey("dired-input-menu", "C-g", "dired-input-resume");

    // Delete confirm: a tiny menu mode — y deletes, n/Escape backs out.
    weft.menuMode("dired-confirm");
    weft.bindKey("dired-confirm", "y", "dired-confirm-yes");
    weft.bindKey("dired-confirm", "n", "dired-confirm-no");
    weft.bindKey("dired-confirm", "Escape", "dired-confirm-no");
    weft.bindKey("dired-confirm", "C-g", "dired-confirm-no");
}
export fn on_command(id: u32) void {
    if (id < cmds.len) cmds[id].handler();
}

// ── on_fill: the async ls output landed → parse the tree + render + publish ──
export fn on_fill() void {
    // Peer listings are the flat `fsListAsync` text (delivered by the peer fs
    // bridge, which doesn't route through this hook anyway) — leave them as-is;
    // peer navigation reads the raw lines. Only the local proc tree re-renders.
    if (peer_mode) return;
    if (!std.mem.eql(u8, activeName(), dired_buf)) return;
    loadRaw();
    parse();
    render();
    // The projection is authored FIRST; styles/decorations/folds/ids then index
    // the new bytes. The buffer stays EDITABLE (no read-only, no separate edit
    // posture); saving it reconciles (dired-commit via the `save` action). Mark
    // it this plugin's tool projection and snapshot the tree for that reconcile.
    weft.edit(.{ .start = 0, .end = weft.byteLen() }, render_buf[0..out]);
    publishStyles();
    publishDecorations();
    publishFolds();
    claimIds();
    snapshot();
    weft.toolBacking("dired");
    const target = if (restore_cursor)
        (findRestoreOffset() orelse @min(pending_cursor, out))
    else
        home_off;
    weft.jump(weft.lineAt(target).start);
    restore_cursor = false;
    noteDrops();
}

var name_buf: [256]u8 = undefined;
fn activeName() []const u8 {
    const count = weft.bufferCount();
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (!weft.bufferActive(i)) continue;
        const bn = weft.bufferName(i) orelse return "";
        const n = @min(bn.len, name_buf.len);
        @memcpy(name_buf[0..n], bn[0..n]);
        return name_buf[0..n];
    }
    return "";
}

/// `noteDrops` is only ever reached from `on_fill` (BACKGROUND — its sole
/// call site, at the tail of that export above). `weft.echo` is head-gated
/// (task #19 item 4), so the actual echoes defer through a self-registered
/// command — a nested `weft.run` from a background entry IS a dispatching
/// entry for its duration (same door `src/guest/git.zig`'s `noteDrops` and
/// `src/guest/lsp.zig`'s async responses use).
fn noteDrops() void {
    if (dropped_entries or truncated_raw or truncated_cmd or expanded.overflow or marked.overflow)
        weft.run("dired-note-drops-deliver");
}

fn diredNoteDropsDeliver() void {
    if (dropped_entries) weft.echo("dired: >1024 entries — some omitted");
    if (truncated_raw) weft.echo("dired: ls output > 256 KiB — truncated");
    if (truncated_cmd) weft.echo("dired: too many expanded dirs — gather truncated");
    if (expanded.overflow) weft.echo("dired: >256 expanded dirs — this won't persist");
    if (marked.overflow) weft.echo("dired: >256 marks — this one won't stick");
}

/// Page the buffer's raw bytes into `raw` (a read clamps to the 64 KiB scratch,
/// so window it). Cap at RAW_CAP and note truncation — no silent drop.
fn loadRaw() void {
    const total = weft.byteLen();
    raw_len = 0;
    truncated_raw = false;
    while (raw_len < total and raw_len < RAW_CAP) {
        const chunk = weft.slice(raw_len, total);
        if (chunk.len == 0) break;
        const n = @min(chunk.len, RAW_CAP - raw_len);
        @memcpy(raw[raw_len .. raw_len + n], chunk[0..n]);
        raw_len += n;
        if (n < chunk.len) break;
    }
    if (total > RAW_CAP) truncated_raw = true;
}

// ── Gather: one shell command, `ls -l` for the root + every expanded dir ─────
/// Append a `printf '\x1e\x1e<dir>\n'; ls … -- '<dir>'` block for `dir`. The
/// printf marker lets `parse` split the combined output and key each block to
/// its dir; `%s` takes `dir` as an ARG (so `%`/specials in the path are inert).
fn emitBlock(w: usize, flags: []const u8, dir: []const u8) usize {
    const seg = std.fmt.bufPrint(
        cmd_buf[w..],
        "printf '\\036\\036%s\\n' '{s}'; ls {s} --time-style=long-iso -- '{s}' 2>/dev/null; ",
        .{ dir, flags, dir },
    ) catch {
        truncated_cmd = true;
        return w;
    };
    return w + seg.len;
}
/// Build the whole gather into `cmd_buf` starting at `w0`: the root, then every
/// gathered (expanded) dir. Returns the new write offset.
fn emitGather(w0: usize) usize {
    truncated_cmd = false;
    const flags: []const u8 = if (show_hidden) "-lA" else "-l";
    var w = emitBlock(w0, flags, cwd());
    var i: usize = 0;
    while (i < expanded.count) : (i += 1) {
        w = emitBlock(w, flags, expanded.paths[i][0..expanded.lens[i]]);
    }
    return w;
}

/// Focus the reused tool buffer (create if absent — `buffer-create` doesn't
/// dedupe by name), then fill it with `cmd`'s output. `on_fill` renders it.
fn show(cmd: []const u8) void {
    if (!focusBuffer(dired_buf)) weft.runStr("buffer-create", dired_buf);
    weft.procToBuffer(cmd, dired_buf);
}

fn focusBuffer(name: []const u8) bool {
    const count = weft.bufferCount();
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const bn = weft.bufferName(i) orelse continue;
        if (std.mem.eql(u8, bn, name)) {
            const id = weft.bufferId(i) orelse return false;
            weft.runInt("buffer-switch", id);
            return true;
        }
    }
    return false;
}

/// Re-gather the local tree (root + expanded dirs) into `*dired*`. `restore`
/// keeps point on the node it was on across the async re-render.
fn regather(restore: bool) void {
    if (restore) markRestore() else restore_cursor = false;
    const w = emitGather(0);
    show(cmd_buf[0..w]);
    weft.setMode("dired");
}

/// `mutation >/dev/null 2>&1; <gather>` in ONE shell command — the op runs, its
/// stdout is swallowed (so only the gather output reaches the buffer), then we
/// ALWAYS re-gather so the tree reflects the real post-op state. Expand state
/// persists (the gather derives from the `expanded` set).
fn gatherAfter(mutation: []const u8) void {
    markRestore();
    var w: usize = 0;
    const pre = std.fmt.bufPrint(cmd_buf[w..], "{s} >/dev/null 2>&1; ", .{mutation}) catch return;
    w += pre.len;
    w = emitGather(w);
    show(cmd_buf[0..w]);
    weft.setMode("dired");
}

fn markRestore() void {
    restore_cursor = true;
    pending_cursor = weft.cursor();
    restore_plen = 0;
    // Only meaningful when point is in the dired buffer (not the input prompt).
    if (!std.mem.eql(u8, activeName(), dired_buf)) return;
    const n = nodeAt(weft.cursor());
    if (n) |i| {
        restore_plen = @min(entries[i].plen, restore_path.len);
        @memcpy(restore_path[0..restore_plen], entries[i].path[0..restore_plen]);
    }
}
fn findRestoreOffset() ?usize {
    if (restore_plen == 0) return null;
    const want = restore_path[0..restore_plen];
    var i: usize = 0;
    while (i < entry_count) : (i += 1) {
        if (std.mem.eql(u8, entries[i].pathS(), want)) return entries[i].r_start;
    }
    return null;
}

// ── Parse: the marked `ls -l` blocks → a flat, tree-ordered Entry list ───────
const Block = struct { dir: []const u8, start: usize, end: usize };
var blocks: [MAX_BLOCKS]Block = undefined;
var block_count: usize = 0;

fn parse() void {
    entry_count = 0;
    dropped_entries = false;
    findBlocks();
    buildTree(cwd(), 0);
    // Re-apply the persisted marks (entries rebuild each gather).
    var i: usize = 0;
    while (i < entry_count) : (i += 1) entries[i].marked = marked.has(entries[i].pathS());
}

/// Index the `ls` blocks: a line beginning with MARK opens a block whose dir is
/// the rest of that line; its body runs to the next MARK (or end).
fn findBlocks() void {
    block_count = 0;
    var i: usize = 0;
    while (i < raw_len) {
        var le = i;
        while (le < raw_len and raw[le] != '\n') le += 1;
        if (std.mem.startsWith(u8, raw[i..le], MARK)) {
            if (block_count > 0) blocks[block_count - 1].end = i;
            if (block_count < MAX_BLOCKS) {
                blocks[block_count] = .{
                    .dir = raw[i + MARK.len .. le],
                    .start = @min(le + 1, raw_len),
                    .end = raw_len,
                };
                block_count += 1;
            }
        }
        i = le + 1;
    }
}
fn findBlock(dir: []const u8) ?*const Block {
    var i: usize = 0;
    while (i < block_count) : (i += 1) {
        if (std.mem.eql(u8, blocks[i].dir, dir)) return &blocks[i];
    }
    return null;
}

/// List `dir`'s block at `depth`, appending each child; recurse into a child dir
/// that's expanded (its children come from its own block) — depth-first, so the
/// flat list is in tree/display order. Bounded by DEPTH_CAP.
fn buildTree(dir: []const u8, depth: usize) void {
    if (depth >= DEPTH_CAP) return;
    const blk = findBlock(dir) orelse return;
    var i = blk.start;
    while (i < blk.end) {
        var le = i;
        while (le < blk.end and raw[le] != '\n') le += 1;
        const idx = parseLsLine(raw[i..le], dir, depth);
        i = le + 1;
        const ei = idx orelse continue;
        if (entries[ei].kind == .dir and expanded.has(entries[ei].pathS())) {
            buildTree(entries[ei].pathS(), depth + 1);
        }
    }
}

/// Parse one `ls -l --time-style=long-iso` line into an Entry appended to the
/// model; returns its index, or null for a skipped line (`total …`, `.`/`..`,
/// unparseable). Fields: perms links owner group size date time name…
fn parseLsLine(line: []const u8, dir: []const u8, depth: usize) ?usize {
    if (line.len == 0) return null;
    if (std.mem.startsWith(u8, line, "total ")) return null;
    const perms = tokenAt(line, 0) orelse return null;
    if (perms.len == 0) return null;
    var name = restFrom(line, 7);
    if (name.len == 0) return null;
    // A symlink line reads "name -> target"; split off the target for display.
    var link: []const u8 = "";
    if (perms[0] == 'l') {
        if (std.mem.indexOf(u8, name, " -> ")) |ai| {
            link = name[ai + 4 ..];
            name = name[0..ai];
        }
    }
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return null;

    const kind: Kind = switch (perms[0]) {
        'd' => .dir,
        'l' => .symlink,
        else => if (std.mem.indexOfScalar(u8, perms[1..], 'x') != null) .exe else .file,
    };
    if (entry_count >= MAX_ENTRIES) {
        dropped_entries = true;
        return null;
    }
    var e = &entries[entry_count];
    e.* = .{ .kind = kind, .depth = depth };
    e.nlen = copyInto(&e.name, name);
    e.llen = copyInto(&e.link, link);
    e.plen = joinPath(&e.path, dir, name);
    e.permslen = copyInto(&e.perms, perms);
    if (tokenAt(line, 4)) |sz| e.sizelen = copyInto(&e.size, sz);
    // date + time (tokens 5,6) → one "YYYY-MM-DD HH:MM" column.
    if (tokenAt(line, 5)) |d| {
        e.datelen = copyInto(&e.date, d);
        if (tokenAt(line, 6)) |tm| {
            if (e.datelen + 1 + tm.len <= e.date.len) {
                e.date[e.datelen] = ' ';
                @memcpy(e.date[e.datelen + 1 ..][0..tm.len], tm);
                e.datelen += 1 + tm.len;
            }
        }
    }
    entry_count += 1;
    return entry_count - 1;
}

fn copyInto(dst: anytype, src: []const u8) usize {
    const n = @min(src.len, dst.len);
    @memcpy(dst[0..n], src[0..n]);
    return n;
}
fn joinPath(dst: []u8, dir: []const u8, name: []const u8) usize {
    if (std.mem.eql(u8, dir, ".")) return copyInto(dst, name);
    const s = std.fmt.bufPrint(dst, "{s}/{s}", .{ dir, name }) catch return copyInto(dst, name);
    return s.len;
}

// Whitespace-delimited token helpers over an `ls -l` line.
fn tokenAt(line: []const u8, n: usize) ?[]const u8 {
    var i: usize = 0;
    var k: usize = 0;
    while (true) {
        while (i < line.len and line[i] == ' ') i += 1;
        if (i >= line.len) return null;
        const s = i;
        while (i < line.len and line[i] != ' ') i += 1;
        if (k == n) return line[s..i];
        k += 1;
    }
}
/// Everything from the start of the `n`-th token to end-of-line (the name, which
/// may contain spaces), leading whitespace trimmed.
fn restFrom(line: []const u8, n: usize) []const u8 {
    var i: usize = 0;
    var k: usize = 0;
    while (k < n) : (k += 1) {
        while (i < line.len and line[i] == ' ') i += 1;
        while (i < line.len and line[i] != ' ') i += 1;
    }
    while (i < line.len and line[i] == ' ') i += 1;
    return std.mem.trimEnd(u8, line[i..], " \t\r");
}

// ── Render: the tree → pretty, foldable text (offsets recorded into nodes) ──
fn put(bytes: []const u8) void {
    const n = @min(bytes.len, render_buf.len - out);
    @memcpy(render_buf[out .. out + n], bytes[0..n]);
    out += n;
}
fn putPad(s: []const u8, width: usize) void {
    if (s.len < width) {
        var k = width - s.len;
        while (k > 0) : (k -= 1) put(" ");
    }
    put(s);
}

/// A dir is visually OPEN (▾, children shown) iff its children are gathered AND
/// it's not folded; otherwise it's collapsed (▸).
fn isOpen(e: *const Entry) bool {
    return e.kind == .dir and expanded.has(e.pathS()) and !folded.has(e.pathS());
}

/// The buffer's TEXT is only the editable name tree: `<indent><name>[/]`. All
/// chrome — the fold arrow, mark, perms/size — is DECORATION (publishDecorations),
/// never document bytes, so `yy` yanks exactly the name (+indent) and reconcile
/// parses trivially. One always-editable render; no separate view/edit posture.
fn render() void {
    out = 0;
    home_off = 0;
    var i: usize = 0;
    while (i < entry_count) : (i += 1) {
        var e = &entries[i];
        e.r_start = out;
        var d: usize = 0;
        while (d < e.depth) : (d += 1) put("  ");
        e.name_r = out;
        put(e.nameS());
        if (e.kind == .dir) put("/");
        put("\n");
        e.body = out;
        e.r_end = out;
        if (home_off == 0) home_off = e.r_start;
    }
}

/// The metadata chrome, drawn BESIDE each name as a `virtual_before` decoration
/// (dimmed): fold arrow (dirs), mark, and — when the listing had them — perms +
/// size. Never in the text, so editing/yank/reconcile see only the name. Anchored
/// at the name start; rebases as the name is edited.
fn publishDecorations() void {
    weft.decorateClear();
    var i: usize = 0;
    while (i < entry_count) : (i += 1) {
        const e = &entries[i];
        const arrow = if (e.kind == .dir) (if (isOpen(e)) "\xe2\x96\xbe" else "\xe2\x96\xb8") else " ";
        const mk = if (e.marked) "*" else " ";
        var buf: [96]u8 = undefined;
        const msg = if (e.permslen > 0)
            (std.fmt.bufPrint(&buf, "{s} {s} {s} {s:>7} ", .{ arrow, mk, e.perms[0..e.permslen], e.size[0..e.sizelen] }) catch continue)
        else
            (std.fmt.bufPrint(&buf, "{s} {s} ", .{ arrow, mk }) catch continue);
        weft.decorate(e.name_r, .virtual_before, .muted, msg);
    }
}

/// Claim the hidden id-span over each name (id = the entry's current path), so
/// reconcile can read identity back. Rebases as the name is edited (rename) and
/// — via the core register ferry — rides a `dd`→`p` (move). Cleared + re-claimed
/// each authoring.
fn claimIds() void {
    weft.subbufferClear();
    var i: usize = 0;
    while (i < entry_count) : (i += 1) {
        const e = &entries[i];
        const end = if (e.r_end > e.r_start) e.r_end - 1 else e.r_end; // exclude the '\n'
        const h = weft.claimSubbuffer(e.name_r, end) orelse continue;
        weft.subbufferPutFact(h, "id", e.pathS());
        weft.subbufferPutFact(h, "kind", if (e.kind == .dir) "dir" else "file");
    }
}

// ── Publish styles + folds over the freshly-authored buffer ──────────────────
fn lineEnd(off: usize) usize {
    var e = off;
    while (e < out and render_buf[e] != '\n') e += 1;
    return e;
}
fn publishStyles() void {
    weft.styleClear();
    var i: usize = 0;
    while (i < entry_count) : (i += 1) {
        const e = &entries[i];
        const le = lineEnd(e.r_start);
        // Only the NAME is text now (metadata is decoration): color it by kind.
        const cls: weft.StyleClass = switch (e.kind) {
            .dir => .location, // blue, like ls dirs
            .exe => .added, // green, like ls executables
            .symlink => .emphasis,
            .file => .normal,
        };
        if (cls != .normal) weft.style(e.name_r, le, cls);
    }
}
/// Fold the subtree of each collapsed-but-gathered dir (in `expanded` AND
/// `folded`): from just past its line to the end of its last descendant, so the
/// subtree collapses to the single dir line. A never-expanded dir has no children
/// in the buffer, so nothing to fold.
fn publishFolds() void {
    weft.foldClear();
    var i: usize = 0;
    while (i < entry_count) : (i += 1) {
        const e = &entries[i];
        if (e.kind != .dir) continue;
        if (!(expanded.has(e.pathS()) and folded.has(e.pathS()))) continue;
        // Descendants are the contiguous run with depth > e.depth.
        var j = i + 1;
        while (j < entry_count and entries[j].depth > e.depth) j += 1;
        if (j > i + 1) weft.fold(e.body, entries[j - 1].r_end);
    }
}

/// Re-render + re-publish over the current model WITHOUT a re-gather (fold
/// toggles, mark toggles — the byte layout is stable, so point holds). Cursor
/// stays where it was.
fn republish() void {
    const cur = weft.cursor();
    render();
    weft.edit(.{ .start = 0, .end = weft.byteLen() }, render_buf[0..out]);
    publishStyles();
    publishDecorations();
    publishFolds();
    claimIds();
    weft.jump(weft.lineAt(@min(cur, out)).start);
}

// ── Node resolution: cursor/offset → the entry whose line contains it ────────
fn nodeAt(off: usize) ?usize {
    var i: usize = 0;
    while (i < entry_count) : (i += 1) {
        if (off >= entries[i].r_start and off < entries[i].r_end) return i;
    }
    return null;
}

// ── Navigation ───────────────────────────────────────────────────────────────
fn openLocal() void {
    peer_mode = false;
    setCwd(".");
    expanded.clear();
    folded.clear();
    marked.clear();
    regather(false);
}
fn refresh() void {
    if (peer_mode) {
        listPeer(cwd());
        return;
    }
    regather(true);
}
fn toggleHidden() void {
    if (peer_mode) {
        weft.echo("dired: hidden toggle is local-only");
        return;
    }
    show_hidden = !show_hidden;
    regather(true);
}

/// Up a level: re-root to the parent. Entry paths stay cwd-relative, so the
/// persisted expand/mark sets remain valid.
fn up() void {
    const trimmed = std.mem.trimEnd(u8, cwd(), "/");
    const parent = if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |i|
        (if (i == 0) trimmed[0..1] else trimmed[0..i])
    else
        "..";
    var buf: [PATH_CAP]u8 = undefined;
    const n = copyInto(&buf, parent);
    if (peer_mode) {
        listPeer(buf[0..n]);
        return;
    }
    setCwd(buf[0..n]);
    regather(false);
}

/// Return: on a file → open it; on a directory → toggle its inline expansion
/// (the magit-treatment intent). Peer mode reads the raw line (the old behavior).
fn openEntry() void {
    if (peer_mode) {
        openPeerLine();
        return;
    }
    const i = nodeAt(weft.cursor()) orelse return;
    if (entries[i].kind == .dir) {
        toggleFold();
        return;
    }
    var pathbuf: [PATH_CAP]u8 = undefined;
    const n = copyInto(&pathbuf, entries[i].pathS()); // copy before host reuse
    weft.runStr("open", pathbuf[0..n]);
}

/// Tab (and Return on a dir): flip a directory's inline expansion.
///  · never gathered → add to `expanded`, re-gather (fetch + splice children).
///  · open           → add to `folded`, re-render (fold hides — no re-gather).
///  · folded         → drop from `folded`, re-render (unfold — no re-gather).
fn toggleFold() void {
    if (peer_mode) {
        weft.echo("dired: expand is local-only (peer descends with Return)");
        return;
    }
    const i = nodeAt(weft.cursor()) orelse return;
    if (entries[i].kind != .dir) return;
    var pathbuf: [PATH_CAP]u8 = undefined;
    const n = copyInto(&pathbuf, entries[i].pathS());
    const pth = pathbuf[0..n];
    if (!expanded.has(pth)) {
        _ = expanded.add(pth);
        folded.remove(pth);
        regather(true); // fetch this dir's children, keep point on the dir
    } else if (!folded.has(pth)) {
        _ = folded.add(pth); // collapse (fold) — children stay in the model
        republish();
    } else {
        folded.remove(pth); // re-expand instantly (no re-fetch)
        republish();
    }
}

// ── Marks ────────────────────────────────────────────────────────────────────
fn mark() void {
    const i = nodeAt(weft.cursor()) orelse return;
    _ = marked.add(entries[i].pathS());
    entries[i].marked = true;
    republish();
    weft.run("cursor-down"); // dired advances after a mark
}
fn unmark() void {
    const i = nodeAt(weft.cursor()) orelse return;
    marked.remove(entries[i].pathS());
    entries[i].marked = false;
    republish();
    weft.run("cursor-down");
}
fn unmarkAll() void {
    marked.clear();
    var i: usize = 0;
    while (i < entry_count) : (i += 1) entries[i].marked = false;
    republish();
}
fn toggleMarks() void {
    var i: usize = 0;
    while (i < entry_count) : (i += 1) {
        const e = &entries[i];
        if (e.marked) {
            marked.remove(e.pathS());
            e.marked = false;
        } else {
            _ = marked.add(e.pathS());
            e.marked = true;
        }
    }
    republish();
}

// ── File operations (shell out, then re-gather; delete is confirmed) ─────────
/// Append ` 'p1' 'p2' …` for the marked set (or the entry under point if no
/// marks) to `w` in `buf`; returns the new offset and how many targets. 0 targets
/// ⇒ nothing to act on.
fn appendTargets(buf: []u8, w0: usize, count: *usize) usize {
    var w = w0;
    count.* = 0;
    if (marked.count > 0) {
        var i: usize = 0;
        while (i < marked.count) : (i += 1) {
            const seg = std.fmt.bufPrint(buf[w..], " '{s}'", .{marked.paths[i][0..marked.lens[i]]}) catch break;
            w += seg.len;
            count.* += 1;
        }
    } else if (nodeAt(weft.cursor())) |i| {
        const seg = std.fmt.bufPrint(buf[w..], " '{s}'", .{entries[i].pathS()}) catch return w;
        w += seg.len;
        count.* = 1;
    }
    return w;
}

fn localOnly() bool {
    if (peer_mode) {
        weft.echo("dired: file ops are local-only");
        return false;
    }
    return true;
}

fn diredMkdir() void {
    if (!localOnly()) return;
    openInput(.mkdir, "make directory:  (C-c C-c)");
}
fn diredRename() void {
    if (!localOnly()) return;
    const i = nodeAt(weft.cursor()) orelse return;
    op_src_len = copyInto(&op_src, entries[i].pathS());
    openInput(.rename, "rename to:  (C-c C-c)");
}
fn diredCopy() void {
    if (!localOnly()) return;
    const i = nodeAt(weft.cursor()) orelse return;
    op_src_len = copyInto(&op_src, entries[i].pathS());
    openInput(.copy, "copy to:  (C-c C-c)");
}
fn diredShell() void {
    if (!localOnly()) return;
    var count: usize = 0;
    op_args_len = appendTargets(&op_args, 0, &count);
    if (count == 0) {
        weft.echo("dired: no target");
        return;
    }
    openInput(.shell, "! shell command (args appended):  (C-c C-c)");
}
/// Delete the marked set (or the entry under point) — ALWAYS behind a y/n
/// confirm; never deletes without it.
fn diredDelete() void {
    if (!localOnly()) return;
    var w: usize = 0;
    const pre = std.fmt.bufPrint(confirm_cmd[w..], "rm -rf --", .{}) catch return;
    w += pre.len;
    var count: usize = 0;
    w = appendTargets(&confirm_cmd, w, &count);
    if (count == 0) {
        weft.echo("dired: no target");
        return;
    }
    confirm_len = w;
    var msg: [64]u8 = undefined;
    weft.echo(std.fmt.bufPrint(&msg, "delete {d} item(s)? y/n", .{count}) catch "delete? y/n");
    weft.setMode("dired-confirm");
}
fn confirmYes() void {
    commit_pending = false;
    marked.clear(); // any delete targets are gone; drop stale marks
    gatherAfter(confirm_cmd[0..confirm_len]);
}
fn confirmNo() void {
    if (commit_pending) {
        commit_pending = false;
        // Keep the user's edits: return to the (always-editable) *dired* buffer.
        _ = focusBuffer(dired_buf);
        weft.setMode("dired");
        weft.echo("dired: not applied — keep editing (g refreshes to discard)");
        return;
    }
    weft.setMode("dired");
    weft.echo("cancelled");
}

// ── The `*dired-input*` single-line prompt ───────────────────────────────────
fn openInput(action: InputAction, prompt: []const u8) void {
    input_action = action;
    if (!focusBuffer(input_buf)) weft.runStr("buffer-create", input_buf);
    weft.edit(.{ .start = 0, .end = weft.byteLen() }, "");
    weft.jump(0);
    weft.setMode("dired-input");
    weft.echo(prompt);
}
fn inputAbort() void {
    input_action = .none;
    weft.setMode("dired");
    weft.echo("cancelled");
}
fn inputResume() void {
    weft.setMode("dired-input");
}
fn inputFinish() void {
    // First line, trimmed — copy off the shared scratch before any host read.
    const text = weft.slice(0, weft.byteLen());
    var e: usize = 0;
    while (e < text.len and text[e] != '\n') e += 1;
    const line = std.mem.trim(u8, text[0..e], " \t\r");
    var typed: [PATH_CAP]u8 = undefined;
    const tn = copyInto(&typed, line);
    const t = typed[0..tn];
    if (t.len == 0) {
        inputAbort();
        return;
    }
    const act = input_action;
    input_action = .none;
    switch (act) {
        .mkdir => {
            var dbuf: [PATH_CAP]u8 = undefined;
            const dn = joinPath(&dbuf, cwd(), t);
            const cmd = std.fmt.bufPrint(&op_buf, "mkdir -p -- '{s}'", .{dbuf[0..dn]}) catch return;
            gatherAfter(cmd);
        },
        .rename => {
            var dbuf: [PATH_CAP]u8 = undefined;
            const dn = resolveDst(&dbuf, op_src[0..op_src_len], t);
            const cmd = std.fmt.bufPrint(&op_buf, "mv -- '{s}' '{s}'", .{ op_src[0..op_src_len], dbuf[0..dn] }) catch return;
            gatherAfter(cmd);
        },
        .copy => {
            var dbuf: [PATH_CAP]u8 = undefined;
            const dn = resolveDst(&dbuf, op_src[0..op_src_len], t);
            const cmd = std.fmt.bufPrint(&op_buf, "cp -r -- '{s}' '{s}'", .{ op_src[0..op_src_len], dbuf[0..dn] }) catch return;
            gatherAfter(cmd);
        },
        .shell => {
            // `<typed> 'f1' 'f2' …` (targets captured when `!` was pressed).
            var w: usize = copyInto(&op_buf, t);
            const n = @min(op_args_len, op_buf.len - w);
            @memcpy(op_buf[w .. w + n], op_args[0..n]);
            w += n;
            gatherAfter(op_buf[0..w]);
        },
        .none => weft.setMode("dired"),
    }
}
/// Resolve a rename/copy destination: an absolute or slash-bearing `typed` is
/// taken as-is (cwd-relative); a bare name lands beside the source (its dirname).
fn resolveDst(dst: []u8, src: []const u8, typed: []const u8) usize {
    if (typed.len > 0 and (typed[0] == '/' or std.mem.indexOfScalar(u8, typed, '/') != null)) {
        return copyInto(dst, typed);
    }
    if (std.mem.lastIndexOfScalar(u8, src, '/')) |i| {
        const s = std.fmt.bufPrint(dst, "{s}/{s}", .{ src[0..i], typed }) catch return copyInto(dst, typed);
        return s.len;
    }
    return copyInto(dst, typed);
}

// ── Editable-buffer file management (mini.files) — DRY RUN ONLY ──────────────
// SAFETY INVARIANT: none of the functions below execute a file operation. They
// read the buffer, diff against the snapshot, and WRITE A PREVIEW into a buffer.
// The only host doors used are buffer writes (`edit`/`style`/`echo`/`setMode`).

fn dirnameOf(pth: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, pth, '/')) |k| return pth[0..k];
    return ""; // a root-level (depth-0, cwd-relative) name has no parent segment
}
fn basenameOf(pth: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, pth, '/')) |k| return pth[k + 1 ..];
    return pth;
}

/// `dired-edit` (`i`/`E`): SNAPSHOT the current tree model, then re-render the
/// `*dired*` buffer as a SIMPLE editable projection (indent = depth, one name per
/// line, dirs trail `/`) and switch to the editable `dired-edit` posture. The
/// simple projection (no header/perms/marks/fold glyphs) is what the reconcile
/// parser reads back — far more robust than re-parsing the rich render.
/// Copy the live tree model into the snapshot arrays (path/kind/depth) — taken
/// at each gather (on_fill). `save` (dired-commit) diffs the edited buffer
/// against this to infer the file ops.
fn snapshot() void {
    snap_count = @min(entry_count, MAX_ENTRIES);
    var i: usize = 0;
    while (i < snap_count) : (i += 1) {
        snap[i] = .{};
        snap[i].plen = copyInto(&snap[i].path, entries[i].pathS());
        snap[i].is_dir = entries[i].kind == .dir;
        snap[i].depth = entries[i].depth;
    }
}

/// Parse the editable buffer (in `raw`) into `elines`: leading spaces → depth,
/// the rest is the name, a trailing `/` marks a directory. Full paths are rebuilt
/// from the indent→parent chain (depth d hangs off the last depth-(d-1) line).
fn parseEdit() void {
    el_count = 0;
    el_overflow = false;
    for (&ep_have) |*h| h.* = false;
    var i: usize = 0;
    while (i < raw_len) {
        const ls = i; // this line's start offset in the buffer (raw is buffer[0..])
        var le = i;
        while (le < raw_len and raw[le] != '\n') le += 1;
        const line = raw[i..le];
        i = le + 1;
        var s: usize = 0;
        while (s < line.len and line[s] == ' ') s += 1;
        var d: usize = s / 2;
        if (d >= DEPTH_CAP) d = DEPTH_CAP - 1;
        var rest = std.mem.trimEnd(u8, line[s..], " \t\r");
        if (rest.len == 0) continue; // blank line
        var is_dir = false;
        if (rest[rest.len - 1] == '/') {
            is_dir = true;
            rest = rest[0 .. rest.len - 1];
        }
        if (rest.len == 0) continue;
        // Clamp to the deepest established parent (tolerate malformed indent).
        while (d > 0 and !ep_have[d - 1]) d -= 1;
        const parent: []const u8 = if (d == 0) cwd() else ep_path[d - 1][0..ep_len[d - 1]];
        if (el_count >= MAX_ENTRIES) {
            el_overflow = true;
            break;
        }
        var e = &elines[el_count];
        e.* = .{};
        e.depth = d;
        e.is_dir = is_dir;
        e.plen = joinPath(&e.path, parent, rest);
        // The hidden identity: the id-span over this row's name (at ls+indent)
        // carries the original path. Present ⇒ this row IS that entry (renamed/
        // moved); absent ⇒ a typed/new line (a create).
        if (weft.subbufferFactAt(ls + s, "id")) |oid| {
            e.oidlen = @min(oid.len, PATH_CAP);
            @memcpy(e.oid[0..e.oidlen], oid[0..e.oidlen]);
        }
        // This line becomes the parent for depth d+1; a dedent invalidates deeper.
        const pn = @min(e.plen, PATH_CAP);
        @memcpy(ep_path[d][0..pn], e.path[0..pn]);
        ep_len[d] = pn;
        ep_have[d] = true;
        var k = d + 1;
        while (k < DEPTH_CAP) : (k += 1) ep_have[k] = false;
        el_count += 1;
    }
}

/// Infer ops by matching edited lines against the snapshot. EXACT identity via
/// hidden id-spans first — (0) a row whose id (original path) is in the snapshot
/// IS that entry: same path ⇒ unchanged, same parent ⇒ RENAME, else MOVE; a
/// second row with the same id ⇒ COPY. Then the heuristic fallback for id-less
/// rows: (1) exact path ⇒ unchanged; (2) same-parent ⇒ rename; (3) shared
/// basename ⇒ move; (4) leftovers ⇒ DELETE (originals) / CREATE (edits). The
/// id pass makes `dd`→`p`-move and rename path-independent (the exact identity
/// the old heuristic-only diff couldn't get); the fallback still handles a
/// freshly-typed line that carries no id.
fn diff() void {
    var i: usize = 0;
    while (i < snap_count) : (i += 1) {
        snap[i].matched = false;
        snap[i].deleted = false;
    }
    var j: usize = 0;
    while (j < el_count) : (j += 1) {
        elines[j].matched = false;
        elines[j].cat = .unchanged;
    }

    // (0) id-exact: a row's hidden id (original path) resolves its identity.
    j = 0;
    while (j < el_count) : (j += 1) {
        if (elines[j].oidlen == 0) continue;
        const oid = elines[j].oid[0..elines[j].oidlen];
        // Find the snapshot entry this id names.
        i = 0;
        var snap_idx: ?usize = null;
        while (i < snap_count) : (i += 1) {
            if (std.mem.eql(u8, snap[i].pathS(), oid)) {
                snap_idx = i;
                break;
            }
        }
        const si = snap_idx orelse continue; // id names nothing we snapshotted
        elines[j].matched = true;
        elines[j].partner = si;
        if (snap[si].matched) {
            // The original id already claimed by another row ⇒ this is a COPY.
            elines[j].cat = .copy;
        } else {
            snap[si].matched = true;
            if (std.mem.eql(u8, elines[j].pathS(), oid)) {
                elines[j].cat = .unchanged;
            } else if (std.mem.eql(u8, dirnameOf(elines[j].pathS()), dirnameOf(oid))) {
                elines[j].cat = .rename_to;
            } else {
                elines[j].cat = .move_to;
            }
        }
    }

    // (1) exact path + kind → unchanged.
    j = 0;
    while (j < el_count) : (j += 1) {
        i = 0;
        while (i < snap_count) : (i += 1) {
            if (snap[i].matched) continue;
            if (snap[i].is_dir == elines[j].is_dir and
                std.mem.eql(u8, snap[i].pathS(), elines[j].pathS()))
            {
                snap[i].matched = true;
                elines[j].matched = true;
                break;
            }
        }
    }

    // (2) rename: unmatched original ↔ unmatched edit under the SAME parent.
    i = 0;
    while (i < snap_count) : (i += 1) {
        if (snap[i].matched) continue;
        const parent = dirnameOf(snap[i].pathS());
        j = 0;
        while (j < el_count) : (j += 1) {
            if (elines[j].matched) continue;
            if (std.mem.eql(u8, dirnameOf(elines[j].pathS()), parent)) {
                snap[i].matched = true;
                elines[j].matched = true;
                elines[j].cat = .rename_to;
                elines[j].partner = i;
                break;
            }
        }
    }

    // (3) move: unmatched original ↔ unmatched edit sharing a basename elsewhere.
    i = 0;
    while (i < snap_count) : (i += 1) {
        if (snap[i].matched) continue;
        const base = basenameOf(snap[i].pathS());
        j = 0;
        while (j < el_count) : (j += 1) {
            if (elines[j].matched) continue;
            if (std.mem.eql(u8, basenameOf(elines[j].pathS()), base)) {
                snap[i].matched = true;
                elines[j].matched = true;
                elines[j].cat = .move_to;
                elines[j].partner = i;
                break;
            }
        }
    }

    // (4) leftovers: originals → DELETE, edits → CREATE.
    i = 0;
    while (i < snap_count) : (i += 1) if (!snap[i].matched) {
        snap[i].deleted = true;
    };
    j = 0;
    while (j < el_count) : (j += 1) if (!elines[j].matched) {
        elines[j].cat = .create;
    };
}

/// Render the op plan into `render_buf`; returns the op count. Order: renames,
/// moves, creates, deletes (each grouped). Text only — see `showPlan`.
fn buildPlan() usize {
    out = 0;
    put("dired: pending changes (in apply order)\n\n");
    var n: usize = 0;
    var j: usize = 0;
    while (j < el_count) : (j += 1) if (elines[j].cat == .rename_to) {
        put("rename  ");
        put(snap[elines[j].partner].pathS());
        put(" -> ");
        put(elines[j].pathS());
        put("\n");
        n += 1;
    };
    j = 0;
    while (j < el_count) : (j += 1) if (elines[j].cat == .move_to) {
        put("move    ");
        put(snap[elines[j].partner].pathS());
        put(" -> ");
        put(elines[j].pathS());
        put("\n");
        n += 1;
    };
    j = 0;
    while (j < el_count) : (j += 1) if (elines[j].cat == .copy) {
        put("copy    ");
        put(snap[elines[j].partner].pathS());
        put(" -> ");
        put(elines[j].pathS());
        put("\n");
        n += 1;
    };
    j = 0;
    while (j < el_count) : (j += 1) if (elines[j].cat == .create) {
        if (elines[j].is_dir) {
            put("mkdir   ");
            put(elines[j].pathS());
            put("/\n");
        } else {
            put("create  ");
            put(elines[j].pathS());
            put("\n");
        }
        n += 1;
    };
    var i: usize = 0;
    while (i < snap_count) : (i += 1) if (snap[i].deleted) {
        put("delete  ");
        put(snap[i].pathS());
        put("\n");
        n += 1;
    };
    if (n == 0) put("(no changes)\n");
    put("\n");
    var mb: [96]u8 = undefined;
    put(std.fmt.bufPrint(&mb, "{d} op(s)", .{n}) catch "");
    put("\n");
    return n;
}

/// Compose the reconcile plan into ONE shell command (into `confirm_cmd`), in
/// apply order: mkdir parents → rename/move (mv) → copy (cp -r) → create
/// (mkdir/touch) → delete (rm -rf). Paths are single-quoted (with `'` escaped),
/// so spaces/specials are inert. Returns the byte length, or 0 on overflow.
fn composeOps() usize {
    var w: usize = 0;
    const Emit = struct {
        fn q(buf: []u8, at: usize, path: []const u8) ?usize {
            var o = at;
            if (o >= buf.len) return null;
            buf[o] = '\'';
            o += 1;
            for (path) |ch| {
                if (ch == '\'') { // ' → '\'' (close, escaped quote, reopen)
                    const esc = "'\\''";
                    if (o + esc.len > buf.len) return null;
                    @memcpy(buf[o .. o + esc.len], esc);
                    o += esc.len;
                } else {
                    if (o >= buf.len) return null;
                    buf[o] = ch;
                    o += 1;
                }
            }
            if (o >= buf.len) return null;
            buf[o] = '\'';
            return o + 1;
        }
        fn lit(buf: []u8, at: usize, s: []const u8) ?usize {
            if (at + s.len > buf.len) return null;
            @memcpy(buf[at .. at + s.len], s);
            return at + s.len;
        }
    };
    // Directory creates first (a mkdir -p makes any parents a move/copy needs).
    var j: usize = 0;
    while (j < el_count) : (j += 1) if (elines[j].cat == .create and elines[j].is_dir) {
        w = Emit.lit(&confirm_cmd, w, "mkdir -p -- ") orelse return 0;
        w = Emit.q(&confirm_cmd, w, elines[j].pathS()) orelse return 0;
        w = Emit.lit(&confirm_cmd, w, "; ") orelse return 0;
    };
    j = 0;
    while (j < el_count) : (j += 1) if (elines[j].cat == .rename_to or elines[j].cat == .move_to) {
        w = Emit.lit(&confirm_cmd, w, "mv -- ") orelse return 0;
        w = Emit.q(&confirm_cmd, w, snap[elines[j].partner].pathS()) orelse return 0;
        w = Emit.lit(&confirm_cmd, w, " ") orelse return 0;
        w = Emit.q(&confirm_cmd, w, elines[j].pathS()) orelse return 0;
        w = Emit.lit(&confirm_cmd, w, "; ") orelse return 0;
    };
    j = 0;
    while (j < el_count) : (j += 1) if (elines[j].cat == .copy) {
        w = Emit.lit(&confirm_cmd, w, "cp -r -- ") orelse return 0;
        w = Emit.q(&confirm_cmd, w, snap[elines[j].partner].pathS()) orelse return 0;
        w = Emit.lit(&confirm_cmd, w, " ") orelse return 0;
        w = Emit.q(&confirm_cmd, w, elines[j].pathS()) orelse return 0;
        w = Emit.lit(&confirm_cmd, w, "; ") orelse return 0;
    };
    j = 0;
    while (j < el_count) : (j += 1) if (elines[j].cat == .create and !elines[j].is_dir) {
        w = Emit.lit(&confirm_cmd, w, "touch -- ") orelse return 0;
        w = Emit.q(&confirm_cmd, w, elines[j].pathS()) orelse return 0;
        w = Emit.lit(&confirm_cmd, w, "; ") orelse return 0;
    };
    var i: usize = 0;
    while (i < snap_count) : (i += 1) if (snap[i].deleted) {
        w = Emit.lit(&confirm_cmd, w, "rm -rf -- ") orelse return 0;
        w = Emit.q(&confirm_cmd, w, snap[i].pathS()) orelse return 0;
        w = Emit.lit(&confirm_cmd, w, "; ") orelse return 0;
    };
    return w;
}

/// `dired-commit` — the `save` action's provider for a *dired* projection: parse
/// the edited buffer, reconcile it against the gather snapshot by hidden id,
/// preview the ordered ops in `*dired-plan*`, and stage them behind the y/n
/// confirm (which runs them via `gatherAfter` and re-gathers). A save OUTSIDE
/// edit mode is a no-op (the view render is not an editable projection).
fn diredCommit() void {
    // A local *dired* projection only (a peer listing has no editable model).
    if (peer_mode or !std.mem.eql(u8, activeName(), dired_buf)) return;
    loadRaw(); // page the EDITED buffer text (active buffer is *dired*)
    parseEdit();
    diff();
    const n = buildPlan();
    if (n == 0) {
        weft.echo("dired: no changes");
        return;
    }
    const w = composeOps();
    if (w == 0) {
        weft.echo("dired: too many changes to apply at once");
        return;
    }
    confirm_len = w;
    commit_pending = true;
    showPlan(); // the pending-changes list, in *dired-plan*
    weft.setMode("dired-confirm");
}

/// Publish the plan text (from `render_buf`) into `*dired-plan*` and color it.
/// Switching focus makes it the active buffer, which is what `edit`/`style` target.
fn showPlan() void {
    if (!focusBuffer(plan_buf)) weft.runStr("buffer-create", plan_buf);
    weft.edit(.{ .start = 0, .end = weft.byteLen() }, render_buf[0..out]);
    weft.jump(0);
    stylePlan();
}
fn planClass(line: []const u8) ?weft.StyleClass {
    if (std.mem.startsWith(u8, line, "rename")) return .emphasis;
    if (std.mem.startsWith(u8, line, "move")) return .location;
    if (std.mem.startsWith(u8, line, "create")) return .added;
    if (std.mem.startsWith(u8, line, "mkdir")) return .added;
    if (std.mem.startsWith(u8, line, "delete")) return .removed;
    if (std.mem.startsWith(u8, line, "copy")) return .location;
    if (std.mem.startsWith(u8, line, "dired:")) return .header;
    return null; // blanks / footer / "(no changes)" — default
}
fn stylePlan() void {
    weft.styleClear();
    var i: usize = 0;
    while (i < out) {
        var le = i;
        while (le < out and render_buf[le] != '\n') le += 1;
        if (planClass(render_buf[i..le])) |c| weft.style(i, le, c);
        i = le + 1;
    }
}

// ── Peer locus: flat `fsListAsync` listing (the old behavior, preserved) ─────
fn openPeer() void {
    peer_mode = true;
    listPeer(".");
}
/// List a peer dir asynchronously into `*dired*` (delivered by the session's
/// RemoteFs a few frames later). Plain names, dirs trailing `/` — read directly
/// by the line-based peer navigation below (no model, no proc).
fn listPeer(dir: []const u8) void {
    setCwd(dir);
    if (!focusBuffer(dired_buf)) weft.runStr("buffer-create", dired_buf);
    _ = weft.fsListAsync("peer", dir, dired_buf);
    weft.setMode("dired");
}
/// Return in peer mode: read the current line; a trailing `/` descends (re-root),
/// else open the file — both cwd-relative to the peer root.
fn openPeerLine() void {
    const ln = weft.lineAt(weft.cursor());
    const rawline = weft.slice(ln.start, ln.end);
    var nb: [PATH_CAP]u8 = undefined;
    const n = @min(rawline.len, nb.len);
    @memcpy(nb[0..n], rawline[0..n]);
    const name = std.mem.trim(u8, nb[0..n], " \t\r\n");
    if (name.len == 0) return;
    var pathbuf: [PATH_CAP + NAME_CAP]u8 = undefined;
    const full = std.fmt.bufPrint(&pathbuf, "{s}/{s}", .{ cwd(), name }) catch return;
    if (std.mem.endsWith(u8, name, "/")) {
        listPeer(full[0 .. full.len - 1]); // descend (drop the marker)
    } else {
        weft.runStr("open", full);
    }
}
