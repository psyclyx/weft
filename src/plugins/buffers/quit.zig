//! Quitting with unsaved work ASKS. `buffers.quit` provides the `app.quit`
//! action (C-q, `:q`, File ▸ Quit, the window's close button, ⌘Q), over core's
//! floor provider, which only refuses: it names what a quit would lose and
//! offers to save all of it first, to discard it, or to keep editing.
//!
//! What is unsaved is core's census (`app.unsaved`), never a list kept here.
//! "Save all and quit" is two doors: `file.save-all`, then `file.when-saved
//! app.quit`, which holds the quit until those saves have landed and drops it,
//! naming the file, if one fails. The quit it runs then comes back HERE: with
//! nothing left it quits, and anything save-all cannot write (a scratch, a
//! listing's draft) is asked about again, by name — never dropped quietly.

const std = @import("std");
const weft = @import("weft");

/// The question asked last. A quit while it is still open asks again, and the
/// new question REPLACES it (the picker cancels the one it displaces), so two
/// close clicks never stack two questions; the displaced one's answer is
/// stale and ignored.
var asked: u32 = 0;

const save_all = "Save all and quit";
const discard = "Quit without saving";
const cancel = "Cancel";

var prompt_buf: [512]u8 = undefined;
var save_doc_buf: [128]u8 = undefined;

/// The `app.quit` provider: quit when nothing is unsaved, else ask.
pub fn quit() void {
    const listing = weft.callString("app.unsaved") orelse return weft.run("app.quit-unless-unsaved");
    var files: usize = 0;
    var total: usize = 0;
    var w: std.Io.Writer = .fixed(&prompt_buf);
    w.writeAll("Quit with unsaved changes (") catch {};
    var lines = std.mem.tokenizeScalar(u8, listing, '\n');
    while (lines.next()) |line| {
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        if (std.mem.eql(u8, line[0..tab], "file")) files += 1;
        total += 1;
        if (total <= 4) w.print("{s}{s}", .{ if (total == 1) "" else ", ", line[tab + 1 ..] }) catch {};
    }
    // Nothing would be lost: core's own quit, which agrees.
    if (total == 0) return weft.run("app.quit-unless-unsaved");
    if (total > 4) w.print(" and {d} more", .{total - 4}) catch {};
    w.writeAll(")?") catch {};

    const save_doc = if (files == total)
        std.fmt.bufPrint(&save_doc_buf, "save {d} file{s}, then quit", .{ files, if (files == 1) "" else "s" }) catch "save, then quit"
    else
        std.fmt.bufPrint(&save_doc_buf, "save {d} file{s}, then ask about the rest", .{ files, if (files == 1) "" else "s" }) catch "save, then ask about the rest";
    const discard_row: weft.AskCandidate = .{ .text = discard, .doc = "discard every unsaved change" };
    const cancel_row: weft.AskCandidate = .{ .text = cancel, .doc = "keep editing" };
    // Saving leads where there is a file to save — Return saves, as a
    // desktop's quit dialog does. With none, keeping on editing leads: the
    // only other answer loses work.
    const with_save = [_]weft.AskCandidate{ .{ .text = save_all, .doc = save_doc }, discard_row, cancel_row };
    const without_save = [_]weft.AskCandidate{ cancel_row, discard_row };
    asked +%= 1;
    const spec: weft.AskSpec = .{
        .prompt = w.buffered(),
        .candidates = if (files > 0) &with_save else &without_save,
    };
    if (!weft.askWith(u32, asked, spec, answered)) weft.run("app.quit-unless-unsaved");
}

fn answered(answer: weft.Answer, which: u32) void {
    if (which != asked) return; // displaced by a newer question
    const text = answer.text();
    if (std.mem.eql(u8, text, save_all)) {
        weft.run("file.save-all");
        weft.runStr("file.when-saved", "app.quit");
    } else if (std.mem.eql(u8, text, discard)) {
        weft.run("app.quit-force");
    } else {
        weft.echo("quit cancelled");
    }
}
