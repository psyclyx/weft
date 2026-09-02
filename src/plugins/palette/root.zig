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
///   commands = documented | all — whether the list is what plugin authors
///     documented (default) or the whole registry. See `commands()`.
///   hide = <patterns> — space-separated exact names and `prefix-*`, replacing
///     the built-in list of keystrokes and UI plumbing. See `hidden()`.
var show_signature: bool = true;
/// `commands = documented | all` — whether an UNDOCUMENTED command gets a row.
/// See `commands()` for why the default is silence.
var list_all: bool = false;

/// What a bare weft hides: the keystrokes and the UI plumbing. Every one of
/// these is a key's implementation or a picker's own machinery — reachable by
/// the key that owns it, meaningless typed by name, and forty of them between
/// you and the verb you were looking for.
///
/// The std vocabulary is here too (`selection-*`, `hierarchy-*`,
/// `target-open-focused`) because the OFFERS half already lists exactly those,
/// contextually and attributed to whoever answers them here — a second row for
/// the same act, minus the context, is worse than no row.
const default_hide =
    "cursor-* row-* pick-* insert-* delete-* selection-* hierarchy-* " ++
    "set-mark set-mode set-cursor cursor-blink clear-selection undo-barrier " ++
    "posture-break-out menu-escape which-key-* repeat-change field-edit " ++
    "target-open-focused echo save close split vsplit unsplit focus-other";

/// `hide = <patterns>` — read once at init, defaulting to `default_hide`.
var hide_patterns: []const u8 = default_hide;

const pick_commands = 0;
const pick_buffers = 1;

/// Missing arguments are asked for in the entry's own resting mode — the
/// palette is a service, not a grammar, so it must not strand a helix or
/// emacs user in someone else's `normal` (see `weft_prompt`'s `resting`).
const asker = invoke.Invoker(.{ .name = "palette-arg" });

const own_cmds = [_]weft.CommandEntry{
    .{ .name = "pick-commands", .call = palette, .summary = "run a command by name" },
    .{ .name = "help", .call = palette, .summary = "browse every command with its summary" },
    .{ .name = "buffers", .call = buffers, .summary = "switch to another open buffer" },
    .{ .name = "status", .call = status, .summary = "say what the status line is showing" },
};
/// The argument prompt's five editing commands, spliced into this plugin's
/// one flat table so `on_command`'s id indexing stays a single array.
const arg_cmds: [asker.commands.len]weft.CommandEntry = blk: {
    var arr: [asker.commands.len]weft.CommandEntry = undefined;
    for (asker.commands, 0..) |c, i| arr[i] = .{ .name = c.name, .call = c.handler };
    break :blk arr;
};
const cmds = own_cmds ++ arg_cmds;

fn initExtra() void {
    // The manifest registered these; ask it what the host called them, rather
    // than registering a second time and keeping a parallel index by position.
    id_palette = manifest.idOf("pick-commands");
    id_help = manifest.idOf("help");
    id_buffers = manifest.idOf("buffers");
    id_status = manifest.idOf("status");
    asker.install();
    asker.setAsk(!std.mem.eql(u8, weft.config("arguments"), "off"));
    show_signature = !std.mem.eql(u8, weft.config("signature"), "off");
    list_all = std.mem.eql(u8, weft.config("commands"), "all");
    // `weft.config` hands back a view of the shim's own scratch, and this is
    // read on every palette open — so it is copied, once, into memory this
    // plugin owns for its whole life.
    const configured = weft.config("hide");
    if (configured.len > 0) {
        if (weft.allocator.dupe(u8, configured)) |owned| {
            hide_patterns = owned;
        } else |_| {}
    }
}

/// A fuzzy pick over what this context OFFERS and over the whole command
/// registry; accept runs the choice.
fn palette() void {
    weft.pickBegin("command", pick_commands);
    weft.pickCategory("command");
    // A query with arguments in it (`listen 7777 edit`) matches no row by
    // construction — every completion style splits on whitespace. Free text
    // is what makes that query mean something instead of accepting into a
    // silent cancel. It is also the escape hatch for an undocumented command:
    // typing its exact name runs it whether or not this list showed it.
    weft.pickFreeText();
    offers();
    commands();
    weft.pickEnd();
}

/// The command half, BY OWNER.
///
/// Two policies live here, and both are this plugin's rather than core's:
///
/// WHAT IS LISTED. A command earns a row by being DOCUMENTED — by having a
/// summary its author wrote. Before this the palette listed the whole registry,
/// which is ~330 rows of which most are keystrokes (`vim-append`,
/// `motion.doc-end`, `pair-paren`) or trampolines one plugin runs on another's
/// behalf (`files-show`, `git-commit-settle`). None of those are things a
/// person looks up by name, and a list that contains them is a list you scroll
/// past rather than read. The default is silence, which is the right default:
/// a new internal command stays out without anyone remembering to hide it.
///
/// It is a REFUSAL TO LIST, not a refusal to run — the pick is free-text, so
/// an undocumented command still runs when you type its name. `commands = all`
/// puts everything back for a session that wants to go looking.
///
/// IN WHAT ORDER. By owner, then by name, so the list reads grouped even
/// though a fuzzy pick has no headings. The owner leads each row's annotation
/// for the same reason: `goto-definition` and `rename` do not say `lsp` in
/// their names, and knowing whose a command is is most of knowing what it is.
fn commands() void {
    var owners = ownerList() orelse return listUnordered();
    defer {
        for (owners.items) |o| weft.allocator.free(o);
        owners.deinit(weft.allocator);
    }
    for (owners.items) |owner| {
        const n = weft.commandCount();
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (!listed(i)) continue;
            const who = weft.commandOwner(i) orelse continue;
            if (!std.mem.eql(u8, who, owner)) continue;
            const doc = rowDoc(i);
            const name = weft.commandName(i) orelse continue;
            weft.pickAdd(name, doc);
        }
    }
}

/// Whether the `i`-th command gets a row.
///
/// TWO RULES, and they catch different things. A PLUGIN says what its commands
/// are for and leaves its internals bare, so "documented" sorts vim's
/// seventy-seven keystrokes from git's forty verbs by itself. CORE cannot say
/// it that way — `command.define` takes a summary and every core command has
/// one — so `cursor-down` and `save-file` are equally documented and only one
/// of them is something you look up by name.
///
/// So the second rule is a PATTERN LIST, and it is deliberately the user's
/// rather than core's: what counts as noise in a list you read is a matter of
/// taste, it changes with the grammar you drive, and core holding an opinion
/// about its own commands' worth would be exactly the policy that does not
/// belong there. `weft.set("palette", "hide", …)` replaces the default.
fn listed(i: usize) bool {
    const name = weft.commandName(i) orelse return false;
    if (hidden(name)) return false;
    if (list_all) return true;
    const summary = weft.commandSummary(i) orelse return false;
    return summary.len > 0;
}

/// Does `name` match one of the hide patterns? A pattern is an exact name or a
/// `prefix-*`. Two forms and no more: a glob language here would be a second
/// matcher to learn, for a list whose whole job is to be readable at a glance.
fn hidden(name: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, hide_patterns, " ");
    while (it.next()) |pattern| {
        if (std.mem.endsWith(u8, pattern, "*")) {
            if (std.mem.startsWith(u8, name, pattern[0 .. pattern.len - 1])) return true;
        } else if (std.mem.eql(u8, name, pattern)) return true;
    }
    return false;
}

/// Every distinct owner, sorted. Unbounded — a ceiling here would silently
/// drop a plugin's whole namespace, which is the failure this grouping exists
/// to prevent.
fn ownerList() ?std.ArrayList([]u8) {
    var out: std.ArrayList([]u8) = .empty;
    const n = weft.commandCount();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (!listed(i)) continue;
        const who = weft.commandOwner(i) orelse continue;
        var seen = false;
        for (out.items) |o| seen = seen or std.mem.eql(u8, o, who);
        if (seen) continue;
        const owned = weft.allocator.dupe(u8, who) catch {
            for (out.items) |o| weft.allocator.free(o);
            out.deinit(weft.allocator);
            return null;
        };
        out.append(weft.allocator, owned) catch {
            weft.allocator.free(owned);
            for (out.items) |o| weft.allocator.free(o);
            out.deinit(weft.allocator);
            return null;
        };
    }
    std.mem.sort([]u8, out.items, {}, lessOwner);
    return out;
}

fn lessOwner(_: void, a: []u8, b: []u8) bool {
    // `core` first: the editor's own verbs are what a person reaches for
    // before any plugin's, and they are the ones with no prefix to type.
    const a_core = std.mem.eql(u8, a, "core");
    const b_core = std.mem.eql(u8, b, "core");
    if (a_core != b_core) return a_core;
    return std.mem.lessThan(u8, a, b);
}

/// The fallback when the owner pass cannot allocate: the old flat listing,
/// still filtered. Losing the ORDER is a cosmetic degradation; losing rows
/// would not be.
fn listUnordered() void {
    const n = weft.commandCount();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (!listed(i)) continue;
        const doc = rowDoc(i);
        const name = weft.commandName(i) orelse continue;
        weft.pickAdd(name, doc);
    }
}

/// A row's detail: its parameter shape, then its summary. The shape is what
/// turns "this row will do nothing" into "this row wants a port and an access
/// grade" — before you commit to the row, not after.
fn rowDoc(i: usize) []const u8 {
    const owner = weft.commandOwner(i) orelse "";
    const summary = weft.commandSummary(i) orelse "";
    // `commandSummary`, `commandOwner` and `commandArg` land in different shim
    // scratches, but the shape has to be copied out regardless: rendering it
    // walks every parameter, and each walk reuses the same one.
    const shape = if (show_signature) asker.params(&shape_buf, i) else "";
    // The OWNER LEADS. `goto-definition` does not say `lsp` and `pair-paren`
    // does not say `autopair`; whose a command is is most of what a row has to
    // tell you before you run it.
    return std.fmt.bufPrint(&doc_buf, "{s}{s}{s}{s}{s}", .{
        owner,
        if (owner.len > 0 and (shape.len > 0 or summary.len > 0)) " · " else "",
        shape,
        if (shape.len > 0 and summary.len > 0) " · " else "",
        summary,
    }) catch summary;
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
    weft.pickCategory("buffer");
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

fn onPickAccept(pick_id: u32) void {
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

const manifest = weft.plugin(&cmds, .{ .init = initExtra, .pick = onPickAccept });
comptime {
    manifest.exportAll();
}
