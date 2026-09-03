# Plugin ABI negotiation design

**Status:** Approved design  
**Date:** 2026-09-03  
**Scope:** Phase 1b of `2026-09-03-plugin-driven-editor-design.md`

## Purpose

Weft currently discovers plugin incompatibility at linker instantiation. A newer plugin that imports an unavailable host function fails as a generic Wasmtime instantiate error. The host cannot distinguish an unsupported ABI major, an unknown required feature, a malformed signature, or an unrelated foreign import before linking.

Phase 1b makes compatibility an explicit preflight over the module's real imports and host-called exports. It executes before guest code, plugin resources, grants, or declarations. It introduces no compatibility shim and does not change the phase 1a API census.

## Decisions

1. The full plugin ABI major is encoded in a canonical Wasm import namespace and host-called export prefix.
2. ABI major 1 uses `weft:abi/1`.
3. Within one major, a plugin may require any subset the host supports. Exact SDK/build fingerprints are not required.
4. A plugin's actual imports and namespaced callback exports are its required features. There is no duplicated feature manifest or marker import.
5. The host validates the compiled module before linker construction or instantiation.
6. Legacy full plugins are rejected. The host does not carry a `weft` compatibility namespace.
7. The test-only `runGuest` mini-ABI and QuickJS's internal WASI transport are separate transports and remain outside phase 1b.

## Source constraints

Weft's Nix shell provides Wasmtime 47.0.3 and Zig 0.16.0.

Wasmtime 47's C API exposes `wasmtime_module_imports` and `wasmtime_module_exports` on a compiled `wasmtime_module_t`. Import descriptions include module name, field name, and extern type. Export descriptions include name and extern type. These APIs require no store, linker, instance, or guest execution and work for compiled modules restored from Weft's `.cwasm` cache.

The C API does not expose arbitrary Wasm custom sections. Wasmtime does not retain arbitrary sections as general compiled-module metadata, and Zig 0.16 does not reliably emit a named Wasm custom section through `linksection`. Exported global values and exported function results are unavailable before instantiation. Therefore imports and export declarations are the only small, source-verified preflight carrier.

## Compatibility contract

### Canonical namespace

The authoritative membrane declares:

```text
abi_major     = 1
abi_namespace = "weft:abi/1"
export_prefix = "weft:abi/1/"
```

Every full plugin host import uses the exact module namespace `weft:abi/1`:

```zig
extern "weft:abi/1" fn wl_edit(...)
```

Every host-called plugin export uses the same major as a prefix:

```text
weft:abi/1/init
weft:abi/1/describe
weft:abi/1/on_command
weft:abi/1/on_exec
```

`init` remains the required lifecycle callback. Encoding the major in this real callback means a plugin with zero host imports still identifies its callback ABI without a no-op marker.

### Required features

For guest-to-host traffic, each actual imported field and its Wasm function type is a required feature. For host-to-guest traffic, each export under `weft:abi/1/` and its Wasm function type is a required callback feature.

A host accepts any subset for which:

- every Weft import uses the supported namespace;
- every imported field exists in the authoritative import table;
- every imported extern is a function with the authoritative Wasm parameter and result shape;
- every namespaced callback exists in the authoritative export table;
- every namespaced callback is a function with the authoritative Wasm parameter and result shape; and
- the required namespaced `init` callback exists.

An old same-major plugin continues to load when the host adds unrelated supported features. A plugin that names a same-major feature the host does not implement is rejected before instantiation.

### Wasm types

Preflight compares Wasm extern kinds and Wasm value types. Zig source `i32` and `u32` both lower to Wasm `i32`, so compiled-module inspection cannot distinguish their signedness. `src/plugin_sdk/externs.zig` retains the existing comptime comparison with membrane `ValType` to enforce source-level signedness for Zig guests.

### Reserved names

- `weft:abi/` is reserved for full plugin ABI namespaces and callback prefixes.
- `weft` is the retired legacy full-plugin import namespace.
- An unprefixed name matching a known host-called callback is a retired legacy callback.
- Other module exports, including `memory`, are not host callback requirements and are ignored.
- Full plugins are `wasm32-freestanding`; any imported module outside the supported Weft namespace is refused rather than left to fail generically in Wasmtime.

## Ownership and layering

### Low-level Wasmtime wrapper

`src/core/wasm.zig` exposes an owned module-interface snapshot containing only transport facts:

- import module and field names;
- export names;
- extern kind;
- function parameter and result Wasm value types.

The snapshot copies data that must outlive Wasmtime's import/export vectors and owns one allocation arena or equivalent bounded owner. Its `deinit` releases all copied names and type arrays. The wrapper knows no Weft namespaces, lifecycle names, membrane groups, permissions, or feature policy.

### Pure preflight validator

`src/core/wasm_abi/preflight.zig` owns compatibility policy. It consumes:

- the owned module-interface snapshot;
- `src/membrane/root.zig`'s ABI namespace, import table, and export table.

It returns either success or one structured refusal. It performs no logging, allocation, Wasmtime calls, linker mutation, or guest execution.

### Loader

`runtime.loadPlugin` owns sequencing and diagnostics:

1. compile or deserialize the module through `compileCached`;
2. obtain its owned interface snapshot;
3. run pure preflight;
4. on refusal, log one actionable message containing plugin name and refusal details, release snapshot/module state, and return `error.IncompatiblePluginAbi`;
5. only on success, construct `WasmPlugin`, acquire semantic ownership, create the linker/store/instance, run `describe`, mint grants, and run `init`.

`construct` accepts the already validated owning `wasm.Module` instead of recompiling bytes. Ownership moves exactly once. Error paths before and after that move remain separate so module, instance, plugin state, and semantic ownership cannot double-free.

### Membrane binding and callback lookup

`wasm_host.defineImports` binds authoritative imports under `abi_namespace` rather than a string literal.

Host callback helpers continue to accept logical names such as `init` and `on_command`. `core/membrane/contract.zig` resolves the authoritative export row and constructs its namespaced ABI export name in one place. Call sites do not repeat prefixes.

### Guest SDK

`plugin_sdk/externs.zig` uses the authoritative ABI namespace for all 231 raw imports. The plugin manifest generator exports lifecycle and hook functions under namespaced callback names through `@export`. Manual plugins and fixtures use the same SDK helper or explicit namespaced `@export`; no full plugin retains an unprefixed host-called callback.

## Preflight algorithm

### Import pass

For every compiled-module import:

1. If the module is exactly `weft:abi/1`, locate its field in the authoritative imports table.
2. If the field is absent, return `unknown_import`.
3. If its extern kind or Wasm function signature differs, return `import_type_mismatch`.
4. If the module is exactly `weft`, return `legacy_import_namespace`.
5. If the module begins with `weft:abi/` but is not supported, return `unsupported_abi_namespace`.
6. Otherwise return `foreign_import_namespace`.

A module with no imports remains valid if its required namespaced `init` export identifies ABI major 1.

### Export pass

For every compiled-module export:

1. If the name begins with `weft:abi/1/`, strip the prefix and locate the logical callback name in the authoritative exports table.
2. If absent, return `unknown_callback`.
3. If its extern kind or Wasm function signature differs, return `callback_type_mismatch`.
4. Mark `init` present when its exact namespaced function is valid.
5. If the name begins with another `weft:abi/` major, return `unsupported_abi_namespace`.
6. If the unprefixed name matches a known callback, return `legacy_callback_export`.
7. Ignore other exports.

After the pass, return `missing_init` unless valid namespaced `init` was observed.

### Mixed majors

Any module containing recognized Weft imports or callbacks from more than one namespace is refused. The first unsupported namespace is reported with the supported namespace; no namespace wins by ordering.

### Determinism

Validation order is imports in compiled-module order, then exports in compiled-module order, then required-callback checks. The first refusal in that order is returned. Tests pin this order so diagnostics do not vary with hash-table iteration.

## Structured refusals

The pure validator distinguishes:

- `legacy_import_namespace { field }`;
- `legacy_callback_export { name }`;
- `unsupported_abi_namespace { found, supported }`;
- `foreign_import_namespace { module, field }`;
- `unknown_import { field }`;
- `unknown_callback { name }`;
- `import_type_mismatch { field, expected, found }`;
- `callback_type_mismatch { name, expected, found }`;
- `missing_init`.

Names and types in a refusal borrow from the owned module-interface snapshot or static membrane tables. They remain valid until the loader formats its diagnostic and deinitializes the snapshot.

All refusals map to the single public error `error.IncompatiblePluginAbi`. They are expected load refusals, not guest traps and not `error.Instantiate`.

## Clean cutover

Phase 1b migrates the entire full-plugin transport in one branch:

- ABI namespace constants in the membrane;
- low-level module interface inspection;
- pure preflight policy;
- loader sequencing;
- linker import namespace;
- callback lookup;
- all 231 SDK extern declarations;
- generated plugin callback exports;
- every manual plugin and fixture callback export;
- embedded guest builds and loader tests; and
- demolition gates for retired spellings.

At completion:

- `loadPlugin` accepts no `weft` full-plugin imports;
- `loadPlugin` accepts no unprefixed known callbacks;
- no full-plugin host path binds the legacy namespace;
- no fallback retries instantiation under a legacy namespace;
- no plugin carries both old and new callback names; and
- all bundled plugins use the public major-1 transport.

The test-only `runGuest` mini-ABI remains isolated around its `cursor`, `edit`, and `run` fixture. It is not accepted by `loadPlugin`, does not use the 231-door membrane, and is removed in phase 2. QuickJS's private WASI module imports and exports remain governed by `qjs_contract.zig`.

## API census

Phase 1b changes namespace/version identity, not API cardinality. The authoritative phase 1a census must remain:

- 231 guest imports;
- 18 host callback exports; and
- 249 semantic operations.

No marker import, metadata callback, feature-list door, or compatibility door is added.

## Verification

### Pure validator matrix

Tests use synthetic interface snapshots and authoritative-shaped contract fixtures to prove:

- a valid current plugin is accepted;
- a same-major subset is accepted;
- a zero-import plugin with namespaced `init` is accepted;
- legacy import namespace is refused;
- legacy callback export is refused;
- unsupported import namespace major is refused;
- unsupported callback namespace major is refused;
- foreign import namespace is refused;
- unknown same-major import is refused;
- unknown same-major callback is refused;
- import extern-kind mismatch is refused;
- import parameter/result mismatch is refused;
- callback extern-kind mismatch is refused;
- callback parameter/result mismatch is refused;
- missing namespaced `init` is refused;
- mixed old/new or major-1/other-major requirements are refused; and
- first-refusal order is deterministic.

### Wasmtime interface inspection

Low-level tests compile small modules and verify:

- import module/field names and function types are copied correctly;
- export names and function types are copied correctly;
- non-function extern kinds are preserved for preflight refusal;
- snapshot data remains valid after Wasmtime vectors are deleted;
- all owned memory is released; and
- a compiled module and the same serialized/deserialized module produce equivalent snapshots.

### Loader behavior

End-to-end loader tests prove:

- a current bundled fixture loads and initializes;
- a same-major subset fixture loads;
- each refusal family returns `IncompatiblePluginAbi`, not `Instantiate` or `Trap`;
- incompatible modules publish no commands, providers, grants, semantic resources, or other plugin-owned state;
- no `describe`, `init`, or module start behavior is observed after preflight refusal; and
- current plugins still enforce declaration and grant rules after successful preflight.

A deliberately incompatible binary with a trapping start section verifies that preflight refusal occurs before instantiation. The fixture is checked in as fixed Wasm bytes or built by an existing pinned tool; phase 1b does not add an ad-hoc system compiler or unpinned tool.

### Structural gates

- The membrane census remains exactly 231/18/249.
- A source gate rejects full-plugin `extern "weft"` declarations outside the explicitly named `runGuest` fixture.
- A source gate rejects unprefixed known callback exports in full plugins and fixtures.
- The linker binds the full membrane only under `weft:abi/1`.
- Host callback lookup constructs namespaced names only through the membrane contract.

### Commands

Focused low-level and loader tests run first. Completion requires:

```text
nix-shell --run 'zig build test-contract --summary all'
nix-shell --run 'zig build test --summary all'
```

Expected warning-rich negative-path logs remain allowed only when the build exits zero and reports no failed step.

## Acceptance criteria

Phase 1b is complete when:

- the full plugin namespace and callback prefix are `weft:abi/1`;
- compatibility is validated from compiled-module imports and exports before instantiation;
- same-major supported subsets load without an exact build fingerprint;
- every incompatible shape receives the specified structured refusal and public error;
- old full plugins fail clearly and no legacy compatibility path exists;
- every bundled plugin and full-plugin fixture uses namespaced imports and callbacks;
- rejection cannot execute guest code or leave plugin-owned state;
- the test-only mini-ABI and QuickJS transport remain explicitly separate;
- the membrane census remains 231/18/249; and
- focused, contract, and full regression gates pass in the Nix shell.
