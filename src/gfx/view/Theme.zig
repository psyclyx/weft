//! Theme — the view's color palette (data + small lookups).
//!
//! sRGB-authored, converted to linear at init (the scene color ABI is linear,
//! straight alpha). Pure data plus the semantic-role → color lookups the
//! render path consults; a colorscheme change is a mutation here, never a
//! per-span branch. Split out of `view.zig` and re-exported by it.

const std = @import("std");

const scene = @import("weft_scene");
const core = @import("weft_core");

const HighlightClass = core.capability.HighlightClass;
const StyleClass = core.capability.StyleClass;

const Theme = @This();

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
        @field(out, f.name) = scene.srgbToLinearColor(@field(self, f.name));
    }
    return out;
}

// `Theme`'s fields ARE the palette vocabulary, so the two must not drift:
// adding a colour here without making it addressable from a config stops
// compiling rather than shipping an unthemeable colour.
comptime {
    const fields = @typeInfo(Theme).@"struct".fields;
    if (fields.len != core.palette.names.len)
        @compileError("Theme fields and core.palette.names differ in length");
    for (fields, core.palette.names) |f, n| {
        if (!std.mem.eql(u8, f.name, n))
            @compileError("Theme field '" ++ f.name ++ "' does not match palette name '" ++ n ++ "'");
    }
}

/// Re-read every `palette/<name>` binding over the shipped defaults.
///
/// This is a RESOLVE, not a one-shot apply: it starts from `self` and only
/// overwrites what something has actually bound, so calling it again after a
/// rebind is how a colourscheme changes live. The walk lives here, next to the
/// fields it walks — `main.zig` used to do it, and had no reason to know the
/// palette's shape in order to start an editor.
///
/// Resolution happens HERE and not per-span for the reason the module doc
/// gives: the mutation owns the sRGB→linear cost so the draw path stays a
/// plain field read.
pub fn resolve(self: *Theme, container: *const core.container.Container, facts: core.facts.Facts) void {
    inline for (@typeInfo(Theme).@"struct".fields) |f| {
        if (core.palette.colorFor(container, facts, f.name)) |srgb| {
            @field(self, f.name) = scene.srgbToLinearColor(srgb);
        }
    }
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
        .annotation => self.syn_comment, // a dimmed side note (completion kind/detail)
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

const testing = std.testing;

test "theme: a bound palette slot overrides a shipped default; the rest stand" {
    var c = core.container.Container.init(testing.allocator);
    defer c.deinit();
    try core.palette.declare(&c);

    var th: Theme = (Theme{}).linearized();
    const shipped_bg = th.background;

    try c.bind(.{
        .slot = core.palette.slotFor("accent").?,
        .provider = .{ .value = "#ff0000" },
        .predicate = .{ .all = &.{} },
        .tier = .config,
        .owner = "test",
    });
    th.resolve(&c, .{});

    // The bound one moved...
    try testing.expectApproxEqAbs(@as(f32, 1.0), th.accent[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), th.accent[1], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), th.accent[3], 0.001);
    // ...and nothing else did: an unbound slot means "whatever weft ships".
    try testing.expectEqual(shipped_bg, th.background);
}

test "theme: a malformed colour leaves the default standing" {
    var c = core.container.Container.init(testing.allocator);
    defer c.deinit();
    try core.palette.declare(&c);

    var th: Theme = (Theme{}).linearized();
    const shipped = th.accent;
    try c.bind(.{
        .slot = core.palette.slotFor("accent").?,
        .provider = .{ .value = "zzzzzz" },
        .predicate = .{ .all = &.{} },
        .tier = .config,
        .owner = "test",
    });
    th.resolve(&c, .{});
    // Not black, not garbage — unchanged. A typo must not blank the editor.
    try testing.expectEqual(shipped, th.accent);
}
