//! Theme — the view's color palette (data + small lookups).
//!
//! sRGB-authored, converted to linear at init (snail's color ABI is linear,
//! straight alpha). Pure data plus the semantic-role → color lookups the
//! render path consults; a colorscheme change is a mutation here, never a
//! per-span branch. Split out of `view.zig` and re-exported by it.

const std = @import("std");

const snail = @import("snail");
const core = @import("../../core/core.zig");

const HighlightClass = core.capability.HighlightClass;
const StyleClass = core.capability.StyleClass;

/// sRGB-authored theme, converted to linear at init (snail's color ABI
/// is linear, straight alpha).
pub const Theme = struct {
    background: [4]f32 = .{ 0.086, 0.09, 0.102, 1 },
    foreground: [4]f32 = .{ 0.85, 0.86, 0.87, 1 },
    cursor: [4]f32 = .{ 0.95, 0.75, 0.30, 1 },
    cursor_text: [4]f32 = .{ 0.086, 0.09, 0.102, 1 },
    selection: [4]f32 = .{ 0.25, 0.34, 0.47, 1 },
    status: [4]f32 = .{ 0.55, 0.58, 0.62, 1 },
    accent: [4]f32 = .{ 0.55, 0.78, 0.55, 1 },
    // Syntax classes.
    syn_keyword: [4]f32 = .{ 0.78, 0.56, 0.88, 1 },
    syn_string: [4]f32 = .{ 0.62, 0.79, 0.55, 1 },
    syn_comment: [4]f32 = .{ 0.45, 0.49, 0.54, 1 },
    syn_number: [4]f32 = .{ 0.85, 0.65, 0.45, 1 },
    syn_type: [4]f32 = .{ 0.45, 0.78, 0.78, 1 },
    syn_function: [4]f32 = .{ 0.53, 0.70, 0.92, 1 },
    syn_constant: [4]f32 = .{ 0.85, 0.65, 0.45, 1 },
    syn_operator: [4]f32 = .{ 0.70, 0.72, 0.75, 1 },
    syn_attribute: [4]f32 = .{ 0.86, 0.80, 0.55, 1 },
    diag_error: [4]f32 = .{ 0.92, 0.45, 0.45, 1 },
    diag_warn: [4]f32 = .{ 0.88, 0.72, 0.42, 1 },
    // Markdown styling.
    heading: [4]f32 = .{ 0.93, 0.87, 0.72, 1 },
    md_marker: [4]f32 = .{ 0.42, 0.46, 0.52, 1 },
    md_code: [4]f32 = .{ 0.62, 0.79, 0.55, 1 },
    md_link: [4]f32 = .{ 0.53, 0.70, 0.92, 1 },

    pub fn linearized(self: Theme) Theme {
        var out: Theme = undefined;
        inline for (@typeInfo(Theme).@"struct".fields) |f| {
            @field(out, f.name) = snail.color.srgbToLinearColor(@field(self, f.name));
        }
        return out;
    }

    /// Set the named color from an sRGB hex string ("#rrggbb" or "rrggbb"),
    /// re-linearizing just that field — the mutation owns the sRGB→linear cost,
    /// so the per-span draw path stays a plain lookup. Config's `weft.color` and
    /// the `set-color` command both route here; theme is DATA, not a constant.
    /// Returns false on an unknown name or malformed hex (caller may warn).
    pub fn setColor(self: *Theme, name: []const u8, hex: []const u8) bool {
        const srgb = parseHexColor(hex) orelse return false;
        inline for (@typeInfo(Theme).@"struct".fields) |f| {
            if (std.mem.eql(u8, f.name, name)) {
                @field(self, f.name) = snail.color.srgbToLinearColor(srgb);
                return true;
            }
        }
        return false;
    }

    fn parseHexColor(hex: []const u8) ?[4]f32 {
        const h = if (hex.len > 0 and hex[0] == '#') hex[1..] else hex;
        if (h.len != 6) return null;
        const r = std.fmt.parseInt(u8, h[0..2], 16) catch return null;
        const g = std.fmt.parseInt(u8, h[2..4], 16) catch return null;
        const b = std.fmt.parseInt(u8, h[4..6], 16) catch return null;
        const s = 1.0 / 255.0;
        return .{ @as(f32, @floatFromInt(r)) * s, @as(f32, @floatFromInt(g)) * s, @as(f32, @floatFromInt(b)) * s, 1 };
    }

    /// Map a surface span's semantic role to a color, so a colorscheme restyles
    /// every overlay. Groups (submenu entries) and effects read distinctly from
    /// plain leaf commands — the which-key color-coding ask.
    pub fn roleColor(self: *const Theme, role: core.surface.Role) [4]f32 {
        return switch (role) {
            .accent => self.accent,
            .group => self.heading, // a submenu — distinct from a leaf command
            .effect => self.md_link,
            .muted => self.status,
            else => self.foreground, // .normal, .leaf, unknown
        };
    }

    /// Background color for the status-line mode chip, keyed by mode family so
    /// the editor's current state reads at a glance (green normal, blue insert,
    /// purple visual/select, amber operator/menu).
    pub fn modeChipColor(self: *const Theme, mode: []const u8) [4]f32 {
        if (std.mem.startsWith(u8, mode, "insert")) return self.syn_function;
        if (std.mem.startsWith(u8, mode, "visual") or std.mem.startsWith(u8, mode, "select")) return self.syn_keyword;
        if (std.mem.startsWith(u8, mode, "normal")) return self.accent;
        if (std.mem.startsWith(u8, mode, "op") or std.mem.startsWith(u8, mode, "leader") or
            std.mem.startsWith(u8, mode, "menu") or std.mem.startsWith(u8, mode, "pick"))
            return self.diag_warn;
        return self.status;
    }

    pub fn classColor(self: *const Theme, class: HighlightClass) [4]f32 {
        return switch (class) {
            .none, .variable => self.foreground,
            .keyword => self.syn_keyword,
            .string => self.syn_string,
            .comment => self.syn_comment,
            .number => self.syn_number,
            .type => self.syn_type,
            .function => self.syn_function,
            .constant => self.syn_constant,
            .operator, .punctuation => self.syn_operator,
            .attribute, .label => self.syn_attribute,
        };
    }

    /// Map a tool-buffer style class to a color, reusing the existing theme
    /// palette so a colorscheme restyles tool output for free (no new fields):
    /// added→string-green, removed→error-red, header→type, location→function-
    /// blue (file:line), emphasis→attribute-yellow (a grep match), muted→status.
    /// `.normal` is plain foreground, so an unstyled byte reads as today.
    pub fn styleColor(self: *const Theme, class: StyleClass) [4]f32 {
        return switch (class) {
            .normal => self.foreground,
            .added => self.syn_string,
            .removed => self.diag_error,
            .header => self.syn_type,
            .location => self.syn_function,
            .emphasis => self.syn_attribute,
            .muted => self.status,
        };
    }
};

const testing = std.testing;

test "theme: setColor updates a named field from hex; rejects bad input" {
    var th: Theme = .{};
    // sRGB #ff0000 → stored linearized: red ~1.0, green/blue 0.
    try testing.expect(th.setColor("accent", "#ff0000"));
    try testing.expectApproxEqAbs(@as(f32, 1.0), th.accent[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), th.accent[1], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), th.accent[3], 0.001); // alpha
    // Works without the leading '#', too.
    try testing.expect(th.setColor("background", "000000"));
    try testing.expectApproxEqAbs(@as(f32, 0.0), th.background[0], 0.001);
    // Unknown field and malformed hex are rejected (and leave the field alone).
    try testing.expect(!th.setColor("nope", "#ffffff"));
    try testing.expect(!th.setColor("accent", "zzzzzz"));
    try testing.expect(!th.setColor("accent", "#12"));
    try testing.expectApproxEqAbs(@as(f32, 1.0), th.accent[0], 0.001);
}
