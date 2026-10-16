//! complete — buffer-word (dabbrev) completion: scan the active buffer for
//! words sharing the query prefix and offer them. It is the host→guest
//! data-gather membrane's worked example:
//! `describe` declares the capability, `init` registers the provider, and the
//! host calls `on_complete(session)` per request, during which the guest reads
//! the prefix and offers candidates for that session, then commits them (a sync
//! source — it answers before returning).
//!
//! It is also where completion pops up BY ITSELF while you type — the policy
//! half of auto-completion, over three doors that know nothing of it: core's
//! `input.typed` signal (a person's keystroke typed text into a document),
//! `signalEmitAfter` (a timer that comes back as a signal), and the
//! `complete.show-inline` command (the popup that leaves the keyboard to the
//! grammar). The rules, all here and all config (`weft.set("complete", …)`):
//!
//!   - `auto`         "on" | "off" — whether it pops up at all (default on);
//!   - `auto-prefix`  how many word characters before it does (default 2);
//!   - `auto-delay`   how long typing must pause first, in ms (default 120) —
//!                    each keystroke moves the timer, so fast typing asks
//!                    nothing until it stops;
//!   - a language server's trigger characters (`.` in Go and Zig) pop it up at
//!     once, whatever came before. They are the `lsp` plugin's to know: it
//!     publishes them as the context key `lsp.trigger-characters`, and this
//!     reads that, never a table of its own;
//!   - `auto-quiet-in` the syntax nodes it stays quiet inside: a node whose
//!                    kind contains one of these (default `comment`,
//!                    `string`) — tree-sitter knows, so nothing is guessed.
//!
//! When the timer fires it asks again from what is in the buffer now, so a
//! popup is only ever for the word under the caret — a stale ask (the caret
//! moved, the text changed, the mode was left) opens nothing.

const std = @import("std");
const weft = @import("weft");

const seps = " \t\n\r(){}[].,;:\"'`<>=+-*/\\|&!?@#$%^~";

/// This plugin's own timer, raised back to it when typing pauses.
const auto_signal = "complete.auto";
/// Where a language server's trigger characters are published (`lsp`).
const trigger_key = "lsp.trigger-characters";

const popup = @import("popup.zig");

var typed_id: ?u32 = null;
var auto_id: ?u32 = null;
var caret_id: ?u32 = null;
var mode_id: ?u32 = null;

/// The popup's verbs. What opens it by itself is the auto-trigger below;
/// these are what keys and the palette reach.
const cmds = [_]weft.CommandEntry{
    .{ .name = "complete.show", .call = popup.showChosen, .arity = .whole, .summary = "Show completions for the word at the cursor.", .label = "Trigger Completion", .icon = "sparkles" },
    .{ .name = "complete.show-inline", .call = showInline, .arity = .whole, .summary = "Show completions for the word being typed, unless they show already.", .internal = true },
    .{ .name = "complete.next", .call = next, .arity = .whole, .summary = "Choose the next completion.", .internal = true },
    .{ .name = "complete.prev", .call = prev, .arity = .whole, .summary = "Choose the previous completion.", .internal = true },
    .{ .name = "complete.accept", .call = popup.accept, .arity = .whole, .summary = "Put the chosen completion in place of the word.", .internal = true },
    .{ .name = "complete.dismiss", .call = popup.close, .arity = .whole, .summary = "Close the completion list.", .internal = true },
    // Internal: what a heard signal or a loop's poll does, run as a dispatch
    // (the popup's doors are a dispatching head's).
    .{ .name = "complete.follow", .call = popup.follow, .arity = .whole, .summary = "Narrow the completion list to the word being typed.", .internal = true },
    .{ .name = "complete.tick", .call = popup.tick, .arity = .whole, .summary = "Fold slower completion answers into the list.", .internal = true },
};

fn showInline() void {
    if (popup.isOpen()) return popup.follow();
    popup.show();
}
fn next() void {
    popup.move(1);
}
fn prev() void {
    popup.move(-1);
}

/// What the armed timer is FOR: the caret and the document length when it
/// was armed. Any edit or motion since makes it stale.
var armed_cursor: usize = 0;
var armed_len: usize = 0;

fn describe() void {
    weft.declareCapability("edit/completion");
    weft.requestPerm(.timer);
}

fn init() void {
    weft.provideCompletion();
    typed_id = weft.signalSubscribe(weft.typed_signal);
    auto_id = weft.signalSubscribe(auto_signal);
    caret_id = weft.signalSubscribe(weft.caret_signal);
    mode_id = weft.signalSubscribe(weft.mode_signal);
}

/// Each loop: a race still running may have answers to fold in.
fn on_poll() void {
    if (popup.racing()) weft.run("complete.tick");
}

fn on_complete(session: u32) callconv(.c) void {
    const prefix = weft.completionPrefix();
    if (prefix.len == 0) {
        weft.capsDecline(session);
        return;
    }
    const text = weft.slice(0, weft.byteLen());
    var it = std.mem.tokenizeAny(u8, text, seps);
    var rank: i32 = 0;
    while (it.next()) |word| {
        if (word.len <= prefix.len or !std.mem.startsWith(u8, word, prefix)) continue;
        // kind 1 = Text (LSP CompletionItemKind); the merge dedups by text.
        weft.capsItem(session, .{ .text = word, .kind = 1, .rank = rank });
        rank += 1;
    }
    weft.capsCommit(session);
}

fn on_signal(id: i32) callconv(.c) void {
    if (id < 0) return;
    const sig: u32 = @intCast(id);
    if (mode_id == sig) {
        // The typing a pending ask or an open list was about is over.
        weft.signalCancel(auto_signal);
        if (popup.isOpen()) weft.run("complete.dismiss");
        return;
    }
    if (caret_id == sig) {
        if (popup.isOpen()) weft.run("complete.follow");
        return;
    }
    if (typed_id == sig) {
        // An open list follows the typing; a closed one may be due.
        if (popup.isOpen()) return weft.run("complete.follow");
        return typed();
    }
    if (auto_id == sig) return due();
}

const wordByte = popup.wordByte;

/// A person typed: arm the timer, move it, or drop it.
fn typed() void {
    if (!std.mem.eql(u8, orDefault("auto", "on"), "on")) return;
    const cur = weft.cursor();
    // Copied: every later door reuses the shim's scratch.
    var buf: [64]u8 = undefined;
    const got = weft.slice(cur -| buf.len, cur);
    const before = buf[0..got.len];
    @memcpy(before, got);
    if (before.len == 0) return weft.signalCancel(auto_signal);
    const last = before[before.len - 1];
    if (!wordByte(last)) {
        // Past a trigger character the server has something to say at once;
        // past any other non-word byte there is no word to complete.
        if (isTrigger(last)) return arm(cur, 0);
        return weft.signalCancel(auto_signal);
    }
    var word: usize = 0;
    while (word < before.len and wordByte(before[before.len - 1 - word])) word += 1;
    if (word < orDefaultNum("auto-prefix", 2)) return weft.signalCancel(auto_signal);
    arm(cur, orDefaultNum("auto-delay", 120));
}

fn arm(cur: usize, ms: u32) void {
    armed_cursor = cur;
    armed_len = weft.byteLen();
    weft.signalEmitAfter(auto_signal, ms);
}

/// The pause is over: if nothing moved since, pop up — unless the caret is
/// somewhere completion has nothing to say.
fn due() void {
    const cur = weft.cursor();
    if (cur != armed_cursor or weft.byteLen() != armed_len) return;
    if (quietHere(cur)) return;
    weft.run("complete.show-inline");
}

fn isTrigger(b: u8) bool {
    const triggers = weft.contextGet(trigger_key) orelse return false;
    return std.mem.indexOfScalar(u8, triggers, b) != null;
}

/// Inside a syntax node completion stays out of (`auto-quiet-in`).
fn quietHere(cur: usize) bool {
    if (cur == 0) return false;
    const node = weft.nodeAt(cur - 1) orelse return false;
    var kind_buf: [64]u8 = undefined;
    const n = @min(node.kind.len, kind_buf.len);
    @memcpy(kind_buf[0..n], node.kind[0..n]);
    const kind = kind_buf[0..n];
    if (weft.configList("auto-quiet-in")) |list| {
        var it = list;
        while (it.next()) |quiet| if (quiet.len > 0 and std.mem.indexOf(u8, kind, quiet) != null) return true;
        return false;
    }
    for ([_][]const u8{ "comment", "string" }) |quiet| if (std.mem.indexOf(u8, kind, quiet) != null) return true;
    return false;
}

fn orDefault(key: []const u8, default: []const u8) []const u8 {
    const v = weft.config(key);
    return if (v.len == 0) default else v;
}

fn orDefaultNum(key: []const u8, default: u32) u32 {
    const v = weft.config(key);
    if (v.len == 0) return default;
    return std.fmt.parseInt(u32, v, 10) catch default;
}

comptime {
    weft.plugin(&cmds, .{ .describe = describe, .init = init, .poll = on_poll }).exportAll();
}

comptime {
    weft.exportCallback("on_complete", &on_complete);
    weft.exportCallback("on_signal", &on_signal);
}
