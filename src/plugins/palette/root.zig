//! palette — the bundled UI plugin: the command palette (pick-commands/help),
//! the buffers picker, and the status line. UI policy over core mechanisms
//! through the guest shim — introspection (commandCount/bufferAt), the
//! incremental pick (begin/add/end), and accept dispatched back to
//! on_pick_accept. No core privilege; the same door a user's config uses.
//!
//! ARGUMENTS. A palette that can only run a command with none is a palette
//! that cannot run half the editor: `listen`, `connect`, `grant`, `share-fs`
//! and every other command with a parameter refused on arity into a discarded
//! error, which from the outside is indistinguishable from a dead command.
//! Two ways in, now, and they are the two ways people already try:
//!
//!   · type them — `listen 7777 edit` matches no row, so the pick is opened
//!     free-text (`pickFreeText`) and the typed line is what accepts;
//!   · leave them out — an accepted row with arguments still to fill asks for
//!     them, one prompt per parameter.
//!
//! Both are `weft_invoke`, which the `:` line also uses, so "what does this
//! take?" has one answer in this editor rather than one per door. What the
//! palette adds is its own: each row carries its SHAPE beside its summary, so
//! the parameters are visible before you commit to the row.

const std = @import("std");
const weft = @import("weft");
const invoke = @import("weft_invoke");

var id_palette: u32 = 0;
var id_help: u32 = 0;
var id_buffers: u32 = 0;
var id_status: u32 = 0;

/// Scratch for building a buffer label / status message.
var label_buf: [512]u8 = undefined;
/// Scratch for a row's `<param>` shape, kept apart from `label_buf` because a
/// row renders both at once.
var shape_buf: [256]u8 = undefined;
var doc_buf: [512]u8 = undefined;

/// Config (`weft.set("palette", …)`), read once at init:
///
///   arguments = ask | off — whether a command chosen with its arguments
///     missing is ASKED for them (default), or refused with its signature so
///     you can retype the whole call yourself.
///   signature = on | off — whether a row shows its parameter shape beside
///     the summary. On by default; off is a plainer list.
var show_signature: bool = true;

const pick_commands = 0;
const pick_buffers = 1;

/// Missing arguments are asked for in the entry's own resting mode — the
/// palette is a service, not a grammar, so it must not strand a helix or
/// emacs user in someone else's `normal` (see `weft_prompt`'s `resting`).
const asker = invoke.Invoker(.{ .name = "palette-arg" });

const Cmd = struct { name: []const u8, handler: *const fn () void };
const own_cmds = [_]Cmd{
    .{ .name = "pick-commands", .handler = palette },
    .{ .name = "help", .handler = palette },
    .{ .name = "buffers", .handler = buffers },
    .{ .name = "status", .handler = status },
};
/// The argument prompt's five editing commands, spliced into this plugin's
/// one flat table so `on_command`'s id indexing stays a single array.
const arg_cmds: [asker.commands.len]Cmd = blk: {
    var arr: [asker.commands.len]Cmd = undefined;
    for (asker.commands, 0..) |c, i| arr[i] = .{ .name = c.name, .handler = c.handler };
    break :blk arr;
};
const cmds = own_cmds ++ arg_cmds;

export fn describe() void {
    for (cmds) |c| weft.declareCommand(c.name);
}

export fn init() void {
    for (cmds, 0..) |c, i| {
        const id = weft.register(c.name);
        if (i == 0) id_palette = id;
        if (i == 1) id_help = id;
        if (i == 2) id_buffers = id;
        if (i == 3) id_status = id;
    }
    asker.install();
    asker.setAsk(!std.mem.eql(u8, weft.config("arguments"), "off"));
    show_signature = !std.mem.eql(u8, weft.config("signature"), "off");
}

export fn on_command(id: u32) void {
    if (id < cmds.len) cmds[id].handler();
}

/// A fuzzy pick over what this context OFFERS and over the whole command
/// registry; accept runs the choice.
fn palette() void {
    weft.pickBegin("command", pick_commands);
    // A query with arguments in it (`listen 7777 edit`) matches no row by
    // construction — every completion style splits on whitespace. Free text
    // is what makes that query mean something instead of accepting into a
    // silent cancel.
    weft.pickFreeText();
    offers();
    const n = weft.commandCount();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const name = weft.commandName(i) orelse continue;
        weft.pickAdd(name, rowDoc(i));
    }
    weft.pickEnd();
}

/// A row's detail: its parameter shape, then its summary. The shape is what
/// turns "this row will do nothing" into "this row wants a port and an access
/// grade" — before you commit to the row, not after.
fn rowDoc(i: usize) []const u8 {
    const summary = weft.commandSummary(i) orelse "";
    if (!show_signature) return summary;
    // `commandSummary` and `commandArg` land in different shim scratches, but
    // the shape has to be copied out regardless: rendering it walks every
    // parameter, and each walk reuses the same one.
    const shape = asker.params(&shape_buf, i);
    if (shape.len == 0) return summary;
    if (summary.len == 0) return shape;
    return std.fmt.bufPrint(&doc_buf, "{s} · {s}", .{ shape, summary }) catch summary;
}

/// The focused context's live offers, listed ahead of the raw commands and
/// told apart by their dotted intention names. A disabled offer is listed
/// WITH its reason rather than hidden: absence already means nonapplicable,
/// so hiding one would say something false about it.
fn offers() void {
    const n = weft.offerCount();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const provider = weft.offerProvider(i) orelse continue;
        const doc = if (weft.offerReason(i)) |why|
            std.fmt.bufPrint(&label_buf, "offer · {s} · {s}", .{ provider, why }) catch continue
        else
            std.fmt.bufPrint(&label_buf, "offer · {s}", .{provider}) catch continue;
        const name = weft.offerName(i) orelse continue;
        weft.pickAdd(name, doc);
    }
}

/// Pick over the open buffers ("id: name"); accept switches to that buffer.
fn buffers() void {
    weft.pickBegin("buffer", pick_buffers);
    const n = weft.bufferCount();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const bid = weft.bufferId(i) orelse continue;
        const name = weft.bufferName(i) orelse continue;
        const label = std.fmt.bufPrint(&label_buf, "{d}: {s}{s}{s}", .{
            bid,                                         name,
            if (weft.bufferReadOnly(i)) " [ro]" else "", if (weft.bufferActive(i)) " *" else "",
        }) catch continue;
        // The candidate carries the buffer's identity; the label is display.
        weft.pickAddBuffer(label, "", i);
    }
    weft.pickEnd();
}

/// Echo the active buffer's name + read-only state (the status line).
fn status() void {
    const n = weft.bufferCount();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (!weft.bufferActive(i)) continue;
        const name = weft.bufferName(i) orelse continue;
        const msg = std.fmt.bufPrint(&label_buf, "{s}{s}", .{
            name, if (weft.bufferReadOnly(i)) "  read-only" else "",
        }) catch return;
        weft.echo(msg);
        break;
    }
}

export fn on_pick_accept(pick_id: u32) void {
    var outcome = (weft.pickOutcome(weft.allocator) catch return) orelse return;
    defer outcome.deinit(weft.allocator);
    if (pick_id == pick_commands) {
        switch (outcome) {
            // A ROW: a name and nothing else, so any arguments it needs are
            // still to come. An offer row resolves AGAIN, here, for the
            // context as it is now — the accepted row is a name, never a
            // decision made when the list was built.
            .candidate => |candidate| switch (weft.invokeIntention(candidate.text)) {
                .invoked => {},
                .refused => |why| weft.echo(why),
                .unknown => asker.invokeName(candidate.text),
            },
            // TYPED text: a whole call, arguments and all.
            .input => |input| asker.invokeLine(input),
            .cancelled => {},
        }
    } else if (pick_id == pick_buffers) {
        // The row NAMES a buffer; its label is display text, never an id to
        // parse back out — a buffer closed mid-pick refuses instead of
        // switching to whatever took its slot.
        const id = switch (outcome) {
            .candidate => |candidate| candidate.buffer orelse return weft.echo("that buffer is closed"),
            .input, .cancelled => return,
        };
        weft.runInt("buffer-switch", @intCast(id));
    }
}
