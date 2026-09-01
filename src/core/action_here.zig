//! ONE ACTION NAME, WHATEVER IS SHOWING.
//!
//! `view.apply`, `selection.paste-after`, `target.open-container` are what a
//! PERSON means. Which plane answers is not their business, and it is not the
//! caller's either: a scene-backed view answers from its FOCUSED NODE, and a
//! producer whose view is a text PROJECTION answers from what point is on.
//!
//! This lived in `builtins.invokeSemanticAction`, so only COMMANDS got it. The
//! guest door `wl_semantic_action` — how ex spells `:e!`, how vim asks for a
//! register-carrying yank — went straight to the focused-scene call and so was
//! inert against a listing: `:e!` in a directory reverted nothing, silently,
//! because nothing was focused and "nothing focused" came back as success.
//! Two callers, one rule, one place.

const std = @import("std");
const command = @import("command.zig");
const semantic = @import("semantic.zig");
const semantic_model = @import("weft_semantic");
const projection = @import("projection.zig");

pub const Effect = semantic.Services.ActionEffect;

/// Invoke `action` on whatever is showing. Null when neither plane claims it —
/// which is not a failure, it is an ordinary text buffer having no `view.apply`.
///
/// `register` is the transfer slot a grammar selected (0 for the unnamed one).
pub fn invokeHere(
    ctx: *command.Context,
    action: []const u8,
    register: u8,
) semantic.Services.InvokeActionError!?Effect {
    const services = ctx.semantic orelse return null;
    // The FOCUSED SCENE first, when there is one. A `declined` provider has
    // answered "not me", which is the same standing as no focus at all.
    if (services.invokeFocusedActionInRegister(
        &ctx.head.interactions,
        ctx.head,
        ctx.gpa,
        action,
        register,
    )) |effect| {
        if (effect) |handled| {
            if (handled != .declined) return handled;
        }
    } else |err| switch (err) {
        error.ActionUnavailable, error.StaleView => {},
        else => return err,
    }
    return invokeOnProjection(ctx, services, action, register);
}

/// Offer `action` to the projection showing here.
///
/// SUBJECTS IN ORDER — the PART point is in, the ROW it belongs to, then the
/// VIEW — because a projection has no focus to disambiguate them the way a
/// scene did. Editing permissions is about the mode column; `selection.copy`
/// is about the row; `view.apply` and `target.open-container` are about the
/// listing; `selection.paste-after` in an EMPTY directory has no row to be
/// about at all. A scene answered all four from one focused node because its
/// columns, its rows and its root were all nodes — the ordering here is that
/// same containment, said out loud.
fn invokeOnProjection(
    ctx: *command.Context,
    services: *semantic.Services,
    action: []const u8,
    register: u8,
) semantic.Services.InvokeActionError!?Effect {
    const entry = ctx.buffers.active();
    const view_ref = entry.tool_view orelse return null;
    const view = services.views.get(view_ref) orelse return null;
    const here = subjectsHere(ctx);
    for ([_]?semantic_model.scene.NodeId{ here.part, here.row, view.scene.id }) |candidate| {
        const subject = candidate orelse continue;
        if (services.invokeActionInRegister(
            &ctx.head.interactions,
            ctx.gpa,
            .{ .action = action, .view = view_ref, .subject = subject },
            register,
        )) |effect| {
            if (effect == .declined) continue;
            applyToHead(ctx, effect);
            return effect;
        } else |err| switch (err) {
            // Not this subject. `StaleView` ends the attempt entirely: there is
            // no second subject in a view that is gone.
            error.ActionUnavailable => {},
            error.StaleView => return null,
            else => return err,
        }
    }
    return null;
}

/// THE HALF OF AN EFFECT THAT IS ABOUT THE HEAD.
///
/// `invokeActionInRegister` absorbs the outcome into the SERVICES — the
/// transfer, the interaction stack, the target registry. What it cannot do is
/// touch the head, because it is not given one; the focused-scene entry point
/// does that separately. The projection plane goes through the direct call and
/// so was silently dropping this half: a row that answered
/// `workspace.set-working-target` had its answer computed, validated, and
/// thrown away.
fn applyToHead(ctx: *command.Context, effect: Effect) void {
    switch (effect) {
        .working_target_requested => |target| ctx.head.working_target = target,
        // WHERE POINT IS is what a text projection focuses with, so a focus
        // request moves the caret rather than `semantic_focus`.
        .focus_requested => |focus| focusPart(ctx, focus.node),
        // Deliberately NOT focusing the opened view. A handler that shows a
        // listing shows a BUFFER, and attaching its scene on top is the second
        // display path this whole plane exists to remove. A handler that
        // published only a scene still gets core's default presentation
        // through the ordinary open path.
        .target_opened, .relation_opened => {},
        else => {},
    }
}

/// "FOCUS THIS NODE", said to a text projection, means PUT POINT IN IT.
///
/// A provider that creates a row focuses its name field so the next keystroke
/// replaces the placeholder; one that offers permissions focuses the mode. On a
/// scene that moved `semantic_focus`. Here the same request has to move the
/// CARET, because point is what a text buffer focuses with — and the span is
/// selected for the same reason the scene pre-selected the placeholder.
///
/// Silent when the node names no part: a producer may focus something it did
/// not project, and the listing simply stays where it is.
fn focusPart(ctx: *command.Context, node: semantic_model.scene.NodeId) void {
    const entry = ctx.buffers.active();
    const view = entry.projection orelse return;
    const editor = entry.textEditor() orelse return;
    var key_buf: [24]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "{d}", .{@intFromEnum(node)}) catch return;
    const span = view.subjectSpan(key) orelse return;
    editor.placeCursor(span.start);
    editor.setMark(ctx.gpa) catch return;
    editor.placeCursor(span.end);
}

pub const Subjects = struct {
    part: ?semantic_model.scene.NodeId = null,
    row: ?semantic_model.scene.NodeId = null,
};

/// What point is on, innermost first: the PART (a column), and the ROW it is
/// in. Either may be absent — an empty listing has neither, and a producer that
/// keys no spans has only the row.
pub fn subjectsHere(ctx: *command.Context) Subjects {
    const entry = ctx.buffers.active();
    if (entry.tool_view == null) return .{};
    const view = entry.projection orelse return .{};
    const ed = entry.textEditor() orelse return .{};
    const subject = view.subjectAt(ed.cursorOffset()) orelse return .{};
    const row = nodeIdOf(subject.node.key);
    const part = nodeIdOf(subject.key);
    // The row answering as its own subject is one candidate, not two.
    return .{ .part = if (part != null and part != row) part else null, .row = row };
}

fn nodeIdOf(key: []const u8) ?semantic_model.scene.NodeId {
    const raw = std.fmt.parseInt(u64, key, 10) catch return null;
    return @enumFromInt(raw);
}
