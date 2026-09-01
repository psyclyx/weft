//! The projection doors: a guest publishes a NODE TREE, the host renders it
//! into a text buffer and answers questions about it by KEY.
//!
//! Six doors, and what matters about them is what is NOT among them. There is
//! no door that takes an offset and no door that returns one. A guest builds a
//! tree, commits it, and afterwards asks only "which key is the cursor on" and
//! "which lines of this key are selected". Everything between — laying the text
//! out, painting styles from roles, hiding folded subtrees, hit-testing the
//! cursor, and putting the cursor back on the row it was on before a rebuild —
//! is `core/projection.zig`'s, once, for every producer.
//!
//! The buffer is written as the plugin's own peer through the same
//! `command.renderInto` door `wl_edit` uses, so a projection is authored under
//! the same authority as any other plugin edit and shows up in the same
//! history. The style and fold layers are claimed exactly as `wl_fold_clear`
//! claims its own, so a projection composes with everything already reading
//! those layers rather than needing a second painting path.

const std = @import("std");
const Allocator = std.mem.Allocator;
const wasm = @import("../wasm.zig");
const command = @import("../command.zig");
const Buffers = @import("../Buffers.zig");
const projection = @import("../projection.zig");

const shared = @import("plugin.zig");
const WasmPlugin = shared.WasmPlugin;

/// The layer names the projection paints into — the same two every other
/// layer-claiming door uses. A projection is not a second rendering path.
const styles_layer_name = "styles";
const folds_layer_name = "folds";

/// `wl_proj_begin(name, name_len) -> i32`: open a build over the named buffer.
/// 0 accepted, -1 refused. The buffer is resolved ONCE, here, and captured —
/// so nothing that happens between `begin` and `commit` can redirect where the
/// projection lands.
pub fn hProjBegin(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    results[0] = -1;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const gpa = p.gpa;
    const name = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer gpa.free(name);
    const buffers = p.activeCtx().buffers;
    const id = buffers.findByName(name) orelse return;
    const entry = buffers.get(id) orelse return;
    const view = viewFor(p, entry) orelse return;
    view.begin();
    // The entry is captured HERE, once. Nothing between now and the commit —
    // a focus change, another plugin's fill — can redirect where it lands.
    p.proj_building = entry.ref();
    results[0] = 0;
}

/// The entry whose projection has a build open. A build is not concurrent, so
/// this is unambiguous, and it is a generation-checked `Ref` rather than a
/// pointer: an entry closed mid-build resolves to nothing instead of to
/// whatever took its slot.
fn openBuild(p: *WasmPlugin) ?struct { entry: *Buffers.Buffer, view: *projection.View } {
    const ref = p.proj_building orelse return null;
    const entry = p.activeCtx().buffers.resolve(ref) orelse return null;
    const view = entry.projection orelse return null;
    if (!std.mem.eql(u8, view.owner, p.name)) return null;
    return .{ .entry = entry, .view = view };
}

/// `wl_proj_node(key, key_len, role, role_len, text, text_len, parent, flags)
/// -> i32`: append a node to the open build; returns its ordinal, which a later
/// node names as ITS parent. `parent` is -1 for a root. `flags` bit 0 is
/// foldable.
pub fn hProjNode(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    results[0] = -1;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const gpa = p.gpa;
    const open = openBuild(p) orelse return;
    const view = open.view;
    const key = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer gpa.free(key);
    const role = caller.readMemory(gpa, @intCast(args[2]), @intCast(args[3])) catch return;
    defer gpa.free(role);
    const text = caller.readMemory(gpa, @intCast(args[4]), @intCast(args[5])) catch return;
    defer gpa.free(text);
    const parent: ?u32 = if (args[6] < 0) null else @intCast(args[6]);
    const ordinal = view.add(.{
        .key = key,
        .role = role,
        .text = text,
        .parent = parent,
        .foldable = (args[7] & 1) != 0,
        .focusable = (args[7] & 2) != 0,
        .editable = (args[7] & 4) != 0,
    }) catch return;
    results[0] = @intCast(ordinal);
}

/// `wl_proj_span(node, start, end, role, role_len)`: style a stretch of node
/// `node`'s OWN text.
///
/// The offsets are into the text this plugin passed to `wl_proj_node`, not into
/// the document — which is why this door exists at all rather than a tool view
/// reaching for a door that paints the focused buffer at document
/// coordinates. A producer naming bytes it wrote one call ago is
/// naming something it knows; the same producer naming a document offset is
/// naming something the next render moves. Nothing here can be turned into a
/// document offset by the guest: the node's rendered start is added on this
/// side, and never handed back.
pub fn hProjSpan(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const gpa = p.gpa;
    const open = openBuild(p) orelse return;
    if (args[0] < 0) return;
    const role = caller.readMemory(gpa, @intCast(args[3]), @intCast(args[4])) catch return;
    defer gpa.free(role);
    const start: usize = if (args[1] < 0) 0 else @intCast(args[1]);
    const end: usize = if (args[2] < 0) 0 else @intCast(args[2]);
    open.view.span(@intCast(args[0]), start, end, role) catch {};
}

/// `wl_proj_rows(out, cap) -> i32`: what every EDITABLE row says NOW, as
/// `key\0text\0` pairs in rendered order. Returns bytes written, or -1.
///
/// This is the read half of §F2's fork closing. A producer publishes rows, the
/// user types into them — reorders a rebase plan, renames a file in a listing —
/// and then this says what each row it published has become, addressed by the
/// KEY it chose rather than by where the line ended up. A row the user emptied
/// or deleted comes back with empty text, which is how "dropped" is spelled.
///
/// No offset in either direction: the door takes none, returns none, and what
/// it reads between is found by anchors the document shifted, not by a position
/// anyone remembered.
pub fn hProjRows(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    results[0] = -1;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const entry = p.activeCtx().buffers.active();
    const view = entry.projection orelse return;
    if (!std.mem.eql(u8, view.owner, p.name)) return;
    const editor = entry.textEditor() orelse return;
    const doc = &editor.doc;
    const cap: usize = @intCast(@as(u32, @bitCast(args[1])));

    // IN THE ORDER THEY NOW APPEAR, not the order they were published. A user
    // who moves a line up has said something about order — it is the whole
    // point of an editable plan — so reporting publication order would report
    // the one thing they changed as unchanged. The anchors already know.
    var live = std.ArrayList(*const projection.Node).empty;
    defer live.deinit(p.gpa);
    for (view.nodes.items) |*n| {
        if (n.anchor_start == null or n.anchor_end == null) continue;
        live.append(p.gpa, n) catch return;
    }
    const By = struct {
        d: @TypeOf(doc),
        fn less(self: @This(), x: *const projection.Node, y: *const projection.Node) bool {
            return self.d.anchorOffset(@enumFromInt(x.anchor_start.?)) <
                self.d.anchorOffset(@enumFromInt(y.anchor_start.?));
        }
    };
    std.mem.sort(*const projection.Node, live.items, By{ .d = doc }, By.less);

    var out = std.ArrayList(u8).empty;
    defer out.deinit(p.gpa);
    for (live.items) |n| {
        const lo = doc.anchorOffset(@enumFromInt(n.anchor_start.?));
        const hi = doc.anchorOffset(@enumFromInt(n.anchor_end.?));
        out.appendSlice(p.gpa, n.key) catch return;
        out.append(p.gpa, 0) catch return;
        const rope = editor.text();
        const total = rope.byteLen();
        const s = @min(lo, total);
        const e = @min(hi, total);
        if (e > s) {
            const bytes = p.gpa.alloc(u8, e - s) catch return;
            defer p.gpa.free(bytes);
            var sr = rope.streamReader(.{ .start = s, .end = e }, &.{});
            sr.interface.readSliceAll(bytes) catch return;
            // A row the user split with a newline reads to its first break: the
            // rest is a NEW line, which is a row this producer never published
            // and must not be handed back as if it had.
            const cut = std.mem.indexOfScalar(u8, bytes, '\n') orelse bytes.len;
            out.appendSlice(p.gpa, bytes[0..cut]) catch return;
        }
        out.append(p.gpa, 0) catch return;
    }
    const n = caller.writeMemory(@intCast(@as(u32, @bitCast(args[0]))), cap, out.items) catch return;
    results[0] = @intCast(n);
}

/// `wl_proj_commit() -> i32`: render the built tree into the captured buffer,
/// repaint styles and folds, and put the cursor back on the row it was on.
/// Returns the new revision, or -1.
pub fn hProjCommit(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = args;
    results[0] = -1;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const open = openBuild(p) orelse return;
    results[0] = repaint(p, open.entry, open.view, .commit) orelse -1;
}

/// Whether a repaint swaps a NEW tree in or re-lays the one already committed.
///
/// The distinction is not cosmetic. A fold changes the VIEW, so it re-lays the
/// tree in hand: no producer is consulted, and the REVISION does not move —
/// a decision made against this tree before the fold is still about the same
/// model and must not be refused as stale.
const Repaint = enum { commit, rerender };

/// The whole render: remember where the cursor is BY KEY, lay the tree out,
/// write it, repaint the two layers, and land the cursor on the key it was on.
fn repaint(p: *WasmPlugin, entry: *Buffers.Buffer, view: *projection.View, kind: Repaint) ?i32 {
    const gpa = p.gpa;
    const editor = entry.textEditor() orelse return null;
    const doc = &editor.doc;

    // WHERE THE CURSOR IS, as an identity, taken before anything moves. This is
    // the whole of what a producer used to do with `markRestore`, a captured
    // target, a fallback offset, and a re-find after the render.
    view.rememberFocus(editor.cursorOffset());

    const text = switch (kind) {
        .commit => view.commit() catch return null,
        .rerender => view.render() catch return null,
    };
    const end = editor.text().byteLen();
    command.renderInto(gpa, doc, .plugin, p.name, &.{
        .{ .range = .{ .start = 0, .end = end }, .bytes = text },
    }) catch return null;

    paintStyles(p, view, doc, text.len);
    paintFolds(p, view, doc);
    anchorEditableRows(view, doc);
    editor.placeCursor(@min(view.focusOffset(), editor.text().byteLen()));
    return @bitCast(view.revision);
}

/// Drop an anchor at each end of every EDITABLE row.
///
/// The anchors are the whole mechanism. A row the user may type into cannot be
/// found afterwards by the offset it was rendered at — that is the same stale
/// position this module exists to refuse — and it cannot be found by re-parsing
/// the text either, because what the user typed is exactly what a re-parse
/// would have to guess at. An anchor is neither: the document shifts it as the
/// bytes around it move, so "where row 3 is now" needs nobody to have been
/// careful.
///
/// Biased outward (`.left` at the start, `.right` at the end) so text typed at
/// either edge of a row belongs to that row. A row deleted outright collapses
/// its two anchors together and reads as empty, which is how a producer sees a
/// dropped line.
fn anchorEditableRows(view: *projection.View, doc: anytype) void {
    for (view.nodes.items) |*n| {
        // The PREVIOUS render's anchors, if any: released before new ones are
        // taken, so a rebuild does not leak one per editable row per refresh.
        if (n.anchor_start) |h| doc.removeAnchor(@enumFromInt(h));
        if (n.anchor_end) |h| doc.removeAnchor(@enumFromInt(h));
        n.anchor_start = null;
        n.anchor_end = null;
        if (!n.editable or n.text.len == 0) continue;
        const line_end = @min(n.start + n.text.len, doc.text().byteLen());
        const a = doc.addAnchor(view.gpa, n.start, .left) catch continue;
        const b = doc.addAnchor(view.gpa, line_end, .right) catch {
            doc.removeAnchor(a);
            continue;
        };
        n.anchor_start = @intFromEnum(a);
        n.anchor_end = @intFromEnum(b);
    }
}

/// Roles → classes, in one bulk pass over the rendered bytes. The producer
/// named WHAT each row is; the CONTAINER decides how that reads — `theme/<leaf>`
/// resolved like any other slot — which is what gives a theme something to bind
/// and stops a plugin choosing colours.
fn paintStyles(p: *WasmPlugin, view: *projection.View, doc: anytype, len: usize) void {
    const gpa = p.gpa;
    const layer = p.activeCtx().caps.layers.claim(gpa, doc, styles_layer_name, .local, p.name) catch return;
    const classes = gpa.alloc(u8, len) catch return;
    defer gpa.free(classes);
    @memset(classes, 0);
    // A tree has many nodes and few distinct roles, and the resolution for a
    // role cannot change mid-render — so resolve each role ONCE. Without this
    // a thousand-row grep result would scan the whole binding list a thousand
    // times to be told the same thing.
    var theme: RoleCache = .{ .container = p.activeCtx().actions.container, .facts = .{} };
    // Parents first, children after, so a child's own role wins over the range
    // its parent painted — the reading a nested row wants.
    for (view.nodes.items) |n| {
        const class = theme.classOf(n.role);
        const start = @min(n.start, classes.len);
        // A node's OWN first line, not its whole subtree: a section header is
        // emphasised, its files are not painted as the section.
        const own_end = @min(n.body, classes.len);
        if (class != 0 and start < own_end) @memset(classes[start..own_end], class);
        // Then the stretches INSIDE that line, which are more specific than the
        // row's own role and therefore win over it. Offsets are the producer's,
        // relative to text it wrote; the node's rendered start is added here,
        // which is the only place that knows it.
        for (n.spans.items) |s| {
            const sc = theme.classOf(s.role);
            if (sc == 0) continue;
            const lo = @min(start + s.start, classes.len);
            const hi = @min(start + s.end, classes.len);
            if (lo < hi) @memset(classes[lo..hi], sc);
        }
    }
    const version = doc.version(gpa) catch return;
    defer gpa.free(version);
    layer.publishBulk(gpa, version, 0, classes) catch {};
}

/// One render's answers, so the container is asked once per distinct role.
///
/// Fixed and small on purpose: a tree with more than this many distinct roles
/// is not a styling problem, and past the cap the extra roles simply resolve
/// every time rather than being wrong. Lives for one `paintStyles` call, which
/// is the whole window in which the answer is guaranteed not to move.
const RoleCache = struct {
    container: *const @import("../container.zig").Container,
    facts: @import("weft_facts").Facts,
    leaves: [24][]const u8 = undefined,
    classes: [24]u8 = undefined,
    n: usize = 0,

    fn classOf(self: *RoleCache, role: []const u8) u8 {
        const leaf = projection.leafOf(role);
        for (self.leaves[0..self.n], self.classes[0..self.n]) |seen, class| {
            if (std.mem.eql(u8, seen, leaf)) return class;
        }
        const class = projection.styleForIn(self.container, self.facts, role);
        if (self.n < self.leaves.len) {
            self.leaves[self.n] = leaf;
            self.classes[self.n] = class;
            self.n += 1;
        }
        return class;
    }
};

/// One invisible span per collapsed node, from just past its own line to the
/// end of its subtree — the header stays, the body goes.
fn paintFolds(p: *WasmPlugin, view: *projection.View, doc: anytype) void {
    const gpa = p.gpa;
    const layer = p.activeCtx().caps.layers.claim(gpa, doc, folds_layer_name, .local, p.name) catch return;
    layer.publishSpans(gpa, &.{}) catch return;
    for (view.nodes.items) |n| {
        if (!n.foldable) continue;
        if (!view.isCollapsed(n.key)) continue;
        if (n.end <= n.body) continue;
        layer.appendSpan(gpa, .{
            .start = n.body,
            .end = n.end,
            .kind = 0,
            .message = "",
            .face = .{ .invisible = true, .foldable = true },
        }) catch {};
    }
}

/// `wl_proj_at_cursor(out, cap) -> i32`: the KEY of the innermost row the
/// cursor is on. This is the only question a verb asks, and its answer is an
/// identity — never the offset that produced it.
pub fn hProjAtCursor(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const view = activeView(p) orelse {
        results[0] = -1;
        return;
    };
    const editor = p.activeCtx().buffers.active().textEditor() orelse {
        results[0] = -1;
        return;
    };
    const node = view.nodeAt(editor.cursorOffset()) orelse {
        // Empty space is not an error: the caller reads a zero-length key and
        // does nothing, which is what "the cursor is on no row" means.
        shared.writeExact(caller, args, results, "");
        return;
    };
    shared.writeExact(caller, args, results, node.key);
}

/// `wl_proj_toggle(key, key_len) -> i32`: flip a row's fold and re-render.
/// Unbounded — the collapsed set is exactly the keys you folded, where the
/// table this replaces held 64 and apologised past that.
pub fn hProjToggle(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    results[0] = -1;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const gpa = p.gpa;
    const view = activeView(p) orelse return;
    const key = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer gpa.free(key);
    if (view.byKey(key) == null) return; // a row the tree does not name
    view.toggleFold(key) catch return;
    // Re-lay the tree in hand. It used to swap the live tree through the
    // BUILDER to reuse `commit`, which emptied `nodes` for the length of the
    // swap — so the focus this repaint remembers was read from an empty tree,
    // came back null, and the cursor jumped to the top on every fold.
    results[0] = repaint(p, p.activeCtx().buffers.active(), view, .rerender) orelse -1;
}

/// `wl_proj_selection(key, key_len, out, cap) -> i32`: which body LINES of
/// `key` the selection covers, as two little-endian `u32` ordinals. -1 when the
/// selection touches no line of that row.
///
/// Ordinals, not offsets: a partial hunk is named by "lines 2 through 4 of this
/// row", which stays meaningful across a re-render and is refused outright once
/// the revision moves — where a byte range silently means something else.
pub fn hProjSelection(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const gpa = p.gpa;
    results[0] = -1;
    const view = activeView(p) orelse return;
    const key = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer gpa.free(key);
    const editor = p.activeCtx().buffers.active().textEditor() orelse return;
    const sel = editor.selectedRange() orelse return;
    const lines = view.selectedLines(key, sel.start, sel.end) orelse return;
    var out: [8]u8 = undefined;
    std.mem.writeInt(u32, out[0..4], @intCast(lines.lo), .little);
    std.mem.writeInt(u32, out[4..8], @intCast(lines.hi), .little);
    shared.writeExact(caller, args[2..], results, &out);
}

// ── Where a plugin's projection lives ─────────────────────────────────

/// A plugin's projection plus the entry it was captured against. The `Buffers.Ref`
/// is generation-checked, so an entry closed and its slot reused resolves to
/// nothing rather than to somebody else's buffer.
/// Find-or-create this plugin.s projection for `name`.
///
/// A plugin may hold SEVERAL — one per entry it projects. Not generality for
/// its own sake: git opens a session per repository, each with its own entry
/// (`*git*`, `*git:2*`, …), and a single slot meant the second repository.s
/// projection evicted the first.s, taking its fold state and node tree with it.
/// Find-or-create the projection for `entry`, owned by the ENTRY.
///
/// It lived on the plugin before, which was wrong twice over: one slot meant
/// git.s second repository evicted the first.s, and — the reason it moved —
/// core cannot ask a plugin what row the cursor is on. A projection is what
/// the rows on screen MEAN, so it belongs to the thing showing them, and
/// `intent.factsFor` can read a role off it without knowing a plugin exists.
fn viewFor(p: *WasmPlugin, entry: *Buffers.Buffer) ?*projection.View {
    const gpa = p.gpa;
    if (entry.projection) |existing| {
        // Another plugin.s projection is not this one.s to rebuild.
        if (!std.mem.eql(u8, existing.owner, p.name)) return null;
        return existing;
    }
    const created = gpa.create(projection.View) catch return null;
    created.* = .init(gpa);
    created.owner = gpa.dupe(u8, p.name) catch {
        gpa.destroy(created);
        return null;
    };
    entry.projection = created;
    return created;
}

/// The projection the QUERY doors are about: the ACTIVE entry.s, and only if
/// this plugin owns it. A verb asks what the cursor is on, and the cursor is
/// in exactly one entry — so which projection answers is a fact about focus,
/// not a guess and not last-one-wins.
fn activeView(p: *WasmPlugin) ?*projection.View {
    const view = p.activeCtx().buffers.active().projection orelse return null;
    return if (std.mem.eql(u8, view.owner, p.name)) view else null;
}

/// Drop this plugin.s claim on any open build. The VIEWS are not freed here:
/// each belongs to its entry and dies with it, which is why a projection
/// outlives the plugin that built it exactly as the text does. What must not
/// outlive the plugin is a half-finished build pointing at one.
pub fn release(p: *WasmPlugin) void {
    p.proj_building = null;
}
