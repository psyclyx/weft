//! Menu bindings + on_menu: which-key (a guest) reads the CURRENT menu mode's
//! table by index during its on_menu(open) and renders it into a surface. Core
//! owns WHEN (fired at the frame boundary, top-level — see notifyMenu).

const wasm = @import("../wasm.zig");
const contract = @import("../membrane/contract.zig");
const intent = @import("../intent.zig");

const shared = @import("plugin.zig");
const WasmPlugin = shared.WasmPlugin;

// which-key enumerates the CHOICES available right now. Mid-chord (a pending
// key sequence — `space f`) it lists that prefix's next-key COMPLETIONS (`f`, `r`
// …), the leader tree as sequences. At rest / on an F1 peek it lists the current
// mode's top-level choices (`completions("")` — segments deduped, a chord-opener
// shown as a group). A legacy menu MODE (still-migrating config) falls back to
// the mode's whole resolved table. Either way `key`/`cmd`/`group` index the built
// list; the guest enumerates synchronously in one `on_menu`.
pub fn hMenuBindingCount(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = args;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const km = p.activeCtx().keymap;
    const head = p.activeCtx().head;
    const n = if (head.pending.len > 0)
        head.completions(p.gpa, km, head.pending) catch 0
    else if (km.isMenuMode(head.currentMode()))
        head.resolveBindings(p.gpa, km, head.currentMode()) catch 0
    else
        head.completions(p.gpa, km, "") catch 0;
    results[0] = @intCast(n);
}
pub fn hMenuBindingKey(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const b = p.activeCtx().head.resolvedAt(@intCast(args[0])) orelse {
        results[0] = -1;
        return;
    };
    // which-key shows keys in the config's notation ("SPC :"), not the canonical
    // stored form ("space colon") — display only; logic uses the canonical key.
    var dbuf: [256]u8 = undefined;
    const disp = p.activeCtx().keymap.displayKey(&dbuf, b.key);
    results[0] = @intCast(caller.writeMemory(@intCast(args[1]), @intCast(args[2]), disp) catch 0);
}
pub fn hMenuBindingCmd(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const b = p.activeCtx().head.resolvedAt(@intCast(args[0])) orelse {
        results[0] = -1;
        return;
    };
    results[0] = @intCast(caller.writeMemory(@intCast(args[1]), @intCast(args[2]), b.command) catch 0);
}

/// Whether the `i`-th entry is a GROUP (opens a submenu / continues a chord)
/// rather than a runnable leaf — computed when the list was built (a chord
/// completion with more keys after it, or a legacy binding onto a menu mode).
pub fn hMenuBindingIsGroup(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = if (p.activeCtx().head.resolvedIsGroup(@intCast(args[0]))) 1 else 0;
}

// ── Explaining an intention binding ──────────────────────────────────
//
// A binding whose arms name intentions has no useful command NAME to show:
// what the key does is whatever the focused context offers. These three
// reads answer that from the resolver itself (`intent.explain` — the same
// context derivation and the same first-applicable walk dispatch runs), so a
// hint cannot promise what the keypress would not deliver.
//
// They DESCRIBE only: no endpoint is invoked. Explanation conveys no
// authority.

fn explainAt(p: *WasmPlugin, i: usize) intent.Explanation {
    const b = p.activeCtx().head.resolvedAt(i) orelse return .none;
    if (b.arms.len == 0) return .none;
    return intent.explain(p.activeCtx(), b.arms);
}

/// What the `i`-th binding would do: 0 = nothing an intention explains (the
/// guest keeps showing the command name), 1 = an arm would run, 2 = the
/// relevant arm is unavailable and says why.
pub fn hMenuBindingIntentStatus(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = switch (explainAt(p, @intCast(args[0]))) {
        .none => 0,
        .ready => 1,
        .blocked => 2,
    };
}

/// The winning (or blocked) arm's intention name, into guest memory.
pub fn hMenuBindingIntent(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const name = switch (explainAt(p, @intCast(args[0]))) {
        .none => {
            results[0] = -1;
            return;
        },
        .ready => |r| r.intention,
        .blocked => |b| b.intention,
    };
    results[0] = @intCast(caller.writeMemory(@intCast(args[1]), @intCast(args[2]), name) catch 0);
}

/// The row's second term: the provider that WOULD run it, or — when the arm
/// is unavailable — the reason it cannot.
pub fn hMenuBindingIntentNote(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const note = switch (explainAt(p, @intCast(args[0]))) {
        .none => {
            results[0] = -1;
            return;
        },
        .ready => |r| r.provider,
        .blocked => |b| b.reason,
    };
    results[0] = @intCast(caller.writeMemory(@intCast(args[1]), @intCast(args[2]), note) catch 0);
}

/// Fire a guest's `on_menu(open)` — a menu mode was entered (open=1) or left
/// (open=0). Called at the FRAME boundary (top-level, never nested inside
/// another guest call), so a menu-owner plugin re-entering its own wasmtime
/// store is impossible. Guests without the export are skipped.
pub fn notifyMenu(p: *WasmPlugin, open: bool) void {
    contract.callOptionalExport("on_menu", &p.instance, .{@as(i32, if (open) 1 else 0)}) catch {};
}
