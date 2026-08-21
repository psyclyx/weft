//! Typed commands over a portable value ABI. A command is a name, a
//! typed argument schema, and a handler; invocation goes value-ABI in,
//! value-ABI out, so every caller — keymaps, the M5 Lua/Fennel VMs, other
//! commands — uses the same door. The schema is *derived* from a typed
//! Zig function at comptime (`define`), so built-in commands are ordinary
//! functions and the validation layer cannot drift from the signature.

const std = @import("std");
const Allocator = std.mem.Allocator;

const registry = @import("registry.zig");
const Document = @import("Document.zig");
const Editor = @import("Editor.zig");
const Buffers = @import("Buffers.zig");
const Keymap = @import("Keymap.zig");
const Head = @import("Head.zig");
const Actions = @import("action.zig");
const capability = @import("capability.zig");
const authority = @import("authority.zig");
const position = @import("position.zig");

pub const Principal = authority.Principal;
pub const Grade = authority.Grade;

/// The portable argument/result ABI. Mirrors what a Lua boundary can
/// carry; strings are borrowed for the duration of the call.
pub const Value = union(enum) {
    nil,
    boolean: bool,
    integer: i64,
    number: f64,
    string: []const u8,
    /// A version-stamped position ([FIX 1]): the honest way a position
    /// crosses the ABI. It rebases through the commit log to a current
    /// offset or to null — never a bare offset that silently breaks under
    /// concurrent edits. Backed by position.zig; borrowed for the call
    /// (its version token, like `string`). The prerequisite for
    /// motions-that-return-ranges and the pick pool's anchor column.
    anchor: position.StampedOffset,
    /// A version-stamped range — a stamped `(start, end)`.
    range: position.StampedRange,
};

pub const Type = std.meta.Tag(Value);

pub const ArgSpec = struct {
    name: []const u8,
    type: Type,
};

/// Everything a handler may touch — the whole editor surface, because
/// commands ARE the editor's features. Commands only ever see this,
/// never core internals. `editor()`/`document()` always mean the
/// ACTIVE buffer — a buffer switch mid-command redirects the rest of
/// the command, which is the honest semantics.
pub const Context = struct {
    gpa: Allocator,
    buffers: *Buffers,
    commands: *Commands,
    /// The system-scoped keymap TABLES (bindings, fallback chains, menu/
    /// locked/resting declarations) — shared by every head attached to this
    /// system. See `Keymap.zig`'s module doc for the table/cursor split.
    keymap: *Keymap,
    actions: *Actions,
    caps: *@import("capability.zig").Caps,
    quit: *bool,
    /// The interaction state of the head DISPATCHING this call — current
    /// mode, pending chord, pick session, echo line (north-star-plan §2.7/§4
    /// C14/§6 W2a-1). The SINGLE way core code reaches interaction state; two
    /// heads on one system get two `Head`s, so there is no shared mode/pick/
    /// echo left to collide on. The e2e harness and `main()` construct
    /// exactly one `Head` today — W2a-2 is what makes more than one live.
    head: *Head,
    /// Who is invoking right now (default: the interactive user). Plugins
    /// swap this in around their trampolines so their edits GRADE-gate as the
    /// plugin peer — see `plugin.zig`.
    principal: Principal = Principal.user,
    /// Set for the synchronous handling of a user keystroke/command. A helper
    /// plugin (dw, autopair, comment) editing under this flag is the USER's
    /// edit — it joins the user's single undo history (still grade-gated as the
    /// plugin). Cleared for AUTONOMOUS plugin/agent activity (async ticks,
    /// streaming), whose edits stay their own peer — the per-principal
    /// selective-undo property we keep for collaborators and agents.
    user_initiated: bool = false,

    pub fn buffer(self: *Context) *Buffers.Buffer {
        return self.buffers.active();
    }

    /// Snapshot the ambient facts an action's `when` predicate resolves
    /// against: the active keymap mode + the active buffer's language (its
    /// name's extension). Borrowed for the duration of the call.
    pub fn actionCtx(self: *Context) Actions.Ctx {
        return .{
            .mode = self.head.currentMode(),
            .lang = Actions.langOfName(self.buffers.active().name),
            // The active buffer's projection identity — the reliable per-buffer
            // signal a projection scopes `save`/etc. by (mode changes as you
            // edit; the tool-backing doesn't). "" when not a tool projection.
            .tool = self.editor().toolName() orelse "",
        };
    }

    /// Fire a `race`-policy intent (completion/hover/definition/…): the capability
    /// system's async fan-out. This is the seam the capability call sites route
    /// through instead of touching `caps` directly — it records the kind as a
    /// race action in the registry (so every intent, pick and race, is
    /// enumerable in one place) and then drives `Caps`, returning the session id
    /// to poll (or null when no provider matches). The consumer UIs own the
    /// session/poll lifecycle; this owns the dispatch entry.
    pub fn fireRace(
        self: *Context,
        kind: capability.Kind,
        doc: *Document,
        path: ?[]const u8,
        opts: capability.Caps.FireOptions,
    ) !?u64 {
        self.actions.noteRace(kind.actionName());
        return self.caps.fire(kind, doc, path, opts);
    }

    pub fn editor(self: *Context) *Editor {
        return &self.buffers.active().editor;
    }

    pub fn document(self: *Context) *Document {
        return &self.buffers.active().editor.doc;
    }

    pub const EditError = Document.AddPeerError || error{Unauthorized};

    /// The invoking principal's grade on `doc`. The user inherits the
    /// document's own grade; a plugin/agent may not exceed `.edit` (nor the
    /// user's grade), per the design's `min(owner_grant, manifest_max)`
    /// until per-plugin manifests bound it more tightly.
    pub fn gradeOn(self: *Context, doc: *Document) Grade {
        const local = doc.my_grant;
        return switch (self.principal.role) {
            .user, .remote => local,
            .plugin, .agent => authority.gradeMin(local, .edit),
        };
    }

    /// INTERACTIVE edit: delete `r`, insert `bytes` on the ACTIVE document as a
    /// direct user/tool text mutation. This is the door for typing, vim
    /// operators, autopair, comment — anything that edits text AS text. It is
    /// refused on a read-only span/buffer (§`render` is the door for producing
    /// derived content there), so a projection like magit/dired has NO
    /// interactive-edit path at all — no mode, split, or plugin can corrupt it
    /// as text. Refusal leaves the replica untouched (no ghost commit).
    pub fn edit(self: *Context, r: Document.Range, bytes: []const u8) EditError!void {
        if (self.buffer().read_only or self.readOnlyOverlaps(r)) return error.Unauthorized;
        return self.applyEdit(r, bytes, self.user_initiated);
    }

    /// Whether `r` overlaps a read-only SPAN of the active buffer — the
    /// span-level guard (a comint's produced output is read-only, its input line
    /// editable). A caret AT a span boundary may still type (insert adjacent);
    /// only a range that actually reaches into read-only content is refused.
    fn readOnlyOverlaps(self: *Context, r: Document.Range) bool {
        const layer = self.buffer().editor.readonly_layer orelse return false;
        var i: usize = 0;
        const n = layer.spanCount();
        while (i < n) : (i += 1) {
            const s = layer.resolvedSpan(i);
            if (r.start < s.end and s.start < r.end) return true; // ranges overlap
            if (r.isEmpty() and r.start > s.start and r.start < s.end) return true; // insert INSIDE
        }
        return false;
    }

    /// CONTENT PRODUCTION: draw a derived/streamed projection (magit's status
    /// tree, dired's listing, an agent transcript) into a buffer. A DISTINCT
    /// operation from `edit` — it BYPASSES read-only (that's the point: the text
    /// is output, regenerated from a model, not user-editable), and it authors
    /// as the plugin's OWN peer (never the user's undo — a re-render isn't a
    /// user edit). Any plugin may render (no single owner); still grade-gated.
    /// A read-only buffer's content is thus editable only by re-rendering, while
    /// an EDITABLE projection (mini.files dired) simply isn't marked read-only
    /// and takes `edit`.
    pub fn render(self: *Context, r: Document.Range, bytes: []const u8) EditError!void {
        return self.applyEdit(r, bytes, false); // never joins user undo
    }

    /// The shared apply: grade-gate, then route to the user's single undo
    /// history (the user, or a helper plugin acting on the user's keystroke) or
    /// to the principal's own selective-undo peer. `join_user` is the caller's
    /// intent — set for interactive edits, cleared for renders/autonomous work.
    /// An `.agent`/`.remote` NEVER joins the user's undo even under a keystroke.
    fn applyEdit(self: *Context, r: Document.Range, bytes: []const u8, join_user: bool) EditError!void {
        const doc = self.document();
        if (!self.gradeOn(doc).canEdit()) return error.Unauthorized;
        const joins_user_undo = self.principal.role == .user or
            (join_user and self.principal.role == .plugin);
        if (joins_user_undo) {
            try self.editor().applyUserEdit(self.gpa, r, bytes);
            return;
        }
        const pid = try self.principal.peerOn(doc);
        var snap = try doc.peerSnapshot(self.gpa, pid);
        snap.deinit(self.gpa);
        if (!r.isEmpty()) try doc.peerDelete(self.gpa, pid, r);
        if (bytes.len > 0) try doc.peerInsert(self.gpa, pid, r.start, bytes);
        _ = try doc.peerCommit(self.gpa, pid);
    }
};

pub const RenderError = Document.AddPeerError || error{Unauthorized};

/// Content production into a background document — the doc-targeted twin of
/// `Context.render`, and the ONE home of the content-production membrane for
/// streamed/async producers (repl, net, proc→buffer, agent fs-writes) that
/// target a buffer OTHER than the active one, where the active-doc-only
/// `Context.render` can't reach. Same contract: the single grade gate
/// (plugin/agent capped at `.edit`, per the design's `min(owner_grant,
/// manifest_max)`), authored as the named peer, one atomic commit, never the
/// user's undo. Producers MUST route through this instead of re-deriving the
/// gate (`gradeMin` + `peerNamed` + `peerReplaceAll`) — a fragmented gate is a
/// policy that drifts when per-plugin manifests tighten the `.edit` cap.
pub fn renderInto(
    gpa: Allocator,
    doc: *Document,
    role: authority.Role,
    name: []const u8,
    items: []const Document.Replacement,
) RenderError!void {
    const grade = switch (role) {
        .user, .remote => doc.my_grant,
        .plugin, .agent => authority.gradeMin(doc.my_grant, .edit),
    };
    if (!grade.canEdit()) return error.Unauthorized;
    const pid = try doc.peerNamed(gpa, name);
    doc.peerReplaceAll(gpa, pid, items) catch {};
}

pub const Command = struct {
    name: []const u8,
    summary: []const u8,
    args: []const ArgSpec,
    /// `data` is the command's closure payload (null for comptime-typed
    /// commands; a VM trampoline for scripted ones).
    handler: *const fn (ctx: *Context, data: ?*anyopaque, args: []const Value) anyerror!Value,
    data: ?*anyopaque = null,
};

pub const Commands = registry.Registry(Command);

pub const RunError = error{UnknownCommand} || anyerror;

/// Invoke by name — resolution happens *now* (late binding), then the
/// schema-checking wrapper validates `args` before the typed handler
/// runs.
pub fn run(commands: *const Commands, ctx: *Context, name: []const u8, args: []const Value) RunError!Value {
    const cmd = commands.resolve(name) orelse return error.UnknownCommand;
    return cmd.handler(ctx, cmd.data, args);
}

/// The trampoline a declared action is registered under (see `registerAction`):
/// resolve the action name against the live context and tail-call the winning
/// provider's command with the same args. A `pick` action with no applicable
/// provider is a graceful no-op with feedback (never an error — pressing an
/// action key in the wrong buffer should explain, not fail). A `race` action's
/// synchronous trampoline resolves nothing (its providers answer over time
/// through `Caps`); it's a no-op here by design, surfaced as such.
pub fn actionTrampoline(ctx: *Context, data: ?*anyopaque, args: []const Value) anyerror!Value {
    const tr: *Actions.Trampoline = @ptrCast(@alignCast(data.?));
    if (ctx.actions.resolve(tr.name, ctx.actionCtx())) |cmd| {
        return run(ctx.commands, ctx, cmd, args);
    }
    ctx.head.echo.clearRetainingCapacity();
    const lang = Actions.langOfName(ctx.buffers.active().name);
    var buf: [128]u8 = undefined;
    const msg = if (lang.len > 0)
        std.fmt.bufPrint(&buf, "no {s} provider for .{s}", .{ tr.name, lang }) catch tr.name
    else
        std.fmt.bufPrint(&buf, "no {s} provider here", .{tr.name}) catch tr.name;
    ctx.head.echo.appendSlice(ctx.gpa, msg) catch {};
    return .nil;
}

/// Declare an action and bind its same-named trampoline `Command`, so the
/// keymap, ex, palette, and `command.run` all dispatch it uniformly. Idempotent
/// per the underlying `Actions.declare`; a re-declare just binds another
/// trampoline for the same name (they resolve identically).
pub fn registerAction(
    gpa: Allocator,
    commands: *Commands,
    actions: *Actions,
    name: []const u8,
    policy: Actions.Policy,
) !void {
    const tr = try actions.declare(name, policy);
    _ = try commands.bind(gpa, name, .{
        .name = name,
        .summary = "action",
        .args = &.{},
        .handler = actionTrampoline,
        .data = tr,
    });
}

/// Derive a `Command` from a typed function at comptime. `f` must be
/// `fn (*Context, Args) anyerror!Value` where `Args` is a struct whose
/// fields are `bool`, `i64`, `f64`, `[]const u8`, or `Value` (untyped
/// passthrough). Field order is the positional argument order; the
/// generated wrapper checks arity and types against the schema.
pub fn define(
    comptime name: []const u8,
    comptime summary: []const u8,
    comptime f: anytype,
) Command {
    const Args = ArgsStructOf(f);
    const fields = @typeInfo(Args).@"struct".fields;

    const specs = comptime blk: {
        var s: [fields.len]ArgSpec = undefined;
        for (fields, 0..) |fld, i| {
            s[i] = .{ .name = fld.name, .type = typeOf(fld.type) };
        }
        const frozen = s;
        break :blk frozen;
    };

    const Wrap = struct {
        fn call(ctx: *Context, data: ?*anyopaque, args: []const Value) anyerror!Value {
            _ = data;
            if (args.len != fields.len) return error.ArityMismatch;
            var typed: Args = undefined;
            inline for (fields, 0..) |fld, i| {
                @field(typed, fld.name) = try unpack(fld.type, args[i]);
            }
            return f(ctx, typed);
        }
    };

    return .{
        .name = name,
        .summary = summary,
        .args = &specs,
        .handler = Wrap.call,
    };
}

fn ArgsStructOf(comptime f: anytype) type {
    const params = @typeInfo(@TypeOf(f)).@"fn".params;
    if (params.len != 2 or params[0].type != *Context) {
        @compileError("command fn must be fn (*Context, Args) anyerror!Value");
    }
    return params[1].type.?;
}

fn typeOf(comptime T: type) Type {
    return switch (T) {
        bool => .boolean,
        i64 => .integer,
        f64 => .number,
        []const u8 => .string,
        position.StampedOffset => .anchor,
        position.StampedRange => .range,
        Value => .nil, // untyped: schema says nil-able, wrapper passes through
        else => @compileError("unsupported command arg type " ++ @typeName(T)),
    };
}

fn unpack(comptime T: type, v: Value) error{TypeMismatch}!T {
    if (T == Value) return v;
    return switch (T) {
        bool => if (v == .boolean) v.boolean else error.TypeMismatch,
        i64 => if (v == .integer) v.integer else error.TypeMismatch,
        f64 => if (v == .number) v.number else error.TypeMismatch,
        []const u8 => if (v == .string) v.string else error.TypeMismatch,
        position.StampedOffset => if (v == .anchor) v.anchor else error.TypeMismatch,
        position.StampedRange => if (v == .range) v.range else error.TypeMismatch,
        else => unreachable,
    };
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

fn insertText(ctx: *Context, args: struct { offset: i64, text: []const u8 }) anyerror!Value {
    try ctx.document().insert(ctx.gpa, @intCast(args.offset), args.text);
    return .{ .integer = @intCast(ctx.document().text().byteLen()) };
}

test "command Value: a stamped range rebases through a concurrent edit or nulls" {
    const gpa = t.allocator;
    var doc = try Document.init(gpa, "user");
    defer doc.deinit(gpa);
    try doc.insert(gpa, 0, "hello");
    const v0 = try doc.version(gpa);
    defer gpa.free(v0);

    // Carry a stamped range as an ABI Value; a concurrent head insert shifts
    // it, and it rebases to the current offsets (never a bare stale offset).
    const val: Value = .{ .range = position.StampedRange.at(v0, 0, 5) };
    try doc.insert(gpa, 0, "XYZ");
    const r = val.range.rebase(&doc).?;
    try t.expectEqual(@as(usize, 3), r.start);
    try t.expectEqual(@as(usize, 8), r.end);

    // An unknown version rebases to null — rebase or discard, no third result.
    const bogus: Value = .{ .range = position.StampedRange.at("nope", 0, 5) };
    try t.expectEqual(@as(?Document.Range, null), bogus.range.rebase(&doc));

    // The value survives the typed-arg door too (unpack round-trips it).
    try t.expectEqual(Type.range, comptime typeOf(position.StampedRange));
}

test "command: schema derivation, validation, late-bound run" {
    const gpa = t.allocator;
    const task = @import("task.zig");
    var pool = try task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    var buffers = try Buffers.init(gpa, pool, "user");
    defer buffers.deinit(gpa);
    var keymap: Keymap = .empty;
    defer keymap.deinit(gpa);
    var head: Head = .empty;
    defer head.deinit(gpa);
    var caps = @import("capability.zig").Caps.init(gpa, @import("task.zig").nowNs);
    defer caps.deinit();
    var actions = Actions.init(gpa);
    defer actions.deinit();
    var quit = false;

    var commands: Commands = .empty;
    defer commands.deinit(gpa);
    var ctx: Context = .{
        .gpa = gpa,
        .buffers = &buffers,
        .commands = &commands,
        .keymap = &keymap,
        .actions = &actions,
        .caps = &caps,
        .quit = &quit,
        .head = &head,
    };

    // Late binding: invoked-by-name before it exists → UnknownCommand.
    try t.expectError(error.UnknownCommand, run(&commands, &ctx, "insert-text", &.{}));

    const cmd = comptime define("insert-text", "Insert text at a byte offset.", insertText);
    try t.expectEqual(@as(usize, 2), cmd.args.len);
    try t.expectEqual(Type.integer, cmd.args[0].type);
    try t.expectEqual(Type.string, cmd.args[1].type);
    try t.expectEqualStrings("offset", cmd.args[0].name);
    _ = try commands.bind(gpa, "insert-text", cmd);

    // Wrong arity / wrong types are rejected before the handler runs.
    try t.expectError(error.ArityMismatch, run(&commands, &ctx, "insert-text", &.{.nil}));
    try t.expectError(error.TypeMismatch, run(&commands, &ctx, "insert-text", &.{
        .{ .string = "oops" }, .{ .string = "hi" },
    }));
    try t.expectEqual(@as(usize, 0), buffers.active().editor.text().byteLen());

    const res = try run(&commands, &ctx, "insert-text", &.{
        .{ .integer = 0 }, .{ .string = "graft" },
    });
    try t.expectEqual(Value{ .integer = 5 }, res);
    try t.expectEqual(@as(usize, 5), buffers.active().editor.text().byteLen());
}

test "command: an agent principal authors as its own peer even under a keystroke" {
    const gpa = t.allocator;
    const task = @import("task.zig");
    var pool = try task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    var buffers = try Buffers.init(gpa, pool, "user");
    defer buffers.deinit(gpa);
    var keymap: Keymap = .empty;
    defer keymap.deinit(gpa);
    var head: Head = .empty;
    defer head.deinit(gpa);
    var caps = @import("capability.zig").Caps.init(gpa, task.nowNs);
    defer caps.deinit();
    var actions = Actions.init(gpa);
    defer actions.deinit();
    var quit = false;
    var commands: Commands = .empty;
    defer commands.deinit(gpa);
    var ctx: Context = .{
        .gpa = gpa,
        .buffers = &buffers,
        .commands = &commands,
        .keymap = &keymap,
        .actions = &actions,
        .caps = &caps,
        .quit = &quit,
        .head = &head,
    };
    const doc = ctx.document();

    // Seed as the user (a keystroke): realizes the base + a user-authored commit.
    ctx.user_initiated = true;
    try ctx.edit(.{ .start = 0, .end = 0 }, "hello");
    const after_user = doc.commitCount();
    try t.expect(after_user >= 1);
    try t.expectEqual(Document.PeerId.user, doc.commitAt(after_user - 1).author);

    // An AGENT edit, STILL under the keystroke (user_initiated stays true). The
    // refinement: an .agent never folds into the user's undo history — it
    // commits as its own peer, so the new commit's author is not `.user`. (A
    // helper .plugin under the same flag WOULD join the user's history.)
    const AgentCtx = struct {
        gpa: std.mem.Allocator,
        name: []const u8,
        fn resolve(actx: *anyopaque, d: *Document) Document.AddPeerError!Document.PeerId {
            const a: *@This() = @ptrCast(@alignCast(actx));
            return d.peerNamed(a.gpa, a.name);
        }
    };
    var actx = AgentCtx{ .gpa = gpa, .name = "claude" };
    ctx.principal = .{ .role = .agent, .name = "claude", .ctx = &actx, .resolve = AgentCtx.resolve };
    try ctx.edit(.{ .start = 5, .end = 5 }, "!");
    const after_agent = doc.commitCount();
    try t.expect(after_agent > after_user);
    try t.expect(doc.commitAt(after_agent - 1).author != Document.PeerId.user);
}

test "command: read-only refuses interactive edit, allows render (in depth)" {
    const gpa = t.allocator;
    const task = @import("task.zig");
    var pool = try task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    var buffers = try Buffers.init(gpa, pool, "user");
    defer buffers.deinit(gpa);
    var keymap: Keymap = .empty;
    defer keymap.deinit(gpa);
    var head: Head = .empty;
    defer head.deinit(gpa);
    var caps = @import("capability.zig").Caps.init(gpa, task.nowNs);
    defer caps.deinit();
    var actions = Actions.init(gpa);
    defer actions.deinit();
    var quit = false;
    var commands: Commands = .empty;
    defer commands.deinit(gpa);
    var ctx: Context = .{
        .gpa = gpa,
        .buffers = &buffers,
        .commands = &commands,
        .keymap = &keymap,
        .actions = &actions,
        .caps = &caps,
        .quit = &quit,
        .head = &head,
    };

    // Seed via render (content production), THEN mark the buffer read-only.
    ctx.user_initiated = true;
    try ctx.edit(.{ .start = 0, .end = 0 }, "tree");
    ctx.buffer().read_only = true;

    const Peer = struct {
        gpa: std.mem.Allocator,
        name: []const u8,
        fn resolve(o: *anyopaque, d: *Document) Document.AddPeerError!Document.PeerId {
            const a: *@This() = @ptrCast(@alignCast(o));
            return d.peerNamed(a.gpa, a.name);
        }
    };

    // INTERACTIVE edit is refused for EVERYONE — the user, and a vim-operator
    // plugin (no owner exception). No ghost commit; the text is untouched.
    ctx.principal = .user; // name "user"
    try t.expectError(error.Unauthorized, ctx.edit(.{ .start = 0, .end = 1 }, ""));
    var ops = Peer{ .gpa = gpa, .name = "operators" };
    ctx.principal = .{ .role = .plugin, .name = "operators", .ctx = &ops, .resolve = Peer.resolve };
    try t.expectError(error.Unauthorized, ctx.edit(.{ .start = 0, .end = 1 }, ""));
    const mid = try ctx.document().text().toOwnedSlice(gpa);
    defer gpa.free(mid);
    try t.expectEqualStrings("tree", mid);

    // RENDER (content production) is a DIFFERENT door — it bypasses read-only,
    // so a projection's renderer (ANY plugin, not one owner) can redraw it.
    var dired = Peer{ .gpa = gpa, .name = "dired" };
    ctx.principal = .{ .role = .plugin, .name = "dired", .ctx = &dired, .resolve = Peer.resolve };
    try ctx.render(.{ .start = 0, .end = 4 }, "TREE");
    const out = try ctx.document().text().toOwnedSlice(gpa);
    defer gpa.free(out);
    try t.expectEqualStrings("TREE", out);

    // ── Span-level: a read-only SPAN (a comint's output) refuses edits inside
    // it, while the rest of the buffer (its input line) stays editable.
    ctx.buffer().read_only = false;
    ctx.principal = .user;
    ctx.user_initiated = true;
    const doc2 = ctx.document();
    const ro = try ctx.caps.layers.claim(gpa, doc2, "readonly", .local, "test");
    try ro.appendSpan(gpa, .{ .start = 0, .end = 2, .kind = 0, .message = "", .face = .{} });
    ctx.buffer().editor.readonly_layer = ctx.caps.layers.find(doc2, "readonly");
    // "TREE": [0,2) is read-only; an edit reaching into it is refused, an edit
    // past it (the "input line") is allowed.
    try t.expectError(error.Unauthorized, ctx.edit(.{ .start = 1, .end = 2 }, "x"));
    try ctx.edit(.{ .start = 4, .end = 4 }, "!"); // append after the RO span → ok
    const out2 = try ctx.document().text().toOwnedSlice(gpa);
    defer gpa.free(out2);
    try t.expectEqualStrings("TREE!", out2);
}
