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

### Composition

Configuration evaluates to a sealed manifest containing:

- plugin instances and scopes;
- grants;
- typed value bindings;
- protocol providers;
- input grammar and intention bindings;
- presentation selection; and
- workspace assembly.

The runtime reconciles the manifest deterministically. The default editor is one bundled manifest. Plugin declaration order is not behavior.

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
- Every mutation carries a principal, subject revision, and invocation ID.
- Every asynchronous result arrives through one typed event export with an owned event envelope.
- ABI major and required protocol features are negotiated before initialization.
- Unsupported requirements reject the plugin before it acquires authority or publishes state.
- Expensive work is explicit in the operation: snapshot, commit batch, publish, patch, spawn, or read.
- Limits and partial results are represented in the contract; nothing truncates silently.

The raw ABI may use generated scalar parameters where Wasm requires them. The semantic operation remains one bounded typed exchange. Physical door count and semantic operation count are tracked separately.

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

Owns entry handles and labels, active and previous entry per head, focus history, and open/retire orchestration. Display names are labels only. It does not own keymaps, text editing, pane layout, or presentation.

### Text state

Owns cursor, selection, movement goals, insert/delete commands, and undo-unit boundaries. It depends only on the document contract and the focused-subject protocol.

### File session

Owns backing association, open/dedupe/save/reload behavior, dirty-close policy, and prompts. It does not own panes, keys, or rendering.

### Layout

Owns pane and viewport topology, split/focus/move behavior, placement decisions, and the relationship between focused viewport and presented entry. It consumes entry presentations rather than document internals.

### Input grammars

Modeless, Vim, Helix, and Emacs are separate plugins over the same input declaration contract. They bind shared intentions and do not import domain or presentation plugins.

### Interaction presenters

Chooser, prompt, transient, and confirmation are separate scoped providers. Each owns its retained view and interaction state. None is a kernel singleton.

### Presentation providers

Viewport, cursor, tabs, statusline, gutter, notifications, which-key, and theme are independent providers. They consume typed feeds and publish retained patches. Cursor appearance and blink behavior are presentation policy.

### Domain and service plugins

Git, files, LSP, DAP, ACP, completion, annotations, formatters, processes, and similar plugins expose typed intentions and endpoints. They do not own global keys, menus, or core-specific command names.

### Instance scopes

Every stateful plugin instance declares exactly one scope:

- system;
- head;
- workspace entry;
- viewport attachment;
- interaction;
- task; or
- service session.

The runtime mints the instance handle and tears down all owned resources exactly. This replaces `System`, `Head`, `WasmPlugin`, and named-buffer session state as cross-domain lifetime buckets.

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
- **Denied or revoked grant:** typed authority refusal; resource operations re-check live authority, or resources close when the grant is revoked.
- **Cancellation or timeout:** typed terminal result delivered exactly once.
- **Provider ambiguity:** no last-writer-wins behavior. Return a conflict with the same trace the resolver used.
- **Backpressure:** queues are bounded. Coalescing is allowed only when the event contract declares it; otherwise producers receive explicit pressure or refusal.
- **Plugin crash:** exact owner teardown removes handles, providers, bindings, interactions, retained views, and queued events.
- **Diagnostics:** the kernel emits structured diagnostic events. Presentation plugins decide whether they appear as a status message, log row, notification, or nowhere.

Expected domain failures do not trap. Protocol violations at the trust boundary do not become recoverable editor state.

## Migration

The migration is ordered to shrink the API before extracting behavior that would otherwise request more doors.

### 1. Structural gates

- Add ABI major and required-feature negotiation.
- Generate physical-door and semantic-operation censuses.
- Add a monotonic ratchet for both counts.
- Add plugin-library layer metadata and enforce dependency direction at build time.
- Ban editor presentation/workflow nouns from the runtime kernel, command literals and editor vocabulary from shared libraries, and module-global mutable library state.

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

The default manifest must preserve current editor behavior and resolved scene while ownership moves. Each vertical cut exercises the actual editor path, not only isolated modules. The architecture migration does not redesign the UX.

### Public-path parity

Every bundled editor component is built and loaded as Wasm through the public membrane. A structural test rejects direct imports or native registrations of editor policy. No benchmark exception creates a private fast path.

### Zero-plugin contract

With no composition loaded, the runtime exposes no editor commands, modes, entries, picker, HUD, default bindings, or typing behavior. It can load and reconcile a manifest afterward.

### Replacement coverage

Before an old protocol is deleted, an end-to-end scenario must exercise the same observable behavior through its replacement. Tests defend behavior and failure semantics, not source spelling.

### Structural gates

Build-time gates enforce:

- dependency tiers;
- no forbidden kernel ontology;
- no command-name or editor-policy literals in shared libraries;
- no module-global mutable shared-library state;
- one action plane, one view plane, one event path, and one lifetime model;
- non-increasing physical and semantic API censuses; and
- no bundled-plugin private transport.

### Performance

Before extraction, record current input dispatch, projection publication, and representative 1080p viewport costs. The identical Wasm path must satisfy the existing editor's measured input and frame budgets. Regressions are addressed with coarser records, retained diffs, bounded caching, and host execution over published data—not private native policy.

### Failure coverage

Exercise malformed records, oversized payloads, stale and wrong-owner handles, revision conflicts, revocation during resource use, provider ambiguity, plugin failure during an interaction, queue saturation, cancellation, and teardown with queued events.

## API governance

A new physical door or semantic operation requires:

1. at least two independent real consumers, except for an unavoidable base mechanism;
2. explicit ownership, authority, lifetime, cost, bounds, and failure semantics;
3. analysis showing why composition from existing operations is incorrect;
4. analysis of which existing operation or product-shaped door it replaces; and
5. updated physical and semantic censuses.

Sharing a verb is not enough to unify operations. Conversely, changing only a noun is not enough to justify another operation. The test is whether the operation, authority, lifetime, and cost are genuinely the same.

## Acceptance criteria

The architecture is complete when:

- zero-plugin Weft is an inert runtime;
- the default editor is assembled entirely from Wasm plugins;
- bundled and third-party replacements use the identical public transport;
- core and app contain no editor input, workspace, interaction, or presentation policy;
- native document/effect/render providers expose only versioned public mechanisms;
- all plugins use explicit handles rather than ambient active-buffer or singleton UI state;
- action, view, callback, and resource lifetime each have one canonical plane;
- every product-shaped legacy door named in the migration is removed;
- the physical and semantic API ratchets are lower than the current 231-import baseline and cannot increase silently;
- the default editor retains its current behavior and rendered scene; and
- measured input and frame budgets are met without a private fast path.
