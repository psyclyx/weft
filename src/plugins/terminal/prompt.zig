//! prompt — what a shell's integration says about its turns, read off the
//! byte stream before the emulator sees it (doc/terminal.md §7–8):
//!
//!   OSC 133 ; A            a prompt starts
//!   OSC 133 ; B            the command line starts (the cursor is there)
//!   OSC 133 ; C            the line was accepted: a command runs
//!   OSC 133 ; D [; N]      it finished
//!   OSC 7780 ; hello ; 1   the integration syncs its command line (v1)
//!   OSC 7780 ; line ; SEQ ; CURSOR ; HEX
//!                          the shell's line buffer (hex of its bytes), its
//!                          cursor in bytes, and the last line-set it applied
//!
//! and what weft says back, as keys the integration binds in every keymap:
//!
//!   ESC [ 7780 ~ SEQ ; CURSOR ; HEX BEL   set the line buffer and cursor
//!   ESC [ 7781 ~                          report the line now
//!
//! The emulator sees every byte too (it ignores the private OSC); this only
//! watches. Nothing here routes a key: the state it keeps is what the
//! terminal DECLARES to core (`State.ownsKeys`), and core routes by that.

const std = @import("std");
const weft = @import("weft");

/// The command line is sent and read as hex: any byte, no escaping.
pub fn hexEncode(out: *std.ArrayList(u8), gpa: std.mem.Allocator, bytes: []const u8) !void {
    const digits = "0123456789abcdef";
    try out.ensureUnusedCapacity(gpa, bytes.len * 2);
    for (bytes) |b| {
        out.appendAssumeCapacity(digits[b >> 4]);
        out.appendAssumeCapacity(digits[b & 15]);
    }
}

pub fn hexDecode(out: *std.ArrayList(u8), gpa: std.mem.Allocator, hex: []const u8) !void {
    out.clearRetainingCapacity();
    if (hex.len % 2 != 0) return error.Malformed;
    try out.ensureUnusedCapacity(gpa, hex.len / 2);
    var i: usize = 0;
    while (i < hex.len) : (i += 2) out.appendAssumeCapacity(std.fmt.parseInt(u8, hex[i..][0..2], 16) catch return error.Malformed);
}

/// One sequence the scanner finished.
pub const Event = union(enum) {
    prompt_start,
    line_start,
    command_start,
    command_end,
    hello,
    /// The shell's line: `payload` is `SEQ;CURSOR;HEX`, borrowed until the
    /// next byte.
    line: []const u8,
};

/// Finds OSC 133 and OSC 7780 in output as it streams, across reads.
pub const Scanner = struct {
    state: enum { text, esc, osc, osc_esc } = .text,
    /// The OSC being collected (only ours: others are skipped, not kept).
    buf: std.ArrayList(u8) = .empty,
    keep: bool = false,
    /// Longest OSC of ours kept: a command line fits many times over.
    const cap = 1 << 20;

    pub fn deinit(self: *Scanner) void {
        self.buf.deinit(weft.allocator);
    }

    /// Feed one byte; an event when it ended a sequence of ours.
    pub fn step(self: *Scanner, b: u8) ?Event {
        switch (self.state) {
            .text => if (b == 0x1b) {
                self.state = .esc;
            },
            .esc => {
                if (b == ']') {
                    self.state = .osc;
                    self.buf.clearRetainingCapacity();
                    self.keep = true;
                } else self.state = if (b == 0x1b) .esc else .text;
            },
            .osc => switch (b) {
                0x07 => return self.finish(),
                0x1b => self.state = .osc_esc,
                else => self.collect(b),
            },
            .osc_esc => {
                if (b == '\\') return self.finish();
                // Not a string terminator: an ESC inside is the end of it
                // for any terminal; start over from this ESC.
                self.state = .esc;
                return self.step(b);
            },
        }
        return null;
    }

    fn collect(self: *Scanner, b: u8) void {
        if (!self.keep) return;
        // Only 133 and 7780 are ours; decide as soon as the number is read.
        if (self.buf.items.len == 5 and !std.mem.startsWith(u8, self.buf.items, "133;") and !std.mem.startsWith(u8, self.buf.items, "7780;")) {
            self.keep = false;
            return;
        }
        if (self.buf.items.len >= cap) {
            self.keep = false;
            return;
        }
        self.buf.append(weft.allocator, b) catch {
            self.keep = false;
        };
    }

    fn finish(self: *Scanner) ?Event {
        self.state = .text;
        if (!self.keep) return null;
        const s = self.buf.items;
        if (std.mem.startsWith(u8, s, "133;") and s.len >= 5) return switch (s[4]) {
            'A' => .prompt_start,
            'B' => .line_start,
            'C' => .command_start,
            'D' => .command_end,
            else => null,
        };
        if (std.mem.startsWith(u8, s, "7780;hello;")) return .hello;
        if (std.mem.startsWith(u8, s, "7780;line;")) return .{ .line = s["7780;line;".len..] };
        return null;
    }
};

/// A parsed line report.
pub const Report = struct { seq: u64, cursor: usize, hex: []const u8 };

pub fn parseReport(payload: []const u8) ?Report {
    var it = std.mem.splitScalar(u8, payload, ';');
    const seq = std.fmt.parseInt(u64, it.next() orelse return null, 10) catch return null;
    const cursor = std.fmt.parseInt(usize, it.next() orelse return null, 10) catch return null;
    const hex = it.next() orelse "";
    if (it.next() != null) return null;
    return .{ .seq = seq, .cursor = cursor, .hex = hex };
}
