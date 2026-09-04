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

Within one major, an existing import/callback name, Wasm signature, and
established semantics are stable. Additive features require the API-governance
exception defined by the parent architecture because the phase 1a ratchet
normally forbids growth. Removing a feature, changing its signature, or
changing its established meaning requires a new ABI-major namespace and a
clean cutover; the host does not retain the old namespace.

### Wasm types

Preflight compares Wasm extern kinds and Wasm value types. Zig source `i32` and `u32` both lower to Wasm `i32`, so compiled-module inspection cannot distinguish their signedness. `src/plugin_sdk/externs.zig` retains the existing comptime comparison with membrane `ValType` to enforce source-level signedness for Zig guests.

### Reserved-name grammar

- An import namespace is reserved when it begins with `weft:abi/`. Its only
  valid form is `weft:abi/<major>`, where `<major>` is canonical ASCII decimal:
  `[1-9][0-9]*`, with no sign or leading zero.
- A callback export is reserved when it begins with `weft:abi/`. Its only valid
  form is `weft:abi/<major>/<callback>`, with the same major grammar and one
  non-empty callback segment.
- Any reserved string that does not parse exactly is
  `malformed_reserved_name`; it is never ignored. Thus `weft:abi/1`,
  `weft:abi/1x/init`, `weft:abi//init`, and `weft:abi/01/init` are refusals
  when encountered as export names.
- `weft` is the retired legacy full-plugin import namespace.
- An unprefixed name in the frozen major-0 legacy callback set is a retired
  callback. Phase 1b-II records that set from the callbacks existing at its
  cutover, excluding `runGuest`'s `run`; same-major additions never enlarge the
  legacy set.
- Other module exports, including `memory`, are not host callback requirements
  and are ignored.
- Full plugins are `wasm32-freestanding`; any imported module outside the
  supported Weft namespace is refused rather than left to fail generically in
  Wasmtime.

## Ownership and layering

### Low-level Wasmtime wrapper

`src/core/wasm.zig` exposes an owned module-interface snapshot containing only transport facts:

- import module and field names;
- export names;
- extern kind;
- function parameter and result Wasm value types.

The snapshot uses one `std.heap.ArenaAllocator`; `deinit` releases every copied
name and type array together. Before each copy it enforces: at most 1,024
imports, 1,024 exports, 256 bytes per module/field/export name, 16 function
parameters, 8 function results, and 256 KiB of copied name bytes total.

Inspection returns `error{OutOfMemory}!Inspection`, where `Inspection` is a
tagged union of `interface: OwnedInterface` and
`limit: InterfaceLimit { kind, limit, found }`. A limit result releases
Wasmtime's vectors and the partial arena before returning its payload.
Allocation failure performs the same cleanup. The wrapper knows no Weft
namespaces, lifecycle names, membrane groups, permissions, or feature policy.

### Pure preflight validator

`src/core/wasm_abi/preflight.zig` owns compatibility policy. Its public
`Contract` input contains canonical major text/namespace/export prefix, import
rows, full-plugin callback rows, and frozen legacy callback names. The required
full-plugin callback is the fixed logical name `init`; it is not configurable.

`Contract.init` validates:

- canonical major text and matching namespace/prefix;
- non-empty import/callback/legacy names using `[a-z][a-z0-9_]*`;
- uniqueness separately within imports, callbacks, and the legacy set;
- exactly one `init` callback row;
- every frozen legacy name names a callback row—the overlap between those two
  collections is intentional; and
- `run` is absent from both callback rows and the frozen legacy set. An import
  field named `run` is unrelated and not prohibited.

Invalid contract data is a host programming error rejected by `Contract.init`;
it is never attributed to a plugin.

Validation borrows `*const OwnedInterface` and `*const Contract`; it takes
ownership of neither. It returns success or one structured refusal whose slices
remain borrowed from those two owners. It performs no logging, allocation,
Wasmtime calls, linker mutation, or guest execution.

Phase 1b-I tests the validator with synthetic valid `Contract` values and tests
each `Contract.init` invariant. It does not change membrane constants. Phase
1b-II makes `src/membrane/root.zig` expose the production `Contract` view, so
validation, linker binding, and callback lookup share its authoritative rows
without a second table.

### Loader
`runtime.loadPlugin` owns sequencing and diagnostics:

1. compile or deserialize the module through `compileCached`;
2. inspect its interface;
3. on `Inspection.limit`, log the structured `kind/limit/found` refusal and
   return `error.IncompatiblePluginAbi`;
4. on `Inspection.interface`, run pure preflight against the membrane's
   production contract;
5. on preflight refusal, log one actionable message containing plugin name and
   details, release snapshot/module state, and return
   `error.IncompatiblePluginAbi`;
6. only on success, construct `WasmPlugin`, acquire semantic ownership, create
   the linker/store/instance, call optional `describe` when present, mint
   grants, and call required `init`.

Only `init` is globally required by preflight. `describe` remains optional and
its absence follows today's no-op path. Other callbacks may be absent; when
present they prove that the plugin requires host support for that callback.
Their existing call-site missing-export policy remains unchanged. The
`runGuest`-only `run` row is not a full-plugin callback and is excluded.

`construct` accepts the already validated owning `wasm.Module` instead of
recompiling bytes. Ownership moves exactly once. Error paths before and after
that move remain separate so module, interface snapshot, instance, plugin
state, and semantic ownership cannot double-free.

### Membrane binding and callback lookup

`wasm_host.defineImports` binds authoritative imports under `abi_namespace` rather than a string literal.

Host callback helpers continue to accept logical names such as `init` and `on_command`. `core/membrane/contract.zig` resolves the authoritative export row and constructs its namespaced ABI export name in one place. Call sites do not repeat prefixes.

### Guest SDK

`plugin_sdk/externs.zig` uses the authoritative ABI namespace for all 231 raw imports. The plugin manifest generator exports lifecycle and hook functions under namespaced callback names through `@export`. Manual plugins and fixtures use the same SDK helper or explicit namespaced `@export`; no full plugin retains an unprefixed host-called callback.

## Preflight algorithm

### Import pass

For every compiled-module import:

1. If the module is exactly `weft`, return `legacy_import_namespace`.
2. If the module does not begin with `weft:abi/`, immediately return
   `foreign_import_namespace`.
3. Parse the reserved import namespace; malformed names return
   `malformed_reserved_name`.
4. Compare the parsed canonical major digit slice textually with the supplied
   contract's canonical major text. If unequal, return
   `unsupported_abi_namespace`. No integer conversion occurs, so an arbitrarily
   large syntactically valid major is unsupported rather than overflow.
5. Locate the field in the supplied contract's import rows.
6. If the field is absent, return `unknown_import`.
7. If its extern kind or Wasm function signature differs, return
   `import_type_mismatch`.

### Export pass

For every compiled-module export:

1. Parse every name beginning with `weft:abi/` using the reserved-name grammar;
   malformed names return `malformed_reserved_name`.
2. Compare its canonical major digit slice textually with the supplied
   contract's canonical major text; if unequal, return
   `unsupported_abi_namespace`.
3. Strip the supplied contract's export prefix and locate the logical callback
   in its full-plugin callback rows.
4. If absent, return `unknown_callback`.
5. If its extern kind or Wasm function signature differs, return
   `callback_type_mismatch`.
6. Mark the contract's required `init` callback present when its exact
   namespaced function is valid.
7. If an unprefixed name belongs to the contract's frozen legacy callback set,
   return `legacy_callback_export`.
8. Ignore other exports, including the separately classified `runGuest` `run`.

After the pass, return `missing_init` unless valid namespaced `init` was
observed.

### Mixed majors

Any module containing recognized Weft imports or callbacks from more than one namespace is refused. The first unsupported namespace is reported with the supported namespace; no namespace wins by ordering.

### Determinism

Validation order is imports in compiled-module order, then exports in compiled-module order, then required-callback checks. The first refusal in that order is returned. Tests pin this order so diagnostics do not vary with hash-table iteration.

## Structured refusals

The pure validator distinguishes:

- `legacy_import_namespace { field }`;
- `legacy_callback_export { name }`;
- `malformed_reserved_name { name, direction }`;
- `unsupported_abi_namespace { found, supported }`;
- `foreign_import_namespace { module, field }`;
- `unknown_import { field }`;
- `unknown_callback { name }`;
- `import_type_mismatch { field, expected, found }`;
- `callback_type_mismatch { name, expected, found }`;
- `missing_init`.

The low-level snapshot may additionally refuse `interface_limit { kind, limit,
found }`. Names and types borrow from the owned module-interface snapshot or
static membrane tables and remain valid until the loader formats its diagnostic
and deinitializes the snapshot.

All refusals map to the single public error `error.IncompatiblePluginAbi`.
Allocation failure remains `error.OutOfMemory`. Expected incompatibility is not
a guest trap and not `error.Instantiate`.

## Implementation boundaries

Phase 1b is executed as two reviewed plans on one worktree branch:

### Phase 1b-I — inspection and pure policy

- add the bounded low-level module-interface inspection result and ownership
  tests;
- add the parameterized pure preflight `Contract`, validator, and complete
  synthetic refusal matrix;
- add a focused `test-plugin-abi` build step covering those units; and
- leave production `loadPlugin`, membrane namespaces/rows, SDK declarations,
  and bundled artifacts unchanged.

### Phase 1b-I acceptance

Phase 1b-I is complete when the bounded `OwnedInterface`/`Inspection` API, all
ownership and limit-boundary tests, the validated parameterized `Contract`, and
the complete synthetic preflight matrix are present; production namespaces and
`loadPlugin` remain unchanged; and both commands pass:

```text
nix-shell --run 'zig build test-plugin-abi --summary all'
nix-shell --run 'zig build test --summary all'
```

Phase 1b-II receives its own plan and final phase-1b acceptance review. The
overall criteria below do not gate merging phase 1b-I.
This is the next implementation plan. It is independently testable and changes
no plugin behavior.

### Phase 1b-II — atomic transport cutover

- add ABI namespace/export-prefix, production preflight `Contract`, full-plugin
  callback classification, and frozen major-0 callback names to the membrane;
- integrate preflight and loader ownership sequencing;
- change linker import namespace and callback lookup;
- migrate all 231 SDK extern declarations;
- migrate generated and manual plugin callback exports;
- rebuild every embedded guest;
- add hostile loader fixtures and built-module conformance gates; and
- remove every legacy full-plugin spelling in the same cutover.

At completion:

- `loadPlugin` accepts no `weft` full-plugin imports;
- `loadPlugin` accepts no unprefixed callback from the frozen major-0 legacy set;
- no full-plugin host path binds the legacy namespace;
- no fallback retries instantiation under a legacy namespace;
- no plugin carries both old and new callback names; and
- all bundled plugins use the public major-1 transport.

The test-only `runGuest` mini-ABI remains isolated around its `cursor`, `edit`, and `run` fixture. It is not accepted by `loadPlugin`, does not use the 231-door membrane, and is removed in phase 2. QuickJS's private WASI module imports and exports remain governed by `qjs_contract.zig`.

The two-plan split is not a compatibility interval. Phase 1b-I exposes no new
accepted ABI and phase 1b-II removes the old full-plugin transport atomically.
No released or merged state accepts both namespaces.

## API census

Phase 1b changes namespace/version identity, not API cardinality. The authoritative phase 1a census must remain:

- 231 guest imports;
- 18 host callback exports; and
- 249 semantic operations.

No marker import, metadata callback, feature-list door, or compatibility door is added.

## Verification

### Pure validator matrix

Tests use synthetic interface snapshots and authoritative-shaped contract
fixtures to prove:

- a valid current plugin is accepted;
- a same-major subset is accepted;
- a zero-import plugin with namespaced `init` is accepted;
- optional `describe` and other absent non-`init` callbacks are accepted;
- invalid contract major/namespace/prefix agreement, duplicate rows, missing or
  duplicate contract `init`, and accidental mini-ABI `run` are rejected as host
  contract errors;
- legacy import namespace is refused;
- legacy callback export is refused;
- malformed reserved import/export names are refused;
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
- every count, per-name, signature, and total-name-byte limit accepts equality,
  refuses `limit + 1`, and frees partial state on refusal;
- allocation failure frees partial state;
- all owned memory is released; and
- a compiled module and the same serialized/deserialized module produce
  equivalent snapshots.

### Loader behavior

End-to-end loader tests prove:

- a current bundled fixture loads and initializes;
- a same-major subset fixture loads;
- each refusal family returns `IncompatiblePluginAbi`, not `Instantiate` or `Trap`;
- incompatible modules publish no commands, providers, grants, semantic resources, or other plugin-owned state;
- optional `describe` remains a no-op when absent;
- no `describe`, `init`, or module start behavior is observed after preflight refusal;
- `runGuest` still executes only `src/plugin_fixtures/hello.zig` through its
  isolated mini-ABI and does not invoke full-plugin preflight;
- QuickJS still instantiates through its existing WASI/qjs contract path and
  does not invoke full-plugin preflight; and
- current plugins still enforce declaration and grant rules after successful preflight.

The start-order fixture is a documented test-only Wasm byte array beside the
loader test. It contains a valid namespaced `init`, an unknown same-major
callback export, and a start function that traps. Its source bytes are the
reproducible fixture—no external compiler is required. Without preflight it
links and traps; with preflight it returns `unknown_callback` before
instantiation.

### Structural and conformance gates

- The membrane census remains exactly 231/18/249.
- `core/membrane/contract.zig`'s existing data↔handler zip remains exhaustive,
  and a contract test proves every preflight-supported import is bound from the
  same authoritative row and signature.
- Callback lookup and preflight both use the same authoritative export rows; no
  second callback signature table exists.
- Tests inspect every built bundled plugin and full-plugin fixture, rejecting a
  legacy import namespace, an unprefixed callback from the frozen major-0 set,
  a foreign import, or a reserved malformed name. This observes
  generated/comptime names and final Wasm artifacts rather than guessing from
  source text.
- The linker binds the full membrane only under `weft:abi/1`.
- The only legacy mini-ABI exceptions are
  `src/core/wasm_abi/runtime.zig:runGuest` and
  `src/plugin_fixtures/hello.zig`; neither is accepted by `loadPlugin`.

### Commands

Phase 1b-I introduces and runs:

```text
nix-shell --run 'zig build test-plugin-abi --summary all'
```

Phase 1b-II keeps that focused gate and additionally requires:

```text
nix-shell --run 'zig build test-contract --summary all'
nix-shell --run 'zig build test --summary all'
```

Expected warning-rich negative-path logs remain allowed only when the build
exits zero and reports no failed step.

## Acceptance criteria

Phase 1b is complete when:

- the full plugin namespace and callback prefix are `weft:abi/1`;
- compatibility is validated from compiled-module imports and exports before instantiation;
- same-major supported subsets load without an exact build fingerprint;
- same-major names, signatures, and semantics obey the stability rule;
- every incompatible shape receives the specified structured refusal and public error;
- old full plugins fail clearly and no legacy compatibility path exists;
- every bundled plugin and full-plugin fixture uses namespaced imports and callbacks;
- rejection cannot execute guest code or leave plugin-owned state;
- the test-only mini-ABI and QuickJS transport remain behaviorally verified and separate;
- preflight, linker binding, and callback invocation consume the same authoritative contract rows;
- the membrane census remains 231/18/249; and
- focused, contract, and full regression gates pass in the Nix shell.
