# Plugin-driven editor architecture

**Status:** Approved design  
**Date:** 2026-09-03

## Purpose

Weft's editor experience will be assembled entirely from decomplected Wasm plugins. The native runtime will provide mechanisms, not an editor profile. The bundled editor and third-party replacements will use the identical public Wasm transport.

The current 231-import membrane is not, by itself, proof that core is too large. It mixes three different things:

- necessary mechanisms such as ownership, grants, documents, scheduling, and effects;
- low-level scalar spellings of operations that should be exchanged in bounded records; and
- product-shaped APIs such as picker, menu, completion, process-to-buffer, status, and breakpoint facilities.

The stronger evidence is ownership. Core and app currently implement modeless editing, key dispatch, modal/menu state, picker behavior, HUD composition, active-buffer policy, and editor command surfaces. Some plugins only alias those built-ins. This contradicts the intended runtime boundary in `doc/contextual-workspace-architecture.md`: the kernel knows neither buffers nor menus, and the standard workspace is replaceable.

This design makes that boundary executable.

## Product decisions

The following decisions are settled:

1. **Zero-plugin Weft is an inert runtime.** It can load a composition but provides no typing, caret policy, keymap, picker, HUD, workspace entries, or editor commands.
2. **Bundled and third-party editor plugins use the identical Wasm transport.** There is no private native editor API or privileged fast path.
3. **Plugins own policy through declarative bulk publication.** Native mechanisms execute generic hot loops over published data; rendering and input do not call Wasm per row, glyph, provider candidate, or binding explanation.
4. **The default editor keeps today's behavior and rendered scene.** This is an ownership and boundary change, not a UX redesign.
5. **Migration is a sequence of clean cutovers.** A replacement and every caller migrate together; obsolete doors, aliases, state, and compatibility paths are then deleted.

## Goals

- Make the complete editor experience a replaceable Wasm composition.
- Reduce both the physical ABI and the number of semantic contracts.
- Keep costs, ownership, authority, and failure visible at every boundary.
- Give bundled and third-party plugins the same observable capabilities.
- Preserve native performance through retained data, batching, and generic host-side execution.
- Make wrong dependency direction, API growth, and parallel protocols mechanically difficult.
- Keep each standard plugin independently understandable, reusable, and scoped.

## Non-goals

- Redesigning the default editor's behavior or appearance.
- Replacing optimized native CRDT, platform, filesystem, process, network, layout, or renderer implementations with Wasm implementations.
- Reducing symbol count by hiding an unbounded semantic API behind an untyped opcode.
- A free-form inter-plugin message bus.
- Compatibility wrappers for old plugin architectures.
- Private native implementations of editor policy for bundled plugins.
- Per-row, per-candidate, or per-frame Wasm callbacks on hot paths.

## Architecture

### Runtime kernel

The runtime kernel owns only mechanisms required by any composition:

- plugin lifecycle and ABI/feature negotiation;
- generation-checked handles and exact owner teardown;
- principals, named grants, revocation, and effect attribution;
- canonical schema and protocol identifiers;
- invocation IDs, cancellation, deadlines, and backpressure;
- component and endpoint routing;
- deterministic provider eligibility, conflict resolution, and traces; and
- bounded event delivery.

The runtime kernel has no editor ontology. It knows no buffer, mode, menu, picker, pane, cursor, statusline, breakpoint, or editor command. A headless service host can instantiate it without document, graphics, input, or workspace providers.

### Native mechanism providers

Optimized native providers implement versioned public capability contracts:

- CRDT document storage, snapshots, anchors, attributed transactions, and subscriptions;
- confined filesystem, process, network, environment, and platform resources;
- normalized input events;
- retained view admission, projection, layout primitives, hit-testing, and damage;
- rasterization and platform presentation; and
- generic task and event-source scheduling.

These providers are not ambient fields on one command context. They register capabilities with the runtime and may be omitted. Their machine code may be native, but their contracts do not confer editor policy.

For example, the document provider may store text efficiently. It does not decide which document is active, what a cursor means, where an undo unit ends, whether a dirty entry may close, or which key saves it. The renderer may submit frames efficiently. It does not decide that tabs, a statusline, a picker, or a blinking block cursor exist.

### Wasm protocol and editor plugins

Protocol packages define typed, namespaced, versioned records and operations. Wasm plugins implement resource providers, input grammars, workspace policy, interactions, presentations, and domain behavior.

Plugins publish declarations and retained models in bounded batches. Native providers execute generic dispatch, projection, layout, hit-test, and render loops over that data. Policy originates in the plugin; mechanism runs where it is efficient.

Every bundled component crosses the same public membrane as a third-party replacement. Tests reject private native shortcuts.

JavaScript remains a configuration language, not a second resident-plugin
transport. Bundled JavaScript ACP/DAP implementations must move to Wasm before
public-path parity is complete.

### Composition

Configuration evaluates to a sealed manifest containing:

- plugin instances and opaque parent/child scopes;
- grants;
- typed value bindings;
- protocol providers;
- input grammar and intention bindings;
- presentation selection; and
- plugin-owned composition records.

The runtime reconciles only generic instances, ownership, bindings, and
endpoints. The workspace plugin interprets workspace composition records; the
runtime does not. The default editor is one bundled manifest. Plugin
declaration order is not behavior.

### Dependency direction

Dependencies point one way:

```text
composition -> plugins -> protocol contracts -> runtime kernel
                    |                         ^
                    +---- public membrane ----+

native mechanism providers -> protocol contracts
```

Native mechanism providers never import workspace or plugin policy. Plugins do not import siblings. Shared behavior is an explicitly named library or a typed endpoint. There are no command-string dependencies between plugins.

## Public membrane

### Common invariants

- Every stateful operation names an explicit generation-checked handle.
- Handles carry owner identity and cannot be forged, persisted as display names, or used after generation change.
- Every payload is a bounded, versioned record with a canonical schema ID.
- Every externally initiated effect carries a principal and a causal invocation or event ID. A mutation of a revisioned resource also carries the subject revision. Owner teardown has its own teardown cause and requires no live invocation.
- Every asynchronous result arrives through one typed event export with an owned event envelope.
- ABI major and required protocol features are negotiated before initialization.
- Unsupported requirements reject the plugin before it acquires authority or publishes state.
- Expensive work is explicit in the operation: snapshot, commit batch, publish, patch, spawn, or read.
- Limits and partial results are represented in the contract; nothing truncates silently.

The raw ABI may use generated scalar parameters where Wasm requires them. The semantic operation remains one bounded typed exchange. Physical door count and semantic operation count are tracked separately.

The censuses use these rules:

- A **physical door** is one named guest import or host callback export in the
  authoritative membrane table. Imports and exports are counted separately.
- A **semantic operation** is one public `(protocol major, operation name,
  direction)` that a guest may request or receive. Result/refusal variants,
  schema types, generated scalar parameters, and SDK-only helpers do not add
  operations.
- Each legacy import or export without an operation identity counts as one
  semantic operation until its clean-cutover replacement declares that
  identity. This makes the initial semantic baseline deterministic rather than
  guessing which scalar doors were conceptually one call.
- Commit `d5e74ff` pins the pre-design baseline: 231 imports, 18 exports, and
  therefore 249 legacy semantic operations.

### Contract families

#### Lifecycle and ownership

Manifest description, initialization, typed event delivery, cancellation, release, and teardown. Capability-specific callbacks such as completion, picker acceptance, menu updates, fill tokens, and exec completion do not get separate exports.

#### Catalog and invocation

- Bulk typed command descriptors.
- One typed invocation and result form.
- One intention/provider protocol for command, focused-node, and contextual actions.
- Deterministic resolution against immutable subject facts.
- Conflict and explanation data produced by the same resolver used for dispatch.

This replaces command overloads, scalar command metadata reconstruction, and the parallel command-action and semantic-action planes.

#### Documents

- Capture a document handle.
- Read a bounded versioned snapshot or slice.
- Create and resolve anchored ranges.
- Submit one attributed atomic transaction batch.
- Subscribe to versioned changes.
- Access generic inverse-log primitives where authorized.

The document contract does not define active buffers, cursor movement, selection behavior, undo grouping, save policy, projection rows, or editor modes.

#### Typed endpoints

Schema-checked declaration, binding, invocation, response, decline, completion, cancellation, and provider attribution. Schema versions are validated, not merely recorded.

Completion, annotations, breakpoints, status contributions, diagnostics, progress, and other application protocols are packages over typed endpoints. The kernel does not know their nouns.

#### Views and interactions

- Publish, patch, and close retained views.
- Carry stable node identity, roles, facts, affordances, editable fields, and accessibility data.
- Deliver focus and subject changes in bounded events.
- Open and close scoped interactions with exactly-once continuation ownership.
- Admit retained hit regions and route pointer/accessibility activation through the same action reference used by keyboard activation.

Picker, menu, prompt, transient, which-key, tabs, statusline, gutter, cursor, and notification behavior are plugin compositions over this family. There is one view plane and one interaction lifetime model.

#### Effects

- One argv-based process execution contract with explicit stdin, stdout, stderr, status, place, environment, cancellation, and limits.
- One streaming resource family for process, network, and terminal-like byte streams where their operations are genuinely identical.
- Confined filesystem operations over granted roots and stable resource handles.
- Explicit environment and place handles.

Process-to-buffer, filter, transcript append, named output buffer, and REPL buffer behavior are guest libraries composed from effects, documents, and views.

#### Input declarations

Input plugins bulk-publish:

- grammar states and state facts;
- key and committed-text patterns;
- bindings to shared intentions;
- deterministic transitions;
- capture/return relationships; and
- text commit behavior.

The native input mechanism matches published tables and resolves intentions without crossing Wasm for every candidate. Wasm receives unresolved input, explicit state/focus events, and command invocations. Mode names, resting behavior, sticky menus, dot-repeat, and which-key are plugin policy, not kernel concepts.

### SDK policy

The SDK remains ergonomic and strongly typed. Helpers may provide command overloads, transients, prompts, output projections, session maps, or protocol clients, but helpers are guest code over the contract families. Adding an SDK helper does not add a host import.

Shared plugin libraries:

- depend only downward through mechanically enforced tiers;
- contain no module-global mutable state;
- contain no concrete editor mode, key, or command-name literals;
- accept policy as typed parameters;
- gain an abstraction only after at least two independent consumers establish its shape.

## Standard editor composition

The standard editor is deliberately several plugins, not a replacement god object.

### Workspace

Owns entry handles and labels, the active entry and focus history per head, and
the sole create/activate/retire state machine. Display names are labels only. It
does not own keymaps, text editing, pane layout, backing policy, or
presentation.

An open request resolves a target provider. A file-session provider may acquire
a document/backing resource and return an entry descriptor; only workspace
creates and activates the entry. A close request asks the entry owner for an
allow/refuse result, then only workspace retires it. Layout reports viewport
focus changes to workspace; workspace remains the source of truth for the
active entry.

### Text state

Owns cursor, selection, movement goals, insert/delete commands, and undo-unit
boundaries. It depends on document, focused-subject, catalog/invocation, and
typed-feed contracts. Cursor and selection changes are published through a
typed feed for presentation consumers.

### File session

Owns backing association, target opening, deduplication, save/reload behavior,
and dirty-close decisions. It requests prompts through the interaction
protocol; the selected prompt presenter owns the interaction state and view.
File session does not create or activate workspace entries and does not own
panes, keys, or rendering.

### Layout

Owns pane and viewport topology, split/focus/move behavior, placement decisions,
and which entry each viewport presents. It consumes entry presentations rather
than document internals and requests active-entry changes through workspace.

### Input grammars

Modeless, Vim, Helix, and Emacs are separate plugins over the same input declaration contract. They bind shared intentions and do not import domain or presentation plugins.

### Interaction presenters

Chooser, prompt, transient, and confirmation are separate scoped providers. Each owns its retained view and interaction state. None is a kernel singleton.

### Presentation providers

Viewport, cursor, tabs, statusline, gutter, notifications, which-key, and theme are independent providers. They consume typed feeds and publish retained patches. Cursor appearance and blink behavior are presentation policy.

### Domain and service plugins

Git, files, LSP, DAP, ACP, completion, annotations, formatters, processes, and similar plugins expose typed intentions and endpoints. They do not own global keys, menus, or core-specific command names.

### Instance scopes

Standard protocol packages define scopes such as system, head, workspace entry,
viewport attachment, interaction, task, and service session. These are
namespaced schema values, not a closed runtime enum.

The runtime sees only an opaque scope handle with owner, parent, generation,
schema identity, and bounded payload. It mints the handle and tears down all
children and owned resources exactly; the owning protocol interprets the
payload. This replaces `System`, `Head`, `WasmPlugin`, and named-buffer session
state as cross-domain lifetime buckets without teaching the kernel their
editor meanings.

## Data flows

### Input to rendered edit

1. A platform provider emits a normalized key, committed-text, pointer, or accessibility event.
2. The native input mechanism consults grammar tables published by the active input plugin.
3. A binding names a shared intention.
4. The runtime resolves eligible providers against immutable focused-subject facts.
5. The selected Wasm command receives a narrow invocation record and explicit capability handles.
6. The command submits an attributed document transaction or updates plugin-owned state.
7. Document, focus, and endpoint changes are delivered in bounded event batches.
8. Interested presentation plugins publish retained patches.
9. Native projection, layout, hit-testing, and rendering consume one resolved immutable presentation snapshot.

No renderer calls plugin code per row. No input resolver executes provider code to explain a key. No plugin reaches another by running an undocumented command string.

### Interaction

1. A plugin requests an interaction through a typed endpoint.
2. The selected interaction presenter opens a scoped interaction and publishes its retained view and input declarations.
3. Candidate or prompt data arrives through typed endpoints and may update incrementally.
4. Acceptance, cancellation, timeout, or presenter failure resolves the continuation exactly once.
5. Owner teardown removes the view, input capture, continuation, and pending events together.

Picker, prompt, transient, and confirmation differ in protocol data and presentation, not in kernel lifetime machinery.

### Background effect

1. A plugin invokes an effect with an explicit grant and place/environment handle.
2. The native provider returns a resource or task handle.
3. Readiness and bounded data arrive through typed events.
4. The plugin decides whether to update a document, a model, progress, or nothing.
5. Cancellation, grant revocation, plugin unload, or task completion closes the resource and its events.

The effect provider never chooses a buffer or presentation.

## Failure semantics

- **ABI or feature mismatch:** reject before initialization and list missing or incompatible contracts.
- **Malformed schema, oversized payload, wrong-owner handle, or forged generation:** protocol fault; terminate the plugin instance and tear down everything it owns.
- **Stale revision:** typed refusal containing the current revision where disclosure is authorized.
- **Denied or revoked grant:** typed authority refusal. Revocation immediately closes every resource derived from that grant; any later operation on its handle is stale and refused.
- **Cancellation or timeout:** the continuation enters one terminal state exactly once. Its result is delivered once only while the receiving owner is live; owner teardown discards undeliverable events.
- **Provider ambiguity:** no last-writer-wins behavior. Return a conflict with the same trace the resolver used.
- **Backpressure:** queues are bounded. Coalescing is allowed only when the event contract declares it; otherwise producers receive explicit pressure or refusal.
- **Plugin crash:** exact owner teardown removes handles, providers, bindings, interactions, retained views, and queued events.
- **Diagnostics:** the kernel emits structured diagnostic events. Presentation plugins decide whether they appear as a status message, log row, notification, or nowhere.

Expected domain failures do not trap. Protocol violations at the trust boundary do not become recoverable editor state.

## Migration

The migration is ordered to shrink the API before extracting behavior that would otherwise request more doors.

This is an umbrella architecture, not one implementation unit. Each numbered
phase receives its own reviewed implementation plan and completion proof; a
phase does not begin while a preceding boundary remains half-migrated.

The next plan covers **phase 1a only**: extend
`src/membrane/root.zig`'s existing authoritative `imports` and `exports` data
with semantic-operation identities, add physical and semantic non-growth gates
over those tables, and add `Library` tier metadata with dependency-direction
validation in `build.zig`. The existing comptime comparison with
`src/plugin_sdk/externs.zig` remains the mechanical proof that table and raw
guest declarations agree. Phase 1a changes no runtime behavior and adds no ABI
operation. ABI negotiation is phase 1b; vocabulary ratchets are phase 1c.

### 1. Structural gates

#### 1a. Census and dependency direction

- Record `(protocol major, operation name, direction)` on each authoritative
  import/export row. Every legacy row uses protocol major `0` and initially
  receives the unique synthetic name `legacy.<wl_symbol>` or
  `legacy.<export_symbol>`. A later clean cutover may assign one operation
  identity to several generated physical rows; the semantic census counts
  unique identities.
- Generate import, export, and unique-semantic-operation counts directly from
  those tables.
- Pin the `d5e74ff` baselines: 231 imports, 18 exports, and 249 semantic operations.
- Add non-growth ratchets for all three counts.
- Assign current libraries to these strictly ordered tiers:
  - tier 0, protocol/data: `rowkey`, `jsonrpc`, `sessions`;
  - tier 1, service/presentation: `annotate`, `output`, `files`, `prompt`;
  - tier 2, interaction orchestration: `invoke`;
  - tier 3, editor composition: `ex`.
- Validate the edges returned by `Library.deps()` only; Zig module construction
  already makes undeclared library imports unavailable. Tests compiled within
  a library receive that same declared dependency set. Generated sources
  outside the `Library` graph receive no tier. Every declared edge must point
  to a lower tier, and a new library takes the lowest tier that can express its
  role.

Phase 1a is complete when `src/membrane/root.zig` exports one comptime `census`
value containing the three counts, its compile-time ratchets pass at the pinned
values, and the current declared library graph passes the tier check.
`build.zig` adds the membrane module to `test-contract`. Pure validator fixtures
use synthetic tables and per-test custom limits so they independently reject an
import overrun, an export overrun, a semantic-operation overrun, an upward
library edge, and a same-tier library edge. `nix-shell --run 'zig build
test-contract'` is the acceptance command.
Phase 1a does not create behavioral goldens or performance baselines.

#### 1b. Negotiation

- Add ABI major and required-feature negotiation before plugin initialization.

#### 1c. Boundary ratchets

- Record, then monotonically reduce, exported runtime declarations named for
  editor policy: `buffer`, `mode`, `menu`, `picker`, `pane`, `cursor`,
  `statusline`, `gutter`, `tab`, `breakpoint`, `which-key`, and `transient`.
  The check applies to production declaration/import names, not comments,
  tests, or native implementations of public protocol adapters.
- Record, then monotonically reduce, concrete editor mode/key/command string
  literals and module-global mutable state in shared plugin libraries.
- `weak surface plane` means the current `wl_surface_*` import family and its
  host/plugin state. `Files` means `src/plugin_lib/files`.

### 2. Proven duplicate protocols

- Migrate completion to typed endpoints and delete its dedicated imports and callback.
- Unify command actions and semantic actions, migrate every provider, and delete name-based core fallbacks.
- Replace command invocation overloads and scalar metadata reads with one invocation and bulk descriptor exchange.
- Unify process, network, and REPL streams where operation and lifetime semantics match; enforce live revocation.
- Migrate the weak surface plane to retained views/projection and delete it.
- Remove test-only and unused membrane paths.

### 3. Explicit invocation and resources

- Replace ambient `command.Context` with narrow invocation records and explicit capability handles.
- Replace active-buffer scalar calls with captured entry/document handles and bounded bulk snapshots.
- Split protocol-specific state and teardown out of `WasmPlugin` into owner-scoped resources.
- Remove display-name session identity.

### 4. Vertical editor extraction

- Introduce workspace, text-state, and modeless-input plugins over the reduced contracts.
- Migrate the default behavior without changing key behavior or rendered output.
- Migrate Vim, Helix, and Emacs to the same input contract.
- Delete core built-in editor commands, bootstrap keymap, app command shadowing, and zero-plugin editor behavior.

### 5. Interaction and presentation extraction

- Move chooser, prompt, transient, confirmation, and which-key to scoped Wasm presenters.
- Move HUD, cursor, tabs, statusline, gutter, notifications, theme, and layout policy to Wasm providers.
- Delete picker, menu, HUD, mode, posture, transient, palette, and fixed-surface policy state from core and app.

### 6. Domain exception removal

- Replace ACP transcript helpers with plugin-owned models/documents/views.
- Replace DAP breakpoint and singleton status doors with typed providers.
- Port the resident ACP and DAP implementations from JavaScript to Wasm; QuickJS remains only the configuration evaluator.
- Replace process-to-buffer and named output buffer helpers with guest libraries.
- Remove editor policy from shared output libraries.
- Collapse Files to one editable retained view with stable typed identity.

### 7. Aggregate demolition

- Split remaining `System`, `Head`, and `Buffers` policy into scoped plugin instances and narrow native providers.
- Make app a composition root for platform providers, runtime creation, configuration loading, and event-source wiring only.
- Delete obsolete aggregates, aliases, compatibility paths, and the old API census baseline.
- Set the final lower ratchet from the resulting membrane.

## Verification

### Behavioral parity

The default manifest must preserve the behavior and resolved scene of commit
`d5e74ff` while ownership moves. The pinned baseline is the existing whole-app
behavioral suite plus `src/e2e/popup_layout_baseline.zon`; a migration phase
adds a golden before changing a surface only when those checks do not observe
it. Each vertical cut exercises the actual editor path, not only isolated
modules. The architecture migration does not redesign the UX.

### Public-path parity

Every bundled editor component is built and loaded as Wasm through the public membrane. A structural test rejects direct imports or native registrations of editor policy. No benchmark exception creates a private fast path.

### Zero-plugin contract

With no composition loaded, the runtime exposes no editor commands, modes, entries, picker, HUD, default bindings, or typing behavior. It can load and reconcile a manifest afterward.

### Replacement coverage

Before an old protocol is deleted, an end-to-end scenario must exercise the same observable behavior through its replacement. Tests defend behavior and failure semantics, not source spelling.

### Structural gates

Phase 1 activates the census, dependency, and no-new-violation ratchets that can
pass on the current tree. A canonical-plane or public-path gate becomes
mandatory in the same cutover that removes its legacy alternative. Final
build-time gates enforce:

- dependency tiers;
- no forbidden kernel ontology;
- no command-name or editor-policy literals in shared libraries;
- no module-global mutable shared-library state;
- one action plane, one view plane, one event path, and one lifetime model;
- non-increasing physical-import, physical-export, and semantic-operation
  censuses; and
- no bundled-plugin private transport.

### Performance

Input dispatch keeps the existing `e2e-latency` instrument and recorded
baseline; rasterization keeps `bench-raster`. Before a phase changes projection
publication or full-viewport assembly, that phase's reviewed plan must name the
document/model size, viewport dimensions, plugin set, build mode, hardware
provenance, command, and accepted regression rule, then record the baseline
before implementation. Regressions are addressed with coarser records, retained
diffs, bounded caching, and host execution over published data—not private
native policy.

### Failure coverage

Exercise malformed records, oversized payloads, stale and wrong-owner handles, revision conflicts, revocation during resource use, provider ambiguity, plugin failure during an interaction, queue saturation, cancellation, and teardown with queued events.

## API governance

A new physical door or semantic operation requires:

1. at least two independent real consumers;
2. explicit ownership, authority, lifetime, cost, bounds, and failure semantics;
3. analysis showing why composition from existing operations is incorrect;
4. deletion of enough obsolete doors or operations in the same clean cutover
   that the active ratchets do not increase; and
5. updated physical and semantic censuses.

This migration never raises a ratchet. A future product capability may revise a
post-migration baseline only through an explicit architecture decision; normal
feature work cannot.

Sharing a verb is not enough to unify operations. Conversely, changing only a noun is not enough to justify another operation. The test is whether the operation, authority, lifetime, and cost are genuinely the same.

## Acceptance criteria
The architecture is complete when:

- zero-plugin Weft is an inert runtime;
- the default editor is assembled entirely from Wasm plugins;
- bundled and third-party replacements use the identical public transport;
- core and app contain no editor input, workspace, interaction, or presentation policy;
- native document/effect/render providers expose only versioned public mechanisms;
- all stateful plugin calls use explicit handles rather than ambient active-buffer or singleton UI state;
- action, view, callback, and resource lifetime each have one canonical plane;
- every product-shaped legacy door named in the migration is removed;
- physical imports are below 231, physical exports are below 18, and semantic
  operations are below 249; none can increase silently;
- the default editor matches the pinned `d5e74ff` behavioral and scene
  baselines; and
- the pinned input and frame budgets are met without a private fast path.
