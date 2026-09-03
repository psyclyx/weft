# Plugin API Census and Tiers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Weft's current plugin membrane size and plugin-library dependency direction explicit, executable, and unable to grow silently without changing runtime behavior.

**Architecture:** The authoritative `src/membrane/root.zig` import/export rows gain semantic-operation metadata and are projected into a small pure census validator. Physical imports, physical exports, and unique directional semantic operations are ratcheted at 231, 18, and 249. A second pure validator defines strict plugin-library tiers; `build.zig` maps every `Library` to one tier and rejects same-tier or upward declared dependencies.

**Tech Stack:** Zig 0.16, Zig build graph, compile-time contract tables, `std.testing`, Nix shell.

## Global Constraints

- Scope is phase 1a of `docs/superpowers/specs/2026-09-03-plugin-driven-editor-design.md` only.
- Runtime behavior MUST remain unchanged.
- No ABI import, export, or semantic operation may be added or removed.
- Baselines are exactly 231 guest imports, 18 host callback exports, and 249 semantic operations from commit `d5e74ff`.
- Every legacy door has protocol major `0`; a missing explicit operation name means the unique synthetic identity `legacy.<symbol>` in that door's direction.
- Semantic identity is `(protocol major, operation name, direction)`; result variants, schema types, generated scalar parameters, and SDK-only helpers do not count separately.
- `src/membrane/root.zig` remains the authoritative contract table. `src/plugin_sdk/externs.zig` remains mechanically cross-checked against its imports.
- Plugin-library tiers are strictly ordered: tier 0 `rowkey/jsonrpc/sessions`; tier 1 `annotate/output/files/prompt`; tier 2 `invoke`; tier 3 `ex`.
- Every declared `Library.deps()` edge MUST point to a lower tier. Same-tier and upward edges are both invalid.
- Tests and build commands MUST run inside `nix-shell`.
- No compatibility facade, parallel census, source-text scraping, or generated documentation file.

---

## File structure

- **Create `src/membrane/census.zig`** — pure door identity, count, and budget validation; no knowledge of Weft handler groups or Wasmtime.
- **Modify `src/membrane/root.zig`** — attach operation metadata to authoritative import/export row types, project rows into census doors, export the live census, and replace hand-maintained count checks with validator limits.
- **Modify `src/plugin_sdk/externs.zig`** — documentation-only corrections so comments name this file, not the pre-split `plugin_sdk/root.zig`, as the raw extern mirror.
- **Create `src/plugin_lib/tiers.zig`** — pure tier ordering and dependency-edge validation with independent negative tests.
- **Modify `build.zig`** — map each `Library` to a tier, validate `Library.deps()`, and include membrane/tier unit tests in `test-contract`.

---

### Task 1: Pure membrane census validator

**Files:**
- Create: `src/membrane/census.zig`
- Test: `src/membrane/census.zig`

**Interfaces:**
- Consumes: only Zig standard library.
- Produces:
  - `pub const Direction = enum { guest_import, host_export };`
  - `pub const Operation = struct { major: u16 = 0, name: ?[]const u8 = null };`
  - `pub const Door = struct { symbol: []const u8, direction: Direction, operation: Operation = .{} };`
  - `pub const Counts = struct { imports: usize, exports: usize, semantic_operations: usize };`
  - `pub const Limits = Counts;`
  - `pub const ValidationError = error{ ImportBudgetExceeded, ExportBudgetExceeded, SemanticOperationBudgetExceeded };`
  - `pub fn count(doors: []const Door) Counts`
  - `pub fn validate(doors: []const Door, limits: Limits) ValidationError!Counts`

- [ ] **Step 1: Create failing independent budget tests**

Create `src/membrane/census.zig` with the public data types and these tests, but without `count` or `validate`:

```zig
const std = @import("std");

pub const Direction = enum { guest_import, host_export };

pub const Operation = struct {
    major: u16 = 0,
    name: ?[]const u8 = null,
};

pub const Door = struct {
    symbol: []const u8,
    direction: Direction,
    operation: Operation = .{},
};

pub const Counts = struct {
    imports: usize,
    exports: usize,
    semantic_operations: usize,
};

pub const Limits = Counts;

pub const ValidationError = error{
    ImportBudgetExceeded,
    ExportBudgetExceeded,
    SemanticOperationBudgetExceeded,
};

const t = std.testing;

test "census rejects an import overrun independently" {
    const doors = [_]Door{
        .{ .symbol = "wl_a", .direction = .guest_import },
    };
    try t.expectError(error.ImportBudgetExceeded, validate(&doors, .{
        .imports = 0,
        .exports = 0,
        .semantic_operations = 1,
    }));
}

test "census rejects an export overrun independently" {
    const doors = [_]Door{
        .{ .symbol = "on_a", .direction = .host_export },
    };
    try t.expectError(error.ExportBudgetExceeded, validate(&doors, .{
        .imports = 0,
        .exports = 0,
        .semantic_operations = 1,
    }));
}

test "census rejects a semantic-operation overrun independently" {
    const doors = [_]Door{
        .{ .symbol = "wl_begin", .direction = .guest_import, .operation = .{ .major = 1, .name = "view.publish" } },
        .{ .symbol = "wl_finish", .direction = .guest_import, .operation = .{ .major = 1, .name = "view.publish" } },
    };
    try t.expectError(error.SemanticOperationBudgetExceeded, validate(&doors, .{
        .imports = 2,
        .exports = 0,
        .semantic_operations = 0,
    }));
}
```

- [ ] **Step 2: Run the focused test and verify it fails**

Run:

```bash
nix-shell --run 'zig test src/membrane/census.zig'
```

Expected: compilation fails because `validate` is undeclared.

- [ ] **Step 3: Implement counting and validation**

Insert above `const t = std.testing;`:

```zig
const legacy_prefix = "legacy.";

fn legacyMatches(symbol: []const u8, explicit: []const u8) bool {
    return std.mem.startsWith(u8, explicit, legacy_prefix) and
        std.mem.eql(u8, explicit[legacy_prefix.len..], symbol);
}

fn sameSemanticOperation(a: Door, b: Door) bool {
    if (a.direction != b.direction or a.operation.major != b.operation.major)
        return false;
    if (a.operation.name) |a_name| {
        if (b.operation.name) |b_name| return std.mem.eql(u8, a_name, b_name);
        return legacyMatches(b.symbol, a_name);
    }
    if (b.operation.name) |b_name| return legacyMatches(a.symbol, b_name);
    return std.mem.eql(u8, a.symbol, b.symbol);
}

pub fn count(doors: []const Door) Counts {
    var result: Counts = .{
        .imports = 0,
        .exports = 0,
        .semantic_operations = 0,
    };

    for (doors, 0..) |door, i| {
        switch (door.direction) {
            .guest_import => result.imports += 1,
            .host_export => result.exports += 1,
        }

        var first = true;
        for (doors[0..i]) |prior| {
            if (sameSemanticOperation(prior, door)) {
                first = false;
                break;
            }
        }
        if (first) result.semantic_operations += 1;
    }

    return result;
}

pub fn validate(doors: []const Door, limits: Limits) ValidationError!Counts {
    const result = count(doors);
    if (result.imports > limits.imports) return error.ImportBudgetExceeded;
    if (result.exports > limits.exports) return error.ExportBudgetExceeded;
    if (result.semantic_operations > limits.semantic_operations)
        return error.SemanticOperationBudgetExceeded;
    return result;
}
```

Add a positive test proving direction is part of semantic identity while multiple physical rows may share one explicit operation:

```zig
test "census counts unique operation identity per direction" {
    const doors = [_]Door{
        .{ .symbol = "wl_begin", .direction = .guest_import, .operation = .{ .major = 1, .name = "view.publish" } },
        .{ .symbol = "wl_finish", .direction = .guest_import, .operation = .{ .major = 1, .name = "view.publish" } },
        .{ .symbol = "on_publish", .direction = .host_export, .operation = .{ .major = 1, .name = "view.publish" } },
        .{ .symbol = "wl_legacy", .direction = .guest_import },
    };

    try t.expectEqual(Counts{
        .imports = 3,
        .exports = 1,
        .semantic_operations = 3,
    }, count(&doors));
}

test "legacy identity is prefixed rather than the raw symbol" {
    const doors = [_]Door{
        .{ .symbol = "wl_legacy", .direction = .guest_import },
        .{ .symbol = "another_physical_row", .direction = .guest_import, .operation = .{ .major = 0, .name = "legacy.wl_legacy" } },
        .{ .symbol = "third_physical_row", .direction = .guest_import, .operation = .{ .major = 0, .name = "wl_legacy" } },
    };

    try t.expectEqual(@as(usize, 2), count(&doors).semantic_operations);
}
```

- [ ] **Step 4: Run the focused test and verify it passes**

Run:

```bash
nix-shell --run 'zig test src/membrane/census.zig'
```

Expected: all five census tests pass.

- [ ] **Step 5: Commit the validator**

```bash
git add src/membrane/census.zig
git commit -m "test(membrane): define API census validator"
```

---

### Task 2: Authoritative membrane metadata and ratchets

**Files:**
- Modify: `src/membrane/root.zig:1-31,105-159,461-590,636-646`
- Modify: `src/plugin_sdk/externs.zig:1-18,294-320`
- Modify: `build.zig:902-907`
- Test: `src/membrane/root.zig`

**Interfaces:**
- Consumes: Task 1's `census.Direction`, `census.Operation`, `census.Door`, `census.Counts`, and `census.validate`.
- Produces:
  - `Entry.operation: census_mod.Operation = .{}`
  - `Export.operation: census_mod.Operation = .{}`
  - `pub const census: census_mod.Counts`
  - compile-time maximums `231`, `18`, and `249`
  - membrane tests included in `zig build test-contract`

- [ ] **Step 1: Replace count assertions with a failing census contract test**

In `src/membrane/root.zig`, replace the import-count assertion at the end of the first test and the export-count assertion at the end of the export test with:

```zig
try t.expectEqual(@as(usize, 231), census.imports);
try t.expectEqual(@as(usize, 18), census.exports);
try t.expectEqual(@as(usize, 249), census.semantic_operations);
```

Keep the semantic assertion in only one of the two tests so it is not duplicated. At this point `census` is intentionally undefined.

- [ ] **Step 2: Run the membrane test and verify it fails**

Run:

```bash
nix-shell --run 'zig test src/membrane/root.zig'
```

Expected: compilation fails because `census` is undeclared.

- [ ] **Step 3: Add operation metadata to authoritative row types**

At the top of `src/membrane/root.zig`, retain `std` and import the validator:

```zig
const std = @import("std");
const census_mod = @import("census.zig");
```

Add this field to `Entry` immediately after `name`:

```zig
operation: census_mod.Operation = .{},
```

Add the same field to `Export` immediately after `name`:

```zig
operation: census_mod.Operation = .{},
```

The default means protocol major `0` and synthetic semantic name `legacy.<entry.name>`. Do not touch the 249 table rows individually; the default is the deliberate legacy recording rule. Future cutovers override `.operation` on only the physical rows that implement a new explicit operation.

- [ ] **Step 4: Project authoritative rows into census data and enforce budgets**

After the `exports` table and before the existing `comptime` block, replace `expected_import_count` and `expected_export_count` with:

```zig
const max_import_count: usize = 231;
const max_export_count: usize = 18;
const max_semantic_operation_count: usize = 249;

fn censusDoors() [imports.len + exports.len]census_mod.Door {
    var doors: [imports.len + exports.len]census_mod.Door = undefined;
    for (imports, 0..) |entry, i| {
        doors[i] = .{
            .symbol = entry.name,
            .direction = .guest_import,
            .operation = entry.operation,
        };
    }
    for (exports, 0..) |entry, i| {
        doors[imports.len + i] = .{
            .symbol = entry.name,
            .direction = .host_export,
            .operation = entry.operation,
        };
    }
    return doors;
}

const census_doors = censusDoors();
pub const census = census_mod.count(&census_doors);
```

At the beginning of the existing `comptime` block, replace the two hand-maintained equality checks with one ratchet:

```zig
_ = census_mod.validate(&census_doors, .{
    .imports = max_import_count,
    .exports = max_export_count,
    .semantic_operations = max_semantic_operation_count,
}) catch |err| @compileError("plugin membrane census exceeds its ratchet: " ++ @errorName(err));
```

Keep the existing name, duplicate, parameter-count, result-count, and documentation validation loops unchanged. They validate row correctness; the new validator owns only census identity and budgets.

- [ ] **Step 5: Make comments and tests name the actual source of truth**

Update membrane comments that still say raw externs live in `src/plugin_sdk/root.zig` or `weft.zig` to say `src/plugin_sdk/externs.zig`. Update `src/plugin_sdk/externs.zig` comments only where they still name the pre-split location. Do not change declarations or verification logic.

Change the final count assertions in `src/membrane/root.zig` to:

```zig
try t.expectEqual(@as(usize, max_import_count), census.imports);
try t.expectEqual(@as(usize, max_export_count), census.exports);
try t.expectEqual(@as(usize, max_semantic_operation_count), census.semantic_operations);
```

- [ ] **Step 6: Put membrane tests on the portable contract gate**

In `build.zig`, add `architecture.membrane` to the tuple tested by `test-contract`:

```zig
inline for (.{
    architecture.wire,
    architecture.schema,
    architecture.membrane,
    architecture.semantic,
    architecture.scene_codec,
    architecture.fs,
    architecture.fs_codec,
    architecture.fs_runtime,
    architecture.view_runtime,
    architecture.target_runtime,
    architecture.plugin_semantic,
}) |contract_mod| {
    const contract_tests = b.addTest(.{ .root_module = contract_mod });
    contract_step.dependOn(&b.addRunArtifact(contract_tests).step);
}
```

- [ ] **Step 7: Run the contract gate**

Run:

```bash
nix-shell --run 'zig build test-contract --summary all'
```

Expected: membrane tests compile through the architecture module, all contract tests pass, and the summary reports no failed steps.

- [ ] **Step 8: Commit the authoritative census**

```bash
git add src/membrane/root.zig src/membrane/census.zig src/plugin_sdk/externs.zig build.zig
git commit -m "arch(membrane): ratchet physical and semantic doors"
```

---

### Task 3: Enforced plugin-library tiers

**Files:**
- Create: `src/plugin_lib/tiers.zig`
- Modify: `build.zig:1-2,40-87,902-908`
- Test: `src/plugin_lib/tiers.zig`

**Interfaces:**
- Consumes: `Library.deps()` from `build.zig`.
- Produces:
  - `pub const Tier = enum(u8) { protocol_data, service_presentation, interaction_orchestration, editor_composition };`
  - `pub const ValidationError = error{ SameTierDependency, UpwardDependency };`
  - `pub fn validateEdge(consumer: Tier, dependency: Tier) ValidationError!void`
  - `Library.tier() plugin_lib_tiers.Tier`
  - compile-time validation of every declared library edge
  - tier tests included in `zig build test-contract`

- [ ] **Step 1: Create failing tier-direction tests**

Create `src/plugin_lib/tiers.zig` with the enum, error set, and tests but without `validateEdge`:

```zig
const std = @import("std");

pub const Tier = enum(u8) {
    protocol_data,
    service_presentation,
    interaction_orchestration,
    editor_composition,
};

pub const ValidationError = error{
    SameTierDependency,
    UpwardDependency,
};

const t = std.testing;

test "tier validation accepts only a lower dependency" {
    try validateEdge(.interaction_orchestration, .service_presentation);
}

test "tier validation rejects a same-tier dependency" {
    try t.expectError(
        error.SameTierDependency,
        validateEdge(.service_presentation, .service_presentation),
    );
}

test "tier validation rejects an upward dependency" {
    try t.expectError(
        error.UpwardDependency,
        validateEdge(.protocol_data, .service_presentation),
    );
}
```

- [ ] **Step 2: Run the focused test and verify it fails**

Run:

```bash
nix-shell --run 'zig test src/plugin_lib/tiers.zig'
```

Expected: compilation fails because `validateEdge` is undeclared.

- [ ] **Step 3: Implement the pure edge validator**

Insert before `const t = std.testing;`:

```zig
pub fn validateEdge(consumer: Tier, dependency: Tier) ValidationError!void {
    const consumer_level = @intFromEnum(consumer);
    const dependency_level = @intFromEnum(dependency);
    if (dependency_level == consumer_level) return error.SameTierDependency;
    if (dependency_level > consumer_level) return error.UpwardDependency;
}
```

- [ ] **Step 4: Run the focused test and verify it passes**

Run:

```bash
nix-shell --run 'zig test src/plugin_lib/tiers.zig'
```

Expected: all three tier tests pass.

- [ ] **Step 5: Map every library and validate declared edges in `build.zig`**

Add the build helper import after `std`:

```zig
const std = @import("std");
const plugin_lib_tiers = @import("src/plugin_lib/tiers.zig");
```

Add this method to `Library` after `importName`:

```zig
fn tier(self: Library) plugin_lib_tiers.Tier {
    return switch (self) {
        .rowkey, .jsonrpc, .sessions => .protocol_data,
        .annotate, .output, .files, .prompt => .service_presentation,
        .invoke => .interaction_orchestration,
        .ex => .editor_composition,
    };
}
```

After `Library`, add a compile-time graph check:

```zig
comptime {
    for (std.meta.tags(Library)) |consumer| {
        for (consumer.deps()) |dependency| {
            plugin_lib_tiers.validateEdge(consumer.tier(), dependency.tier()) catch |err|
                @compileError(std.fmt.comptimePrint(
                    "plugin library dependency {s} -> {s} violates tier direction: {s}",
                    .{ @tagName(consumer), @tagName(dependency), @errorName(err) },
                ));
        }
    }
}
```

Do not infer dependencies from source text. `addPluginLibrary` already gives a module only the imports returned by `Library.deps()`; the new check validates that authoritative graph.

- [ ] **Step 6: Put tier validator tests on `test-contract`**

Near the portable contract gate in `build.zig`, add:

```zig
const plugin_lib_tiers_mod = b.createModule(.{
    .root_source_file = b.path("src/plugin_lib/tiers.zig"),
    .target = target,
    .optimize = optimize,
});
const plugin_lib_tiers_tests = b.addTest(.{ .root_module = plugin_lib_tiers_mod });
contract_step.dependOn(&b.addRunArtifact(plugin_lib_tiers_tests).step);
```

- [ ] **Step 7: Run the phase 1a acceptance gate**

Run:

```bash
nix-shell --run 'zig build test-contract --summary all'
```

Expected: the membrane census tests, three independent census budget failures, the current library graph, and the lower/same/upward tier tests all pass; no contract step fails.

- [ ] **Step 8: Run the full regression suite**

Run:

```bash
nix-shell --run 'zig build test --summary all'
```

Expected: all build and test steps pass. Existing expected guest-trap warnings may appear on stderr; success is the zero exit code and summary with no failed step.

- [ ] **Step 9: Commit the tier gate**

```bash
git add src/plugin_lib/tiers.zig build.zig
git commit -m "arch(plugins): enforce library dependency tiers"
```

---

## Completion proof

Phase 1a is complete only when all of the following are true in one clean tree:

- `src/membrane/root.zig.census` reports exactly 231 imports, 18 exports, and 249 semantic operations.
- The existing extern/table cross-check still compiles.
- Independent synthetic fixtures reject import, export, and semantic-operation overruns.
- Every current `Library.deps()` edge points strictly downward under the approved mapping.
- Independent tests reject both same-tier and upward library edges.
- `nix-shell --run 'zig build test-contract --summary all'` passes.
- `nix-shell --run 'zig build test --summary all'` passes.
- No runtime behavior, ABI door, or plugin composition changed.
