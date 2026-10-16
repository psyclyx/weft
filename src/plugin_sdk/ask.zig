//! `ask` — a question with a continuation, instead of a pick id to demux.
//!
//! The pick doors work. What was missing around them is the same thing that
//! was missing around `proc`: a way to say "ask this, then do that" without
//! the plugin inventing a correspondence. `pickBegin` takes a `u32` the guest
//! gives meaning to, and every guest gave it the same meaning by hand — git
//! packs `@intFromEnum(which) | (session << 8)` and unpacks it in
//! `on_pick_accept`, then re-reads the outcome, then compares the answer text
//! to `"yes"`, for a question whose only two answers it wrote itself.
//!
//! That hand-rolled confirmation is worth naming, because seven plugins have
//! some version of it and it is where the interesting bug lives: the code that
//! ASKS and the code that ACTS are in different functions with a `u32` between
//! them, so the thing being confirmed has to be stashed somewhere global
//! (`pending_target`, `confirm_cmd`) and re-validated on the way back out. A
//! continuation that closes over the target has no gap to stash anything in.
//!
//! Ids here carry `sdk_bit`. A plugin still driving the raw doors chooses its
//! own ids below it and reaches them through the manifest's `pick` hook; the
//! two never collide.

const std = @import("std");
const weft = @import("root.zig");
const e = @import("externs.zig");

/// A row to offer.
pub const Candidate = struct {
    text: []const u8,
    doc: []const u8 = "",
};

/// What to ask.
pub const Spec = struct {
    prompt: []const u8,
    candidates: []const Candidate = &.{},
    /// Accept a query that matches no row — the door for "type something new".
    free_text: bool = false,
    /// The annotation category rows are decorated under, if any.
    category: []const u8 = "",
};

/// A question whose rows the plugin FEEDS (`search`): asked again as the
/// query settles, or once at open, and answered as rows arrive — a search
/// per query (ripgrep), a file list that takes a moment, a server's symbols.
pub const SearchSpec = struct {
    prompt: []const u8,
    category: []const u8 = "",
    free_text: bool = false,
    /// Ask `on_query` again each time the query settles. Off: it is asked
    /// once, at open, with an empty query, and the picker narrows its rows.
    per_query: bool = true,
    /// The rows ARE the match (the plugin searched): shown as given, in its
    /// order, unfiltered by the picker. Off: the picker narrows them.
    matched: bool = true,
    /// How long the query must be still before it is asked about.
    debounce_ms: u32 = 30,
    /// Shorter queries are not asked about.
    min_query: u32 = 0,
};

/// Where a query's rows go. Carries its query's generation, so rows pushed
/// after the query has moved on are refused rather than mixed in — keep one
/// and push from a later callback (a process's answer) freely.
pub const Feed = struct {
    epoch: u32,

    /// One row. False once the query has moved on or its rows are full:
    /// stop producing.
    pub fn push(self: Feed, text: []const u8, doc: []const u8) bool {
        return e.wl_pick_push(self.epoch, @intCast(@intFromPtr(text.ptr)), @intCast(text.len), @intCast(@intFromPtr(doc.ptr)), @intCast(doc.len)) == 1;
    }

    /// Every row for this query is in (so an answer of none clears the last).
    pub fn done(self: Feed) void {
        e.wl_pick_done(self.epoch);
    }
};

/// What came back. `text` is the answer either way, so a caller that does not
/// care whether a row was chosen or typed need not ask.
pub const Answer = union(enum) {
    chosen: []const u8,
    typed: []const u8,
    cancelled,

    pub fn text(self: Answer) []const u8 {
        return switch (self) {
            .chosen, .typed => |s| s,
            .cancelled => "",
        };
    }

    pub fn answered(self: Answer) bool {
        return self != .cancelled;
    }
};

// ── The pending table ─────────────────────────────────────────────────

const Pending = struct {
    thunk: *const fn (Answer, ?*anyopaque) void,
    /// A `search`'s rows: asked with each settled query.
    on_query: ?*const fn ([]const u8, Feed) void = null,
    ctx: ?*anyopaque = null,
    release: ?*const fn (std.mem.Allocator, ?*anyopaque) void = null,
};

var pending: std.ArrayList(?Pending) = .empty;

/// The bit that says "this pick is the SDK's". A plugin driving the raw doors
/// keeps its own ids below it.
///
/// Bit 30, not 31: a pick id crosses the membrane as an `i32`, so the top bit
/// would arrive negative and the host's `@intCast` would take the process down
/// (`wasm_host/pick.zig` — the same sign-bit class `core/handles.zig` fixed for
/// handles). Half the id space is still a billion questions.
pub const sdk_bit: u32 = 0x4000_0000;

/// Ask `spec`; `on_answer` receives what came back, including a cancel. False
/// means the question was never asked and the continuation will not run.
pub fn ask(spec: Spec, on_answer: *const fn (Answer) void) bool {
    const Shim = struct {
        fn call(answer: Answer, ctx: ?*anyopaque) void {
            const f: *const fn (Answer) void = @ptrCast(@alignCast(ctx.?));
            f(answer);
        }
    };
    return open(spec, .{ .thunk = Shim.call, .ctx = @ptrCast(@constCast(on_answer)) });
}

/// `ask`, carrying a value of your own to the callback — the target a
/// destructive verb was armed with, rather than a module-level `pending_target`
/// and a re-resolution on the way back.
pub fn askWith(
    comptime Ctx: type,
    ctx: Ctx,
    spec: Spec,
    comptime on_answer: fn (Answer, Ctx) void,
) bool {
    const Shim = struct {
        fn call(answer: Answer, raw: ?*anyopaque) void {
            const held: *Ctx = @ptrCast(@alignCast(raw.?));
            on_answer(answer, held.*);
        }
        fn release(gpa: std.mem.Allocator, raw: ?*anyopaque) void {
            const held: *Ctx = @ptrCast(@alignCast(raw.?));
            gpa.destroy(held);
        }
    };
    const held = weft.allocator.create(Ctx) catch return false;
    held.* = ctx;
    if (!open(spec, .{ .thunk = Shim.call, .ctx = @ptrCast(held), .release = Shim.release })) {
        weft.allocator.destroy(held);
        return false;
    }
    return true;
}

/// A yes/no, asked through the pick membrane like every other question — so a
/// plugin owns no confirmation mode, and the safe answer leads.
pub fn confirm(question: []const u8, on_answer: *const fn (bool) void) bool {
    // Carried through `askWith` rather than parked in a module `var`: two
    // questions can be in flight, and the second must not answer the first.
    const Shim = struct {
        fn call(answer: Answer, f: *const fn (bool) void) void {
            f(std.mem.eql(u8, answer.text(), yes));
        }
    };
    return askWith(*const fn (bool) void, on_answer, confirmSpec(question), Shim.call);
}

/// `confirm`, carrying the thing being confirmed. This is the shape that closes
/// the gap: what the answer acts on travels WITH the question, so there is
/// nothing to stash between the two and nothing to re-resolve on the way back.
pub fn confirmWith(
    comptime Ctx: type,
    ctx: Ctx,
    question: []const u8,
    comptime on_answer: fn (bool, Ctx) void,
) bool {
    const Shim = struct {
        fn call(answer: Answer, held: Ctx) void {
            on_answer(std.mem.eql(u8, answer.text(), yes), held);
        }
    };
    return askWith(Ctx, ctx, confirmSpec(question), Shim.call);
}

const yes = "yes";

/// Safe answer first, so accepting the leading candidate changes nothing.
fn confirmSpec(question: []const u8) Spec {
    return .{
        .prompt = question,
        .candidates = &.{
            .{ .text = "no", .doc = "leave it alone" },
            .{ .text = yes, .doc = "go ahead" },
        },
    };
}

/// Open a pick this plugin feeds: `on_query` is handed each settled query
/// (or, without `per_query`, one empty query at open) and a `Feed` for its
/// rows; `on_answer` gets the chosen row, the typed text, or a cancel.
pub fn search(
    spec: SearchSpec,
    on_query: *const fn ([]const u8, Feed) void,
    on_answer: *const fn (Answer) void,
) bool {
    if (spec.prompt.len == 0) return false;
    const Shim = struct {
        fn call(answer: Answer, ctx: ?*anyopaque) void {
            const f: *const fn (Answer) void = @ptrCast(@alignCast(ctx.?));
            f(answer);
        }
    };
    const slot = claim(.{ .thunk = Shim.call, .ctx = @ptrCast(@constCast(on_answer)), .on_query = on_query }) orelse return false;
    weft.pickBegin(spec.prompt, sdk_bit | slot);
    if (spec.free_text) weft.pickFreeText();
    if (spec.category.len > 0) weft.pickCategory(spec.category);
    const flags: u32 = @as(u32, @intFromBool(spec.per_query)) | @as(u32, @intFromBool(spec.matched)) << 1;
    e.wl_pick_live(flags, spec.debounce_ms, spec.min_query);
    weft.pickEnd();
    if (!spec.per_query) on_query("", .{ .epoch = 0 });
    return true;
}

/// The host's `on_pick_query`, routed to the `search` that asked. False for
/// an id that is not ours.
pub fn deliverQuery(pick_id: u32, epoch: u32) bool {
    if (pick_id & sdk_bit == 0) return false;
    const slot = pick_id & ~sdk_bit;
    if (slot >= pending.items.len) return true;
    const cont = pending.items[slot] orelse return true;
    const f = cont.on_query orelse return true;
    const len = e.wl_pick_query(0, 0);
    if (len < 0) return true;
    const query = weft.allocator.alloc(u8, @intCast(len)) catch return true;
    defer weft.allocator.free(query);
    if (len > 0 and e.wl_pick_query(@intCast(@intFromPtr(query.ptr)), @intCast(query.len)) != len) return true;
    f(query, .{ .epoch = epoch });
    return true;
}

fn open(spec: Spec, cont: Pending) bool {
    if (spec.prompt.len == 0) return false;
    const slot = claim(cont) orelse return false;
    weft.pickBegin(spec.prompt, sdk_bit | slot);
    if (spec.free_text) weft.pickFreeText();
    if (spec.category.len > 0) weft.pickCategory(spec.category);
    for (spec.candidates) |c| weft.pickAdd(c.text, c.doc);
    weft.pickEnd();
    return true;
}

fn claim(cont: Pending) ?u32 {
    for (pending.items, 0..) |slot, i| {
        if (slot == null) {
            pending.items[i] = cont;
            return @intCast(i);
        }
    }
    pending.append(weft.allocator, cont) catch return null;
    return @intCast(pending.items.len - 1);
}

/// The host's accept, routed to the continuation that asked. Returns false for
/// an id that is not ours, which is how the manifest knows to pass it on to a
/// plugin still driving the raw doors.
pub fn deliver(pick_id: u32) bool {
    if (pick_id & sdk_bit == 0) return false;
    const slot = pick_id & ~sdk_bit;
    if (slot >= pending.items.len) return true; // ours, but not one we issued
    const cont = pending.items[slot] orelse return true;
    // Freed BEFORE the callback, so a continuation that asks another question
    // can reuse this slot and cannot be re-entered into its own.
    pending.items[slot] = null;
    defer if (cont.release) |f| f(weft.allocator, cont.ctx);

    var outcome = (weft.pickOutcome(weft.allocator) catch {
        cont.thunk(.cancelled, cont.ctx);
        return true;
    }) orelse {
        cont.thunk(.cancelled, cont.ctx);
        return true;
    };
    defer outcome.deinit(weft.allocator);
    const answer: Answer = switch (outcome) {
        .candidate => |c| .{ .chosen = c.text },
        .input => |typed| .{ .typed = typed },
        .cancelled => .cancelled,
    };
    cont.thunk(answer, cont.ctx);
    return true;
}
