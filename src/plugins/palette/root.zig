//! palette — the bundled UI plugin: the command palette and the status line. UI policy over core mechanisms
//! through the guest shim — introspection (commandCount/bufferAt), the
//! incremental pick (begin/add/end), and accept dispatched back to
//! on_pick_accept. No core privilege; the same door a user's config uses.
//!
//! ARGUMENTS. A palette that can only run a command with none is a palette
//! that cannot run half the editor: `collab.listen`, `collab.connect`, `collab.grant`, `collab.share-fs`
//! and every other command with a parameter refused on arity into a discarded
//! error, which from the outside is indistinguishable from a dead command.
//! Two ways in, now, and they are the two ways people already try:
//!
//!   · type them — `collab.listen 7777 edit` matches no row, so the pick is opened
//!     free-text (`pickFreeText`) and the typed line is what accepts;
//!   · leave them out — an accepted row with arguments still to fill asks for
//!     them, one prompt per parameter.
//!
//! Both are `weft_invoke`, which the `:` line also uses, so "what does this
//! take?" has one answer in this editor rather than one per door. What the
//! palette adds is its own: each row carries its SHAPE beside its summary, so
//! the parameters are visible before you commit to the row.
//!
//! LABELS. A row reads the way a person names the verb (`Split Editor Right`,
//! `Open File…`), with its id and summary as secondary text and the key that
//! runs it here beside it (doc/chrome.md §1.2-1.3) — never the raw id alone.

const std = @import("std");
const weft = @import("weft");
const invoke = @import("weft_invoke");
const offers_lib = @import("weft_offers");

/// Scratch for the status message.
var label_buf: [512]u8 = undefined;
/// Scratch for a row's `<param>` shape, kept apart from the others because a
/// row renders several at once.
var shape_buf: [256]u8 = undefined;
var doc_buf: [768]u8 = undefined;
var shown_buf: [256]u8 = undefined;

/// Config (`weft.set("palette", …)`), read once at init:
///
///   arguments = ask | off — whether a command chosen with its arguments
///     missing is ASKED for them (default), or refused with its signature so
///     you can retype the whole call yourself.
///   signature = on | off — whether a row shows its parameter shape beside
///     the summary. On by default; off is a plainer list.
///   commands = listed | all — whether the list leaves out the commands that
///     say they are keymap machinery (default), or is the whole registry.
var show_signature: bool = true;
/// `commands = all` — whether an `internal` command gets a row too.
var list_all: bool = false;

const pick_commands = 0;

/// Missing arguments are asked for in the entry's own resting mode — the
/// palette is a service, not a grammar, so it must not strand a helix or
/// emacs user in someone else's `normal` (see `weft_prompt`'s `resting`).
const asker = invoke.Invoker(.{ .name = "palette.arg" });

const own_cmds = [_]weft.CommandEntry{
    .{
        .name = "palette.open",
        .arity = .whole,
        .call = palette,
        .summary = "Run a command, or act on what the focused context offers, by name.",
        .label = "Command Palette",
        .prompts = true,
        .menu = "View",
        .group = "palette",
        .order = 1,
        .icon = "command",
    },
    .{
        .name = "palette.show-status",
        .arity = .whole,
        .call = status,
        .summary = "Say which buffer is active and whether it is read-only.",
        .label = "Show Status",
    },
};
/// The argument prompt's five editing commands, spliced into this plugin's
/// one flat table so `on_command`'s id indexing stays a single array.
const arg_cmds: [asker.commands.len]weft.CommandEntry = blk: {
    var arr: [asker.commands.len]weft.CommandEntry = undefined;
    // Editing the prompt's own line: never the selection.
    for (asker.commands, 0..) |c, i| arr[i] = .{ .name = c.name, .call = c.handler, .arity = .whole, .summary = c.summary, .internal = true };
    break :blk arr;
};
const cmds = own_cmds ++ arg_cmds;

fn initExtra() void {
    asker.install();
    asker.setAsk(!std.mem.eql(u8, weft.config("arguments"), "off"));
    show_signature = !std.mem.eql(u8, weft.config("signature"), "off");
    list_all = std.mem.eql(u8, weft.config("commands"), "all");
}

/// What each row of the open palette runs, in the order the rows were added
/// — an accepted row is read back by that order (`PickCandidate.index`),
/// because what a person reads on it is a LABEL, not a name to run. Owned;
/// replaced on every open.
var row_names: std.ArrayList([]u8) = .empty;
var row_is_offer: std.ArrayList(bool) = .empty;

fn clearRows() void {
    for (row_names.items) |n| weft.allocator.free(n);
    row_names.clearRetainingCapacity();
    row_is_offer.clearRetainingCapacity();
}

/// Add one row: `shown` is what a person reads, `name` what it runs (and the
/// key an annotator looks it up by — the key that runs it, doc/chrome.md
/// §1.3), `doc` its secondary text.
fn addRow(shown: []const u8, doc: []const u8, name: []const u8, offer: bool) void {
    const owned = weft.allocator.dupe(u8, name) catch return;
    row_names.append(weft.allocator, owned) catch {
        weft.allocator.free(owned);
        return;
    };
    row_is_offer.append(weft.allocator, offer) catch {
        _ = row_names.pop();
        weft.allocator.free(owned);
        return;
    };
    weft.pickAddKeyed(shown, doc, name);
}

/// A fuzzy pick over what this context OFFERS and over the whole command
/// registry; accept runs the choice.
fn palette() void {
    clearRows();
    weft.pickBegin("command", pick_commands);
    weft.pickCategory("command");
    // A query with arguments in it (`collab.listen 7777 edit`) matches no row
    // by construction — every completion style splits on whitespace. Free text
    // is what makes that query mean something instead of accepting into a
    // silent cancel. It is also the escape hatch for machinery: typing an
    // internal command's exact id runs it though this list does not show it.
    weft.pickFreeText();
    offers();
    commands();
    weft.pickEnd();
}

/// The command half: every command a person runs, by LABEL (doc/chrome.md
/// §1.2), its id and summary the row's secondary text, its key beside it
/// (the annotator asks `keysFor` by the row's key, which is the id).
///
/// WHAT IS LISTED is what a command says about itself, not a list kept here:
/// a command marked `internal` is keymap machinery — a count digit, a
/// prompt's backspace, a motion a grammar wraps — and gets no row. It used to
/// be a pattern list in this file (`cursor-*`, `pick-*`, …), which is policy
/// about other plugins' commands held by the one plugin that could not know
/// them, and which a dotted id slipped straight past.
///
/// It is a REFUSAL TO LIST, not a refusal to run: the pick is free-text, so an
/// internal command still runs when you type its id. `commands = all` lists
/// them too, for a session that wants to go looking.
fn commands() void {
    const n = weft.commandCount();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const name_view = weft.commandName(i) orelse continue;
        var name_buf: [256]u8 = undefined;
        if (name_view.len > name_buf.len) continue;
        @memcpy(name_buf[0..name_view.len], name_view);
        const name = name_buf[0..name_view.len];
        const meta = weft.commandMeta(name) orelse weft.Presentation{};
        if (meta.internal and !list_all) continue;
        addRow(meta.shown(&shown_buf, name), rowDoc(i, name, meta.summary), name, false);
    }
}

/// A row's secondary text: the id, then the parameter shape, then the
/// summary. The id is what the `:` line and a config name it by; the shape
/// turns "this row will do nothing" into "this row wants a port and an access
/// grade" — before you commit to the row, not after.
fn rowDoc(i: usize, name: []const u8, summary: []const u8) []const u8 {
    const shape = if (show_signature) asker.params(&shape_buf, i) else "";
    return std.fmt.bufPrint(&doc_buf, "{s}{s}{s}{s}{s}", .{
        name,
        if (shape.len > 0) " " else "",
        shape,
        if (summary.len > 0) " · " else "",
        summary,
    }) catch name;
}

/// The focused context's live offers, listed ahead of the commands by their
/// LABELS — read through `weft_offers`, the same reading the offers
/// projection's strip, list and menu are, so the palette, the toolbar and the
/// context menu cannot disagree about what a context offers or in what order.
/// Every word is listed (the grammar's own included: a palette is where you
/// look one up), and a disabled offer WITH its reason rather than hidden:
/// absence already means nonapplicable, so hiding one would say something
/// false about it.
fn offers() void {
    var arena = std.heap.ArenaAllocator.init(weft.allocator);
    defer arena.deinit();
    const items = offers_lib.collect(arena.allocator(), .{ .where = .active, .grammar_words = true }) catch return;
    for (items) |item| {
        const doc = if (!item.enabled())
            std.fmt.bufPrint(&doc_buf, "{s} · offered by {s} · {s}", .{ item.name, item.provider, item.reason }) catch continue
        else
            std.fmt.bufPrint(&doc_buf, "{s} · offered by {s}", .{ item.name, item.provider }) catch continue;
        addRow(item.label, doc, item.name, true);
    }
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

fn onPickAccept(pick_id: u32) void {
    var outcome = (weft.pickOutcome(weft.allocator) catch return) orelse return;
    defer outcome.deinit(weft.allocator);
    if (pick_id != pick_commands) return;
    switch (outcome) {
        // A ROW: what it runs is its name, found by the order it was added —
        // never parsed out of the label a person read. Any arguments it needs
        // are still to come. An offer row resolves AGAIN, here, for the
        // context as it is now — the accepted row is a name, never a decision
        // made when the list was built.
        .candidate => |candidate| {
            const i = candidate.index;
            if (i >= row_names.items.len) return;
            const name = row_names.items[i];
            if (row_is_offer.items[i]) switch (weft.invokeIntention(name)) {
                .invoked => {},
                .refused => |why| weft.echo(why),
                .unknown => asker.invokeName(name),
            } else asker.invokeName(name);
        },
        // TYPED text: a whole call, arguments and all.
        .input => |input| asker.invokeLine(input),
        .cancelled => {},
    }
}

const manifest = weft.plugin(&cmds, .{ .init = initExtra, .pick = onPickAccept });
comptime {
    manifest.exportAll();
}
