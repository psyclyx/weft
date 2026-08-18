//! Navigation consumers over the capability registry: goto-definition
//! (race: instant tree-sitter tier answers immediately, higher-priority
//! fast/slow providers may overtake within a grace window) and document
//! symbols (pick over the winning provider's set). Consumers of names —
//! no provider imports, verified by the boundary check.

const std = @import("std");
const Allocator = std.mem.Allocator;

const command = @import("command.zig");
const capability = @import("capability.zig");
const task = @import("task.zig");
const pick_mod = @import("pick.zig");

/// After the first result arrives, wait this long for a better-priority
/// one before jumping.
const grace_ns: u64 = 200 * std.time.ns_per_ms;

pub const DefinitionUi = struct {
    session: ?u64 = null,
    first_result_ns: u64 = 0,

    pub const empty: DefinitionUi = .{};

    pub fn commandSpec(self: *DefinitionUi) command.Command {
        return .{
            .name = "goto-definition",
            .summary = "Jump to the definition under the cursor (all providers).",
            .args = &.{},
            .handler = fire,
            .data = self,
        };
    }

    fn fire(ctx: *command.Context, data: ?*anyopaque, args: []const command.Value) anyerror!command.Value {
        _ = args;
        const self: *DefinitionUi = @ptrCast(@alignCast(data.?));
        if (self.session) |old| ctx.caps.finish(old);
        self.session = try ctx.caps.fire(.definition, &ctx.editor().doc, ctx.editor().backingPath(), .{
            .offset = ctx.editor().cursorOffset(),
        });
        self.first_result_ns = 0;
        _ = try self.tick(ctx);
        return .nil;
    }

    pub fn tick(self: *DefinitionUi, ctx: *command.Context) !bool {
        const id = self.session orelse return false;
        const s = ctx.caps.session(id) orelse {
            self.session = null;
            return false;
        };
        _ = s.poll();
        const now = task.nowNs();
        const have_any = for (s.all()) |*r| {
            if (r.payload == .locations and r.payload.locations.len > 0) break true;
        } else false;
        if (have_any and self.first_result_ns == 0) self.first_result_ns = now;
        const settled = s.done(now) or
            (self.first_result_ns != 0 and now - self.first_result_ns >= grace_ns);
        if (!settled) return false;

        defer {
            ctx.caps.finish(id);
            self.session = null;
        }
        // first-wins-by-priority among non-empty answers.
        var best: ?*const capability.Result = null;
        for (s.all()) |*r| {
            if (r.payload != .locations or r.payload.locations.len == 0) continue;
            if (best == null or r.priority > best.?.priority) best = r;
        }
        const winner = best orelse return false;
        const loc = winner.payload.locations[0];
        if (loc.uri.len > 0) {
            std.log.info("definition in another file: {s}", .{loc.uri});
            return true;
        }
        // Rebase-or-discard: the stamp machinery is the only path.
        const range = loc.range.rebase(&ctx.editor().doc) orelse return false;
        ctx.editor().doc.anchors.set(ctx.editor().cursor, .{ .offset = range.start, .bias = .right });
        ctx.editor().history.barrier();
        return true;
    }
};

/// Hover: info about the symbol under the cursor, from the `.hover` capability
/// (LSP today). `fire` requests it; `tick` folds the winning provider's text in;
/// the app draws it as a caret popup while `active`, until the cursor moves.
pub const HoverUi = struct {
    session: ?u64 = null,
    first_result_ns: u64 = 0,
    text: std.ArrayList(u8) = .empty,
    offset: usize = 0,
    active: bool = false,

    pub const empty: HoverUi = .{};

    pub fn deinit(self: *HoverUi, gpa: std.mem.Allocator) void {
        self.text.deinit(gpa);
    }

    pub fn commandSpec(self: *HoverUi) command.Command {
        return .{
            .name = "hover",
            .summary = "Show info about the symbol under the cursor.",
            .args = &.{},
            .handler = fireHover,
            .data = self,
        };
    }

    fn fireHover(ctx: *command.Context, data: ?*anyopaque, args: []const command.Value) anyerror!command.Value {
        _ = args;
        const self: *HoverUi = @ptrCast(@alignCast(data.?));
        if (self.session) |old| ctx.caps.finish(old);
        self.offset = ctx.editor().cursorOffset();
        self.active = false;
        self.session = try ctx.caps.fire(.hover, &ctx.editor().doc, ctx.editor().backingPath(), .{
            .offset = self.offset,
        });
        self.first_result_ns = 0;
        _ = try self.tick(ctx);
        return .nil;
    }

    pub fn tick(self: *HoverUi, ctx: *command.Context) !bool {
        const id = self.session orelse return false;
        const s = ctx.caps.session(id) orelse {
            self.session = null;
            return false;
        };
        _ = s.poll();
        const now = task.nowNs();
        const have = for (s.all()) |*r| {
            if (r.payload == .text and r.payload.text.len > 0) break true;
        } else false;
        if (have and self.first_result_ns == 0) self.first_result_ns = now;
        const settled = s.done(now) or
            (self.first_result_ns != 0 and now - self.first_result_ns >= grace_ns);
        if (!settled) return false;
        defer {
            ctx.caps.finish(id);
            self.session = null;
        }
        var best: ?*const capability.Result = null;
        for (s.all()) |*r| {
            if (r.payload != .text or r.payload.text.len == 0) continue;
            if (best == null or r.priority > best.?.priority) best = r;
        }
        const winner = best orelse return false;
        self.text.clearRetainingCapacity();
        try self.text.appendSlice(ctx.gpa, winner.payload.text);
        self.active = true;
        return true;
    }

    pub fn clear(self: *HoverUi) void {
        self.active = false;
    }
};

pub const SymbolsUi = struct {
    session: ?u64 = null,
    /// Jump targets for the open pick (label index-aligned).
    names: std.ArrayList([]u8) = .empty,
    offsets: std.ArrayList(usize) = .empty,

    pub const empty: SymbolsUi = .{};

    pub fn deinit(self: *SymbolsUi, gpa: Allocator) void {
        self.clearTargets(gpa);
        self.names.deinit(gpa);
        self.offsets.deinit(gpa);
    }

    fn clearTargets(self: *SymbolsUi, gpa: Allocator) void {
        for (self.names.items) |n| gpa.free(n);
        self.names.clearRetainingCapacity();
        self.offsets.clearRetainingCapacity();
    }

    pub fn commandSpec(self: *SymbolsUi) command.Command {
        return .{
            .name = "symbols",
            .summary = "Pick a document symbol and jump to it.",
            .args = &.{},
            .handler = fire,
            .data = self,
        };
    }

    fn fire(ctx: *command.Context, data: ?*anyopaque, args: []const command.Value) anyerror!command.Value {
        _ = args;
        const self: *SymbolsUi = @ptrCast(@alignCast(data.?));
        if (self.session) |old| ctx.caps.finish(old);
        self.session = try ctx.caps.fire(.symbols, &ctx.editor().doc, ctx.editor().backingPath(), .{});
        _ = try self.tick(ctx);
        return .nil;
    }

    pub fn tick(self: *SymbolsUi, ctx: *command.Context) !bool {
        const id = self.session orelse return false;
        const s = ctx.caps.session(id) orelse {
            self.session = null;
            return false;
        };
        _ = s.poll();
        if (!s.done(task.nowNs())) return false;
        defer {
            ctx.caps.finish(id);
            self.session = null;
        }
        const best = s.best() orelse return false;
        if (best.payload != .symbols or best.payload.symbols.len == 0) return false;

        const gpa = ctx.gpa;
        self.clearTargets(gpa);
        var labels: std.ArrayList(pick_mod.Entry) = .empty;
        defer labels.deinit(gpa);
        for (best.payload.symbols) |sym| {
            const range = sym.range.rebase(&ctx.editor().doc) orelse continue;
            const name = try gpa.dupe(u8, sym.name);
            errdefer gpa.free(name);
            try self.names.append(gpa, name);
            try self.offsets.append(gpa, range.start);
            try labels.append(gpa, .{ .text = name });
        }
        if (labels.items.len == 0) return false;
        try ctx.pick.open(ctx, "symbol", labels.items, .{ .handler = jump, .data = self });
        return true;
    }

    fn jump(ctx: *command.Context, data: ?*anyopaque, choice: []const u8) anyerror!void {
        const self: *SymbolsUi = @ptrCast(@alignCast(data.?));
        for (self.names.items, self.offsets.items) |n, off| {
            if (std.mem.eql(u8, n, choice)) {
                const clamped = @min(off, ctx.editor().text().byteLen());
                ctx.editor().doc.anchors.set(ctx.editor().cursor, .{ .offset = clamped, .bias = .right });
                ctx.editor().history.barrier();
                return;
            }
        }
    }
};

test {
    std.testing.refAllDecls(@This());
}
