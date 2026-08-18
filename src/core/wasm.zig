//! wasm — the plugin sandbox runtime (milestone 5), over wasmtime's C
//! embedding API. This is the *membrane* the roadmap describes: the same
//! plugin ABI (abi.zig), but the guest is an untrusted `.wasm` component
//! instead of a linked-in Zig module, so the transport changes and the
//! shape does not. A guest crosses only bytes and opaque handles; it holds
//! no host pointer and reaches the world only through host imports the host
//! grants after the perm handshake.
//!
//! This file is the low-level runtime: engine, store, module compile,
//! instantiate, call exports, and define host imports (via a linker). The
//! `abi.zig` marshalling that turns Value/handle calls into wasm imports
//! rides on top. Wasmtime ships no pkg-config; build.zig links libwasmtime
//! from the nix shell's dev/lib outputs (see `addWasm`).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const c = @cImport({
    @cInclude("wasmtime.h");
});

pub const Error = error{ Compile, Instantiate, Call, Trap, MissingExport, BadType } || Allocator.Error;

/// Turn a wasmtime `*wasmtime_error_t` (null = ok) into a Zig error, logging
/// its message. Consumes the error object.
fn checkErr(err: ?*c.wasmtime_error_t, comptime tag: Error) Error!void {
    const e = err orelse return;
    var msg: c.wasm_byte_vec_t = undefined;
    c.wasmtime_error_message(e, &msg);
    std.log.err("wasm: {s}", .{msg.data[0..msg.size]});
    c.wasm_byte_vec_delete(&msg);
    c.wasmtime_error_delete(e);
    return tag;
}

fn checkTrap(trap: ?*c.wasm_trap_t) Error!void {
    const tr = trap orelse return;
    var msg: c.wasm_byte_vec_t = undefined;
    c.wasm_trap_message(tr, &msg);
    std.log.err("wasm trap: {s}", .{msg.data[0..msg.size]});
    c.wasm_byte_vec_delete(&msg);
    c.wasm_trap_delete(tr);
    return error.Trap;
}

/// One wasmtime engine — thread-safe, shareable across stores. Compiling a
/// module is engine-scoped; running it is store-scoped.
pub const Engine = struct {
    engine: *c.wasm_engine_t,

    pub fn init() Error!Engine {
        // Single-threaded compilation: wasmtime's default parallel path spins
        // up a persistent (process-lifetime) rayon worker pool that would
        // compete with weft's own frame/collab threads. Plugin modules are
        // small; the serial compile cost is negligible and the runtime stays
        // a good citizen among the editor's timing-sensitive subsystems.
        const config = c.wasm_config_new() orelse return error.OutOfMemory;
        c.wasmtime_config_parallel_compilation_set(config, false);
        return .{ .engine = c.wasm_engine_new_with_config(config) orelse return error.OutOfMemory };
    }

    pub fn deinit(self: *Engine) void {
        c.wasm_engine_delete(self.engine);
        self.* = undefined;
    }

    /// Compile a `.wasm` binary into a reusable module.
    pub fn compile(self: *Engine, wasm: []const u8) Error!Module {
        var module: ?*c.wasmtime_module_t = null;
        try checkErr(c.wasmtime_module_new(self.engine, wasm.ptr, wasm.len, &module), error.Compile);
        return .{ .module = module.? };
    }

    /// Reconstruct a module from a serialized compiled image (a `.cwasm` cache
    /// entry). Returns null on an incompatible/stale image — wasmtime validates
    /// the engine + version, so a cross-version cache is rejected safely and the
    /// caller falls back to a fresh `compile`. A miss is expected, not logged.
    pub fn deserialize(self: *Engine, image: []const u8) ?Module {
        var module: ?*c.wasmtime_module_t = null;
        const err = c.wasmtime_module_deserialize(self.engine, image.ptr, image.len, &module);
        if (err != null) {
            c.wasmtime_error_delete(err);
            return null;
        }
        return .{ .module = module.? };
    }
};

pub const Module = struct {
    module: *c.wasmtime_module_t,

    pub fn deinit(self: *Module) void {
        c.wasmtime_module_delete(self.module);
        self.* = undefined;
    }

    /// Serialize this module's compiled image into an owned byte slice, for the
    /// `.cwasm` cache. Caller frees. Errors are best-effort at the call site
    /// (a failed serialize just means we recompile next start).
    pub fn serialize(self: *const Module, gpa: Allocator) Error![]u8 {
        var vec: c.wasm_byte_vec_t = undefined;
        const err = c.wasmtime_module_serialize(self.module, &vec);
        if (err != null) {
            c.wasmtime_error_delete(err);
            return error.Compile;
        }
        defer c.wasm_byte_vec_delete(&vec);
        return gpa.dupe(u8, vec.data[0..vec.size]);
    }
};

/// A store holds one instance's state (memory, tables, host data). One store
/// per plugin instance; teardown is `deinit` (the hot-reload contract:
/// dropping the store re-instantiates cleanly, no shared mutable state).
pub const Instance = struct {
    store: *c.wasmtime_store_t,
    context: *c.wasmtime_context_t,
    instance: c.wasmtime_instance_t,

    /// Instantiate `module` in a fresh store with no imports.
    pub fn init(engine: *Engine, module: *Module) Error!Instance {
        const store = c.wasmtime_store_new(engine.engine, null, null) orelse return error.OutOfMemory;
        errdefer c.wasmtime_store_delete(store);
        const context = c.wasmtime_store_context(store).?;
        var instance: c.wasmtime_instance_t = undefined;
        var trap: ?*c.wasm_trap_t = null;
        try checkErr(c.wasmtime_instance_new(context, module.module, null, 0, &instance, &trap), error.Instantiate);
        try checkTrap(trap);
        return .{ .store = store, .context = context, .instance = instance };
    }

    pub fn deinit(self: *Instance) void {
        c.wasmtime_store_delete(self.store);
        self.* = undefined;
    }

    fn exportFunc(self: *Instance, name: []const u8) Error!c.wasmtime_func_t {
        var item: c.wasmtime_extern_t = undefined;
        if (!c.wasmtime_instance_export_get(self.context, &self.instance, name.ptr, name.len, &item))
            return error.MissingExport;
        if (item.kind != c.WASMTIME_EXTERN_FUNC) return error.BadType;
        return item.of.func;
    }

    /// Copy `len` bytes at `ptr` out of the guest's exported linear memory
    /// (bounds-checked). This is how bulk data (a Value's bytes, a command
    /// name, an edit's text) crosses the membrane — the guest writes its
    /// memory and passes `(ptr, len)`; the host copies out. Caller frees.
    pub fn readGuest(self: *Instance, gpa: Allocator, ptr: usize, len: usize) Error![]u8 {
        var item: c.wasmtime_extern_t = undefined;
        if (!c.wasmtime_instance_export_get(self.context, &self.instance, "memory", 6, &item))
            return error.MissingExport;
        if (item.kind != c.WASMTIME_EXTERN_MEMORY) return error.BadType;
        var mem = item.of.memory;
        const data = c.wasmtime_memory_data(self.context, &mem);
        const size = c.wasmtime_memory_data_size(self.context, &mem);
        if (ptr + len > size) return error.BadType;
        return gpa.dupe(u8, data[ptr .. ptr + len]);
    }

    /// Copy `bytes` INTO the guest's exported linear memory at `ptr`
    /// (bounds-checked). The host→guest bulk path for the reactor ABI: the
    /// host `malloc`s a buffer in the guest, writes source/data here, then
    /// calls an export over `(ptr, len)`. Mirrors `readGuest`.
    pub fn writeGuest(self: *Instance, ptr: usize, bytes: []const u8) Error!void {
        var item: c.wasmtime_extern_t = undefined;
        if (!c.wasmtime_instance_export_get(self.context, &self.instance, "memory", 6, &item))
            return error.MissingExport;
        if (item.kind != c.WASMTIME_EXTERN_MEMORY) return error.BadType;
        var mem = item.of.memory;
        const data = c.wasmtime_memory_data(self.context, &mem);
        const size = c.wasmtime_memory_data_size(self.context, &mem);
        if (ptr + bytes.len > size) return error.BadType;
        @memcpy(data[ptr .. ptr + bytes.len], bytes);
    }

    /// Call an exported `(iN…) -> ()` function (the common plugin export
    /// shape: side effects through host imports, no return).
    pub fn callVoid(self: *Instance, name: []const u8, args: []const i32) Error!void {
        var func = try self.exportFunc(name);
        var argv: [8]c.wasmtime_val_t = undefined;
        if (args.len > argv.len) return error.BadType;
        for (args, 0..) |a, i| argv[i] = .{ .kind = c.WASMTIME_I32, .of = .{ .i32 = a } };
        var trap: ?*c.wasm_trap_t = null;
        try checkErr(c.wasmtime_func_call(self.context, &func, &argv, args.len, null, 0, &trap), error.Call);
        try checkTrap(trap);
    }

    /// Call an exported `(iN…) -> i32` function with i32 args, returning the
    /// i32 result. The bulk-Value marshalling (abi.zig) builds on this.
    pub fn callI32(self: *Instance, name: []const u8, args: []const i32) Error!i32 {
        var func = try self.exportFunc(name);
        var argv: [8]c.wasmtime_val_t = undefined;
        if (args.len > argv.len) return error.BadType;
        for (args, 0..) |a, i| argv[i] = .{ .kind = c.WASMTIME_I32, .of = .{ .i32 = a } };
        var results: [1]c.wasmtime_val_t = undefined;
        var trap: ?*c.wasm_trap_t = null;
        try checkErr(c.wasmtime_func_call(self.context, &func, &argv, args.len, &results, 1, &trap), error.Call);
        try checkTrap(trap);
        if (results[0].kind != c.WASMTIME_I32) return error.BadType;
        return results[0].of.i32;
    }
};

/// A host↔guest membrane: the guest reaches the world ONLY through host
/// functions the host defines here (the perm gate). The guest holds no host
/// pointer; a call crosses as scalars/handles + the guest's linear memory
/// for bulk bytes. This is the transport plan 05 puts under the same
/// `abi.zig` ABI the in-process plugins already use.
pub const Linker = struct {
    linker: *c.wasmtime_linker_t,
    engine: *Engine,

    pub fn init(engine: *Engine) Error!Linker {
        return .{ .linker = c.wasmtime_linker_new(engine.engine) orelse return error.OutOfMemory, .engine = engine };
    }

    pub fn deinit(self: *Linker) void {
        c.wasmtime_linker_delete(self.linker);
        self.* = undefined;
    }

    /// The Zig-facing host-callback shape: `data` is the host context,
    /// `caller` lets the callback read the guest's memory (bulk args), and
    /// scalar args/results are i32 (the membrane's word). A real ABI import
    /// (edit, kv, log) reads its bytes from `caller.readMemory(ptr, len)`.
    pub const HostFn = *const fn (data: ?*anyopaque, caller: *Caller, args: []const i32, results: []i32) void;

    /// Define `module.name` as an `(i32×nparams) -> (i32×nresults)` host
    /// function backed by `func` — a host grant the guest may import.
    pub fn defineFn(self: *Linker, module: []const u8, name: []const u8, nparams: usize, nresults: usize, func: HostFn, data: ?*anyopaque) Error!void {
        const box = try std.heap.c_allocator.create(Boxed);
        box.* = .{ .func = func, .data = data };
        const ty = funcType(nparams, nresults);
        defer c.wasm_functype_delete(ty);
        try checkErr(c.wasmtime_linker_define_func(
            self.linker,
            module.ptr,
            module.len,
            name.ptr,
            name.len,
            ty,
            trampoline,
            box,
            finalizeBoxed,
        ), error.Instantiate);
    }

    // The boxed callback lives as long as the linker; wasmtime frees it via
    // the finalizer (c_allocator, so the finalizer can free symmetrically
    // without a Zig allocator handle).
    const Boxed = struct { func: HostFn, data: ?*anyopaque };

    /// Instantiate `module` with this linker's host imports satisfied.
    pub fn instantiate(self: *Linker, module: *Module) Error!Instance {
        const store = c.wasmtime_store_new(self.engine.engine, null, null) orelse return error.OutOfMemory;
        errdefer c.wasmtime_store_delete(store);
        const context = c.wasmtime_store_context(store).?;
        var instance: c.wasmtime_instance_t = undefined;
        var trap: ?*c.wasm_trap_t = null;
        try checkErr(c.wasmtime_linker_instantiate(self.linker, context, module.module, &instance, &trap), error.Instantiate);
        try checkTrap(trap);
        return .{ .store = store, .context = context, .instance = instance };
    }

    /// Satisfy the `wasi_snapshot_preview1` imports on this linker, for a WASI
    /// guest (e.g. `quickjs.wasm`, compiled to wasm32-wasi). Pair with
    /// `instantiateWasi`, which gives the store the matching WASI context.
    pub fn defineWasi(self: *Linker) Error!void {
        try checkErr(c.wasmtime_linker_define_wasi(self.linker), error.Instantiate);
    }

    /// Instantiate a WASI reactor `module`: a fresh store carrying a sandboxed
    /// WASI context (no stdio inherited — the config plane is pure compute, so
    /// the engine's stray `fd_write`s harmlessly fail rather than reach the
    /// terminal), with this linker's imports (WASI + any host grants) bound.
    /// `defineWasi` must have run on this linker first.
    pub fn instantiateWasi(self: *Linker, module: *Module) Error!Instance {
        const store = c.wasmtime_store_new(self.engine.engine, null, null) orelse return error.OutOfMemory;
        errdefer c.wasmtime_store_delete(store);
        const context = c.wasmtime_store_context(store).?;
        const wasi = c.wasi_config_new() orelse return error.OutOfMemory;
        // wasmtime takes ownership of the config here — no delete on our side.
        try checkErr(c.wasmtime_context_set_wasi(context, wasi), error.Instantiate);
        var instance: c.wasmtime_instance_t = undefined;
        var trap: ?*c.wasm_trap_t = null;
        try checkErr(c.wasmtime_linker_instantiate(self.linker, context, module.module, &instance, &trap), error.Instantiate);
        try checkTrap(trap);
        return .{ .store = store, .context = context, .instance = instance };
    }
};

/// Handed to a host callback: reads the calling guest's linear memory, so a
/// host import can pull its bulk bytes (an edit's text, a command name) out
/// of `(ptr, len)` scalar args.
pub const Caller = struct {
    context: *c.wasmtime_context_t,
    caller: *c.wasmtime_caller_t,

    pub fn readMemory(self: *Caller, gpa: Allocator, ptr: usize, len: usize) Error![]u8 {
        var item: c.wasmtime_extern_t = undefined;
        if (!c.wasmtime_caller_export_get(self.caller, "memory", 6, &item)) return error.MissingExport;
        if (item.kind != c.WASMTIME_EXTERN_MEMORY) return error.BadType;
        var mem = item.of.memory;
        const data = c.wasmtime_memory_data(self.context, &mem);
        const size = c.wasmtime_memory_data_size(self.context, &mem);
        if (ptr + len > size) return error.BadType;
        return gpa.dupe(u8, data[ptr .. ptr + len]);
    }

    /// Write `bytes` into the guest's linear memory at `[ptr, ptr+cap)`,
    /// truncated to `cap` (bounds-checked). Returns the number of bytes
    /// written. This is the host→guest return path for the read primitives
    /// (`slice`, `kvGet`): the guest passes a scratch buffer `(ptr, cap)`, the
    /// host fills it, the guest reads back the returned length.
    pub fn writeMemory(self: *Caller, ptr: usize, cap: usize, bytes: []const u8) Error!usize {
        var item: c.wasmtime_extern_t = undefined;
        if (!c.wasmtime_caller_export_get(self.caller, "memory", 6, &item)) return error.MissingExport;
        if (item.kind != c.WASMTIME_EXTERN_MEMORY) return error.BadType;
        var mem = item.of.memory;
        const data = c.wasmtime_memory_data(self.context, &mem);
        const size = c.wasmtime_memory_data_size(self.context, &mem);
        if (ptr + cap > size) return error.BadType;
        const n = @min(cap, bytes.len);
        @memcpy(data[ptr .. ptr + n], bytes[0..n]);
        return n;
    }
};

fn trampoline(
    env: ?*anyopaque,
    caller_ptr: ?*c.wasmtime_caller_t,
    args: [*c]const c.wasmtime_val_t,
    nargs: usize,
    results: [*c]c.wasmtime_val_t,
    nresults: usize,
) callconv(.c) ?*c.wasm_trap_t {
    const box: *Linker.Boxed = @ptrCast(@alignCast(env.?));
    var abuf: [16]i32 = undefined;
    var rbuf: [8]i32 = @splat(0);
    var i: usize = 0;
    while (i < nargs and i < abuf.len) : (i += 1) abuf[i] = args[i].of.i32;
    var caller: Caller = .{ .context = c.wasmtime_caller_context(caller_ptr).?, .caller = caller_ptr.? };
    box.func(box.data, &caller, abuf[0..@min(nargs, abuf.len)], rbuf[0..@min(nresults, rbuf.len)]);
    i = 0;
    while (i < nresults and i < rbuf.len) : (i += 1) results[i] = .{ .kind = c.WASMTIME_I32, .of = .{ .i32 = rbuf[i] } };
    return null;
}

fn finalizeBoxed(env: ?*anyopaque) callconv(.c) void {
    std.heap.c_allocator.destroy(@as(*Linker.Boxed, @ptrCast(@alignCast(env.?))));
}

/// Build a `wasm_functype_t` of `nparams` i32 params → `nresults` i32
/// results (the only shape the membrane needs at this layer).
fn funcType(nparams: usize, nresults: usize) *c.wasm_functype_t {
    var pbuf: [8]?*c.wasm_valtype_t = undefined;
    var rbuf: [8]?*c.wasm_valtype_t = undefined;
    for (0..nparams) |i| pbuf[i] = c.wasm_valtype_new(c.WASM_I32);
    for (0..nresults) |i| rbuf[i] = c.wasm_valtype_new(c.WASM_I32);
    var params: c.wasm_valtype_vec_t = undefined;
    var results: c.wasm_valtype_vec_t = undefined;
    c.wasm_valtype_vec_new(&params, nparams, &pbuf);
    c.wasm_valtype_vec_new(&results, nresults, &rbuf);
    return c.wasm_functype_new(&params, &results).?;
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

// A hand-assembled wasm module exporting `add(i32,i32)->i32` — proves the
// runtime compiles, instantiates, and calls guest code end to end.
const add_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // \0asm, version 1
    0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f, // type: (i32 i32)->i32
    0x03, 0x02, 0x01, 0x00, // func: one, type 0
    0x07, 0x07, 0x01, 0x03, 0x61, 0x64, 0x64, 0x00, 0x00, // export "add" = func 0
    0x0a, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x6a, 0x0b, // code: local.get 0/1, i32.add
};

test "wasm: compile, instantiate, and call a guest export" {
    var engine = try Engine.init();
    defer engine.deinit();
    var module = try engine.compile(&add_wasm);
    defer module.deinit();
    var instance = try Instance.init(&engine, &module);
    defer instance.deinit();

    try t.expectEqual(@as(i32, 15), try instance.callI32("add", &.{ 7, 8 }));
    try t.expectEqual(@as(i32, -1), try instance.callI32("add", &.{ 41, -42 }));
    try t.expectError(error.MissingExport, instance.callI32("nope", &.{}));
}

// A guest that IMPORTS `env.host_add1 : (i32)->i32` and EXPORTS
// `run(x) = host_add1(host_add1(x))` — proves the sandbox membrane: the
// guest reaches the host only through the granted import.
const import_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x06, 0x01, 0x60, 0x01, 0x7f, 0x01, 0x7f, // type0: (i32)->i32
    // import "env" "host_add1" func type0
    0x02, 0x11, 0x01, 0x03, 0x65, 0x6e, 0x76, 0x09,
    0x68, 0x6f, 0x73, 0x74, 0x5f, 0x61, 0x64, 0x64,
    0x31, 0x00, 0x00,
    0x03, 0x02, 0x01, 0x00, // func "run" type0 (func index 1; import is 0)
    0x07, 0x07, 0x01, 0x03, 0x72, 0x75, 0x6e, 0x00, 0x01, // export "run" = func 1
    // code: local.get 0; call 0; call 0; end
    0x0a, 0x0a, 0x01, 0x08, 0x00, 0x20, 0x00, 0x10, 0x00,
    0x10, 0x00, 0x0b,
};

var host_calls: usize = 0;
fn hostAdd1(data: ?*anyopaque, caller: *Caller, args: []const i32, results: []i32) void {
    _ = data;
    _ = caller;
    host_calls += 1;
    results[0] = args[0] + 1;
}

test "wasm: the guest reaches the host only through a defined import" {
    host_calls = 0;
    var engine = try Engine.init();
    defer engine.deinit();
    var module = try engine.compile(&import_wasm);
    defer module.deinit();

    var linker = try Linker.init(&engine);
    defer linker.deinit();
    try linker.defineFn("env", "host_add1", 1, 1, hostAdd1, null);

    var instance = try linker.instantiate(&module);
    defer instance.deinit();

    // run(5) = host_add1(host_add1(5)) = 7, and the host func ran twice —
    // the guest reached the host only through the granted import.
    try t.expectEqual(@as(i32, 7), try instance.callI32("run", &.{5}));
    try t.expectEqual(@as(usize, 2), host_calls);
    // (A guest whose import is undefined fails to instantiate — wasmtime
    // rejects it with "unknown import"; grants reach explicitly, never
    // ambiently. Not asserted here because that path logs the rejection,
    // which the test runner treats as a failure.)
}

// A guest exporting `memory` + `strptr() -> i32` (a pointer to "hi" in its
// linear memory) — proves the host can copy bulk bytes out of the guest.
const mem_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, // type0: ()->i32
    0x03, 0x02, 0x01, 0x00, // func "strptr" type0
    0x05, 0x03, 0x01, 0x00, 0x01, // memory: 1 page
    // exports: "memory"(mem 0), "strptr"(func 0)
    0x07, 0x13, 0x02, 0x06, 0x6d,
    0x65, 0x6d, 0x6f, 0x72, 0x79,
    0x02, 0x00, 0x06, 0x73, 0x74,
    0x72, 0x70, 0x74, 0x72, 0x00,
    0x00,
    0x0a, 0x06, 0x01, 0x04, 0x00, 0x41, 0x00, 0x0b, // code: i32.const 0 (section 10 before 11)
    0x0b, 0x08, 0x01, 0x00, 0x41, 0x00, 0x0b, 0x02, 0x68, 0x69, // data: "hi" at offset 0
};

test "wasm: the host copies bulk bytes out of the guest's linear memory" {
    const gpa = t.allocator;
    var engine = try Engine.init();
    defer engine.deinit();
    var module = try engine.compile(&mem_wasm);
    defer module.deinit();
    var instance = try Instance.init(&engine, &module);
    defer instance.deinit();

    const ptr: usize = @intCast(try instance.callI32("strptr", &.{}));
    const bytes = try instance.readGuest(gpa, ptr, 2);
    defer gpa.free(bytes);
    try t.expectEqualStrings("hi", bytes);
}

test {
    std.testing.refAllDecls(@This());
}
