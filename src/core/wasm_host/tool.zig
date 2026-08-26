//! Tool-backed buffers: a plugin marks a buffer as its projection
//! (`weft.toolBacking(name)`), so its content is understood to be plugin-
//! regenerated (magit/dired) rather than a file. This is purely the entry's
//! IDENTITY — it does NOT special-case dispatch. `save` (and any other context
//! intent) resolves through the ACTION system: the entry's tool name is an
//! ambient fact (`action.Ctx.tool`, from `Buffers.Buffer.tool`), and a
//! projection provides `save` scoped to `When{ .tool = "<name>" }`, winning
//! over the core file-write provider by specificity. So the core stays
//! projection-agnostic.

const std = @import("std");
const wasm = @import("../wasm.zig");

const shared = @import("plugin.zig");
const WasmPlugin = shared.WasmPlugin;

/// `toolBacking(name)`: mark the ACTIVE buffer as this plugin's tool projection.
pub fn hToolBacking(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const name = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer p.gpa.free(name);
    p.activeCtx().buffers.active().setTool(p.gpa, name) catch return;
}
