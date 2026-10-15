//! Completion UI — the race-and-refine consumer over `edit/completion`.
//! Written against the capability name only: it fires a session at
//! whatever providers matched, opens the pick immediately (instant-tier
//! results usually land inside the same frame), and refreshes the item
//! set as slower providers arrive. A dead provider degrades the list;
//! nothing here waits. Accepting replaces the word prefix the session
//! was fired with.
//!
//! The refresh is a `pick.Source`: the picker's own per-frame `tick`
//! folds new results in and closing the pick cancels the caps session —
//! one drive loop, no bespoke tick call in the frame loop.
//!
//! Two ways to open the same list. `complete.show` takes the keyboard (the
//! "pick" mode): what you type narrows the query, and accepting replaces the
//! prefix it was fired with. `complete.show-inline` does not (an INLINE pick,
//! `pick.InlineKeys`): typing goes on into the buffer, the query is the word
//! being typed read back off it each frame, and the popup closes itself once
//! it describes nothing being typed — the caret left the word, the mode was
//! left, nothing matches, or the one match is what is already there. Deciding
//! WHEN to open it is not here: that is an auto-trigger's policy, and the
//! `complete` plugin holds it.
//!
//! Stale policy (declared): completion items are plain text — if peer
//! commits land while the popup is open, accepted text still inserts at
//! the *current* cursor, which is the only honest interpretation; range
//! -carrying capabilities go through stamped-range rebase instead.

const std = @import("std");
const Allocator = std.mem.Allocator;

const command = @import("command.zig");
const capability = @import("capability.zig");
const Buffers = @import("Buffers.zig");
const Editor = @import("Editor.zig");
const pick_mod = @import("pick.zig");
const task = @import("task.zig");

pub const CompletionUi = struct {
    session: ?u64 = null,
    /// Buffer identity the capability request and prefix belong to. Completion
    /// follows concurrent edits within this buffer, but never ambient focus to
    /// another buffer (or a replacement which reused its slot).
    buffer: ?Buffers.Ref = null,
    prefix_len: usize = 0,
    /// Stashed at fire time so the source's `close` (which gets no ctx)
    /// can cancel the session when the pick is dismissed.
    caps: ?*capability.Caps = null,
    /// The popup on screen (or last on screen) is INLINE
    /// (`complete.show-inline`): typing goes on into the buffer and the query
    /// is read back off it. Kept past close — `accept` runs after the pick
    /// has closed, and replaces what was typed rather than the fired prefix.
    inline_open: bool = false,
    /// Inline: where the word being completed begins. The popup lives while
    /// the caret stays in one run of word bytes from here.
    word_start: usize = 0,
    /// Inline: the mode the popup was opened in. Leaving it (vim's Escape out
    /// of insert) is leaving the typing the popup was about.
    mode_buf: [64]u8 = undefined,
    mode_len: usize = 0,

    pub const empty: CompletionUi = .{};

    /// The key layers an inline popup answers through (`pick.InlineKeys`):
    /// config binds `complete` (move, dismiss) and `complete-chosen` (accept,
    /// only once a row was chosen). Core binds neither.
    pub const inline_keys: pick_mod.InlineKeys = .{ .base = "complete", .chosen = "complete-chosen" };

    pub fn commandSpec(self: *CompletionUi) command.Command {
        return .{
            .name = "complete.show",
            .summary = "Show completions for the text at the cursor.",
            .args = &.{},
            .handler = fireHandler,
            .data = self,
            .meta = .{ .label = "Trigger Completion", .icon = "sparkles" },
        };
    }

    /// The door an auto-trigger opens: the same race, drawn at the word being
    /// typed WITHOUT taking the keyboard (`pick.InlineKeys`). When to open it
    /// — after how many characters, after what pause, on which trigger
    /// characters, never in a comment — is the caller's; the `complete`
    /// plugin is one such caller.
    pub fn inlineCommandSpec(self: *CompletionUi) command.Command {
        return .{
            .name = "complete.show-inline",
            .summary = "Show completions for the word being typed, while typing goes on into the buffer.",
            .args = &.{},
            .handler = inlineHandler,
            .data = self,
            .meta = .{ .label = "Show Completions While Typing", .internal = true },
        };
    }

    fn fireHandler(ctx: *command.Context, data: ?*anyopaque, args: []const command.Value) anyerror!command.Value {
        _ = args;
        const self: *CompletionUi = @ptrCast(@alignCast(data.?));
        try self.fire(ctx, false);
        return .nil;
    }

    fn inlineHandler(ctx: *command.Context, data: ?*anyopaque, args: []const command.Value) anyerror!command.Value {
        _ = args;
        const self: *CompletionUi = @ptrCast(@alignCast(data.?));
        // Whatever is open is the person's — a picker, the modal popup, or
        // this word's inline list already showing. An inline popup displaces
        // none of them.
        if (ctx.head.pick.active) return .nil;
        // Inline means the typing goes on into the buffer; where typing
        // commits nothing (a normal mode) there is no typing to follow.
        if (ctx.head.commitCommand(ctx.keymap) == null) return .nil;
        try self.fire(ctx, true);
        return .nil;
    }

    fn fire(self: *CompletionUi, ctx: *command.Context, inline_popup: bool) !void {
        if (self.session) |old| {
            ctx.caps.finish(old);
            self.session = null;
        }
        self.caps = ctx.caps;
        const buffer = ctx.buffer();
        const editor = buffer.textEditor() orelse return;
        const mode = ctx.head.currentMode();
        if (inline_popup and mode.len > self.mode_buf.len) return;
        const prefix = try editor.wordPrefix(ctx.gpa);
        defer ctx.gpa.free(prefix);
        const cursor = editor.cursorOffset();
        const id = try ctx.fireRace(.completion, &editor.doc, editor.backingPath(), .{
            .offset = cursor,
            .text = prefix,
        }) orelse return;
        errdefer ctx.caps.finish(id);
        const plen = prefix.len;
        // Open with the source BEFORE recording the session, so a failed
        // open (which closes the source) sees session == null and the
        // errdefer above is the sole owner that finishes it.
        try ctx.head.pick.openWith(ctx, "complete", &.{}, .{
            .handler = accept,
            .data = self,
        }, .{
            .source = self.source(),
            .category = "complete",
            .inline_keys = if (inline_popup) inline_keys else null,
        });
        // Draw the completion list as a popup AT the caret, not the bottom
        // dock — inline, at the word's start, so it holds still while the
        // word grows under it.
        ctx.head.pick.caret_anchor = if (inline_popup) cursor - plen else cursor;
        self.session = id;
        self.buffer = buffer.ref();
        self.prefix_len = plen;
        self.inline_open = inline_popup;
        self.word_start = cursor - plen;
        if (inline_popup) {
            @memcpy(self.mode_buf[0..mode.len], mode);
            self.mode_len = mode.len;
        }
        // Surface instant-tier results (they answered during fire) now.
        _ = try poll(self, ctx);
    }

    /// Inline: follow the typing. The query is the word from `word_start` to
    /// the caret, read back off the buffer. False when the popup no longer
    /// describes anything being typed: the mode was left, or the caret is out
    /// of the word (a non-word byte typed, a jump, a deletion past its start).
    fn followTyping(self: *CompletionUi, ctx: *command.Context, editor: *Editor) !bool {
        if (!std.mem.eql(u8, ctx.head.currentMode(), self.mode_buf[0..self.mode_len])) return false;
        const cursor = editor.cursorOffset();
        if (cursor < self.word_start) return false;
        const word = try editor.wordPrefix(ctx.gpa);
        defer ctx.gpa.free(word);
        if (cursor - self.word_start != word.len) return false;
        _ = try ctx.head.pick.setQuery(ctx.gpa, word);
        return true;
    }

    /// Inline: close rather than hang about. Every provider has answered and
    /// nothing matches what is typed — or the one match left IS what is
    /// typed, so there is nothing to complete it to.
    fn nothingToOffer(self: *const CompletionUi, p: *const pick_mod.Pick) bool {
        const rows = p.filtered.items;
        if (rows.len == 0) return self.session == null;
        return rows.len == 1 and std.mem.eql(u8, p.items.items[rows[0]], p.query.items);
    }

    pub fn source(self: *CompletionUi) pick_mod.Source {
        return .{ .data = self, .poll = poll, .close = close };
    }

    /// Per-frame: fold newly arrived results into the live pick; finish
    /// the session once every provider has answered (or timed out).
    fn poll(data: ?*anyopaque, ctx: *command.Context) anyerror!bool {
        const self: *CompletionUi = @ptrCast(@alignCast(data.?));
        const target = self.buffer orelse {
            try ctx.head.pick.dismiss(ctx);
            return true;
        };
        const buffer = ctx.buffers.resolve(target) orelse {
            try ctx.head.pick.dismiss(ctx);
            return true;
        };
        if (buffer != ctx.buffer()) {
            try ctx.head.pick.dismiss(ctx);
            return true;
        }
        if (self.inline_open) {
            const editor = buffer.textEditor() orelse {
                try ctx.head.pick.dismiss(ctx);
                return true;
            };
            if (!try self.followTyping(ctx, editor)) {
                try ctx.head.pick.dismiss(ctx);
                return true;
            }
        }
        const changed = try self.fold(ctx);
        if (self.inline_open and self.nothingToOffer(&ctx.head.pick)) {
            try ctx.head.pick.dismiss(ctx);
            return true;
        }
        return changed;
    }

    /// Fold the session's newly arrived results into the live pick.
    fn fold(self: *CompletionUi, ctx: *command.Context) !bool {
        const id = self.session orelse return false;
        const s = ctx.caps.session(id) orelse {
            self.session = null;
            return false;
        };
        const fresh = s.poll();
        var changed = false;
        if (fresh.len > 0) {
            const merged = try ctx.caps.mergedCompletion(ctx.gpa, id);
            defer ctx.gpa.free(merged);
            const entries = try ctx.gpa.alloc(pick_mod.Entry, merged.len);
            defer ctx.gpa.free(entries);
            const infos = try ctx.gpa.alloc([]const u8, merged.len);
            defer ctx.gpa.free(infos);
            for (merged, 0..) |it, i| {
                entries[i] = .{
                    .text = it.text,
                    // The PROVIDER's own affixation — a type or signature it
                    // chose to attach. Not a rendering of anything; core adds
                    // nothing to it (see this file's module doc).
                    .doc = it.detail,
                    // The row's public key is its `CompletionItemKind`
                    // number, so an annotator that understands that number
                    // space can name it. Core carries the digits and reads
                    // nothing into them.
                    .key = kindKey(it.kind),
                };
                infos[i] = it.documentation; // borrowed from the session; refresh dupes
            }
            try pick_mod.refresh(&ctx.head.pick, ctx.gpa, entries, infos);
            changed = true;
        }
        if (s.done(task.nowNs())) {
            ctx.caps.finish(id);
            self.session = null;
        }
        return changed;
    }

    /// The pick closed (accepted or dismissed): the race is moot, drop
    /// the session. No ctx here, so cancel through the stashed caps.
    fn close(data: ?*anyopaque, gpa: Allocator) void {
        _ = gpa;
        const self: *CompletionUi = @ptrCast(@alignCast(data.?));
        if (self.session) |id| {
            if (self.caps) |caps| caps.finish(id);
            self.session = null;
        }
    }

    /// The decimal spelling of a completion item's kind, as its row KEY.
    ///
    /// This is all that remains of what used to be `kindTag` — a switch in
    /// core that turned LSP's `CompletionItemKind` numbers into `"fn"`,
    /// `"var"`, `"kw"`. That was an annotator, it understood a protocol's
    /// number space, and it lived in core. It is now the `lsp` plugin's, which
    /// is where that number space is already understood; core carries the
    /// digits across and reads nothing into them.
    ///
    /// A static table rather than a format call: this runs per item per
    /// refresh, and a refresh happens every time a provider answers.
    /// Two digits is enough — `CompletionItemKind` is 1..25 and has been for
    /// the life of the protocol; anything outside it keys as `"0"`, which an
    /// annotator reads as "unknown" exactly like kind 0 itself.
    const kind_digits = "0123456789";
    var kind_key_bytes: [100 * 2]u8 = undefined;
    var kind_keys: [100][]const u8 = undefined;
    var kind_keys_ready = false;

    fn kindKey(kind: u8) []const u8 {
        if (!kind_keys_ready) {
            for (&kind_keys, 0..) |*s, i| {
                const tens = i / 10;
                const ones = i % 10;
                kind_key_bytes[i * 2] = kind_digits[tens];
                kind_key_bytes[i * 2 + 1] = kind_digits[ones];
                s.* = if (tens == 0)
                    kind_key_bytes[i * 2 + 1 .. i * 2 + 2]
                else
                    kind_key_bytes[i * 2 .. i * 2 + 2];
            }
            kind_keys_ready = true;
        }
        return kind_keys[if (kind < kind_keys.len) kind else 0];
    }

    fn accept(ctx: *command.Context, data: ?*anyopaque, outcome: pick_mod.Outcome) anyerror!void {
        const choice = switch (outcome) {
            .cancelled => return,
            .candidate => |candidate| candidate.text,
            .input => |input| input,
        };
        const self: *CompletionUi = @ptrCast(@alignCast(data.?));
        const target = self.buffer orelse return;
        const buffer = ctx.buffers.resolve(target) orelse return;
        if (buffer != ctx.buffer()) return;
        const editor = buffer.textEditor() orelse return;
        const cur = editor.cursorOffset();
        // Inline, what was typed since the fire is in the buffer too: the
        // whole word before the caret is what the choice replaces.
        const typed = if (self.inline_open) blk: {
            const word = try editor.wordPrefix(ctx.gpa);
            defer ctx.gpa.free(word);
            break :blk word.len;
        } else self.prefix_len;
        const start = cur -| typed;
        // The one edit door: authored by the invoking principal and grade
        // -gated (a view peer's accept is refused, leaving no ghost). Which
        // undo step the accept belongs to is the grammar's declaration, cut
        // by dispatch (`step.zig`): its own step where typing runs are
        // steps, part of the insert session where that is one.
        ctx.edit(.{ .start = start, .end = cur }, choice) catch |e| {
            if (e == error.Unauthorized) return;
            return e;
        };
    }
};

test {
    std.testing.refAllDecls(@This());
}
