//! Icons — named vector icons for core chrome, as scene path commands.
//!
//! An icon is SVG geometry parsed once into `scene.PathCommand`s (move, line,
//! cubic, close) in its own 24-unit box, and drawn as an ordinary stroked
//! `path` item, tinted by the theme (doc/chrome.md §3.3, doc/presentation.md
//! D2). There is no icon draw item and no plugin door: a chrome style asks
//! for an icon by NAME and places it; a renderer only ever sees a path.
//!
//! A `Set` maps chrome names (`save`, `split-right`, `error`) to geometry.
//! Two sets are bundled (`Bundled`): Lucide (ISC; `icons/lucide/LICENSE`),
//! embedded as the upstream SVG files unchanged, and weft's own
//! (`icons/weft/`, drawn to doc/icons.md), which has every chrome name
//! Lucide's table has plus the completion kinds (`kind_names`). A theme picks
//! a set by name (`theme/icons`); `none` draws no icons, and another set is
//! one more `Source` table — the parser takes any stroke-style SVG in a
//! 24-unit viewBox, which is the format every Lucide/Feather-shaped set
//! ships in.
//!
//! The parser covers what such sets use: `path` (every command, arcs
//! converted to cubics, quadratics raised to cubics), `circle`, `ellipse`,
//! `rect` (with `rx`/`ry`), `line`, `polyline` and `polygon`. Fill, colour,
//! stroke width and transforms are ignored — the set's own convention
//! (2-unit round strokes) is the icon's, and the tint is the theme's.

const std = @import("std");
const Allocator = std.mem.Allocator;
const scene = @import("weft_scene");

const PathCommand = scene.PathCommand;

/// One parsed icon: its path, in a `size`-unit box, stroked as its SVG
/// root says (`stroke-width`, `stroke-linecap`, `stroke-linejoin`; Lucide's
/// 2-unit round strokes when it says nothing), and its ACCENT — the
/// elements marked `class="accent"`, drawn in the theme's accent colour
/// (weft's set: the brand mark's caret).
pub const Icon = struct {
    commands: []const PathCommand,
    accent: []const PathCommand = &.{},
    /// The side of the source viewBox the commands are drawn in.
    size: f32 = 24,
    /// The set's stroke width, in the same units.
    stroke_width: f32 = 2,
    cap: scene.StrokeCap = .round,
    join: scene.StrokeJoin = .round,
};

/// One named icon's source: a chrome name and the SVG text drawing it.
pub const Source = struct { name: []const u8, svg: []const u8 };

/// A named set of parsed icons. Owns its geometry.
pub const Set = struct {
    name: []const u8,
    arena: std.heap.ArenaAllocator,
    names: []const []const u8 = &.{},
    icons: []const Icon = &.{},

    /// Parse every source. An SVG that does not parse fails the whole set:
    /// a bundled set is data this build ships, so a bad file is a build bug
    /// to hear about, not an icon to drop quietly.
    pub fn parse(gpa: Allocator, name: []const u8, sources: []const Source) !Set {
        var set: Set = .{ .name = name, .arena = .init(gpa) };
        errdefer set.arena.deinit();
        const arena = set.arena.allocator();
        const names = try arena.alloc([]const u8, sources.len);
        const parsed = try arena.alloc(Icon, sources.len);
        for (sources, names, parsed) |src, *n, *icon| {
            n.* = src.name;
            icon.* = try parseIcon(arena, src.svg);
        }
        set.names = names;
        set.icons = parsed;
        return set;
    }

    pub fn deinit(self: *Set) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// The icon called `name`, or null when this set has none by that name
    /// (a chrome style then draws the label alone).
    pub fn get(self: *const Set, name: []const u8) ?*const Icon {
        for (self.names, self.icons) |n, *icon| if (std.mem.eql(u8, n, name)) return icon;
        return null;
    }
};

/// The bundled set: chrome names onto Lucide's files. A name is what chrome
/// asks for (`error`, `split-right`); the file is Lucide's own name for the
/// drawing, kept unchanged so an upstream refresh is a file copy.
pub const lucide = [_]Source{
    lucideIcon("save", "save"),
    lucideIcon("undo", "undo-2"),
    lucideIcon("redo", "redo-2"),
    lucideIcon("command", "command"),
    lucideIcon("play", "play"),
    lucideIcon("build", "hammer"),
    lucideIcon("bug", "bug"),
    lucideIcon("test", "flask-conical"),
    lucideIcon("format", "text-align-start"),
    lucideIcon("rename", "pencil"),
    lucideIcon("split-right", "columns-2"),
    lucideIcon("split-down", "rows-2"),
    lucideIcon("close", "x"),
    lucideIcon("file", "file"),
    lucideIcon("file-text", "file-text"),
    lucideIcon("folder", "folder"),
    lucideIcon("folder-open", "folder-open"),
    lucideIcon("chevron-right", "chevron-right"),
    lucideIcon("chevron-down", "chevron-down"),
    lucideIcon("chevron-left", "chevron-left"),
    lucideIcon("chevron-up", "chevron-up"),
    lucideIcon("git-branch", "git-branch"),
    lucideIcon("git-commit", "git-commit-horizontal"),
    lucideIcon("error", "circle-x"),
    lucideIcon("warning", "triangle-alert"),
    lucideIcon("info", "info"),
    lucideIcon("search", "search"),
    lucideIcon("terminal", "terminal"),
    lucideIcon("check", "check"),
    lucideIcon("more", "ellipsis"),
    lucideIcon("plus", "plus"),
    lucideIcon("minus", "minus"),
    lucideIcon("dot", "dot"),
    lucideIcon("circle", "circle"),
    lucideIcon("stop", "square"),
    lucideIcon("settings", "settings"),
    lucideIcon("refresh", "refresh-cw"),
    lucideIcon("external-link", "external-link"),
    lucideIcon("lightbulb", "lightbulb"),
    lucideIcon("list", "list"),
    lucideIcon("sidebar", "panel-left"),
    lucideIcon("shield-check", "shield-check"),
    lucideIcon("users", "users"),
    lucideIcon("bell", "bell"),
    lucideIcon("keyboard", "keyboard"),
    lucideIcon("link", "link"),
    lucideIcon("cloud", "cloud"),
    // What commands present themselves with (doc/chrome.md §1.2): the edit,
    // navigation, version-control, run and view verbs a toolbar or menu shows.
    lucideIcon("file-plus", "file-plus"),
    lucideIcon("folder-plus", "folder-plus"),
    lucideIcon("copy", "copy"),
    lucideIcon("scissors", "scissors"),
    lucideIcon("clipboard-paste", "clipboard-paste"),
    lucideIcon("replace", "replace"),
    lucideIcon("arrow-left", "arrow-left"),
    lucideIcon("arrow-right", "arrow-right"),
    lucideIcon("history", "rotate-ccw-clock"),
    lucideIcon("bookmark", "bookmark"),
    lucideIcon("list-tree", "list-tree"),
    lucideIcon("crosshair", "crosshair"),
    lucideIcon("upload", "upload"),
    lucideIcon("download", "download"),
    lucideIcon("git-merge", "git-merge"),
    lucideIcon("git-pull-request", "git-pull-request"),
    lucideIcon("bot", "bot"),
    lucideIcon("sparkles", "sparkles"),
    lucideIcon("notebook-pen", "notebook-pen"),
    lucideIcon("share-2", "share-2"),
    lucideIcon("plug", "plug"),
    lucideIcon("unplug", "unplug"),
    lucideIcon("log-out", "log-out"),
    lucideIcon("palette", "palette"),
    lucideIcon("type", "type"),
    lucideIcon("zoom-in", "zoom-in"),
    lucideIcon("zoom-out", "zoom-out"),
    lucideIcon("indent-increase", "list-indent-increase"),
    lucideIcon("indent-decrease", "list-indent-decrease"),
    lucideIcon("circle-dot", "circle-dot"),
    lucideIcon("step-forward", "step-forward"),
    lucideIcon("arrow-down-to-line", "arrow-down-to-line"),
    lucideIcon("arrow-up-from-line", "arrow-up-from-line"),
    lucideIcon("panel-bottom", "panel-bottom"),
    lucideIcon("text-search", "text-search"),
    lucideIcon("file-search", "file-search"),
    lucideIcon("globe", "globe"),
    lucideIcon("network", "network"),
    lucideIcon("eye", "eye"),
    lucideIcon("list-checks", "list-checks"),
    lucideIcon("hash", "hash"),
    lucideIcon("case-upper", "case-upper"),
    lucideIcon("case-lower", "case-lower"),
    lucideIcon("text-cursor-input", "text-cursor-input"),
    lucideIcon("folder-tree", "folder-tree"),
    lucideIcon("layout-dashboard", "layout-dashboard"),
    lucideIcon("messages-square", "messages-square"),
};

fn lucideIcon(comptime name: []const u8, comptime file: []const u8) Source {
    return .{ .name = name, .svg = @embedFile("icons/lucide/" ++ file ++ ".svg") };
}

/// weft's own set (doc/icons.md): every chrome name the Lucide table has,
/// drawn to one grid and one vocabulary, then the completion kinds.
pub const weft = [_]Source{
    weftIcon("save"),
    weftIcon("undo"),
    weftIcon("redo"),
    weftIcon("command"),
    weftIcon("play"),
    weftIcon("build"),
    weftIcon("bug"),
    weftIcon("test"),
    weftIcon("format"),
    weftIcon("rename"),
    weftIcon("split-right"),
    weftIcon("split-down"),
    weftIcon("close"),
    weftIcon("file"),
    weftIcon("file-text"),
    weftIcon("folder"),
    weftIcon("folder-open"),
    weftIcon("chevron-right"),
    weftIcon("chevron-down"),
    weftIcon("chevron-left"),
    weftIcon("chevron-up"),
    weftIcon("git-branch"),
    weftIcon("git-commit"),
    weftIcon("error"),
    weftIcon("warning"),
    weftIcon("info"),
    weftIcon("search"),
    weftIcon("terminal"),
    weftIcon("check"),
    weftIcon("more"),
    weftIcon("plus"),
    weftIcon("minus"),
    weftIcon("dot"),
    weftIcon("circle"),
    weftIcon("stop"),
    weftIcon("settings"),
    weftIcon("refresh"),
    weftIcon("external-link"),
    weftIcon("lightbulb"),
    weftIcon("list"),
    weftIcon("sidebar"),
    weftIcon("shield-check"),
    weftIcon("users"),
    weftIcon("bell"),
    weftIcon("keyboard"),
    weftIcon("link"),
    weftIcon("cloud"),
    weftIcon("file-plus"),
    weftIcon("folder-plus"),
    weftIcon("copy"),
    weftIcon("scissors"),
    weftIcon("clipboard-paste"),
    weftIcon("replace"),
    weftIcon("arrow-left"),
    weftIcon("arrow-right"),
    weftIcon("history"),
    weftIcon("bookmark"),
    weftIcon("list-tree"),
    weftIcon("crosshair"),
    weftIcon("upload"),
    weftIcon("download"),
    weftIcon("git-merge"),
    weftIcon("git-pull-request"),
    weftIcon("bot"),
    weftIcon("sparkles"),
    weftIcon("notebook-pen"),
    weftIcon("share-2"),
    weftIcon("plug"),
    weftIcon("unplug"),
    weftIcon("log-out"),
    weftIcon("palette"),
    weftIcon("type"),
    weftIcon("zoom-in"),
    weftIcon("zoom-out"),
    weftIcon("indent-increase"),
    weftIcon("indent-decrease"),
    weftIcon("circle-dot"),
    weftIcon("step-forward"),
    weftIcon("arrow-down-to-line"),
    weftIcon("arrow-up-from-line"),
    weftIcon("panel-bottom"),
    weftIcon("text-search"),
    weftIcon("file-search"),
    weftIcon("globe"),
    weftIcon("network"),
    weftIcon("eye"),
    weftIcon("list-checks"),
    weftIcon("hash"),
    weftIcon("case-upper"),
    weftIcon("case-lower"),
    weftIcon("text-cursor-input"),
    weftIcon("folder-tree"),
    weftIcon("layout-dashboard"),
    weftIcon("messages-square"),
    // The completion kinds, in LSP's CompletionItemKind order (`kind_names`).
    weftIcon("kind-text"),
    weftIcon("kind-method"),
    weftIcon("kind-function"),
    weftIcon("kind-constructor"),
    weftIcon("kind-field"),
    weftIcon("kind-variable"),
    weftIcon("kind-class"),
    weftIcon("kind-interface"),
    weftIcon("kind-module"),
    weftIcon("kind-property"),
    weftIcon("kind-unit"),
    weftIcon("kind-value"),
    weftIcon("kind-enum"),
    weftIcon("kind-keyword"),
    weftIcon("kind-snippet"),
    weftIcon("kind-color"),
    weftIcon("kind-file"),
    weftIcon("kind-reference"),
    weftIcon("kind-folder"),
    weftIcon("kind-enum-member"),
    weftIcon("kind-constant"),
    weftIcon("kind-struct"),
    weftIcon("kind-event"),
    weftIcon("kind-operator"),
    weftIcon("kind-type-parameter"),
};

fn weftIcon(comptime name: []const u8) Source {
    return .{ .name = name, .svg = @embedFile("icons/weft/" ++ name ++ ".svg") };
}

/// The completion kinds' icon names, in LSP's `CompletionItemKind` order:
/// kind `k` (1-25) is `kind_names[k - 1]`. A completion UI asks the set for
/// `kindIcon(k)`; doc/icons.md §4 keeps the same table.
pub const kind_names = [_][]const u8{
    "kind-text",     "kind-method", "kind-function",  "kind-constructor", "kind-field",
    "kind-variable", "kind-class",  "kind-interface", "kind-module",      "kind-property",
    "kind-unit",     "kind-value",  "kind-enum",      "kind-keyword",     "kind-snippet",
    "kind-color",    "kind-file",   "kind-reference", "kind-folder",      "kind-enum-member",
    "kind-constant", "kind-struct", "kind-event",     "kind-operator",    "kind-type-parameter",
};

/// The icon name for LSP `CompletionItemKind` `kind`, or null outside 1-25.
pub fn kindIcon(kind: u32) ?[]const u8 {
    if (kind < 1 or kind > kind_names.len) return null;
    return kind_names[kind - 1];
}

/// The sets this build ships, by the name `theme/icons` spells them with.
pub const Bundled = enum {
    lucide,
    weft,

    pub fn sources(self: Bundled) []const Source {
        return switch (self) {
            .lucide => &lucide,
            .weft => &weft,
        };
    }

    /// The set `name` spells, or null for any other name (`none` included —
    /// turning icons off is the view's, not a set).
    pub fn parse(name: []const u8) ?Bundled {
        return std.meta.stringToEnum(Bundled, name);
    }
};

// ── SVG → path commands ─────────────────────────────────────────────

pub const ParseError = error{ InvalidSvg, OutOfMemory };

/// Every drawable element of `svg`, as one path (one subpath per shape).
pub fn parseSvg(arena: Allocator, svg: []const u8) ParseError![]const PathCommand {
    var out: Builder = .{ .arena = arena };
    var icon: Icon = .{ .commands = &.{} };
    try parseInto(svg, &out, &out, &icon);
    return out.list.toOwnedSlice(arena);
}

/// `svg` as an `Icon`: its stroke as the root element declares it, and its
/// `class="accent"` elements apart from the rest.
pub fn parseIcon(arena: Allocator, svg: []const u8) ParseError!Icon {
    var main: Builder = .{ .arena = arena };
    var accent: Builder = .{ .arena = arena };
    var icon: Icon = .{ .commands = &.{} };
    try parseInto(svg, &main, &accent, &icon);
    icon.commands = try main.list.toOwnedSlice(arena);
    icon.accent = try accent.list.toOwnedSlice(arena);
    return icon;
}

fn parseInto(svg: []const u8, main: *Builder, accent: *Builder, icon: *Icon) ParseError!void {
    var at: usize = 0;
    while (std.mem.indexOfScalarPos(u8, svg, at, '<')) |open| {
        const close = std.mem.indexOfScalarPos(u8, svg, open, '>') orelse return error.InvalidSvg;
        const tag = svg[open + 1 .. close];
        at = close + 1;
        const name_end = std.mem.indexOfAny(u8, tag, " \t\r\n/") orelse tag.len;
        const name = tag[0..name_end];
        const attrs = tag[name_end..];
        if (std.mem.eql(u8, name, "svg")) {
            if (attr(attrs, "stroke-width")) |w| icon.stroke_width = parseNum(w);
            if (attr(attrs, "stroke-linecap")) |c| icon.cap = if (std.mem.eql(u8, c, "square")) .square else if (std.mem.eql(u8, c, "butt")) .butt else .round;
            if (attr(attrs, "stroke-linejoin")) |j| icon.join = if (std.mem.eql(u8, j, "miter")) .miter else if (std.mem.eql(u8, j, "bevel")) .bevel else .round;
            continue;
        }
        const out = if (attr(attrs, "class")) |c| (if (std.mem.eql(u8, c, "accent")) accent else main) else main;
        if (std.mem.eql(u8, name, "path")) {
            try parsePathData(out, attr(attrs, "d") orelse return error.InvalidSvg);
        } else if (std.mem.eql(u8, name, "circle")) {
            const r = num(attrs, "r");
            try out.ellipse(num(attrs, "cx"), num(attrs, "cy"), r, r);
        } else if (std.mem.eql(u8, name, "ellipse")) {
            try out.ellipse(num(attrs, "cx"), num(attrs, "cy"), num(attrs, "rx"), num(attrs, "ry"));
        } else if (std.mem.eql(u8, name, "rect")) {
            const rx_attr = attr(attrs, "rx");
            const ry_attr = attr(attrs, "ry");
            const rx = parseNum(rx_attr orelse ry_attr orelse "0");
            const ry = parseNum(ry_attr orelse rx_attr orelse "0");
            try out.rect(num(attrs, "x"), num(attrs, "y"), num(attrs, "width"), num(attrs, "height"), rx, ry);
        } else if (std.mem.eql(u8, name, "line")) {
            try out.moveTo(num(attrs, "x1"), num(attrs, "y1"));
            try out.lineTo(num(attrs, "x2"), num(attrs, "y2"));
        } else if (std.mem.eql(u8, name, "polyline") or std.mem.eql(u8, name, "polygon")) {
            var scan: Scanner = .{ .text = attr(attrs, "points") orelse return error.InvalidSvg };
            var first = true;
            while (scan.number()) |x| {
                const y = scan.number() orelse return error.InvalidSvg;
                if (first) try out.moveTo(x, y) else try out.lineTo(x, y);
                first = false;
            }
            if (std.mem.eql(u8, name, "polygon")) try out.close();
        }
    }
}

fn attr(attrs: []const u8, name: []const u8) ?[]const u8 {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, attrs, at, name)) |i| {
        at = i + name.len;
        // A whole attribute name: preceded by space, followed by `="`.
        if (i == 0 or !std.ascii.isWhitespace(attrs[i - 1])) continue;
        if (!std.mem.startsWith(u8, attrs[at..], "=\"")) continue;
        const start = at + 2;
        const end = std.mem.indexOfScalarPos(u8, attrs, start, '"') orelse return null;
        return attrs[start..end];
    }
    return null;
}

fn num(attrs: []const u8, name: []const u8) f32 {
    return parseNum(attr(attrs, name) orelse "0");
}

fn parseNum(text: []const u8) f32 {
    return std.fmt.parseFloat(f32, std.mem.trim(u8, text, " ")) catch 0;
}

/// Numbers out of path data or a points list: separated by space, comma, or
/// nothing at all where a sign or a second `.` starts the next one (`1-2`,
/// `.5.5`), and arc flags written as bare digits (`a2 2 0 011 1`).
const Scanner = struct {
    text: []const u8,
    at: usize = 0,

    fn skip(self: *Scanner) void {
        while (self.at < self.text.len and (std.ascii.isWhitespace(self.text[self.at]) or self.text[self.at] == ',')) self.at += 1;
    }

    fn number(self: *Scanner) ?f32 {
        self.skip();
        const start = self.at;
        var i = self.at;
        if (i < self.text.len and (self.text[i] == '-' or self.text[i] == '+')) i += 1;
        var dot = false;
        var digits = false;
        while (i < self.text.len) : (i += 1) {
            const c = self.text[i];
            if (std.ascii.isDigit(c)) {
                digits = true;
            } else if (c == '.' and !dot) {
                dot = true;
            } else if ((c == 'e' or c == 'E') and digits) {
                i += 1;
                if (i < self.text.len and (self.text[i] == '-' or self.text[i] == '+')) i += 1;
                while (i < self.text.len and std.ascii.isDigit(self.text[i])) i += 1;
                break;
            } else break;
        }
        if (!digits) return null;
        self.at = i;
        return std.fmt.parseFloat(f32, self.text[start..i]) catch null;
    }

    /// An arc flag: one `0` or `1`, which may run straight into the next
    /// number.
    fn flag(self: *Scanner) ?bool {
        self.skip();
        if (self.at >= self.text.len) return null;
        const c = self.text[self.at];
        if (c != '0' and c != '1') return null;
        self.at += 1;
        return c == '1';
    }

    fn command(self: *Scanner) ?u8 {
        self.skip();
        if (self.at >= self.text.len) return null;
        const c = self.text[self.at];
        if (!std.ascii.isAlphabetic(c)) return null;
        self.at += 1;
        return c;
    }

    fn done(self: *Scanner) bool {
        self.skip();
        return self.at >= self.text.len;
    }
};

const Builder = struct {
    arena: Allocator,
    list: std.ArrayList(PathCommand) = .empty,
    /// The current point and the current subpath's start.
    x: f32 = 0,
    y: f32 = 0,
    start_x: f32 = 0,
    start_y: f32 = 0,

    fn push(self: *Builder, verb: scene.PathVerb, p: [6]f32) !void {
        try self.list.append(self.arena, .{ .verb = verb, .points = p });
    }

    fn moveTo(self: *Builder, x: f32, y: f32) !void {
        try self.push(.move, .{ x, y, 0, 0, 0, 0 });
        self.x = x;
        self.y = y;
        self.start_x = x;
        self.start_y = y;
    }

    fn lineTo(self: *Builder, x: f32, y: f32) !void {
        try self.push(.line, .{ x, y, 0, 0, 0, 0 });
        self.x = x;
        self.y = y;
    }

    fn cubicTo(self: *Builder, x1: f32, y1: f32, x2: f32, y2: f32, x: f32, y: f32) !void {
        try self.push(.cubic, .{ x1, y1, x2, y2, x, y });
        self.x = x;
        self.y = y;
    }

    fn close(self: *Builder) !void {
        try self.push(.close, .{ 0, 0, 0, 0, 0, 0 });
        self.x = self.start_x;
        self.y = self.start_y;
    }

    /// Four quarter arcs, each the standard cubic approximation.
    fn ellipse(self: *Builder, cx: f32, cy: f32, rx: f32, ry: f32) !void {
        const k: f32 = 0.5522847498;
        try self.moveTo(cx + rx, cy);
        try self.cubicTo(cx + rx, cy + k * ry, cx + k * rx, cy + ry, cx, cy + ry);
        try self.cubicTo(cx - k * rx, cy + ry, cx - rx, cy + k * ry, cx - rx, cy);
        try self.cubicTo(cx - rx, cy - k * ry, cx - k * rx, cy - ry, cx, cy - ry);
        try self.cubicTo(cx + k * rx, cy - ry, cx + rx, cy - k * ry, cx + rx, cy);
        try self.close();
    }

    fn rect(self: *Builder, x: f32, y: f32, w: f32, h: f32, rx_in: f32, ry_in: f32) !void {
        const rx = @min(rx_in, w / 2);
        const ry = @min(ry_in, h / 2);
        if (rx <= 0 or ry <= 0) {
            try self.moveTo(x, y);
            try self.lineTo(x + w, y);
            try self.lineTo(x + w, y + h);
            try self.lineTo(x, y + h);
            return self.close();
        }
        const k: f32 = 0.5522847498;
        try self.moveTo(x + rx, y);
        try self.lineTo(x + w - rx, y);
        try self.cubicTo(x + w - rx + k * rx, y, x + w, y + ry - k * ry, x + w, y + ry);
        try self.lineTo(x + w, y + h - ry);
        try self.cubicTo(x + w, y + h - ry + k * ry, x + w - rx + k * rx, y + h, x + w - rx, y + h);
        try self.lineTo(x + rx, y + h);
        try self.cubicTo(x + rx - k * rx, y + h, x, y + h - ry + k * ry, x, y + h - ry);
        try self.lineTo(x, y + ry);
        try self.cubicTo(x, y + ry - k * ry, x + rx - k * rx, y, x + rx, y);
        try self.close();
    }

    /// An SVG elliptical arc (endpoint form) as cubics, one per quarter turn
    /// or less (SVG 1.1 implementation notes, F.6.5-F.6.6).
    fn arcTo(self: *Builder, rx_in: f32, ry_in: f32, rotation_deg: f32, large: bool, sweep: bool, x: f32, y: f32) !void {
        const x0 = self.x;
        const y0 = self.y;
        if (x0 == x and y0 == y) return;
        var rx = @abs(rx_in);
        var ry = @abs(ry_in);
        if (rx == 0 or ry == 0) return self.lineTo(x, y);
        const phi = rotation_deg * std.math.pi / 180.0;
        const cos_phi = @cos(phi);
        const sin_phi = @sin(phi);
        const dx = (x0 - x) / 2;
        const dy = (y0 - y) / 2;
        const x1p = cos_phi * dx + sin_phi * dy;
        const y1p = -sin_phi * dx + cos_phi * dy;
        // Radii too small for the chord scale up to just reach it.
        const lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry);
        if (lambda > 1) {
            const s = @sqrt(lambda);
            rx *= s;
            ry *= s;
        }
        const num_ = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p;
        const den = rx * rx * y1p * y1p + ry * ry * x1p * x1p;
        var coef = if (den == 0) 0 else @sqrt(@max(0, num_ / den));
        if (large == sweep) coef = -coef;
        const cxp = coef * rx * y1p / ry;
        const cyp = -coef * ry * x1p / rx;
        const cx = cos_phi * cxp - sin_phi * cyp + (x0 + x) / 2;
        const cy = sin_phi * cxp + cos_phi * cyp + (y0 + y) / 2;
        const theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry);
        var delta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry);
        if (!sweep and delta > 0) delta -= 2 * std.math.pi;
        if (sweep and delta < 0) delta += 2 * std.math.pi;

        const segments: usize = @intFromFloat(@max(1, @ceil(@abs(delta) / (std.math.pi / 2.0) - 1e-4)));
        const step = delta / @as(f32, @floatFromInt(segments));
        const k = 4.0 / 3.0 * @tan(step / 4);
        var a = theta1;
        for (0..segments) |i| {
            const b = a + step;
            const cos_a = @cos(a);
            const sin_a = @sin(a);
            const cos_b = @cos(b);
            const sin_b = @sin(b);
            // The unit-circle segment's control points, scaled, rotated and
            // moved onto the ellipse.
            const p1 = mapPoint(cx, cy, rx, ry, cos_phi, sin_phi, cos_a - k * sin_a, sin_a + k * cos_a);
            const p2 = mapPoint(cx, cy, rx, ry, cos_phi, sin_phi, cos_b + k * sin_b, sin_b - k * cos_b);
            const end = if (i + 1 == segments) [2]f32{ x, y } else mapPoint(cx, cy, rx, ry, cos_phi, sin_phi, cos_b, sin_b);
            try self.cubicTo(p1[0], p1[1], p2[0], p2[1], end[0], end[1]);
            a = b;
        }
    }
};

fn angle(ux: f32, uy: f32, vx: f32, vy: f32) f32 {
    return std.math.atan2(ux * vy - uy * vx, ux * vx + uy * vy);
}

fn mapPoint(cx: f32, cy: f32, rx: f32, ry: f32, cos_phi: f32, sin_phi: f32, ux: f32, uy: f32) [2]f32 {
    return .{ cx + rx * ux * cos_phi - ry * uy * sin_phi, cy + rx * ux * sin_phi + ry * uy * cos_phi };
}

/// One `d` attribute. Relative commands resolve against the current point;
/// a command letter repeats for as many argument groups as follow it (and a
/// moveto's extra pairs are linetos, per the spec).
fn parsePathData(out: *Builder, d: []const u8) ParseError!void {
    var scan: Scanner = .{ .text = d };
    // Each path starts at the origin: a leading relative moveto is absolute,
    // never relative to where the previous element ended.
    out.x = 0;
    out.y = 0;
    var cmd: u8 = 0;
    // The previous segment's second control point, for S/T reflection.
    var last_ctrl: ?[2]f32 = null;
    var last_quad: ?[2]f32 = null;
    while (!scan.done()) {
        if (scan.command()) |c| {
            cmd = c;
        } else if (cmd == 0) return error.InvalidSvg;
        const rel = std.ascii.isLower(cmd);
        const ox: f32 = if (rel) out.x else 0;
        const oy: f32 = if (rel) out.y else 0;
        var ctrl: ?[2]f32 = null;
        var quad: ?[2]f32 = null;
        switch (std.ascii.toUpper(cmd)) {
            'Z' => try out.close(),
            'M' => {
                const x = scan.number() orelse return error.InvalidSvg;
                const y = scan.number() orelse return error.InvalidSvg;
                try out.moveTo(ox + x, oy + y);
                cmd = if (rel) 'l' else 'L';
            },
            'L' => {
                const x = scan.number() orelse return error.InvalidSvg;
                const y = scan.number() orelse return error.InvalidSvg;
                try out.lineTo(ox + x, oy + y);
            },
            'H' => try out.lineTo(ox + (scan.number() orelse return error.InvalidSvg), out.y),
            'V' => try out.lineTo(out.x, oy + (scan.number() orelse return error.InvalidSvg)),
            'C' => {
                var p: [6]f32 = undefined;
                for (&p) |*v| v.* = scan.number() orelse return error.InvalidSvg;
                try out.cubicTo(ox + p[0], oy + p[1], ox + p[2], oy + p[3], ox + p[4], oy + p[5]);
                ctrl = .{ ox + p[2], oy + p[3] };
            },
            'S' => {
                var p: [4]f32 = undefined;
                for (&p) |*v| v.* = scan.number() orelse return error.InvalidSvg;
                const r = reflect(last_ctrl, out.x, out.y);
                try out.cubicTo(r[0], r[1], ox + p[0], oy + p[1], ox + p[2], oy + p[3]);
                ctrl = .{ ox + p[0], oy + p[1] };
            },
            'Q' => {
                var p: [4]f32 = undefined;
                for (&p) |*v| v.* = scan.number() orelse return error.InvalidSvg;
                try quadTo(out, ox + p[0], oy + p[1], ox + p[2], oy + p[3]);
                quad = .{ ox + p[0], oy + p[1] };
            },
            'T' => {
                const x = scan.number() orelse return error.InvalidSvg;
                const y = scan.number() orelse return error.InvalidSvg;
                const q = reflect(last_quad, out.x, out.y);
                try quadTo(out, q[0], q[1], ox + x, oy + y);
                quad = q;
            },
            'A' => {
                const rx = scan.number() orelse return error.InvalidSvg;
                const ry = scan.number() orelse return error.InvalidSvg;
                const rot = scan.number() orelse return error.InvalidSvg;
                const large = scan.flag() orelse return error.InvalidSvg;
                const sweep = scan.flag() orelse return error.InvalidSvg;
                const x = scan.number() orelse return error.InvalidSvg;
                const y = scan.number() orelse return error.InvalidSvg;
                try out.arcTo(rx, ry, rot, large, sweep, ox + x, oy + y);
            },
            else => return error.InvalidSvg,
        }
        last_ctrl = ctrl;
        last_quad = quad;
    }
}

fn reflect(ctrl: ?[2]f32, x: f32, y: f32) [2]f32 {
    const c = ctrl orelse return .{ x, y };
    return .{ 2 * x - c[0], 2 * y - c[1] };
}

/// A quadratic raised to the cubic with the same curve.
fn quadTo(out: *Builder, qx: f32, qy: f32, x: f32, y: f32) !void {
    const x0 = out.x;
    const y0 = out.y;
    try out.cubicTo(x0 + 2.0 / 3.0 * (qx - x0), y0 + 2.0 / 3.0 * (qy - y0), x + 2.0 / 3.0 * (qx - x), y + 2.0 / 3.0 * (qy - y), x, y);
}

// ── Tests ──

const t = std.testing;

/// The box a path's points span — on-curve and control points alike, so a
/// cubic (which stays inside its control points' hull) is inside it too.
fn pointBounds(commands: []const PathCommand) [4]f32 {
    var b: [4]f32 = .{ std.math.inf(f32), std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32) };
    for (commands) |c| {
        const n: usize = switch (c.verb) {
            .move, .line => 2,
            .cubic => 6,
            .close => 0,
        };
        var i: usize = 0;
        while (i < n) : (i += 2) {
            b[0] = @min(b[0], c.points[i]);
            b[1] = @min(b[1], c.points[i + 1]);
            b[2] = @max(b[2], c.points[i]);
            b[3] = @max(b[3], c.points[i + 1]);
        }
    }
    return b;
}

test "icons: every bundled icon parses into geometry inside its box" {
    for (std.enums.values(Bundled)) |bundled| {
        var set = try Set.parse(t.allocator, @tagName(bundled), bundled.sources());
        defer set.deinit();
        try t.expectEqual(bundled.sources().len, set.icons.len);
        for (set.names, set.icons) |name, icon| {
            errdefer std.debug.print("{s} icon '{s}'\n", .{ @tagName(bundled), name });
            try t.expect(icon.commands.len >= 2);
            try t.expectEqual(scene.PathVerb.move, icon.commands[0].verb);
            // A stroke-style icon stays within its 24-unit box (Lucide's
            // curves may put a control point a little past the stroke).
            const b = pointBounds(icon.commands);
            try t.expect(b[0] > -1 and b[1] > -1 and b[2] < 25 and b[3] < 25);
        }
        try t.expect(set.get("save") != null);
        try t.expect(set.get("split-right") != null);
        try t.expect(set.get("no-such-icon") == null);
    }
}

test "icons: weft's set has every chrome name Lucide's has, every completion kind, and no other" {
    try t.expectEqual(lucide.len + kind_names.len, weft.len);
    for (lucide) |src| {
        errdefer std.debug.print("weft has no '{s}'\n", .{src.name});
        for (weft) |w| {
            if (std.mem.eql(u8, w.name, src.name)) break;
        } else return error.TestUnexpectedResult;
    }
    for (kind_names) |kind| {
        errdefer std.debug.print("weft has no '{s}'\n", .{kind});
        for (weft) |w| {
            if (std.mem.eql(u8, w.name, kind)) break;
        } else return error.TestUnexpectedResult;
    }
    // Each name once: a duplicate would shadow its twin in `Set.get`.
    for (weft, 0..) |a, i| for (weft[i + 1 ..]) |b| {
        errdefer std.debug.print("weft names '{s}' twice\n", .{a.name});
        try t.expect(!std.mem.eql(u8, a.name, b.name));
    };
}

test "icons: weft's ink, stroke included, keeps a unit inside the 24-unit box" {
    // doc/icons.md §1: centrelines live in 3..21 (ink 2..22, the padding);
    // a round or pointed shape may overshoot by one unit for optical size,
    // never further — so no point's stroke comes within a unit of the edge.
    var set = try Set.parse(t.allocator, "weft", &weft);
    defer set.deinit();
    for (set.names, set.icons) |name, icon| {
        errdefer std.debug.print("weft icon '{s}' reaches past its padding\n", .{name});
        try t.expectEqual(@as(f32, 24), icon.size);
        const half = icon.stroke_width / 2;
        const b = pointBounds(icon.commands);
        try t.expect(b[0] - half >= 1 and b[1] - half >= 1);
        try t.expect(b[2] + half <= 23 and b[3] + half <= 23);
    }
}

test "icons: an LSP CompletionItemKind names its kind icon, 1 to 25" {
    try t.expectEqualStrings("kind-text", kindIcon(1).?);
    try t.expectEqualStrings("kind-function", kindIcon(3).?);
    try t.expectEqualStrings("kind-struct", kindIcon(22).?);
    try t.expectEqualStrings("kind-type-parameter", kindIcon(25).?);
    try t.expect(kindIcon(0) == null);
    try t.expect(kindIcon(26) == null);
}

test "icons: `theme/icons` spells the bundled sets by name, and nothing else" {
    try t.expectEqual(Bundled.lucide, Bundled.parse("lucide").?);
    try t.expectEqual(Bundled.weft, Bundled.parse("weft").?);
    try t.expect(Bundled.parse("none") == null);
    try t.expect(Bundled.parse("Weft") == null);
}

/// A contact sheet of `set`: every icon at 14, 16, 24 and 48 px, light on
/// the editor's background, labelled in the editor's mono face, drawn
/// through the same raster path a frame takes. Returns the pixels (caller
/// owns them) and the sheet's size; asserts each icon left ink at 14 px.
fn contactSheet(gpa: Allocator, set: *const Set) !struct { pixels: []u8, w: u32, h: u32 } {
    const harness = @import("harness.zig");
    const View = @import("view/View.zig");
    const font_provider = @import("weft_font_provider");
    var view = try View.init(gpa, font_provider.defaultMono(), 16);
    defer view.deinit();
    const font = view.face_set.monoFont();

    const sizes = [_]f32{ 14, 16, 24, 48 };
    const cols: u32 = 8;
    const cell_w: u32 = 176;
    const cell_h: u32 = 92;
    const pad: u32 = 12;
    const label_size: f32 = 11;
    const rows: u32 = @intCast((set.icons.len + cols - 1) / cols);
    const w = cols * cell_w + 2 * pad;
    const h = rows * cell_h + 2 * pad;
    const fg = view.theme.foreground;
    const dim: scene.Color = .{ fg[0] * 0.45, fg[1] * 0.45, fg[2] * 0.45, 1 };

    var items: std.ArrayList(scene.DrawItem) = .empty;
    defer items.deinit(gpa);
    const advance = view.cell_w * label_size / view.em;
    for (set.names, set.icons, 0..) |name, *icon, i| {
        const cx: f32 = @floatFromInt(pad + @as(u32, @intCast(i % cols)) * cell_w + 8);
        const cy: f32 = @floatFromInt(pad + @as(u32, @intCast(i / cols)) * cell_h + 6);
        var x = cx;
        for (sizes) |side| {
            // Bottom-aligned on the 48 px icon's baseline, each on whole
            // pixels, as chrome places them (`chrome.Sink.icon`).
            try items.append(gpa, .{ .path = .{
                .commands = icon.commands,
                .x = x,
                .y = cy + 48 - side,
                .scale = side / icon.size,
                .stroke_width = icon.stroke_width,
                .color = fg,
                .cap = icon.cap,
                .join = icon.join,
            } });
            // Its accent in the theme's accent, as the renderer draws it.
            if (icon.accent.len > 0) try items.append(gpa, .{ .path = .{
                .commands = icon.accent,
                .x = x,
                .y = cy + 48 - side,
                .scale = side / icon.size,
                .stroke_width = icon.stroke_width,
                .color = view.theme.accent,
                .cap = icon.cap,
                .join = icon.join,
            } });
            x += side + 12;
        }
        var lx = cx;
        for (name) |c| {
            try items.append(gpa, .{ .glyph = .{ .font_id = 1, .glyph_id = try font.glyphIndex(c), .x = lx, .y = cy + 48 + 24, .size = label_size, .color = dim } });
            lx += advance;
        }
    }
    const pixels = try harness.rasterize(gpa, &view, &.{items.items}, w, h);
    errdefer gpa.free(pixels);
    for (set.names, 0..) |name, i| {
        errdefer std.debug.print("icon '{s}' drew nothing at 14 px\n", .{name});
        const x0 = pad + @as(u32, @intCast(i % cols)) * cell_w + 8;
        const y0 = pad + @as(u32, @intCast(i / cols)) * cell_h + 6 + 48 - 14;
        try t.expect(harness.hasContent(pixels, w, x0, y0, x0 + 14, y0 + 14));
    }
    return .{ .pixels = pixels, .w = w, .h = h };
}

test "icons: every bundled icon draws at 14 px through the raster path (contact sheets)" {
    // The sheets land in .zig-cache/tmp (`magick x.ppm x.png` to view);
    // assets/icon-sets/ keeps the reviewed copies.
    for (std.enums.values(Bundled)) |bundled| {
        var set = try Set.parse(t.allocator, @tagName(bundled), bundled.sources());
        defer set.deinit();
        const sheet = try contactSheet(t.allocator, &set);
        defer t.allocator.free(sheet.pixels);
        var path_buf: [96]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/weft-icons-{s}.ppm", .{@tagName(bundled)});
        @import("harness.zig").writePpm(t.allocator, path, sheet.pixels, sheet.w, sheet.h) catch {};
    }
}

test "icons: relative path commands, implicit repeats and closes resolve to absolute points" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cmds = try parseSvg(arena.allocator(), "<svg><path d=\"m2 3 4 0h1v2H2z\" /></svg>");
    try t.expectEqual(@as(usize, 6), cmds.len);
    try t.expectEqual(scene.PathVerb.move, cmds[0].verb);
    try t.expectEqual(@as(f32, 2), cmds[0].points[0]);
    // The moveto's second pair is a relative lineto from (2,3).
    try t.expectEqual(scene.PathVerb.line, cmds[1].verb);
    try t.expectEqual(@as(f32, 6), cmds[1].points[0]);
    try t.expectEqual(@as(f32, 3), cmds[1].points[1]);
    try t.expectEqual(@as(f32, 7), cmds[2].points[0]); // h1
    try t.expectEqual(@as(f32, 5), cmds[3].points[1]); // v2
    try t.expectEqual(@as(f32, 2), cmds[4].points[0]); // H2
    try t.expectEqual(scene.PathVerb.close, cmds[5].verb);
    // A second element's leading `m` starts from the origin, not from where
    // the first ended (Lucide's hammer is drawn this way).
    const two = try parseSvg(arena.allocator(), "<path d=\"M1 1 9 9\" /><path d=\"m3 3 1 1\" />");
    try t.expectEqual(@as(f32, 3), two[2].points[0]);
    try t.expectEqual(@as(f32, 4), two[3].points[0]);
}

test "icons: an arc ends exactly at its endpoint, and a half circle bulges the right way" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    // From (2,12) to (22,12) with r=10, sweep=1: the upper half (y < 12 in
    // SVG's y-down space), split into two quarter cubics.
    const cmds = try parseSvg(arena.allocator(), "<path d=\"M2 12a10 10 0 0 1 20 0\" />");
    try t.expectEqual(@as(usize, 3), cmds.len);
    const last = cmds[2].points;
    try t.expectApproxEqAbs(@as(f32, 22), last[4], 1e-3);
    try t.expectApproxEqAbs(@as(f32, 12), last[5], 1e-3);
    // The midpoint of the half circle is the top, (12, 2).
    try t.expectApproxEqAbs(@as(f32, 12), cmds[1].points[4], 1e-3);
    try t.expectApproxEqAbs(@as(f32, 2), cmds[1].points[5], 1e-3);
    // Flags written without separators (`011`) parse as flags, not a number.
    const packed_flags = try parseSvg(arena.allocator(), "<path d=\"M2 12a10 10 0 0120 0\" />");
    try t.expectEqual(@as(usize, 3), packed_flags.len);
    try t.expectApproxEqAbs(@as(f32, 22), packed_flags[2].points[4], 1e-3);
}

test "icons: shape elements become closed subpaths" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cmds = try parseSvg(arena.allocator(),
        \\<svg><circle cx="12" cy="12" r="10" /><rect width="18" height="18" x="3" y="3" rx="2" />
        \\<line x1="1" y1="2" x2="3" y2="4" /><polygon points="1,1 5,1 3,4" /></svg>
    );
    // circle: move + 4 cubics + close; rounded rect: move + 4 lines + 4
    // cubics + close; line: move + line; polygon: move + 2 lines + close.
    try t.expectEqual(@as(usize, 6 + 10 + 2 + 4), cmds.len);
    try t.expectEqual(scene.PathVerb.close, cmds[5].verb);
    try t.expectEqual(@as(f32, 5), cmds[6].points[0]); // rect starts after its corner
    try t.expectEqual(scene.PathVerb.close, cmds[21].verb);
}

test "icons: malformed path data is refused rather than guessed" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try t.expectError(error.InvalidSvg, parseSvg(arena.allocator(), "<path d=\"3 4\" />"));
    try t.expectError(error.InvalidSvg, parseSvg(arena.allocator(), "<path d=\"M1\" />"));
    try t.expectError(error.InvalidSvg, parseSvg(arena.allocator(), "<path />"));
}

test "icons: an icon is stroked as its root says, and its accent elements are a path of their own" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const icon = try parseIcon(arena.allocator(),
        \\<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="square" stroke-linejoin="miter">
        \\  <path d="M4 6h16M4 12h10" />
        \\  <path class="accent" d="M18 10v8" />
        \\</svg>
    );
    try std.testing.expectEqual(@as(f32, 1.75), icon.stroke_width);
    try std.testing.expectEqual(scene.StrokeCap.square, icon.cap);
    try std.testing.expectEqual(scene.StrokeJoin.miter, icon.join);
    try std.testing.expectEqual(@as(usize, 4), icon.commands.len); // two lines
    try std.testing.expectEqual(@as(usize, 2), icon.accent.len); // one line
    // Lucide's root declares its 2-unit round strokes; nothing is accent.
    const plain = try parseIcon(arena.allocator(),
        \\<svg viewBox="0 0 24 24" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 4h16" /></svg>
    );
    try std.testing.expectEqual(scene.StrokeCap.round, plain.cap);
    try std.testing.expectEqual(@as(usize, 0), plain.accent.len);
}
