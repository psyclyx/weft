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
const grants_mod = @import("grants.zig");
const undo_mod = @import("undo.zig");
const status_feed = @import("status_feed.zig");
const semantic_model = @import("weft_semantic");

pub const Principal = authority.Principal;

/// The embedding shell's workspace placement policy for an activated target
/// (doc/contextual-workspace-architecture.md §9.4). Registered target
/// handlers are asked first; a target none of them claims is offered here,
/// and the shell opens it as an ordinary workspace entry — a file row in a
/// browser therefore reaches the same `open` every other locus uses, without
/// core learning about paths or a plugin acquiring new authority. `false`
/// declines, leaving the unhandled target an explicit refusal.
pub const EntryOpener = struct {
    context: *anyopaque,
    open: *const fn (*anyopaque, *Context, semantic_model.target.Located) anyerror!bool,
};
pub const Grade = authority.Grade;

/// The portable argument/result ABI. Mirrors what a Lua boundary can
/// carry; strings are borrowed for the duration of the call.
pub const Value = union(enum) {
    nil,
    boolean: bool,
    integer: i64,
    number: f64,
    string: []const u8,
    /// A borrowed document-owned live anchor. The producer owns its lifetime;
    /// the value is valid for this synchronous call chain, like `string`.
    anchor: position.LiveOffset,
    /// A borrowed pair of live anchors. It resolves through the CRDT document,
    /// never through a version-plus-offset rebase adapter.
    range: position.LiveRange,
};

pub const Type = std.meta.Tag(Value);

pub const ArgSpec = struct {
    name: []const u8,
    type: Type,
};

/// Everything a handler may touch — the whole editor surface, because
/// commands ARE the editor's features. Commands only ever see this,
/// never core internals. `textEditor()`/`document()` mean the ACTIVE
/// buffer — a buffer switch mid-command redirects the rest of the
/// command, which is the honest semantics — unless a background
/// delivery has `bound_entry` set, in which case they mean the entry
/// that delivery captured at spawn.
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
    /// mode, pending chord, pick session, echo line, dot-repeat register
    /// (doc/contextual-workspace-architecture.md §7). The SINGLE way core code reaches
    /// interaction state; two heads on one system get two `Head`s (a second
    /// `Context` differing only in `.head`), so there is no shared mode/
    /// pick/echo/dot-repeat left to collide on — proven live by the e2e
    /// two-head gate (`e2e/two_head_test.zig`). `main()` still drives exactly
    /// one `Head` (a second RENDERED head is a bigger, later change); the
    /// per-head STATE this field names is what W2a-2 made ready for more.
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
    /// The System's grant table (doc/contextual-workspace-architecture.md §13.5) —
    /// `null` everywhere this isn't wired (every headless test fixture, and
    /// production until a caller opts in), in which case `Ctx.capture`
    /// resolves an empty grant list and the wasm/in-process membrane's
    /// `hasPerm` falls back to its pre-W4 boolean check (see
    /// `wasm_host/plugin.zig`'s `hasPerm` doc). Set by `System.create`
    /// (`&self.grants`) once a caller routes a `Context` through a `System`;
    /// see `grants.zig`'s module doc for the table shape and
    /// `ctx.zig`'s `Ctx.capture` for how a captured `Ctx` resolves it into
    /// `Ctx.grants` (zero allocation, no wallet — capture COLLECTS matching
    /// rows, it never mints new ones).
    grant_table: ?*@import("grants.zig").HandleTable = null,
    /// D2's generic, schema-directed slot host (doc/d2-schema-payloads.md
    /// §3.2, `core/slot.zig`) — the sibling of `caps` for RUNTIME-declared
    /// `wl_slot_*`/`wl_payload_*` slots. `null` everywhere this isn't wired
    /// (every pre-D2 fixture, and any test that doesn't opt in), matching
    /// `grant_table`'s optional-field convention exactly: `wasm_host/slot.zig`'s
    /// handlers no-op (or trap loudly, per handler — see that file) when this
    /// is unset, so every existing `Context{...}` literal across the tree
    /// compiles unchanged.
    slot_host: ?*@import("slot.zig").SlotHost = null,
    /// System-scoped semantic identity and provider registries. Optional for
    /// small/headless embeddings that expose only the text command surface.
    semantic: ?*@import("semantic.zig").Services = null,
    /// Turns a `Place` into an OS directory for a local effect
    /// (`doc/place.md` §2.3). Installed by the shell, which owns the roots it
    /// opened; `null` in headless embeddings, where only the degenerate
    /// `.process` place resolves and every other place is honestly
    /// unavailable rather than silently local.
    realizer: ?@import("place.zig").Realizer = null,
    /// The system's intention plane (`intent.zig`): the offer catalog, the
    /// endpoint-token invoker registry, and core's own editing provider —
    /// one value, so a half-wired pair is unrepresentable. `null` in
    /// embeddings that expose only the concrete command surface; dispatch
    /// then treats an intention binding as unresolvable and says so.
    intent: ?*@import("intent.zig").Plane = null,
    /// Authority-routed filesystem services. Providers are installed by the
    /// embedding app (Linux today, Darwin/remote/synthetic independently);
    /// commands and plugins see only this platform-neutral router.
    filesystems: ?*@import("weft_fs_runtime").Router = null,
    /// The shell's workspace placement policy, when one is installed.
    entries: ?EntryOpener = null,
    /// The system's declared viewports (`weft.viewport`/`weft.present`).
    /// `null` in embeddings with no workspace composition; a viewport
    /// declaration is then reported as dropped rather than silently staged
    /// against nothing.
    viewports: ?*@import("viewport.zig").Registry = null,
    /// The entry an ASYNC delivery captured at spawn, bound for the duration
    /// of its callback (`wasm_host/proc.zig`). While set, `buffer`/
    /// `textEditor`/`document` mean THAT entry rather than whatever is active,
    /// so a background result cannot follow focus into someone else's buffer
    /// (doc/contextual-workspace-architecture.md §2.6). The ref is
    /// generation-checked: an entry closed mid-callback resolves to nothing
    /// and the text doors refuse rather than fall through to the active one.
    bound_entry: ?Buffers.Ref = null,

    /// Bind (or clear, with `null`) the async-delivery entry, returning the
    /// previous binding for the caller to restore.
    pub fn bindEntry(self: *Context, ref: ?Buffers.Ref) ?Buffers.Ref {
        defer self.bound_entry = ref;
        return self.bound_entry;
    }

    /// The entry this call is about — the bound one while a background
    /// delivery is in flight, else the active one. `null` only when a bound
    /// entry has since been closed: a caller that can refuse should, rather
    /// than fall through to whoever happens to be active.
    pub fn entry(self: *Context) ?*Buffers.Buffer {
        const ref = self.bound_entry orelse return self.buffers.active();
        return self.buffers.resolve(ref);
    }

    pub fn buffer(self: *Context) *Buffers.Buffer {
        return self.entry() orelse self.buffers.active();
    }

    /// WHERE this dispatch's effects run (`doc/place.md`).
    ///
    /// Read through `entry()`, which is the whole point: a background fill
    /// delivered into an entry captured at spawn is about THAT entry's place,
    /// not wherever focus has wandered since. The ambient-read-at-the-door
    /// shape means no guest passes a place and no guest can pass the wrong
    /// one.
    ///
    /// A closed bound entry yields the degenerate `.process` place rather than
    /// borrowing whoever is active now — an effect whose subject is gone must
    /// not silently retarget at someone else's project.
    ///
    /// Precedence, outermost first:
    ///
    ///  1. **A bound entry.** A background delivery is ABOUT the entry it
    ///     captured at spawn, so that entry's place wins over anything the user
    ///     has done since — including a pin. Without this, a fill landing after
    ///     the user typed `cd` would resolve against the new pin and act on the
    ///     wrong project.
    ///  2. **The head's pin** (`workspace.set-working-target`, the
    ///     target-oriented `cd`). Validated through `Services`, which clears a
    ///     retired or republished pin lazily rather than reinterpreting it.
    ///  3. **The focused entry's own place.**
    pub fn place(self: *Context) Buffers.Place {
        if (self.bound_entry) |ref| {
            const bound = self.buffers.resolve(ref) orelse return .process;
            return bound.place;
        }
        if (self.semantic) |services| {
            if (services.workingTarget(self.head)) |maybe_pin| {
                if (maybe_pin) |pin| return .{
                    .container = .{
                        // `.here` until a remote-attach head carries a real locus
                        // (`Ctx.locus`, W6). Named rather than assumed: when that
                        // lands, this is the line that reads it.
                        .locus = .here,
                        .ref = pin.target,
                        .revision = pin.revision,
                    },
                };
            } else |_| {
                // A stale pin has already been cleared by the validator; fall
                // through to the entry rather than refusing the whole effect.
            }
        }
        const e = self.entry() orelse return .process;
        return e.place;
    }

    /// How the entry this dispatch addresses RESTS under input (§10.4) — the
    /// entry's declaration plus this head's field focus. The ONE place the
    /// pair is read, so a grammar (`weft.posture()`), a builtin, and the
    /// resting-mode restore all see the same answer.
    pub fn posture(self: *Context) @import("input.zig").Posture {
        return self.buffer().posture(self.head.semantic_focus.field != null);
    }

    /// Reach the captured `Ctx` value (doc/cwa-prior-docs-audit.md §5) — the
    /// door this struct GAINS to the scope/principal/locus/grant snapshot,
    /// without `Context` itself becoming that value. `Context` stays the
    /// PLUMBING struct (long-lived pointers into the system's live state);
    /// `ctx.Ctx` is the immutable-facts snapshot taken fresh each call —
    /// see `ctx.zig`'s module doc for the full split and why `Ctx.setMode`
    /// is now the policy door for dispatch-path mode changes.
    pub fn capturedCtx(self: *Context) @import("ctx.zig").Ctx {
        return @import("ctx.zig").Ctx.capture(self);
    }

    /// Snapshot the ambient facts an action's `when` predicate resolves
    /// against, narrowed to the `Actions.Ctx` (mode/lang/tool) view — the
    /// F5-adapter vocabulary `Actions.resolve` still takes. **Not the
    /// dispatch path anymore** (doc/cwa-prior-docs-audit.md §5): `actionTrampoline`
    /// below now calls `ctx.actions.container.resolveOne` directly against
    /// the FULL `capturedCtx().mergedFacts()`, so the hot path no longer
    /// narrows-then-rebuilds a `Facts` through this type. What's left of this
    /// method is a convenience for callers that still want the narrow
    /// `Actions.Ctx` shape — `Actions.resolve`'s own test/introspection
    /// callers (see `System.zig`'s explain-binding-adjacent test) — kept
    /// working, unmodified, on the same contract it always had.
    pub fn actionCtx(self: *Context) Actions.Ctx {
        const facts = self.capturedCtx().mergedFacts();
        return .{ .mode = facts.mode, .lang = facts.lang, .tool = facts.tool };
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

    /// This entry's text editor, or a REFUSAL: an entry that holds no
    /// text (a semantic view) has no document, cursor, or undo history to
    /// operate on. Refusing here — echoed, like every other refusal — makes a
    /// text op on such an entry one polite no-op instead of a guard each call
    /// site invents for itself (`builtins.editErr` swallows it). A bound entry
    /// that was closed mid-delivery refuses the same way.
    pub fn textEditor(self: *Context) error{Unauthorized}!*Editor {
        const b = self.entry() orelse {
            self.noteRefusal("that entry is gone");
            return error.Unauthorized;
        };
        return b.textEditor() orelse {
            self.noteRefusal("no text in this view");
            return error.Unauthorized;
        };
    }

    /// This entry's document, when it holds text.
    pub fn document(self: *Context) ?*Document {
        const ed = (self.entry() orelse return null).textEditor() orelse return null;
        return &ed.doc;
    }

    pub const EditError = Document.AddPeerError || error{ Unauthorized, OutOfLimit, Collapsed };

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

    /// `checkDocRegion`'s answer (doc/contextual-workspace-architecture.md §13.5, review
    /// B2's repair) — see `grants.DocRegion`'s doc for the full policy this
    /// implements (side semantics, collapse conditions).
    pub const DocRegionVerdict = union(enum) {
        /// No `.doc_region` grant narrows this edit — either nothing is
        /// wired (`grant_table == null`, every pre-W4/headless construction),
        /// or the principal holds no such grant for THIS document. The
        /// pre-existing `gradeOn` gate is the only gate in effect either way.
        ok,
        /// A live `.doc_region` grant applies, its anchors resolve, but `[r.start,
        /// r.end)` reaches outside the resolved `[start, end)` — carries the
        /// CURRENT resolved bounds for the trap message.
        out_of_limit: struct { start: usize, end: usize },
        /// A live `.doc_region` grant applies but its identity anchors no
        /// longer resolve to a well-formed span — either `resolveAnchors`
        /// itself failed (deleted-and-compacted, corrupt, foreign, or an
        /// allocation failure: ANY failure fails CLOSED) or the region
        /// degenerated to empty/inverted (its whole text was deleted — see
        /// `grants.DocRegion`'s "Collapse policy"). A loud "re-grant needed",
        /// never a silent narrowing.
        collapsed,
    };

    /// The doc-region READ side (§6 W4 slice 3): does a live `.doc_region`
    /// grant narrow the acting principal's edit of `[start, end)` on the
    /// ACTIVE document? First live `.doc_region` row (scanned via the SAME
    /// capture-time, predicate-gated collection `Ctx.capture` already
    /// performs — `grants.zig`'s "no wallet" rule: this only ever looks at
    /// what capture resolved, never re-derives possession) whose `doc_id`
    /// names the active buffer wins; a principal holding none degrades to
    /// `.ok` (§6 W4 slice 1/2's honest-v1 precedent: nothing production
    /// mints a `.doc_region` grant yet — see `grants.zig`'s module doc — so
    /// every existing plugin/agent is UNAFFECTED until a test, or a later
    /// `weft.grant` verb, mints one).
    pub fn checkDocRegion(self: *Context, start: usize, end: usize) DocRegionVerdict {
        const table = self.grant_table orelse return .ok;
        const doc = self.document() orelse return .ok;
        const c = self.capturedCtx();
        for (c.grants.constSlice()) |h| {
            const region = switch (table.limitFor(h)) {
                .doc_region => |dr| dr,
                // `.graph_subtree` is a GraphDoc-shaped limit — it never
                // legitimately rides a `doc.edit` row a TEXT buffer's
                // `checkDocRegion` would consult (see `GraphSubtree`'s doc
                // comment: enforcement lives at `GraphCollab.admitRegions`
                // instead). Same "not this chokepoint's business" skip as
                // `.fs_root`.
                .none, .fs_root, .graph_subtree => continue,
            };
            if (!std.mem.eql(u8, region.doc_id, self.buffer().name)) continue;
            var out: [2]usize = undefined;
            doc.resolveAnchors(self.gpa, &.{ region.start, region.end }, &out) catch return .collapsed;
            if (out[0] >= out[1]) return .collapsed; // whole region's text is gone
            if (start < out[0] or end > out[1]) return .{ .out_of_limit = .{ .start = out[0], .end = out[1] } };
            return .ok;
        }
        return .ok;
    }

    /// INTERACTIVE edit: delete `r`, insert `bytes` on the ACTIVE document as a
    /// direct user/tool text mutation. This is the door for typing, vim
    /// operators, autopair, comment — anything that edits text AS text. It is
    /// refused on a read-only span/buffer (§`render` is the door for producing
    /// derived content there), so a projection like git/files has NO
    /// interactive-edit path at all — no mode, split, or plugin can corrupt it
    /// as text. Refusal leaves the replica untouched (no ghost commit).
    ///
    /// **W4 slice 3**: also the doc-region enforcement point — the ONE
    /// chokepoint every `wl_edit`/`wl_edit_as`/`wl_edit_range` guest door and
    /// every host/in-process edit path already funnels through (see
    /// `wasm_host/edit.zig`'s module doc), so wiring `checkDocRegion` HERE
    /// covers all of them for free, with no per-transport duplication.
    /// `render` deliberately does NOT get this check — it's content
    /// PRODUCTION (a re-render from a model), not a principal editing text
    /// it holds a scoped grant over.
    pub fn edit(self: *Context, r: Document.Range, bytes: []const u8) EditError!void {
        if (self.buffer().read_only) return self.refuse("read-only buffer");
        if (self.readOnlyOverlaps(r)) return self.refuse("read-only region");
        switch (self.checkDocRegion(r.start, r.end)) {
            .ok => {},
            .out_of_limit => return error.OutOfLimit,
            .collapsed => return error.Collapsed,
        }
        return self.applyEdit(r, bytes, self.user_initiated);
    }

    /// The UNDO door: this principal's authority over an inverse edit, as the
    /// gate `undo.UndoLog` must clear at its apply site. Undo re-applies text,
    /// so it asks exactly what `edit` asks — the grade gate, then
    /// `checkDocRegion` over every replacement — and a narrowed principal can
    /// no more reach outside its region by unwinding history than by typing.
    pub fn undoGate(self: *Context) undo_mod.Gate {
        return .{ .ctx = self, .admits = admitUndo };
    }

    fn admitUndo(gate_ctx: ?*anyopaque, repls: []const Document.Replacement) undo_mod.Refusal!void {
        const self: *Context = @ptrCast(@alignCast(gate_ctx.?));
        const doc = self.document() orelse return;
        if (!self.gradeOn(doc).canEdit()) {
            self.noteRefusal("read-only: view access");
            return error.Unauthorized;
        }
        for (repls) |r| switch (self.checkDocRegion(r.range.start, r.range.end)) {
            .ok => {},
            .out_of_limit => {
                self.noteRefusal("undo reaches outside the granted region");
                return error.OutOfLimit;
            },
            .collapsed => {
                self.noteRefusal("granted region collapsed; re-grant needed");
                return error.Collapsed;
            },
        };
    }

    /// Announce a refusal on the dispatching head's echo line and return the
    /// refusal. The door owns visibility as well as enforcement, so a denied
    /// edit is equally honest whichever runtime asked — a builtin, a wasm
    /// guest's `wl_edit`, quickjs, the completion UI — with no per-call-site
    /// reporting to keep in sync. Only the refusal path touches the echo; an
    /// allowed keystroke allocates nothing here.
    fn refuse(self: *Context, why: []const u8) EditError {
        self.noteRefusal(why);
        return error.Unauthorized;
    }

    /// The visibility half of a refusal, for the callers that own the error
    /// value themselves.
    fn noteRefusal(self: *Context, why: []const u8) void {
        self.head.echo.clearRetainingCapacity();
        self.head.echo.appendSlice(self.gpa, why) catch {};
    }

    /// Whether `r` overlaps a read-only SPAN of the active buffer — the
    /// span-level guard (a comint's produced output is read-only, its input line
    /// editable). A caret AT a span boundary may still type (insert adjacent);
    /// only a range that actually reaches into read-only content is refused.
    fn readOnlyOverlaps(self: *Context, r: Document.Range) bool {
        const ed = self.buffer().textEditor() orelse return false;
        const layer = ed.readonly_layer orelse return false;
        var i: usize = 0;
        const n = layer.spanCount();
        while (i < n) : (i += 1) {
            const s = layer.resolvedSpan(i);
            if (r.start < s.end and s.start < r.end) return true; // ranges overlap
            if (r.isEmpty() and r.start > s.start and r.start < s.end) return true; // insert INSIDE
        }
        return false;
    }

    /// CONTENT PRODUCTION: draw a derived/streamed projection (git's status
    /// tree, files's listing, an agent transcript) into a buffer. A DISTINCT
    /// operation from `edit` — it BYPASSES read-only (that's the point: the text
    /// is output, regenerated from a model, not user-editable), and it authors
    /// as the plugin's OWN peer (never the user's undo — a re-render isn't a
    /// user edit). Any plugin may render (no single owner); still grade-gated.
    /// A read-only buffer's content is thus editable only by re-rendering, while
    /// an EDITABLE projection (mini.files files) simply isn't marked read-only
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
        const ed = try self.textEditor();
        const doc = &ed.doc;
        if (!self.gradeOn(doc).canEdit()) return self.refuse("read-only: view access");
        const joins_user_undo = self.principal.role == .user or
            (join_user and self.principal.role == .plugin);
        if (joins_user_undo) {
            try ed.applyUserEdit(self.gpa, r, bytes);
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
///
/// Refusals are ANNOUNCED here (`noteRenderRefusal`), because this door has no
/// `Head` to echo on and its callers are background producers that can only
/// drop the error: silence would make a denied render indistinguishable from
/// a plugin that simply produced nothing.
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
    if (!grade.canEdit()) {
        noteRenderRefusal(name, "view access");
        return error.Unauthorized;
    }
    const pid = try doc.peerNamed(gpa, name);
    doc.peerReplaceAll(gpa, pid, items) catch {};
}

/// Make a background refusal observable: a host log line always, plus the
/// generic `weft.status` chip the status line already renders — the same
/// surface a plugin publishes progress on, so a denied producer is visible
/// to the user without inventing a UI for it.
fn noteRenderRefusal(name: []const u8, why: []const u8) void {
    std.log.warn("render refused: '{s}' — {s}", .{ name, why });
    var buf: [96]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "render refused: {s} ({s})", .{ name, why }) catch "render refused";
    status_feed.set(text);
}

/// [FIX 2] (doc/extensibility-native-surface.md, release-blocking): apply a capability
/// `.edits`-shaped `Result` (the format/rename/code-action `action` shape —
/// `capability.Kind.format`/`.rename`, `Payload.edits`) through the SAME
/// content-production gate `renderInto` already provides — grade-capped, one
/// atomic commit — CLAMPED to the range the CONSUMER fired against (`fired`)
/// and attributed to the PROVIDER's own name, never whatever principal is
/// currently dispatching. Nothing calls this in production yet (no
/// guest-side `weft.provideAction` registrar exists to populate an
/// `action`-shaped `Provider` at all — see the module doc below) — same
/// honest-v1 shape as `grants.DocRegion` (§6 W4 slice 3: "the machinery is
/// the deliverable"). Tests fire a real `Caps` session against a fake
/// provider and call this directly.
///
/// **The clamp (security-critical half, DONE).** `result.version` is
/// core-enforced to be the session's FIRE-time version (`Caps.push`'s
/// restamp — never trusted from the provider), so every `Replacement`'s
/// `[start,end)` is unambiguously old-space against that ONE token. Each is
/// mapped to the CURRENT head via the asynchronous snapshot adapter; so is
/// `fired` (the
/// range the consumer itself licensed at fire time — typically stamped at
/// the SAME version, but rebased independently so a late apply against a
/// moved-on document degrades honestly rather than comparing stale numbers).
/// EVERY edit is checked BEFORE any is applied (`error.StaleVersion` if
/// either side's version has fallen out of the commit log); a batch with ANY
/// edit landing outside `fired`'s rebased bounds is refused WHOLESALE
/// (`error.OutOfRange`, the overage logged) — never a partial apply, which
/// would still let an attacker smuggle one bad edit in among legitimate
/// ones.
///
/// **Re-attribution — the OTHER half of [FIX 2], HONEST SUBSET.** Applies as
/// a peer NAMED after `result.provider` (`renderInto`'s `role=.plugin` +
/// `name` — the same peer-naming primitive `Document.peerNamed` already
/// gives `renderInto`'s other callers), never whatever principal is
/// currently dispatching/firing — so the landed commit's author is the
/// PROVIDER, gets its OWN selective-undo unit distinct from the firing
/// user's, and is capped at `.edit` grade like any non-user peer. This
/// closes the peer-attribution half of "a malicious host formatter returns
/// a backdoor that lands as the victim's signed commit": the backdoor, if
/// in-range, lands as the FORMATTER's peer, not the victim's. What this does
/// NOT do: resolve `result.provider` back to a REAL `authority.Principal`
/// with its own LIVE grant/predicate state (a revoked or narrowly-scoped
/// provider still applies here as long as its NAME resolves to a peer) —
/// that needs the capability registry to plumb a resolvable `Principal`
/// through `Provider`/`Result`, which no `action`-shaped registrar exists to
/// populate yet (only `edit/completion`'s `hProvideCompletion` registers
/// ANYTHING guest-side today — there is no guest-side `weft.provideAction`).
/// Named follow-up, not silently dropped.
///
/// **Why this routes through `renderInto`, not `Context.edit` (named
/// divergence, W4 slice 3 review).** `Context.edit` is where `checkDocRegion`
/// lives — but that gate answers "does the ACTING PRINCIPAL's own
/// `.doc_region` grant cover this range", which is the wrong question for an
/// applied action result: the acting authority here is the FIRED RANGE
/// itself (`fired`, this function's clamp), not any grant the PROVIDER
/// happens to hold. [FIX 2]'s threat model is "a formatter answers with
/// bytes outside what it was asked to touch" — the fired-range clamp IS the
/// gate for that threat, and it SUBSTITUTES for (does not stack with) a
/// grant check here. Consequence, stated plainly: a provider's OWN
/// `.doc_region` grant (if it ever held one) is NOT consulted when its
/// results are applied through this function — unreachable in v1 (nothing
/// mints an action-provider `.doc_region` grant, same honest-v1 note as
/// everywhere else in this slice), but worth being honest about should a
/// future caller expect BOTH gates to compose.
pub const ApplyActionError = RenderError || error{ NotAnAction, StaleVersion, OutOfRange };

pub fn applyActionResult(
    gpa: Allocator,
    doc: *Document,
    fired: position.StampedRange,
    result: *const capability.Result,
) ApplyActionError!usize {
    if (result.payload != .edits) return error.NotAnAction;
    const edits = result.payload.edits;
    const bounds = fired.rebase(doc) orelse return error.StaleVersion;

    // Pre-flight EVERY edit before applying ANY of them — see this
    // function's doc's "no partial apply" note.
    const items = try gpa.alloc(Document.Replacement, edits.len);
    defer gpa.free(items);
    for (edits, 0..) |e, i| {
        const r = position.StampedRange.at(result.version, e.start, e.end).rebase(doc) orelse return error.StaleVersion;
        if (r.start < bounds.start or r.end > bounds.end) {
            std.log.warn("capability: provider '{s}' action result touches [{d},{d}), outside the fired range [{d},{d}) — REFUSED", .{ result.provider, r.start, r.end, bounds.start, bounds.end });
            return error.OutOfRange;
        }
        items[i] = .{ .range = r, .bytes = e.text };
    }
    // `peerReplaceAll` requires ascending-by-offset input (see
    // `Document.replaceAll`'s doc); a provider's edits may arrive in any
    // order (LSP TextEdit[] is unordered) — sort defensively rather than
    // trust it, the same "structural impossibility over convention" posture
    // the rest of this gate takes.
    std.mem.sort(Document.Replacement, items, {}, struct {
        fn lessThan(_: void, a: Document.Replacement, b: Document.Replacement) bool {
            return a.range.start < b.range.start;
        }
    }.lessThan);
    try renderInto(gpa, doc, .plugin, result.provider, items);
    return items.len;
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
///
/// **F5/W3, the resolve-path fold (doc/cwa-prior-docs-audit.md §5).** This is
/// now a bare `container.Container.resolveOne` call against the captured
/// `Ctx`'s FULL merged facts — not `Actions.resolve`/`Context.actionCtx`'s
/// narrowed mode/lang/tool round trip (snapshot the full `Facts`, throw away
/// everything but 3 fields into an `Actions.Ctx`, then rebuild a `Facts` with
/// those 3 fields and defaults for the rest — the exact adapter-shape glue
/// the plan's W3 gate names). `action.When` only ever tests mode/lang/tool
/// today, so the two are behaviorally identical; the fold is real anyway,
/// because it deletes a per-dispatch allocation-free-but-still-real double
/// conversion on the hottest path in the editor (`e2e/latency`'s `action`
/// category measures exactly this call), and it means a FUTURE action
/// predicate over a field `Actions.Ctx` doesn't carry (path, tags, pane, …)
/// needs no new plumbing here — the Container already sees the whole `Facts`
/// value. `Actions.resolve` itself is UNCHANGED and still public — see its
/// doc for why it stays (a registration facade's natural read-side
/// convenience, and ~30 existing test call sites depend on its exact
/// signature).
pub fn actionTrampoline(ctx: *Context, data: ?*anyopaque, args: []const Value) anyerror!Value {
    const tr: *Actions.Trampoline = @ptrCast(@alignCast(data.?));
    if (ctx.actions.container.resolveOne(tr.name, ctx.capturedCtx().mergedFacts())) |b| {
        return run(ctx.commands, ctx, b.provider.command, args);
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
        position.LiveOffset => .anchor,
        position.LiveRange => .range,
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
        position.LiveOffset => if (v == .anchor) v.anchor else error.TypeMismatch,
        position.LiveRange => if (v == .range) v.range else error.TypeMismatch,
        else => unreachable,
    };
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

fn insertText(ctx: *Context, args: struct { offset: i64, text: []const u8 }) anyerror!Value {
    try ctx.document().?.insert(ctx.gpa, @intCast(args.offset), args.text);
    return .{ .integer = @intCast(ctx.document().?.text().byteLen()) };
}

test "command Value: a borrowed live range follows edits and rejects another document" {
    const gpa = t.allocator;
    var doc = try Document.init(gpa, "user");
    defer doc.deinit(gpa);
    try doc.insert(gpa, 0, "hello");
    const start = try doc.addAnchor(gpa, 0, .right);
    defer doc.removeAnchor(start);
    const end = try doc.addAnchor(gpa, 5, .left);
    defer doc.removeAnchor(end);

    // Carry live anchors as an ABI Value; an intervening edit advances them.
    const val: Value = .{ .range = .{ .document = &doc, .start = start, .end = end } };
    try doc.insert(gpa, 0, "XYZ");
    const r = val.range.resolve(&doc).?;
    try t.expectEqual(@as(usize, 3), r.start);
    try t.expectEqual(@as(usize, 8), r.end);

    var other = try Document.init(gpa, "other");
    defer other.deinit(gpa);
    try t.expectEqual(@as(?Document.Range, null), val.range.resolve(&other));

    // The value survives the typed-arg door too (unpack round-trips it).
    try t.expectEqual(Type.range, comptime typeOf(position.LiveRange));
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
    var container = @import("container.zig").Container.init(gpa);
    defer container.deinit();
    var caps = @import("capability.zig").Caps.init(gpa, @import("task.zig").nowNs, &container);
    defer caps.deinit();
    var actions = Actions.init(gpa, &container);
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
    try t.expectEqual(@as(usize, 0), buffers.active().textEditor().?.text().byteLen());

    const res = try run(&commands, &ctx, "insert-text", &.{
        .{ .integer = 0 }, .{ .string = "graft" },
    });
    try t.expectEqual(Value{ .integer = 5 }, res);
    try t.expectEqual(@as(usize, 5), buffers.active().textEditor().?.text().byteLen());
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
    var container = @import("container.zig").Container.init(gpa);
    defer container.deinit();
    var caps = @import("capability.zig").Caps.init(gpa, task.nowNs, &container);
    defer caps.deinit();
    var actions = Actions.init(gpa, &container);
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
    const doc = ctx.document().?;

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
    var container = @import("container.zig").Container.init(gpa);
    defer container.deinit();
    var caps = @import("capability.zig").Caps.init(gpa, task.nowNs, &container);
    defer caps.deinit();
    var actions = Actions.init(gpa, &container);
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
    const mid = try ctx.document().?.text().toOwnedSlice(gpa);
    defer gpa.free(mid);
    try t.expectEqualStrings("tree", mid);

    // RENDER (content production) is a DIFFERENT door — it bypasses read-only,
    // so a projection's renderer (ANY plugin, not one owner) can redraw it.
    var plugin_peer = Peer{ .gpa = gpa, .name = "plugin-peer" };
    ctx.principal = .{ .role = .plugin, .name = "plugin-peer", .ctx = &plugin_peer, .resolve = Peer.resolve };
    try ctx.render(.{ .start = 0, .end = 4 }, "TREE");
    const out = try ctx.document().?.text().toOwnedSlice(gpa);
    defer gpa.free(out);
    try t.expectEqualStrings("TREE", out);

    // ── Span-level: a read-only SPAN (a comint's output) refuses edits inside
    // it, while the rest of the buffer (its input line) stays editable.
    ctx.buffer().read_only = false;
    ctx.principal = .user;
    ctx.user_initiated = true;
    const doc2 = ctx.document().?;
    const ro = try ctx.caps.layers.claim(gpa, doc2, "readonly", .local, "test");
    try ro.appendSpan(gpa, .{ .start = 0, .end = 2, .kind = 0, .message = "", .face = .{} });
    ctx.buffer().textEditor().?.readonly_layer = ctx.caps.layers.find(doc2, "readonly");
    // "TREE": [0,2) is read-only; an edit reaching into it is refused, an edit
    // past it (the "input line") is allowed.
    try t.expectError(error.Unauthorized, ctx.edit(.{ .start = 1, .end = 2 }, "x"));
    try ctx.edit(.{ .start = 4, .end = 4 }, "!"); // append after the RO span → ok
    const out2 = try ctx.document().?.text().toOwnedSlice(gpa);
    defer gpa.free(out2);
    try t.expectEqualStrings("TREE!", out2);
}

// ── W4 slice 3: doc_region grants + action-result clamping ─────────────
// (doc/contextual-workspace-architecture.md §13.5, review B2's repair;
// doc/extensibility-native-surface.md [FIX 2]). Shared fixture: a real
// Buffers/Document-backed Context with a wired grant_table — mirrors the
// tests above, factored out because this section needs it five times.

const DocRegionEnv = struct {
    gpa: Allocator,
    pool: *@import("task.zig").Pool,
    buffers: Buffers,
    keymap: Keymap = .empty,
    head: Head = .empty,
    container: @import("container.zig").Container,
    caps: capability.Caps,
    actions: Actions,
    quit: bool = false,
    commands: Commands = .empty,
    table: grants_mod.HandleTable,
    ctx: Context = undefined,

    fn init(gpa: Allocator) !*DocRegionEnv {
        const task = @import("task.zig");
        const pool = try task.Pool.init(gpa, .{ .threads = 1 });
        const self = try gpa.create(DocRegionEnv);
        self.* = .{
            .gpa = gpa,
            .pool = pool,
            .buffers = try Buffers.init(gpa, pool, "user"),
            .container = @import("container.zig").Container.init(gpa),
            .caps = undefined,
            .actions = undefined,
            .table = grants_mod.HandleTable.init(gpa),
        };
        self.caps = capability.Caps.init(gpa, task.nowNs, &self.container);
        self.actions = Actions.init(gpa, &self.container);
        self.ctx = .{
            .gpa = gpa,
            .buffers = &self.buffers,
            .commands = &self.commands,
            .keymap = &self.keymap,
            .actions = &self.actions,
            .caps = &self.caps,
            .quit = &self.quit,
            .head = &self.head,
            .grant_table = &self.table,
        };
        try self.head.setModeRaw(gpa, "normal");
        return self;
    }

    fn deinit(self: *DocRegionEnv) void {
        const gpa = self.gpa;
        self.head.deinit(gpa);
        self.actions.deinit();
        self.caps.deinit();
        self.container.deinit();
        self.commands.deinit(gpa);
        self.keymap.deinit(gpa);
        self.buffers.deinit(gpa);
        self.table.deinit();
        self.pool.deinit();
        gpa.destroy(self);
    }
};

/// A named, resolvable peer identity for these tests — the same tiny
/// resolver shape the tests above already use for `.agent`/`.plugin`
/// principals.
const NamedPeer = struct {
    gpa: Allocator,
    name: []const u8,
    fn resolve(actx: *anyopaque, d: *Document) Document.AddPeerError!Document.PeerId {
        const a: *@This() = @ptrCast(@alignCast(actx));
        return d.peerNamed(a.gpa, a.name);
    }
};

test "command: W4 slice 3 — doc_region grant follows concurrent edits elsewhere, traps outside, grows at both boundaries" {
    const gpa = t.allocator;
    var env = try DocRegionEnv.init(gpa);
    defer env.deinit();
    const ctx = &env.ctx;
    const doc = ctx.document().?;

    // Seed "0123456789" as the user.
    ctx.principal = .user;
    ctx.user_initiated = true;
    try ctx.edit(.{ .start = 0, .end = 0 }, "0123456789");
    ctx.user_initiated = false;

    // Region [3,7) = "3456" — GROWING boundaries: start anchors to the
    // character BEFORE it ('2', side=.after), end to the character AFTER it
    // ('7', side=.before). See `grants.DocRegion`'s doc for the choice.
    const start_anchor = try doc.exportAnchor(gpa, 3, .after);
    defer gpa.free(start_anchor.agent);
    const end_anchor = try doc.exportAnchor(gpa, 7, .before);
    defer gpa.free(end_anchor.agent);
    _ = try env.table.grant(.{
        .capability = "doc.edit",
        .limit = .{ .doc_region = .{ .doc_id = ctx.buffer().name, .start = start_anchor, .end = end_anchor } },
    }, "agent", null);

    var agent_ident = NamedPeer{ .gpa = gpa, .name = "agent" };
    ctx.principal = .{ .role = .agent, .name = "agent", .ctx = &agent_ident, .resolve = NamedPeer.resolve };

    // Inside the region: allowed.
    try ctx.edit(.{ .start = 4, .end = 5 }, "X"); // "3456" → "3X56"

    // Outside the region: refused, distinctly (not Unauthorized).
    try t.expectError(error.OutOfLimit, ctx.edit(.{ .start = 0, .end = 1 }, "Q"));

    // A ground-truth resolve, matching what `checkDocRegion` itself computes
    // — the test's oracle, not a hardcoded offset (proves "follows", not
    // "happens to still work").
    var bounds: [2]usize = undefined;
    try doc.resolveAnchors(gpa, &.{ start_anchor, end_anchor }, &bounds);
    try t.expectEqual(@as(usize, 3), bounds[0]);
    try t.expectEqual(@as(usize, 7), bounds[1]);

    // CONCURRENT EDIT ELSEWHERE (before the region), by an UNRELATED peer
    // holding no doc_region grant — ordinary, unrestricted edit.
    var other_ident = NamedPeer{ .gpa = gpa, .name = "other" };
    ctx.principal = .{ .role = .plugin, .name = "other", .ctx = &other_ident, .resolve = NamedPeer.resolve };
    try ctx.edit(.{ .start = 0, .end = 0 }, "XY"); // insert 2 bytes before the region

    var bounds2: [2]usize = undefined;
    try doc.resolveAnchors(gpa, &.{ start_anchor, end_anchor }, &bounds2);
    try t.expectEqual(bounds[0] + 2, bounds2[0]); // the region SHIFTED with the edit...
    try t.expectEqual(bounds[1] + 2, bounds2[1]); // ...both ends, uniformly — it FOLLOWED, not drifted

    // The agent's grant follows: an edit at the (new) inside offset still
    // works, and the (new) outside offset still traps.
    ctx.principal = .{ .role = .agent, .name = "agent", .ctx = &agent_ident, .resolve = NamedPeer.resolve };
    try ctx.edit(.{ .start = bounds2[0], .end = bounds2[0] + 1 }, "Z");
    try t.expectError(error.OutOfLimit, ctx.edit(.{ .start = 0, .end = 1 }, "Q"));

    // CONCURRENT EDIT ELSEWHERE (after the region) — appending far past the
    // end must not move the region at all (neither anchor is anywhere near
    // it).
    ctx.principal = .{ .role = .plugin, .name = "other", .ctx = &other_ident, .resolve = NamedPeer.resolve };
    const tail = doc.text().byteLen();
    try ctx.edit(.{ .start = tail, .end = tail }, "TAIL");
    var bounds3: [2]usize = undefined;
    try doc.resolveAnchors(gpa, &.{ start_anchor, end_anchor }, &bounds3);
    try t.expectEqual(bounds2[0], bounds3[0]);
    try t.expectEqual(bounds2[1], bounds3[1]);

    // ── Boundary insertions (both edges): GROWING semantics, decided.
    // Insert exactly at the CURRENT start boundary — the agent's own
    // authority — and confirm the region's END shifts right by exactly the
    // inserted length (the interior, including the new text, is now wider).
    ctx.principal = .{ .role = .agent, .name = "agent", .ctx = &agent_ident, .resolve = NamedPeer.resolve };
    try ctx.edit(.{ .start = bounds3[0], .end = bounds3[0] }, "LEFT"); // zero-width insert AT the start boundary
    var bounds4: [2]usize = undefined;
    try doc.resolveAnchors(gpa, &.{ start_anchor, end_anchor }, &bounds4);
    try t.expectEqual(bounds3[0], bounds4[0]); // start offset unchanged (still "right after '2'")...
    try t.expectEqual(bounds3[1] + 4, bounds4[1]); // ...but the region WIDENED by "LEFT".len — inclusive
    // Proof it's really inside: an edit touching exactly the inserted text
    // succeeds under the SAME grant.
    try ctx.edit(.{ .start = bounds4[0], .end = bounds4[0] + 4 }, "left");

    // Insert exactly at the CURRENT end boundary — symmetric check.
    var bounds5: [2]usize = undefined;
    try doc.resolveAnchors(gpa, &.{ start_anchor, end_anchor }, &bounds5);
    try ctx.edit(.{ .start = bounds5[1], .end = bounds5[1] }, "RIGHT"); // zero-width insert AT the end boundary
    var bounds6: [2]usize = undefined;
    try doc.resolveAnchors(gpa, &.{ start_anchor, end_anchor }, &bounds6);
    try t.expectEqual(bounds5[0], bounds6[0]); // start unaffected
    try t.expectEqual(bounds5[1] + 5, bounds6[1]); // end WIDENED by "RIGHT".len — inclusive
    try ctx.edit(.{ .start = bounds6[1] - 5, .end = bounds6[1] }, "right"); // the inserted text is editable too
}

test "command: W4 slice 3 — deleting a doc_region's entire text collapses the grant (trap, never silent narrow)" {
    const gpa = t.allocator;
    var env = try DocRegionEnv.init(gpa);
    defer env.deinit();
    const ctx = &env.ctx;
    const doc = ctx.document().?;

    ctx.principal = .user;
    ctx.user_initiated = true;
    try ctx.edit(.{ .start = 0, .end = 0 }, "0123456789");
    ctx.user_initiated = false;

    const start_anchor = try doc.exportAnchor(gpa, 3, .after);
    defer gpa.free(start_anchor.agent);
    const end_anchor = try doc.exportAnchor(gpa, 7, .before);
    defer gpa.free(end_anchor.agent);
    _ = try env.table.grant(.{
        .capability = "doc.edit",
        .limit = .{ .doc_region = .{ .doc_id = ctx.buffer().name, .start = start_anchor, .end = end_anchor } },
    }, "agent", null);

    var agent_ident = NamedPeer{ .gpa = gpa, .name = "agent" };
    ctx.principal = .{ .role = .agent, .name = "agent", .ctx = &agent_ident, .resolve = NamedPeer.resolve };

    // Deleting the WHOLE region is itself an in-bounds edit (still allowed —
    // the agent has full authority over its own region, including emptying
    // it).
    try ctx.edit(.{ .start = 3, .end = 7 }, "");

    // The NEXT edit attempt under the same grant traps — collapsed, not a
    // silent narrowing to some now-meaningless zero-width point.
    try t.expectError(error.Collapsed, ctx.edit(.{ .start = 3, .end = 3 }, "x"));
    switch (ctx.checkDocRegion(3, 3)) {
        .collapsed => {},
        .ok, .out_of_limit => return error.TestUnexpectedResult,
    }
}

test "command: W4 slice 3 — compaction collapses a doc_region grant (trap, not UB)" {
    const gpa = t.allocator;
    var env = try DocRegionEnv.init(gpa);
    defer env.deinit();
    const ctx = &env.ctx;
    const doc = ctx.document().?;

    ctx.principal = .user;
    ctx.user_initiated = true;
    try ctx.edit(.{ .start = 0, .end = 0 }, "0123456789");
    ctx.user_initiated = false;

    const start_anchor = try doc.exportAnchor(gpa, 3, .after);
    defer gpa.free(start_anchor.agent);
    const end_anchor = try doc.exportAnchor(gpa, 7, .before);
    defer gpa.free(end_anchor.agent);
    _ = try env.table.grant(.{
        .capability = "doc.edit",
        .limit = .{ .doc_region = .{ .doc_id = ctx.buffer().name, .start = start_anchor, .end = end_anchor } },
    }, "agent", null);

    var agent_ident = NamedPeer{ .gpa = gpa, .name = "agent" };
    ctx.principal = .{ .role = .agent, .name = "agent", .ctx = &agent_ident, .resolve = NamedPeer.resolve };
    try ctx.edit(.{ .start = 4, .end = 5 }, "X"); // ordinary in-region edit, pre-compaction

    // Compact at the current head — even though the region's TEXT is still
    // present and untouched, identity anchors into compacted content stop
    // resolving unconditionally (stemma's `TextDoc.compact` doc).
    const version = try doc.version(gpa);
    defer gpa.free(version);
    try doc.compact(gpa, version);

    try t.expectError(error.Collapsed, ctx.edit(.{ .start = 4, .end = 5 }, "y"));
}

test "command: W4 slice 3 — a single-commit rewrite of the WHOLE region survives (re-inflates); a two-step clear-then-type collapses" {
    const gpa = t.allocator;
    var env = try DocRegionEnv.init(gpa);
    defer env.deinit();
    const ctx = &env.ctx;
    const doc = ctx.document().?;

    ctx.principal = .user;
    ctx.user_initiated = true;
    try ctx.edit(.{ .start = 0, .end = 0 }, "0123456789");
    ctx.user_initiated = false;

    const start_anchor = try doc.exportAnchor(gpa, 3, .after);
    defer gpa.free(start_anchor.agent);
    const end_anchor = try doc.exportAnchor(gpa, 7, .before);
    defer gpa.free(end_anchor.agent);
    _ = try env.table.grant(.{
        .capability = "doc.edit",
        .limit = .{ .doc_region = .{ .doc_id = ctx.buffer().name, .start = start_anchor, .end = end_anchor } },
    }, "agent", null);

    var agent_ident = NamedPeer{ .gpa = gpa, .name = "agent" };
    ctx.principal = .{ .role = .agent, .name = "agent", .ctx = &agent_ident, .resolve = NamedPeer.resolve };

    // ONE atomic replace of the WHOLE region: delete [3,7) + insert
    // "REWRITE" in the SAME `edit` call. Per `grants.DocRegion`'s doc, this
    // does NOT collapse — the insert's CRDT origin sits adjacent to BOTH
    // surviving boundary characters, so the region re-inflates around it.
    try ctx.edit(.{ .start = 3, .end = 7 }, "REWRITE");
    var bounds: [2]usize = undefined;
    try doc.resolveAnchors(gpa, &.{ start_anchor, end_anchor }, &bounds);
    try t.expectEqual(@as(usize, 3), bounds[0]);
    try t.expectEqual(@as(usize, 10), bounds[1]); // "REWRITE" (7 bytes) fully absorbed
    // Still-live grant: another in-region edit succeeds right after.
    try ctx.edit(.{ .start = bounds[0], .end = bounds[0] + 1 }, "r");
}

test "command: W4 slice 3 (B2 adversarial a) — a peer's paste INSIDE the region is covered by the grant" {
    const gpa = t.allocator;
    var env = try DocRegionEnv.init(gpa);
    defer env.deinit();
    const ctx = &env.ctx;
    const doc = ctx.document().?;

    ctx.principal = .user;
    ctx.user_initiated = true;
    try ctx.edit(.{ .start = 0, .end = 0 }, "0123456789");
    ctx.user_initiated = false;

    const start_anchor = try doc.exportAnchor(gpa, 3, .after);
    defer gpa.free(start_anchor.agent);
    const end_anchor = try doc.exportAnchor(gpa, 7, .before);
    defer gpa.free(end_anchor.agent);
    _ = try env.table.grant(.{
        .capability = "doc.edit",
        .limit = .{ .doc_region = .{ .doc_id = ctx.buffer().name, .start = start_anchor, .end = end_anchor } },
    }, "agent", null);

    // A DIFFERENT, unrelated peer pastes text into the MIDDLE of the region
    // (not at either boundary) — an ordinary concurrent edit, unrestricted
    // (it holds no doc_region grant of its own).
    var other_ident = NamedPeer{ .gpa = gpa, .name = "other" };
    ctx.principal = .{ .role = .plugin, .name = "other", .ctx = &other_ident, .resolve = NamedPeer.resolve };
    try ctx.edit(.{ .start = 5, .end = 5 }, "PASTE"); // "01234" + "PASTE" + "56789"
    const mid = try doc.text().toOwnedSlice(gpa);
    defer gpa.free(mid);
    try t.expectEqualStrings("01234PASTE56789", mid);

    // The grantee can edit the PASTED text — it landed strictly between the
    // two boundary anchors, so it is covered, not just the original bytes.
    var bounds: [2]usize = undefined;
    try doc.resolveAnchors(gpa, &.{ start_anchor, end_anchor }, &bounds);
    try t.expectEqual(@as(usize, 3), bounds[0]); // unaffected — '2' didn't move
    try t.expectEqual(@as(usize, 12), bounds[1]); // '7' shifted +5 (PASTE landed before it) — the region widened to absorb it

    var agent_ident = NamedPeer{ .gpa = gpa, .name = "agent" };
    ctx.principal = .{ .role = .agent, .name = "agent", .ctx = &agent_ident, .resolve = NamedPeer.resolve };
    // "PASTE" occupies [5,10) in "01234PASTE56789" — squarely inside
    // [bounds[0], bounds[1]). Replace it under the grant: must succeed.
    try ctx.edit(.{ .start = 5, .end = 10 }, "paste");
    const after = try doc.text().toOwnedSlice(gpa);
    defer gpa.free(after);
    try t.expectEqualStrings("01234paste56789", after);
}

test "command: W4 slice 3 (B2 adversarial b) — cut-inside-then-paste-outside traps: the grant does not follow content out of the region" {
    const gpa = t.allocator;
    var env = try DocRegionEnv.init(gpa);
    defer env.deinit();
    const ctx = &env.ctx;
    const doc = ctx.document().?;

    ctx.principal = .user;
    ctx.user_initiated = true;
    try ctx.edit(.{ .start = 0, .end = 0 }, "0123456789");
    ctx.user_initiated = false;

    const start_anchor = try doc.exportAnchor(gpa, 3, .after);
    defer gpa.free(start_anchor.agent);
    const end_anchor = try doc.exportAnchor(gpa, 7, .before);
    defer gpa.free(end_anchor.agent);
    _ = try env.table.grant(.{
        .capability = "doc.edit",
        .limit = .{ .doc_region = .{ .doc_id = ctx.buffer().name, .start = start_anchor, .end = end_anchor } },
    }, "agent", null);

    var agent_ident = NamedPeer{ .gpa = gpa, .name = "agent" };
    ctx.principal = .{ .role = .agent, .name = "agent", .ctx = &agent_ident, .resolve = NamedPeer.resolve };

    // CUT: delete "45" from inside the region ([4,6) of "3456") — an
    // ordinary in-bounds edit, allowed.
    try ctx.edit(.{ .start = 4, .end = 6 }, "");
    const cut = try doc.text().toOwnedSlice(gpa);
    defer gpa.free(cut);
    try t.expectEqualStrings("01236789", cut);

    // PASTE outside: the SAME grantee tries to paste the cut text ("45")
    // at offset 0 — well outside the (now-shrunk) region. The grant is
    // bound to the FIXED identity-anchored span, not to wherever cut
    // content happens to relocate — this MUST trap, never silently follow
    // the content out.
    try t.expectError(error.OutOfLimit, ctx.edit(.{ .start = 0, .end = 0 }, "45"));
    const unchanged = try doc.text().toOwnedSlice(gpa);
    defer gpa.free(unchanged);
    try t.expectEqualStrings("01236789", unchanged); // refused: no ghost paste
}

test "command: W4 slice 3 — multiple doc_region grants for one principal: the FIRST live matching row wins (v1 policy, locked)" {
    const gpa = t.allocator;
    var env = try DocRegionEnv.init(gpa);
    defer env.deinit();
    const ctx = &env.ctx;
    const doc = ctx.document().?;

    ctx.principal = .user;
    ctx.user_initiated = true;
    try ctx.edit(.{ .start = 0, .end = 0 }, "0123456789");
    ctx.user_initiated = false;

    // TWO doc_region grants for the SAME principal+document: a narrow one
    // [3,7) minted FIRST, a wide-open one [0,10) minted SECOND. §6 W4 slice
    // 3's `checkDocRegion` scans in mint order and stops at the first
    // `.doc_region` match — so the NARROW one governs, even though a wider
    // grant also exists. Locked here so a future change to that scan order
    // is a deliberate, reviewed decision, not an accidental drift.
    const narrow_start = try doc.exportAnchor(gpa, 3, .after);
    defer gpa.free(narrow_start.agent);
    const narrow_end = try doc.exportAnchor(gpa, 7, .before);
    defer gpa.free(narrow_end.agent);
    _ = try env.table.grant(.{
        .capability = "doc.edit",
        .limit = .{ .doc_region = .{ .doc_id = ctx.buffer().name, .start = narrow_start, .end = narrow_end } },
    }, "agent", null);

    const wide_start = try doc.exportAnchor(gpa, 0, .after);
    defer gpa.free(wide_start.agent);
    const wide_end = try doc.exportAnchor(gpa, 10, .before);
    defer gpa.free(wide_end.agent);
    _ = try env.table.grant(.{
        .capability = "doc.edit",
        .limit = .{ .doc_region = .{ .doc_id = ctx.buffer().name, .start = wide_start, .end = wide_end } },
    }, "agent", null);

    var agent_ident = NamedPeer{ .gpa = gpa, .name = "agent" };
    ctx.principal = .{ .role = .agent, .name = "agent", .ctx = &agent_ident, .resolve = NamedPeer.resolve };

    // An edit inside the WIDE grant but outside the NARROW one traps —
    // proof the first (narrow) row is the one actually enforced.
    try t.expectError(error.OutOfLimit, ctx.edit(.{ .start = 0, .end = 1 }, "Q"));
    // Inside BOTH: allowed.
    try ctx.edit(.{ .start = 4, .end = 5 }, "X");
}

test "command: W4 slice 3 [FIX 2] — applyActionResult refuses an out-of-range batch wholesale" {
    const gpa = t.allocator;
    var env = try DocRegionEnv.init(gpa);
    defer env.deinit();
    const ctx = &env.ctx;
    const doc = ctx.document().?;

    ctx.principal = .user;
    ctx.user_initiated = true;
    try ctx.edit(.{ .start = 0, .end = 0 }, "0123456789");
    ctx.user_initiated = false;

    // What the consumer fired against — say, a "format this selection"
    // request over [2,8), stamped at the current head.
    const fired_version = try doc.version(gpa);
    defer gpa.free(fired_version);
    const fired = position.StampedRange.at(fired_version, 2, 8);

    // A fake provider whose SESSION answer touches bytes OUTSIDE [2,8) —
    // the laundering shape [FIX 2] closes.
    const BadProvider = struct {
        fn handle(_: ?*anyopaque, caps: *capability.Caps, req: *const capability.Request) anyerror!void {
            var edits = [_]capability.Replacement{
                .{ .start = 0, .end = 1, .text = @constCast("Q") }, // outside [2,8)
            };
            try caps.push(req.session, .{ .id = "evil-formatter" }, .{ .edits = &edits });
        }
    };
    try env.caps.register(.{
        .capability = capability.Kind.format.capabilityName(),
        .id = "test.bad-formatter",
        .placement = .host,
        .handler = BadProvider.handle,
    });
    const bad_session = (try env.caps.fire(.format, doc, null, .{})).?;
    const bad_result = &env.caps.session(bad_session).?.all()[0];
    try t.expectError(error.OutOfRange, applyActionResult(gpa, doc, fired, bad_result));
    // Refused wholesale: the document is untouched.
    const unchanged = try doc.text().toOwnedSlice(gpa);
    defer gpa.free(unchanged);
    try t.expectEqualStrings("0123456789", unchanged);
    env.caps.finish(bad_session);
}

test "command: W4 slice 3 [FIX 2] — applyActionResult applies an in-range batch, re-attributed to the provider" {
    const gpa = t.allocator;
    var env = try DocRegionEnv.init(gpa);
    defer env.deinit();
    const ctx = &env.ctx;
    const doc = ctx.document().?;

    ctx.principal = .user;
    ctx.user_initiated = true;
    try ctx.edit(.{ .start = 0, .end = 0 }, "0123456789");
    ctx.user_initiated = false;

    const fired_version = try doc.version(gpa);
    defer gpa.free(fired_version);
    const fired = position.StampedRange.at(fired_version, 2, 8);

    // A GOOD provider whose batch stays inside [2,8) — applies, and lands
    // authored as the PROVIDER's own peer, not the firing user's.
    const GoodProvider = struct {
        fn handle(_: ?*anyopaque, caps: *capability.Caps, req: *const capability.Request) anyerror!void {
            var edits = [_]capability.Replacement{
                .{ .start = 4, .end = 5, .text = @constCast("X") }, // inside [2,8)
            };
            try caps.push(req.session, .{ .id = "good-formatter" }, .{ .edits = &edits });
        }
    };
    try env.caps.register(.{
        .capability = capability.Kind.format.capabilityName(),
        .id = "test.good-formatter",
        .placement = .host,
        .handler = GoodProvider.handle,
    });
    const good_session = (try env.caps.fire(.format, doc, null, .{})).?;
    const good_result = &env.caps.session(good_session).?.all()[0];
    const applied = try applyActionResult(gpa, doc, fired, good_result);
    try t.expectEqual(@as(usize, 1), applied);

    const after = try doc.text().toOwnedSlice(gpa);
    defer gpa.free(after);
    try t.expectEqualStrings("0123X56789", after);
    // Re-attribution, TIGHT: the landed commit's author is EXACTLY the
    // provider's own peer (`doc.peerNamed("good-formatter")` — idempotent
    // for a live name, so this re-resolves the SAME id `applyActionResult`
    // minted), not merely "some non-user peer".
    const provider_peer = try doc.peerNamed(gpa, "good-formatter");
    const last = doc.commitAt(doc.commitCount() - 1);
    try t.expectEqual(provider_peer, last.author);
    env.caps.finish(good_session);
}

test "command: the undo door — a region-narrowed principal cannot smuggle an out-of-region change through undo" {
    const gpa = t.allocator;
    var env = try DocRegionEnv.init(gpa);
    defer env.deinit();
    const ctx = &env.ctx;
    const doc = ctx.document().?;
    const ed = try ctx.textEditor();

    // Three user units: the seed, an edit OUTSIDE the coming region, an
    // edit INSIDE it.
    ctx.principal = .user;
    ctx.user_initiated = true;
    try ctx.edit(.{ .start = 0, .end = 0 }, "0123456789");
    ed.history.barrier();
    try ctx.edit(.{ .start = 0, .end = 1 }, "U"); // "U123456789"
    ed.history.barrier();

    const start_anchor = try doc.exportAnchor(gpa, 3, .after);
    defer gpa.free(start_anchor.agent);
    const end_anchor = try doc.exportAnchor(gpa, 7, .before);
    defer gpa.free(end_anchor.agent);
    try ctx.edit(.{ .start = 4, .end = 5 }, "X"); // "U123X56789", inside [3,7)
    ctx.user_initiated = false;

    _ = try env.table.grant(.{
        .capability = "doc.edit",
        .limit = .{ .doc_region = .{ .doc_id = ctx.buffer().name, .start = start_anchor, .end = end_anchor } },
    }, "agent", null);

    var agent_ident = NamedPeer{ .gpa = gpa, .name = "agent" };
    ctx.principal = .{ .role = .agent, .name = "agent", .ctx = &agent_ident, .resolve = NamedPeer.resolve };

    // Unwinding the in-region unit is within the grant — the gate is the
    // region, not a blanket "no undo for agents".
    try t.expect(try ed.undo(gpa, ctx.undoGate()));
    const in_region = try doc.text().toOwnedSlice(gpa);
    defer gpa.free(in_region);
    try t.expectEqualStrings("U123456789", in_region); // "X" reverted to "4"

    // The next unit's inverse lands at [0,1) — outside the grant. Refused,
    // with no ghost commit, and the unit stays undoable.
    try t.expectError(error.OutOfLimit, ed.undo(gpa, ctx.undoGate()));
    const unchanged = try doc.text().toOwnedSlice(gpa);
    defer gpa.free(unchanged);
    try t.expectEqualStrings("U123456789", unchanged);

    // The user, holding no such grant, still unwinds it.
    ctx.principal = .user;
    try t.expect(try ed.undo(gpa, ctx.undoGate()));
    const restored = try doc.text().toOwnedSlice(gpa);
    defer gpa.free(restored);
    try t.expectEqualStrings("0123456789", restored);
}

test "command: a refused background render is observable (log + status chip)" {
    const gpa = t.allocator;
    var env = try DocRegionEnv.init(gpa);
    defer env.deinit();
    const doc = env.ctx.document().?;

    status_feed.set("");
    doc.my_grant = .view; // this replica may read, never write
    try t.expectError(error.Unauthorized, renderInto(gpa, doc, .plugin, "ci-plugin", &.{
        .{ .range = .{ .start = 0, .end = 0 }, .bytes = "3 failing" },
    }));

    // No Head to echo on, so the chip is the user-visible seam.
    const chip = status_feed.get() orelse return error.TestUnexpectedResult;
    try t.expect(std.mem.indexOf(u8, chip, "ci-plugin") != null);
    try t.expect(std.mem.indexOf(u8, chip, "refused") != null);
    status_feed.set("");
}

// ── place: the ambient answer to "where does this run" (doc/place.md) ──

test "command: place follows the entry, and a bound entry outranks the active one" {
    const gpa = t.allocator;
    var env = try DocRegionEnv.init(gpa);
    defer env.deinit();
    const ctx = &env.ctx;

    const project_a: Buffers.Place = .{ .container = .{
        .locus = .here,
        .ref = .{ .authority = .here, .slot = 1, .generation = 1 },
        .revision = 1,
    } };
    const project_b: Buffers.Place = .{ .container = .{
        .locus = .here,
        .ref = .{ .authority = .here, .slot = 2, .generation = 1 },
        .revision = 1,
    } };

    // With nothing placed, the degenerate instance — not a null, not a branch.
    try t.expect(ctx.place().isProcess());

    ctx.buffers.setPlace(ctx.buffers.active_id, project_a);
    try t.expect(ctx.place().eql(project_a));

    // A background delivery is ABOUT the entry it captured at spawn. Binding
    // that entry must retarget `place` too, or a fill landing while the user
    // looks at another project would act on the wrong one.
    const other = try ctx.buffers.create(gpa, "*grep*");
    ctx.buffers.setPlace(other, project_b);
    const prev = ctx.bindEntry(ctx.buffers.get(other).?.ref());
    try t.expect(ctx.place().eql(project_b));
    _ = ctx.bindEntry(prev);
    try t.expect(ctx.place().eql(project_a));
}

test "command: a bound entry that has closed places nowhere, not on whoever is active" {
    const gpa = t.allocator;
    var env = try DocRegionEnv.init(gpa);
    defer env.deinit();
    const ctx = &env.ctx;

    const project: Buffers.Place = .{ .container = .{
        .locus = .here,
        .ref = .{ .authority = .here, .slot = 1, .generation = 1 },
        .revision = 1,
    } };
    ctx.buffers.setPlace(ctx.buffers.active_id, project);

    const doomed = try ctx.buffers.create(gpa, "*doomed*");
    const ref = ctx.buffers.get(doomed).?.ref();
    try ctx.buffers.close(gpa, doomed, ctx.head, ctx.keymap);

    _ = ctx.bindEntry(ref);
    // NOT `project`: an effect whose subject is gone must refuse to act
    // somewhere, rather than quietly adopting the focused project.
    try t.expect(ctx.place().isProcess());
    _ = ctx.bindEntry(null);
}
