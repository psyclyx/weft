//! Per-mode caret style + blink, set from config via `set-cursor` and
//! `cursor-blink` and read into the Hud each frame. Blink is per mode so
//! the sample config can blink in insert and stay solid in normal. Also
//! the runtime `set-color` theme command and the markdown-path test.

const std = @import("std");
const core = @import("weft_core");
const view_mod = @import("../gfx/view.zig");

pub const CursorConfig = struct {
    const Entry = struct { mode: []u8, style: view_mod.CursorStyle = .block, blink: bool = false };
    gpa: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,

    pub fn deinit(self: *CursorConfig) void {
        for (self.entries.items) |e| self.gpa.free(e.mode);
        self.entries.deinit(self.gpa);
    }
    fn hasEntry(self: *const CursorConfig, mode: []const u8) bool {
        for (self.entries.items) |e| if (std.mem.eql(u8, e.mode, mode)) return true;
        return false;
    }
    /// The mode whose caret should render for `mode`. A menu mode with no caret
    /// of its own inherits its return target's — so `leader` keeps normal's bar
    /// instead of flipping to a block. (Uses `head`'s menu-return relation, NOT
    /// the key-lookup `parents` chain, so no bindings leak into the menu; the
    /// return target is per-head state — see `Head.menu_return`.)
    pub fn resolveMode(self: *const CursorConfig, keymap: *const core.Keymap, head: *const core.Head, mode: []const u8) []const u8 {
        if (self.hasEntry(mode)) return mode;
        if (keymap.isMenuMode(mode)) if (head.menuReturn(mode)) |ret| return ret;
        return mode;
    }
    pub fn styleFor(self: *const CursorConfig, mode: []const u8) view_mod.CursorStyle {
        for (self.entries.items) |e| if (std.mem.eql(u8, e.mode, mode)) return e.style;
        return .block;
    }
    pub fn blinkFor(self: *const CursorConfig, mode: []const u8) bool {
        for (self.entries.items) |e| if (std.mem.eql(u8, e.mode, mode)) return e.blink;
        return false;
    }
    fn entry(self: *CursorConfig, mode: []const u8) !*Entry {
        for (self.entries.items) |*e| if (std.mem.eql(u8, e.mode, mode)) return e;
        try self.entries.append(self.gpa, .{ .mode = try self.gpa.dupe(u8, mode) });
        return &self.entries.items[self.entries.items.len - 1];
    }
};

fn parseCursorStyle(s: []const u8) ?view_mod.CursorStyle {
    if (std.mem.eql(u8, s, "block")) return .block;
    if (std.mem.eql(u8, s, "bar")) return .bar;
    if (std.mem.eql(u8, s, "underline")) return .underline;
    return null;
}

pub fn setColorHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    _ = ctx;
    const v: *view_mod.View = @ptrCast(@alignCast(data.?));
    if (!v.theme.setColor(args[0].string, args[1].string)) return error.InvalidArgument;
    return .nil;
}

pub fn setCursorHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    _ = ctx;
    const cfg: *CursorConfig = @ptrCast(@alignCast(data.?));
    const style = parseCursorStyle(args[1].string) orelse return error.InvalidArgument;
    (try cfg.entry(args[0].string)).style = style;
    return .nil;
}

pub fn cursorBlinkHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    _ = ctx;
    const cfg: *CursorConfig = @ptrCast(@alignCast(data.?));
    (try cfg.entry(args[0].string)).blink = std.mem.eql(u8, args[1].string, "on");
    return .nil;
}

pub fn isMarkdownPath(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".md") or std.mem.endsWith(u8, path, ".markdown");
}
