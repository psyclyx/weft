//! std (wasm twin) — the bundled UI plugin (src/core/catalog/palette.zig)
//! recompiled as `.wasm`: the command palette (pick-commands/help), the
//! buffers picker, and the status line. UI policy over core mechanisms
//! through the guest shim — introspection (commandCount/bufferAt), the
//! incremental pick (begin/add/end), and accept dispatched back to
//! on_pick_accept. No core privilege; the same door a user's config uses.

const std = @import("std");
const weft = @import("weft");

var id_palette: u32 = 0;
var id_help: u32 = 0;
var id_buffers: u32 = 0;
var id_status: u32 = 0;

/// Scratch for building a buffer label / status message.
var label_buf: [512]u8 = undefined;

const pick_commands = 0;
const pick_buffers = 1;

export fn describe() void {
    weft.declareCommand("pick-commands");
    weft.declareCommand("help");
    weft.declareCommand("buffers");
    weft.declareCommand("status");
}

export fn init() void {
    id_palette = weft.register("pick-commands");
    id_help = weft.register("help");
    id_buffers = weft.register("buffers");
    id_status = weft.register("status");
}

export fn on_command(id: u32) void {
    if (id == id_palette or id == id_help) palette() else if (id == id_buffers) buffers() else if (id == id_status) status();
}

/// A fuzzy pick over what this context OFFERS and over the whole command
/// registry; accept runs the choice.
fn palette() void {
    weft.pickBegin("command", pick_commands);
    offers();
    const n = weft.commandCount();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const name = weft.commandName(i) orelse continue;
        weft.pickAdd(name, weft.commandSummary(i) orelse "");
    }
    weft.pickEnd();
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
    const choice = switch (outcome) {
        .candidate => |candidate| candidate.text,
        .input => |input| input,
        .cancelled => return,
    };
    if (pick_id == pick_commands) {
        // An offer row resolves AGAIN, here, for the context as it is now —
        // the accepted row is a name, never a decision made when the list
        // was built. A name no intention claims is a plain command.
        switch (weft.invokeIntention(choice)) {
            .invoked => {},
            .refused => |why| weft.echo(why),
            .unknown => weft.run(choice),
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
