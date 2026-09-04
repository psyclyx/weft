# Plugin ABI Preflight Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build phase 1b-I's bounded Wasmtime module-interface inspection and parameterized pure ABI preflight policy without changing the plugin ABI or production loader.

**Architecture:** `wasm.Module.inspectInterface` copies compiled-module imports and exports into one arena-owned transport snapshot under explicit limits. `wasm_abi/preflight.zig` validates a borrowed snapshot against a validated, injected contract; it has no Wasmtime calls or dependency on today's membrane namespace. A focused `test-plugin-abi` build step runs both units and becomes the gate phase 1b-II will extend.

**Tech Stack:** Zig 0.16, Wasmtime C API 47.0.3, `std.heap.ArenaAllocator`, Zig build graph, Nix shell.

## Global Constraints

- Scope is phase 1b-I of `docs/superpowers/specs/2026-09-03-plugin-abi-negotiation-design.md` only.
- Production `loadPlugin`, membrane namespaces/rows, SDK declarations, bundled plugins, and embedded guest artifacts MUST remain unchanged.
- Runtime plugin behavior and the 231-import / 18-export / 249-semantic-operation census MUST remain unchanged.
- Module inspection limits are exactly: 1,024 imports, 1,024 exports, 256 bytes per module/field/export name, 16 function parameters, 8 function results, and 256 KiB total copied name bytes.
- Equality with every limit is accepted; `limit + 1` is refused.
- Interface snapshots own copied data in one `std.heap.ArenaAllocator`; Wasmtime vectors are always deleted before return; allocation failure and limit refusal leak nothing.
- Preflight borrows `*const OwnedInterface` and `*const Contract`; it takes ownership of neither and allocates nothing.
- Reserved prefix is `weft:abi/`; retired legacy import namespace is `weft`.
- Canonical majors use `[1-9][0-9]*`, no sign or leading zero. Major comparison is textual; it cannot overflow.
- Contract logical names use `[a-z][a-z0-9_]*`.
- The fixed required full-plugin callback is `init`; `run` is forbidden from callback and frozen-legacy rows but remains legal as an import field.
- Tests and builds MUST run inside `nix-shell`.
- Use TDD: observe each new contract fail before implementation.
- Commit each task independently; do not add compatibility code, source scanning, custom-section parsing, exported metadata, or production loader integration.

---

## File structure

- **Modify `src/core/wasm.zig`** — transport-only extern kinds, owned module-interface snapshot, bounded Wasmtime import/export inspection, and low-level tests.
- **Create `src/core/wasm_abi/preflight.zig`** — pure contract validation, reserved-name parsing, compatibility refusals, and synthetic matrix tests.
- **Create `src/core/plugin_abi_tests.zig`** — focused test root that owns the two units without importing the rest of core.
- **Modify `build.zig`** — add `test-plugin-abi`, wired with the same Wasmtime include/library/cache options as core.

---

### Task 1: Bounded Wasmtime module-interface inspection

**Files:**
- Modify: `src/core/wasm.zig:15-24,236-263,564-712`
- Create: `src/core/plugin_abi_tests.zig`
- Modify: `build.zig:902-960`
- Test: `src/core/wasm.zig`

**Interfaces:**
- Consumes: Wasmtime C APIs `wasmtime_module_imports`, `wasmtime_module_exports`, `wasm_importtype_*`, `wasm_exporttype_*`, `wasm_externtype_*`, `wasm_functype_*`, and `wasm_valtype_kind`.
- Produces:
  - `pub const ExternKind`, whose discriminants come directly from Wasmtime's `c.WASM_EXTERN_*` constants.
  - `pub const ValKind`, whose discriminants come directly from Wasmtime's `c.WASM_*` value-kind constants.
  - `pub const ExternType = struct { kind: ExternKind, params: []const ValKind = &.{}, results: []const ValKind = &.{} };`
  - `pub const ModuleImport = struct { module: []const u8, name: []const u8, ty: ExternType };`
  - `pub const ModuleExport = struct { name: []const u8, ty: ExternType };`
  - `pub const InterfaceLimits` with the approved defaults.
  - `pub const InterfaceLimit { kind, limit, found }` and `LimitKind`.
  - `pub const OwnedInterface { arena, imports, exports, deinit }`.
  - `pub const Inspection = union(enum) { interface: OwnedInterface, limit: InterfaceLimit };`
  - `pub fn Module.inspectInterface(self: *const Module, gpa: Allocator, limits: InterfaceLimits) Allocator.Error!Inspection`.
  - `zig build test-plugin-abi`.

- [ ] **Step 1: Add the focused build root and step**

Create `src/core/plugin_abi_tests.zig`:

```zig
test {
    _ = @import("wasm.zig");
}
```

In `build.zig`, immediately after the portable `test-contract` wiring, add:

```zig
const plugin_abi_test_mod = b.createModule(.{
    .root_source_file = b.path("src/core/plugin_abi_tests.zig"),
    .target = target,
    .optimize = optimize,
    .link_libc = true,
});
addWasm(b, plugin_abi_test_mod);
const plugin_abi_tests = b.addTest(.{ .root_module = plugin_abi_test_mod });
const plugin_abi_step = b.step(
    "test-plugin-abi",
    "Run focused Wasmtime interface and plugin ABI preflight tests",
);
plugin_abi_step.dependOn(&b.addRunArtifact(plugin_abi_tests).step);
```

Run:

```bash
nix-shell --run 'zig build test-plugin-abi --summary all'
```

Expected: PASS using only the existing `wasm.zig` tests. This step establishes the focused harness; it is not the RED for inspection.

- [ ] **Step 2: Write the failing interface-copy test**

After `import_wasm` in `src/core/wasm.zig`, add:

```zig
test "wasm: module interface owns import and export function types" {
    const gpa = t.allocator;
    var engine = try Engine.init(gpa);
    defer engine.deinit();
    var module = try engine.compile(&import_wasm);
    defer module.deinit();

    var inspection = try module.inspectInterface(gpa, .{});
    switch (inspection) {
        .limit => return error.TestUnexpectedResult,
        .interface => |*interface| {
            defer interface.deinit();
            try t.expectEqual(@as(usize, 1), interface.imports.len);
            try t.expectEqualStrings("env", interface.imports[0].module);
            try t.expectEqualStrings("host_add1", interface.imports[0].name);
            try t.expectEqual(ExternKind.function, interface.imports[0].ty.kind);
            try t.expectEqualSlices(ValKind, &.{.i32}, interface.imports[0].ty.params);
            try t.expectEqualSlices(ValKind, &.{.i32}, interface.imports[0].ty.results);

            try t.expectEqual(@as(usize, 1), interface.exports.len);
            try t.expectEqualStrings("run", interface.exports[0].name);
            try t.expectEqual(ExternKind.function, interface.exports[0].ty.kind);
            try t.expectEqualSlices(ValKind, &.{.i32}, interface.exports[0].ty.params);
            try t.expectEqualSlices(ValKind, &.{.i32}, interface.exports[0].ty.results);
        },
    }
}
```

- [ ] **Step 3: Write failing non-function and boundary tests**

Add these test helpers and tests after the interface-copy test:

```zig
fn expectInterface(module: *const Module, gpa: Allocator, limits: InterfaceLimits) !OwnedInterface {
    const inspection = try module.inspectInterface(gpa, limits);
    return switch (inspection) {
        .interface => |interface| interface,
        .limit => error.TestUnexpectedResult,
    };
}

fn expectLimit(
    module: *const Module,
    limits: InterfaceLimits,
    kind: LimitKind,
    maximum: usize,
    found: usize,
) !void {
    var inspection = try module.inspectInterface(t.allocator, limits);
    switch (inspection) {
        .interface => |*interface| {
            interface.deinit();
            return error.TestUnexpectedResult;
        },
        .limit => |got| {
            try t.expectEqual(kind, got.kind);
            try t.expectEqual(maximum, got.limit);
            try t.expectEqual(found, got.found);
        },
    }
}

test "wasm: module interface preserves non-function export kind" {
    const gpa = t.allocator;
    var engine = try Engine.init(gpa);
    defer engine.deinit();
    var module = try engine.compile(&mem_wasm);
    defer module.deinit();
    var interface = try expectInterface(&module, gpa, .{});
    defer interface.deinit();

    try t.expectEqualStrings("memory", interface.exports[0].name);
    try t.expectEqual(ExternKind.memory, interface.exports[0].ty.kind);
    try t.expectEqual(@as(usize, 0), interface.exports[0].ty.params.len);
    try t.expectEqual(@as(usize, 0), interface.exports[0].ty.results.len);
}

test "wasm: module interface limits accept equality and refuse limit plus one" {
    const gpa = t.allocator;
    var engine = try Engine.init(gpa);
    defer engine.deinit();
    var imported = try engine.compile(&import_wasm);
    defer imported.deinit();
    var memory = try engine.compile(&mem_wasm);
    defer memory.deinit();

    var at_limit = try expectInterface(&imported, gpa, .{
        .imports = 1,
        .exports = 1,
        .name_bytes = 9,
        .params = 1,
        .results = 1,
        .total_name_bytes = 15,
    });
    at_limit.deinit();

    // Field equality is covered by `host_add1` above. These two checks make
    // module-name and export-name equality observable independently.
    try expectLimit(&imported, .{ .name_bytes = 3 }, .field_name, 3, 9);
    var export_name_at_limit = try expectInterface(&memory, gpa, .{ .name_bytes = 6 });
    export_name_at_limit.deinit();

    try expectLimit(&imported, .{ .imports = 0 }, .imports, 0, 1);
    try expectLimit(&memory, .{ .exports = 1 }, .exports, 1, 2);
    try expectLimit(&imported, .{ .name_bytes = 2 }, .module_name, 2, 3);
    try expectLimit(&imported, .{ .name_bytes = 8 }, .field_name, 8, 9);
    try expectLimit(&memory, .{ .name_bytes = 5 }, .export_name, 5, 6);
    try expectLimit(&imported, .{ .params = 0 }, .params, 0, 1);
    try expectLimit(&imported, .{ .results = 0 }, .results, 0, 1);
    try expectLimit(&imported, .{ .total_name_bytes = 14 }, .total_name_bytes, 14, 15);
}
```

- [ ] **Step 4: Add failing serialization and allocation-failure tests**

Add:

```zig
const empty_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
};

// One imported ()->() function with empty module and field names, exported
// again under an empty name. Empty names and zero-arity vectors are legal.
const empty_names_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x04, 0x01, 0x60, 0x00, 0x00,
    0x02, 0x05, 0x01, 0x00, 0x00, 0x00, 0x00,
    0x07, 0x04, 0x01, 0x00, 0x00, 0x00,
};

test "wasm: module interface default limits are the approved production bounds" {
    const limits: InterfaceLimits = .{};
    try t.expectEqual(@as(usize, 1024), limits.imports);
    try t.expectEqual(@as(usize, 1024), limits.exports);
    try t.expectEqual(@as(usize, 256), limits.name_bytes);
    try t.expectEqual(@as(usize, 16), limits.params);
    try t.expectEqual(@as(usize, 8), limits.results);
    try t.expectEqual(@as(usize, 256 * 1024), limits.total_name_bytes);
}

test "wasm: module interface handles null vectors and legal empty names" {
    const gpa = t.allocator;
    var engine = try Engine.init(gpa);
    defer engine.deinit();

    var empty_module = try engine.compile(&empty_wasm);
    defer empty_module.deinit();
    var empty_interface = try expectInterface(&empty_module, gpa, .{});
    defer empty_interface.deinit();
    try t.expectEqual(@as(usize, 0), empty_interface.imports.len);
    try t.expectEqual(@as(usize, 0), empty_interface.exports.len);

    var named_module = try engine.compile(&empty_names_wasm);
    defer named_module.deinit();
    var named_interface = try expectInterface(&named_module, gpa, .{});
    defer named_interface.deinit();
    try t.expectEqual(@as(usize, 0), named_interface.imports[0].module.len);
    try t.expectEqual(@as(usize, 0), named_interface.imports[0].name.len);
    try t.expectEqual(@as(usize, 0), named_interface.imports[0].ty.params.len);
    try t.expectEqual(@as(usize, 0), named_interface.imports[0].ty.results.len);
    try t.expectEqual(@as(usize, 0), named_interface.exports[0].name.len);
}

fn expectSameInterface(a: *const OwnedInterface, b: *const OwnedInterface) !void {
    try t.expectEqual(a.imports.len, b.imports.len);
    try t.expectEqual(a.exports.len, b.exports.len);
    for (a.imports, b.imports) |left, right| {
        try t.expectEqualStrings(left.module, right.module);
        try t.expectEqualStrings(left.name, right.name);
        try t.expectEqual(left.ty.kind, right.ty.kind);
        try t.expectEqualSlices(ValKind, left.ty.params, right.ty.params);
        try t.expectEqualSlices(ValKind, left.ty.results, right.ty.results);
    }
    for (a.exports, b.exports) |left, right| {
        try t.expectEqualStrings(left.name, right.name);
        try t.expectEqual(left.ty.kind, right.ty.kind);
        try t.expectEqualSlices(ValKind, left.ty.params, right.ty.params);
        try t.expectEqualSlices(ValKind, left.ty.results, right.ty.results);
    }
}

test "wasm: serialized module preserves the inspected interface" {
    const gpa = t.allocator;
    var engine = try Engine.init(gpa);
    defer engine.deinit();
    var module = try engine.compile(&import_wasm);
    defer module.deinit();
    const image = try module.serialize(gpa);
    defer gpa.free(image);
    var restored = engine.deserialize(image) orelse return error.TestUnexpectedResult;
    defer restored.deinit();

    var original_interface = try expectInterface(&module, gpa, .{});
    defer original_interface.deinit();
    var restored_interface = try expectInterface(&restored, gpa, .{});
    defer restored_interface.deinit();
    try expectSameInterface(&original_interface, &restored_interface);
}

fn inspectAllocationFailureCase(gpa: Allocator, module: *const Module) !void {
    var inspection = try module.inspectInterface(gpa, .{});
    switch (inspection) {
        .interface => |*interface| interface.deinit(),
        .limit => return error.TestUnexpectedResult,
    }
}

test "wasm: interface inspection frees every partial allocation" {
    var engine = try Engine.init(t.allocator);
    defer engine.deinit();
    var module = try engine.compile(&import_wasm);
    defer module.deinit();
    try t.checkAllAllocationFailures(t.allocator, inspectAllocationFailureCase, .{&module});
}
```

- [ ] **Step 5: Run RED for the complete inspection contract**

Run:

```bash
nix-shell --run 'zig build test-plugin-abi --summary all'
```

Expected: FAIL because `Module.inspectInterface`, `ExternKind`, and `ValKind` are undeclared.

- [ ] **Step 6: Add the transport data model**

Immediately before `pub const Module`, add:

```zig
pub const ExternKind = enum(u8) {
    function = c.WASM_EXTERN_FUNC,
    global = c.WASM_EXTERN_GLOBAL,
    table = c.WASM_EXTERN_TABLE,
    memory = c.WASM_EXTERN_MEMORY,
    tag = c.WASM_EXTERN_TAG,
    _,
};

pub const ValKind = enum(u8) {
    i32 = c.WASM_I32,
    i64 = c.WASM_I64,
    f32 = c.WASM_F32,
    f64 = c.WASM_F64,
    externref = c.WASM_EXTERNREF,
    funcref = c.WASM_FUNCREF,
    _,
};

pub const ExternType = struct {
    kind: ExternKind,
    params: []const ValKind = &.{},
    results: []const ValKind = &.{},
};

pub const ModuleImport = struct {
    module: []const u8,
    name: []const u8,
    ty: ExternType,
};

pub const ModuleExport = struct {
    name: []const u8,
    ty: ExternType,
};

pub const InterfaceLimits = struct {
    imports: usize = 1024,
    exports: usize = 1024,
    name_bytes: usize = 256,
    params: usize = 16,
    results: usize = 8,
    total_name_bytes: usize = 256 * 1024,
};

pub const LimitKind = enum {
    imports,
    exports,
    module_name,
    field_name,
    export_name,
    params,
    results,
    total_name_bytes,
};

pub const InterfaceLimit = struct {
    kind: LimitKind,
    limit: usize,
    found: usize,
};

pub const OwnedInterface = struct {
    arena: std.heap.ArenaAllocator,
    imports: []const ModuleImport,
    exports: []const ModuleExport,

    pub fn deinit(self: *OwnedInterface) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Inspection = union(enum) {
    interface: OwnedInterface,
    limit: InterfaceLimit,
};
```

- [ ] **Step 7: Implement bounded two-pass inspection**

Add these helpers before `Module`:

```zig
fn limit(kind: LimitKind, maximum: usize, found: usize) Inspection {
    return .{ .limit = .{ .kind = kind, .limit = maximum, .found = found } };
}

fn nameSlice(name: *const c.wasm_name_t) []const u8 {
    if (name.size == 0) return &.{};
    return name.data[0..name.size];
}

fn checkedNameTotal(total: *usize, n: usize, maximum: usize) ?Inspection {
    total.* = std.math.add(usize, total.*, n) catch return limit(
        .total_name_bytes,
        maximum,
        std.math.maxInt(usize),
    );
    if (total.* > maximum) return limit(.total_name_bytes, maximum, total.*);
    return null;
}

fn checkExternLimits(ty: *const c.wasm_externtype_t, limits: InterfaceLimits) ?Inspection {
    if (c.wasm_externtype_kind(ty) != c.WASM_EXTERN_FUNC) return null;
    const fn_ty = c.wasm_externtype_as_functype_const(ty).?;
    const params = c.wasm_functype_params(fn_ty);
    const results = c.wasm_functype_results(fn_ty);
    if (params.size > limits.params) return limit(.params, limits.params, params.size);
    if (results.size > limits.results) return limit(.results, limits.results, results.size);
    return null;
}

fn copyValKinds(
    arena: Allocator,
    values: *const c.wasm_valtype_vec_t,
) Allocator.Error![]const ValKind {
    if (values.size == 0) return &.{};
    const out = try arena.alloc(ValKind, values.size);
    for (0..values.size) |i| {
        out[i] = @enumFromInt(c.wasm_valtype_kind(values.data[i].?));
    }
    return out;
}

fn copyExternType(arena: Allocator, ty: *const c.wasm_externtype_t) Allocator.Error!ExternType {
    const kind: ExternKind = @enumFromInt(c.wasm_externtype_kind(ty));
    if (kind != .function) return .{ .kind = kind };
    const fn_ty = c.wasm_externtype_as_functype_const(ty).?;
    return .{
        .kind = .function,
        .params = try copyValKinds(arena, c.wasm_functype_params(fn_ty)),
        .results = try copyValKinds(arena, c.wasm_functype_results(fn_ty)),
    };
}
```

Add `inspectInterface` to `Module` after `clone` and before `serialize`:

```zig
pub fn inspectInterface(
    self: *const Module,
    gpa: Allocator,
    limits: InterfaceLimits,
) Allocator.Error!Inspection {
    var raw_imports: c.wasm_importtype_vec_t = undefined;
    c.wasmtime_module_imports(self.module, &raw_imports);
    defer c.wasm_importtype_vec_delete(&raw_imports);

    var raw_exports: c.wasm_exporttype_vec_t = undefined;
    c.wasmtime_module_exports(self.module, &raw_exports);
    defer c.wasm_exporttype_vec_delete(&raw_exports);

    if (raw_imports.size > limits.imports)
        return limit(.imports, limits.imports, raw_imports.size);
    if (raw_exports.size > limits.exports)
        return limit(.exports, limits.exports, raw_exports.size);

    var total_names: usize = 0;
    for (0..raw_imports.size) |i| {
        const entry = raw_imports.data[i].?;
        const module_name = nameSlice(c.wasm_importtype_module(entry).?);
        const field_name = nameSlice(c.wasm_importtype_name(entry).?);
        if (module_name.len > limits.name_bytes)
            return limit(.module_name, limits.name_bytes, module_name.len);
        if (field_name.len > limits.name_bytes)
            return limit(.field_name, limits.name_bytes, field_name.len);
        if (checkedNameTotal(&total_names, module_name.len, limits.total_name_bytes)) |result|
            return result;
        if (checkedNameTotal(&total_names, field_name.len, limits.total_name_bytes)) |result|
            return result;
        if (checkExternLimits(c.wasm_importtype_type(entry).?, limits)) |result| return result;
    }
    for (0..raw_exports.size) |i| {
        const entry = raw_exports.data[i].?;
        const export_name = nameSlice(c.wasm_exporttype_name(entry).?);
        if (export_name.len > limits.name_bytes)
            return limit(.export_name, limits.name_bytes, export_name.len);
        if (checkedNameTotal(&total_names, export_name.len, limits.total_name_bytes)) |result|
            return result;
        if (checkExternLimits(c.wasm_exporttype_type(entry).?, limits)) |result| return result;
    }

    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const allocator = arena.allocator();
    const imports = try allocator.alloc(ModuleImport, raw_imports.size);
    const exports = try allocator.alloc(ModuleExport, raw_exports.size);

    for (0..raw_imports.size) |i| {
        const entry = raw_imports.data[i].?;
        imports[i] = .{
            .module = try allocator.dupe(u8, nameSlice(c.wasm_importtype_module(entry).?)),
            .name = try allocator.dupe(u8, nameSlice(c.wasm_importtype_name(entry).?)),
            .ty = try copyExternType(allocator, c.wasm_importtype_type(entry).?),
        };
    }
    for (0..raw_exports.size) |i| {
        const entry = raw_exports.data[i].?;
        exports[i] = .{
            .name = try allocator.dupe(u8, nameSlice(c.wasm_exporttype_name(entry).?)),
            .ty = try copyExternType(allocator, c.wasm_exporttype_type(entry).?),
        };
    }

    return .{ .interface = .{
        .arena = arena,
        .imports = imports,
        .exports = exports,
    } };
}
```

- [ ] **Step 8: Run GREEN for all inspection behavior**

Run:

```bash
nix-shell --run 'zig build test-plugin-abi --summary all'
```

Expected: all focused Wasmtime tests pass, including copied function metadata,
non-function extern kinds, every limit boundary, serialized/deserialized
equivalence, and all allocation-failure points.

- [ ] **Step 9: Run the full regression gate for the Task 1 commit**

Run:

```bash
nix-shell --run 'zig build test --summary all'
```

Expected: all build steps pass before Task 1 is committed.

- [ ] **Step 10: Commit Task 1**

```bash
git add src/core/wasm.zig src/core/plugin_abi_tests.zig build.zig
git commit -m "feat(wasm): inspect bounded module interfaces"
```

---

### Task 2: Parameterized pure ABI preflight policy

**Files:**
- Create: `src/core/wasm_abi/preflight.zig`
- Modify: `src/core/plugin_abi_tests.zig`
- Test: `src/core/wasm_abi/preflight.zig`

**Interfaces:**
- Consumes: Task 1's `wasm.OwnedInterface`, `ModuleImport`, `ModuleExport`, and `ExternType`.
- Produces:
  - `pub const ContractRow = struct { name: []const u8, ty: wasm.ExternType };`
  - `pub const ContractSpec` and validated borrowed `Contract`.
  - `pub const ContractError` with one error per declared invariant.
  - `pub fn Contract.init(spec: ContractSpec) ContractError!Contract`.
  - `pub const Direction = enum { guest_import, host_callback };`
  - structured `Refusal` with direct `expected` and `found` type fields.
  - `pub fn validate(interface: *const wasm.OwnedInterface, contract: *const Contract) ?Refusal`.

- [ ] **Step 1: Create failing contract-validation tests**

Create `src/core/wasm_abi/preflight.zig` with only the imports and the tests
below; their references to `ContractRow`, `ContractSpec`, and `Contract` are
the wished-for API and must fail before those production declarations exist.
Add `_ = @import("wasm_abi/preflight.zig");` to
`src/core/plugin_abi_tests.zig`.

```zig
const std = @import("std");
const wasm = @import("../wasm.zig");
const t = std.testing;

const void_fn: wasm.ExternType = .{ .kind = .function };
const i32_fn: wasm.ExternType = .{ .kind = .function, .params = &.{.i32} };
const i32_result_fn: wasm.ExternType = .{ .kind = .function, .results = &.{.i32} };
const valid_imports = [_]ContractRow{
    .{ .name = "wl_log", .ty = i32_fn },
    .{ .name = "wl_result", .ty = i32_result_fn },
    .{ .name = "run", .ty = void_fn },
};
const valid_callbacks = [_]ContractRow{
    .{ .name = "init", .ty = void_fn },
    .{ .name = "describe", .ty = void_fn },
    .{ .name = "on_command", .ty = i32_fn },
    .{ .name = "on_result", .ty = i32_result_fn },
};
const valid_legacy = [_][]const u8{ "init", "describe", "on_command" };

fn validSpec() ContractSpec {
    return .{
        .major = "1",
        .namespace = "weft:abi/1",
        .export_prefix = "weft:abi/1/",
        .imports = &valid_imports,
        .callbacks = &valid_callbacks,
        .legacy_callbacks = &valid_legacy,
    };
}

test "preflight contract accepts its canonical consistent shape" {
    _ = try Contract.init(validSpec());
}

test "preflight contract rejects identity disagreement" {
    var spec = validSpec();
    spec.major = "01";
    try t.expectError(error.InvalidMajor, Contract.init(spec));
    spec = validSpec();
    spec.namespace = "weft:abi/2";
    try t.expectError(error.InvalidNamespace, Contract.init(spec));
    spec = validSpec();
    spec.export_prefix = "weft:abi/1x/";
    try t.expectError(error.InvalidExportPrefix, Contract.init(spec));
}

test "preflight contract rejects invalid and duplicate logical names" {
    var imports = valid_imports;
    imports[1].name = "Bad-name";
    var spec = validSpec();
    spec.imports = &imports;
    try t.expectError(error.InvalidLogicalName, Contract.init(spec));

    imports = valid_imports;
    imports[1].name = "wl_log";
    spec = validSpec();
    spec.imports = &imports;
    try t.expectError(error.DuplicateImport, Contract.init(spec));

    var callbacks = valid_callbacks;
    callbacks[2].name = "describe";
    spec = validSpec();
    spec.callbacks = &callbacks;
    try t.expectError(error.DuplicateCallback, Contract.init(spec));

    var legacy = valid_legacy;
    legacy[2] = "describe";
    spec = validSpec();
    spec.legacy_callbacks = &legacy;
    try t.expectError(error.DuplicateLegacyCallback, Contract.init(spec));
}

test "preflight contract pins init, legacy subset, and mini-ABI exclusion" {
    var callbacks = valid_callbacks;
    callbacks[0].name = "start";
    var spec = validSpec();
    spec.callbacks = &callbacks;
    try t.expectError(error.MissingInit, Contract.init(spec));

    callbacks = valid_callbacks;
    callbacks[1].name = "init";
    spec = validSpec();
    spec.callbacks = &callbacks;
    try t.expectError(error.DuplicateCallback, Contract.init(spec));

    var legacy = valid_legacy;
    legacy[2] = "not_a_callback";
    spec = validSpec();
    spec.legacy_callbacks = &legacy;
    try t.expectError(error.UnknownLegacyCallback, Contract.init(spec));

    callbacks = valid_callbacks;
    callbacks[2].name = "run";
    spec = validSpec();
    spec.callbacks = &callbacks;
    try t.expectError(error.MiniAbiRun, Contract.init(spec));

    legacy = valid_legacy;
    legacy[2] = "run";
    spec = validSpec();
    spec.legacy_callbacks = &legacy;
    try t.expectError(error.MiniAbiRun, Contract.init(spec));
}

```

- [ ] **Step 2: Run RED for `Contract`**

Run:

```bash
nix-shell --run 'zig build test-plugin-abi --summary all'
```

Expected: FAIL because `Contract` and its error set are undeclared.

- [ ] **Step 3: Implement contract validation**

Insert before the fixtures:

```zig
pub const ContractRow = struct {
    name: []const u8,
    ty: wasm.ExternType,
};

pub const ContractSpec = struct {
    major: []const u8,
    namespace: []const u8,
    export_prefix: []const u8,
    imports: []const ContractRow,
    callbacks: []const ContractRow,
    legacy_callbacks: []const []const u8,
};
pub const ContractError = error{
    InvalidMajor,
    InvalidNamespace,
    InvalidExportPrefix,
    InvalidLogicalName,
    DuplicateImport,
    DuplicateCallback,
    DuplicateLegacyCallback,
    MissingInit,
    UnknownLegacyCallback,
    MiniAbiRun,
};

pub const Contract = struct {
    major: []const u8,
    namespace: []const u8,
    export_prefix: []const u8,
    imports: []const ContractRow,
    callbacks: []const ContractRow,
    legacy_callbacks: []const []const u8,

    pub fn init(spec: ContractSpec) ContractError!Contract {
        if (!canonicalMajor(spec.major)) return error.InvalidMajor;
        if (!namespaceMatches(spec.namespace, spec.major)) return error.InvalidNamespace;
        if (spec.export_prefix.len != spec.namespace.len + 1 or
            !std.mem.startsWith(u8, spec.export_prefix, spec.namespace) or
            spec.export_prefix[spec.export_prefix.len - 1] != '/')
            return error.InvalidExportPrefix;

        for (spec.imports, 0..) |row, i| {
            if (!logicalName(row.name)) return error.InvalidLogicalName;
            for (spec.imports[0..i]) |prior|
                if (std.mem.eql(u8, row.name, prior.name)) return error.DuplicateImport;
        }

        var init_count: usize = 0;
        for (spec.callbacks, 0..) |row, i| {
            if (!logicalName(row.name)) return error.InvalidLogicalName;
            if (std.mem.eql(u8, row.name, "run")) return error.MiniAbiRun;
            if (std.mem.eql(u8, row.name, "init")) init_count += 1;
            for (spec.callbacks[0..i]) |prior|
                if (std.mem.eql(u8, row.name, prior.name)) return error.DuplicateCallback;
        }
        if (init_count == 0) return error.MissingInit;

        for (spec.legacy_callbacks, 0..) |name, i| {
            if (!logicalName(name)) return error.InvalidLogicalName;
            if (std.mem.eql(u8, name, "run")) return error.MiniAbiRun;
            for (spec.legacy_callbacks[0..i]) |prior|
                if (std.mem.eql(u8, name, prior)) return error.DuplicateLegacyCallback;
            var found = false;
            for (spec.callbacks) |row| {
                if (std.mem.eql(u8, name, row.name)) {
                    found = true;
                    break;
                }
            }
            if (!found) return error.UnknownLegacyCallback;
        }

        return .{
            .major = spec.major,
            .namespace = spec.namespace,
            .export_prefix = spec.export_prefix,
            .imports = spec.imports,
            .callbacks = spec.callbacks,
            .legacy_callbacks = spec.legacy_callbacks,
        };
    }
};

fn canonicalMajor(major: []const u8) bool {
    if (major.len == 0 or major[0] < '1' or major[0] > '9') return false;
    for (major[1..]) |ch| if (ch < '0' or ch > '9') return false;
    return true;
}

fn namespaceMatches(namespace: []const u8, major: []const u8) bool {
    const prefix = "weft:abi/";
    return namespace.len == prefix.len + major.len and
        std.mem.startsWith(u8, namespace, prefix) and
        std.mem.eql(u8, namespace[prefix.len..], major);
}

fn logicalName(name: []const u8) bool {
    if (name.len == 0 or name[0] < 'a' or name[0] > 'z') return false;
    for (name[1..]) |ch| {
        if ((ch < 'a' or ch > 'z') and (ch < '0' or ch > '9') and ch != '_')
            return false;
    }
    return true;
}
```

The callback duplicate check deliberately precedes the final `init_count` check, so a second `init` returns `DuplicateCallback`; there is no redundant `DuplicateInit` error.

- [ ] **Step 4: Run GREEN for contract invariants**

Run:

```bash
nix-shell --run 'zig build test-plugin-abi --summary all'
```

Expected: all contract-shape tests pass alongside Task 1.

- [ ] **Step 5: Write the failing preflight refusal matrix**

Add the test-only owned-interface helper and refusal matrix below. The tests
refer to the not-yet-declared production types `Direction` and `Refusal`, and
to the not-yet-declared `validate`; those missing declarations are the RED.

Add a test-only owned-interface helper that deep-copies synthetic rows into the same owner type production uses:

```zig
fn ownedInterface(
    imports: []const wasm.ModuleImport,
    exports: []const wasm.ModuleExport,
) !wasm.OwnedInterface {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    errdefer arena.deinit();
    const allocator = arena.allocator();
    const copied_imports = try allocator.dupe(wasm.ModuleImport, imports);
    const copied_exports = try allocator.dupe(wasm.ModuleExport, exports);
    for (copied_imports) |*row| {
        row.module = try allocator.dupe(u8, row.module);
        row.name = try allocator.dupe(u8, row.name);
        row.ty.params = try allocator.dupe(wasm.ValKind, row.ty.params);
        row.ty.results = try allocator.dupe(wasm.ValKind, row.ty.results);
    }
    for (copied_exports) |*row| {
        row.name = try allocator.dupe(u8, row.name);
        row.ty.params = try allocator.dupe(wasm.ValKind, row.ty.params);
        row.ty.results = try allocator.dupe(wasm.ValKind, row.ty.results);
    }
    return .{ .arena = arena, .imports = copied_imports, .exports = copied_exports };
}

fn refusalTag(interface: *const wasm.OwnedInterface, contract: *const Contract) ?std.meta.Tag(Refusal) {
    const refusal = validate(interface, contract) orelse return null;
    return std.meta.activeTag(refusal);
}
```

Add the matrix:

```zig
test "preflight accepts supported subsets and optional callback absence" {
    const contract = try Contract.init(validSpec());
    const cases = [_]struct {
        imports: []const wasm.ModuleImport,
        exports: []const wasm.ModuleExport,
    }{
        .{ .imports = &.{}, .exports = &.{.{ .name = "weft:abi/1/init", .ty = void_fn }} },
        .{
            .imports = &.{.{ .module = "weft:abi/1", .name = "wl_log", .ty = i32_fn }},
            .exports = &.{.{ .name = "weft:abi/1/init", .ty = void_fn }},
        },
        .{
            .imports = &.{},
            .exports = &.{
                .{ .name = "memory", .ty = .{ .kind = .memory } },
                .{ .name = "weft:abi/1/init", .ty = void_fn },
                .{ .name = "weft:abi/1/describe", .ty = void_fn },
            },
        },
        .{
            .imports = &.{
                .{ .module = "weft:abi/1", .name = "wl_log", .ty = i32_fn },
                .{ .module = "weft:abi/1", .name = "wl_result", .ty = i32_result_fn },
                .{ .module = "weft:abi/1", .name = "run", .ty = void_fn },
            },
            .exports = &.{
                .{ .name = "weft:abi/1/init", .ty = void_fn },
                .{ .name = "weft:abi/1/describe", .ty = void_fn },
                .{ .name = "weft:abi/1/on_command", .ty = i32_fn },
                .{ .name = "weft:abi/1/on_result", .ty = i32_result_fn },
            },
        },
    };
    for (cases) |case| {
        var interface = try ownedInterface(case.imports, case.exports);
        defer interface.deinit();
        try t.expect(validate(&interface, &contract) == null);
    }
}

test "preflight refusal matrix" {
    const contract = try Contract.init(validSpec());
    const Case = struct {
        imports: []const wasm.ModuleImport = &.{},
        exports: []const wasm.ModuleExport,
        want: std.meta.Tag(Refusal),
    };
    const cases = [_]Case{
        .{ .imports = &.{.{ .module = "weft", .name = "wl_log", .ty = i32_fn }}, .exports = &.{.{ .name = "weft:abi/1/init", .ty = void_fn }}, .want = .legacy_import_namespace },
        .{ .exports = &.{ .{ .name = "init", .ty = void_fn }, .{ .name = "weft:abi/1/init", .ty = void_fn } }, .want = .legacy_callback_export },
        .{ .imports = &.{.{ .module = "weft:abi/01", .name = "wl_log", .ty = i32_fn }}, .exports = &.{.{ .name = "weft:abi/1/init", .ty = void_fn }}, .want = .malformed_reserved_name },
        .{ .exports = &.{ .{ .name = "weft:abi/1x/init", .ty = void_fn }, .{ .name = "weft:abi/1/init", .ty = void_fn } }, .want = .malformed_reserved_name },
        .{ .imports = &.{.{ .module = "weft:abi/999999999999999999999999999999", .name = "wl_log", .ty = i32_fn }}, .exports = &.{.{ .name = "weft:abi/1/init", .ty = void_fn }}, .want = .unsupported_abi_namespace },
        .{ .exports = &.{ .{ .name = "weft:abi/2/init", .ty = void_fn }, .{ .name = "weft:abi/1/init", .ty = void_fn } }, .want = .unsupported_abi_namespace },
        .{ .imports = &.{.{ .module = "wasi_snapshot_preview1", .name = "fd_write", .ty = i32_fn }}, .exports = &.{.{ .name = "weft:abi/1/init", .ty = void_fn }}, .want = .foreign_import_namespace },
        .{ .imports = &.{.{ .module = "weft:abi/1", .name = "wl_missing", .ty = i32_fn }}, .exports = &.{.{ .name = "weft:abi/1/init", .ty = void_fn }}, .want = .unknown_import },
        .{ .exports = &.{ .{ .name = "weft:abi/1/unknown", .ty = void_fn }, .{ .name = "weft:abi/1/init", .ty = void_fn } }, .want = .unknown_callback },
        .{ .imports = &.{.{ .module = "weft:abi/1", .name = "wl_log", .ty = .{ .kind = .memory } }}, .exports = &.{.{ .name = "weft:abi/1/init", .ty = void_fn }}, .want = .import_type_mismatch },
        .{ .imports = &.{.{ .module = "weft:abi/1", .name = "wl_log", .ty = void_fn }}, .exports = &.{.{ .name = "weft:abi/1/init", .ty = void_fn }}, .want = .import_type_mismatch },
        .{ .imports = &.{.{ .module = "weft:abi/1", .name = "wl_result", .ty = void_fn }}, .exports = &.{.{ .name = "weft:abi/1/init", .ty = void_fn }}, .want = .import_type_mismatch },
        .{ .exports = &.{.{ .name = "weft:abi/1/init", .ty = .{ .kind = .global } }}, .want = .callback_type_mismatch },
        .{ .exports = &.{ .{ .name = "weft:abi/1/on_command", .ty = void_fn }, .{ .name = "weft:abi/1/init", .ty = void_fn } }, .want = .callback_type_mismatch },
        .{ .exports = &.{ .{ .name = "weft:abi/1/on_result", .ty = void_fn }, .{ .name = "weft:abi/1/init", .ty = void_fn } }, .want = .callback_type_mismatch },
        .{ .exports = &.{.{ .name = "memory", .ty = .{ .kind = .memory } }}, .want = .missing_init },
    };

    for (cases) |case| {
        var interface = try ownedInterface(case.imports, case.exports);
        defer interface.deinit();
        try t.expectEqual(case.want, refusalTag(&interface, &contract).?);
    }
}
```

- [ ] **Step 6: Add failing deterministic-order and borrowed-lifetime assertions**

Add:

```zig
test "preflight preserves import order and checks imports before exports" {
    const contract = try Contract.init(validSpec());
    var interface = try ownedInterface(
        &.{
            .{ .module = "foreign", .name = "first", .ty = void_fn },
            .{ .module = "weft", .name = "second", .ty = void_fn },
        },
        &.{.{ .name = "init", .ty = void_fn }},
    );
    defer interface.deinit();
    const refusal = validate(&interface, &contract).?;
    try t.expectEqual(std.meta.Tag(Refusal).foreign_import_namespace, std.meta.activeTag(refusal));
    try t.expectEqualStrings("foreign", refusal.foreign_import_namespace.module);
    try t.expectEqualStrings("first", refusal.foreign_import_namespace.field);
}

test "preflight checks exports in module order before missing init" {
    const contract = try Contract.init(validSpec());
    var interface = try ownedInterface(&.{}, &.{
        .{ .name = "weft:abi/1/unknown", .ty = void_fn },
        .{ .name = "init", .ty = void_fn },
    });
    defer interface.deinit();
    try t.expectEqual(
        std.meta.Tag(Refusal).unknown_callback,
        refusalTag(&interface, &contract).?,
    );
}

test "preflight reports every malformed reserved boundary with its direction" {
    const contract = try Contract.init(validSpec());
    for ([_][]const u8{ "weft:abi/", "weft:abi/01", "weft:abi/1/" }) |bad| {
        var interface = try ownedInterface(
            &.{.{ .module = bad, .name = "wl_log", .ty = i32_fn }},
            &.{.{ .name = "weft:abi/1/init", .ty = void_fn }},
        );
        defer interface.deinit();
        const refusal = validate(&interface, &contract).?;
        try t.expectEqual(std.meta.Tag(Refusal).malformed_reserved_name, std.meta.activeTag(refusal));
        try t.expectEqual(Direction.guest_import, refusal.malformed_reserved_name.direction);
        try t.expectEqualStrings(bad, refusal.malformed_reserved_name.name);
    }

    for ([_][]const u8{
        "weft:abi/1",
        "weft:abi//init",
        "weft:abi/01/init",
        "weft:abi/1/",
        "weft:abi/1/a/b",
    }) |bad| {
        var interface = try ownedInterface(&.{}, &.{
            .{ .name = bad, .ty = void_fn },
            .{ .name = "weft:abi/1/init", .ty = void_fn },
        });
        defer interface.deinit();
        const refusal = validate(&interface, &contract).?;
        try t.expectEqual(std.meta.Tag(Refusal).malformed_reserved_name, std.meta.activeTag(refusal));
        try t.expectEqual(Direction.host_callback, refusal.malformed_reserved_name.direction);
        try t.expectEqualStrings(bad, refusal.malformed_reserved_name.name);
    }
}

test "preflight treats a slash-free callback segment as syntax before lookup" {
    const contract = try Contract.init(validSpec());
    var interface = try ownedInterface(&.{}, &.{
        .{ .name = "weft:abi/1/Bad-name", .ty = void_fn },
        .{ .name = "weft:abi/1/init", .ty = void_fn },
    });
    defer interface.deinit();
    const refusal = validate(&interface, &contract).?;
    try t.expectEqual(std.meta.Tag(Refusal).unknown_callback, std.meta.activeTag(refusal));
    try t.expectEqualStrings("Bad-name", refusal.unknown_callback.name);
}

test "preflight callback major refusal reports the namespace, not full export" {
    const contract = try Contract.init(validSpec());
    var interface = try ownedInterface(&.{}, &.{
        .{ .name = "weft:abi/2/init", .ty = void_fn },
        .{ .name = "weft:abi/1/init", .ty = void_fn },
    });
    defer interface.deinit();
    const refusal = validate(&interface, &contract).?;
    try t.expectEqual(std.meta.Tag(Refusal).unsupported_abi_namespace, std.meta.activeTag(refusal));
    try t.expectEqualStrings("weft:abi/2", refusal.unsupported_abi_namespace.found);
    try t.expectEqualStrings("weft:abi/1", refusal.unsupported_abi_namespace.supported);
}

test "preflight type refusal borrows direct expected and found shapes" {
    const contract = try Contract.init(validSpec());
    var interface = try ownedInterface(
        &.{.{ .module = "weft:abi/1", .name = "wl_result", .ty = void_fn }},
        &.{.{ .name = "weft:abi/1/init", .ty = void_fn }},
    );
    defer interface.deinit();
    const refusal = validate(&interface, &contract).?;
    try t.expectEqual(std.meta.Tag(Refusal).import_type_mismatch, std.meta.activeTag(refusal));
    try t.expectEqualSlices(wasm.ValKind, &.{.i32}, refusal.import_type_mismatch.expected.results);
    try t.expectEqual(@as(usize, 0), refusal.import_type_mismatch.found.results.len);
}
```

These tests read refusal slices while both owners are live; do not copy or allocate refusal data.

- [ ] **Step 7: Run RED for complete preflight policy**

Run:

```bash
nix-shell --run 'zig build test-plugin-abi --summary all'
```

Expected: FAIL because `validate` is undeclared.

- [ ] **Step 8: Implement reserved-name parsing, lookup, and validation**

Insert before `validate`:

```zig
pub const Direction = enum { guest_import, host_callback };

pub const Refusal = union(enum) {
    legacy_import_namespace: struct { field: []const u8 },
    legacy_callback_export: struct { name: []const u8 },
    malformed_reserved_name: struct { name: []const u8, direction: Direction },
    unsupported_abi_namespace: struct { found: []const u8, supported: []const u8 },
    foreign_import_namespace: struct { module: []const u8, field: []const u8 },
    unknown_import: struct { field: []const u8 },
    unknown_callback: struct { name: []const u8 },
    import_type_mismatch: struct {
        field: []const u8,
        expected: wasm.ExternType,
        found: wasm.ExternType,
    },
    callback_type_mismatch: struct {
        name: []const u8,
        expected: wasm.ExternType,
        found: wasm.ExternType,
    },
    missing_init,
};

const reserved_prefix = "weft:abi/";

const ParsedExport = struct {
    namespace: []const u8,
    major: []const u8,
    callback: []const u8,
};

fn parseImportMajor(namespace: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, namespace, reserved_prefix)) return null;
    const major = namespace[reserved_prefix.len..];
    if (!canonicalMajor(major)) return null;
    return major;
}

fn parseCallback(name: []const u8) ?ParsedExport {
    if (!std.mem.startsWith(u8, name, reserved_prefix)) return null;
    const rest = name[reserved_prefix.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const major = rest[0..slash];
    const callback = rest[slash + 1 ..];
    if (!canonicalMajor(major) or callback.len == 0 or
        std.mem.indexOfScalar(u8, callback, '/') != null)
        return null;
    return .{
        .namespace = name[0 .. reserved_prefix.len + major.len],
        .major = major,
        .callback = callback,
    };
}

fn sameType(a: wasm.ExternType, b: wasm.ExternType) bool {
    return a.kind == b.kind and
        std.mem.eql(wasm.ValKind, a.params, b.params) and
        std.mem.eql(wasm.ValKind, a.results, b.results);
}

fn contractRow(rows: []const ContractRow, name: []const u8) ?ContractRow {
    for (rows) |row| if (std.mem.eql(u8, row.name, name)) return row;
    return null;
}

fn isLegacyCallback(contract: *const Contract, name: []const u8) bool {
    for (contract.legacy_callbacks) |legacy|
        if (std.mem.eql(u8, legacy, name)) return true;
    return false;
}
```

Implement `validate`:

```zig
pub fn validate(interface: *const wasm.OwnedInterface, contract: *const Contract) ?Refusal {
    for (interface.imports) |entry| {
        if (std.mem.eql(u8, entry.module, "weft"))
            return .{ .legacy_import_namespace = .{ .field = entry.name } };
        if (!std.mem.startsWith(u8, entry.module, reserved_prefix))
            return .{ .foreign_import_namespace = .{ .module = entry.module, .field = entry.name } };
        const major = parseImportMajor(entry.module) orelse
            return .{ .malformed_reserved_name = .{ .name = entry.module, .direction = .guest_import } };
        if (!std.mem.eql(u8, major, contract.major))
            return .{ .unsupported_abi_namespace = .{ .found = entry.module, .supported = contract.namespace } };
        const expected = contractRow(contract.imports, entry.name) orelse
            return .{ .unknown_import = .{ .field = entry.name } };
        if (!sameType(expected.ty, entry.ty))
            return .{ .import_type_mismatch = .{
                .field = entry.name,
                .expected = expected.ty,
                .found = entry.ty,
            } };
    }

    var saw_init = false;
    for (interface.exports) |entry| {
        if (std.mem.startsWith(u8, entry.name, reserved_prefix)) {
            const parsed = parseCallback(entry.name) orelse
                return .{ .malformed_reserved_name = .{ .name = entry.name, .direction = .host_callback } };
            if (!std.mem.eql(u8, parsed.major, contract.major))
                return .{ .unsupported_abi_namespace = .{
                    .found = parsed.namespace,
                    .supported = contract.namespace,
                } };
            const expected = contractRow(contract.callbacks, parsed.callback) orelse
                return .{ .unknown_callback = .{ .name = parsed.callback } };
            if (!sameType(expected.ty, entry.ty))
                return .{ .callback_type_mismatch = .{
                    .name = parsed.callback,
                    .expected = expected.ty,
                    .found = entry.ty,
                } };
            if (std.mem.eql(u8, parsed.callback, "init")) saw_init = true;
            continue;
        }
        if (isLegacyCallback(contract, entry.name))
            return .{ .legacy_callback_export = .{ .name = entry.name } };
    }
    if (!saw_init) return .missing_init;
    return null;
}
```

- [ ] **Step 9: Run GREEN for all preflight behavior**

Run:

```bash
nix-shell --run 'zig build test-plugin-abi --summary all'
```

Expected: supported subsets, every refusal family, deterministic first-refusal
ordering, and borrowed refusal details all pass.

- [ ] **Step 10: Run focused and full phase 1b-I gates**

Run:

```bash
nix-shell --run 'zig build test-plugin-abi --summary all'
nix-shell --run 'zig build test --summary all'
```

Expected: the focused gate passes all Task 1 and Task 2 tests; the full build reports no failed step. Production plugin loading and the membrane census remain unchanged because neither new unit is wired into `loadPlugin`.

- [ ] **Step 11: Commit Task 2**

```bash
git add src/core/wasm_abi/preflight.zig src/core/plugin_abi_tests.zig
git commit -m "feat(wasm): validate plugin ABI requirements"
```

---

## Completion proof

Phase 1b-I is complete only when:

- `Module.inspectInterface` returns a deep-copied arena-owned snapshot or a structured limit result.
- Wasmtime import/export vectors are deleted on every success, limit, and allocation-failure path.
- Every approved limit accepts equality and refuses `limit + 1`.
- Serialized/deserialized modules produce equivalent interface snapshots.
- `Contract.init` enforces every identity, name, uniqueness, `init`, legacy-subset, and mini-ABI invariant.
- Pure preflight accepts supported subsets and returns every specified refusal deterministically.
- Refusals borrow from live interface/contract owners and allocate nothing.
- `nix-shell --run 'zig build test-plugin-abi --summary all'` passes.
- `nix-shell --run 'zig build test --summary all'` passes.
- Production `loadPlugin`, plugin namespaces, SDK declarations, bundled Wasm, and the 231/18/249 census are unchanged.
