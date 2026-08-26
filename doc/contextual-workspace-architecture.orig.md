# Contextual workspace and protocol architecture

Status: design proposal for review  
Date: 2026-08-25

## 1. Purpose

Weft must support text editing, file browsing, version control, language tooling,
debuggers, terminals, agents, collaboration, and interfaces that have not been
invented yet. None of those domains, and none of Vim, Emacs, keyboard input,
pointer input, or a particular renderer, may be privileged in the architecture.

The common substrate is not a universal buffer or universal object. It is:

- provider-owned identity;
- versioned typed protocols;
- generation-checked behavioral endpoints;
- pure contextual resolution;
- explicit component lifetimes;
- effect authority and provenance; and
- replaceable local workspace and presentation systems built on those pieces.

Text documents, file hierarchies, Git repositories, menus, and connected peers
are compositions over that substrate. They are not variants of one giant type.

This document defines the architecture, the problems it is intended to solve,
the boundaries it deliberately preserves, and the migration and acceptance
criteria for adopting it across every shipped plugin.

## 2. Problems to solve

### 2.1 Every workspace entry is secretly an editor

`Buffer` currently embeds an `Editor`, mode, read-only state, and semantic focus.
Attaching structured content creates an empty editor and marks it read-only.
That makes text storage and text-editing policy prerequisites for presenting
anything in the workspace.

Consequences include:

- Files and Git appear as exceptional, read-only text buffers.
- Undo is routed to editor history even when the focused operation belongs to a
  filesystem draft, repository workflow, or interaction.
- Structured views need locked modes and special dispatch paths to prevent text
  editing from leaking through.
- Workspace navigation, resource identity, title metadata, cursor state, and
  editor state are coupled.
- Two panes cannot naturally show one resource with independent focus, folds,
  selections, input modes, and scroll positions.

### 2.2 Unhandled key events become text insertion

Physical key input and committed text are conflated. An unbound printable key
can fall through to insertion into the active editor. This is why Tab can insert
a byte into a file-browser draft instead of expanding a directory.

This is not a missing Files binding. It is a wrong input boundary. A keybinding
grammar should interpret physical keys. An editable endpoint should receive
text or IME commits. Failure to handle the former must never synthesize the
latter.

### 2.3 Plugin interoperability depends on concrete command names

Input plugins and domain plugins know too much about one another. Examples
include semantic-view branches in Vim, Helix invoking Vim commands, Git owning
its own locked mode and keymap, and Make depending on Run's private mode and
command names.

This prevents hypothetical input, UI, or domain plugins from composing without
coordination. It also makes which-key describe implementation commands rather
than the contextual behavior the user will receive.

### 2.4 Presentation identity is mistaken for domain identity

Retained scene nodes currently combine visual content, focusability, facts,
targets, and action advertisements. Action dispatch then routes through the
plugin that owns the view.

This prevents a third-party provider from contributing `copy path`, `open in
terminal`, or another compatible operation to a Files row. It also encourages
row numbers, rendered byte ranges, or scene node identifiers to become durable
semantic identity.

Git exposes the failure sharply: its model keeps tree nodes alongside byte
ranges into rendered text, restores focus heuristically, and parses or renders
large repository state under fixed limits. Neither every diff line as a global
object nor the whole status page as opaque text is an acceptable answer.

### 2.5 Workspace actions, commands, and UI affordances are separate worlds

The command palette enumerates string command names. Which-key sees key-to-
command mappings. Semantic scenes advertise a small owner-controlled action
list. Pointer hits mostly change focus. Toolbars, context menus, actionable
status items, generic forms, and accessibility controls do not share a complete
dispatch contract.

Consequences include:

- Keyboard bindings cannot explain which provider will handle an intention.
- Buttons and menus would have to synthesize keys or call concrete commands.
- Disabled reasons, parameters, check state, async progress, and multi-selection
  behavior cannot be represented consistently.
- A new action provider does not automatically appear in generic discovery UI.

### 2.6 Background work depends on ambient workspace state

Several asynchronous paths target a named buffer or recover the active editor.
Plugin modules frequently hold one global session. Results can therefore be
routed to whichever view happens to be active later, and multiple repositories,
REPLs, conversations, or debugger sessions interfere.

Every asynchronous operation needs a captured resource identity, revision,
requesting principal, authority, cancellation lifetime, and interaction port.
It must never rediscover authority or destination through the current head.

### 2.7 Effect authority differs by plugin runtime and transport

WASM, JavaScript, in-process, and connected-peer effects do not consistently
pass through the same grant checks. Catalog visibility can be confused with
permission. Broad connection grades cannot express "edit this document and use
document-scoped LSP, but do not read the project or run processes."

This becomes dangerous once an action can execute on a coworker's repository,
filesystem, language server, debugger, or process host.

### 2.8 Sharing is too coarse

A resource contains state with different sharing semantics. Sharing a document
does not imply sharing Vim mode, folds, clipboard, easymotion overlays, presence,
diagnostics, filesystem access, or LSP access. Git status may be useful to share
while staging and pushing are not. A commit draft may be collaboratively edited
even though the repository remains owner-authoritative.

A single "shared buffer" or per-resource boolean cannot express this safely.

### 2.9 Silent limits and false uniformity hide costs

Some plugins use fixed-size arrays or byte limits and then present truncated
work as success. A complete retained scene can also impose unbounded cloning or
validation costs. Undo and atomic transactions are presented as if all domains
could support editor-like reversal.

Large or remote work must report whether it is complete, partial, streaming,
windowed, cancellable, compensatable, or irreversible.

## 3. Goals

The architecture must provide:

1. Equal participation for text, structured resources, and rich hybrid tools.
2. Input plugins that bind shared intentions without importing domain plugins.
3. Domain plugins that expose behavior without owning keys, menus, or toolbars.
4. One contextual resolution substrate usable by keyboard, pointer, menus,
   palettes, toolbars, accessibility, agents, and remote peers.
5. Stable provider-owned identity without a global object hierarchy.
6. Multiple independent instances of every session-like plugin.
7. Explicit local, per-pane, replicated, shareable, and derived state.
8. Uniform authority checks for WASM, JavaScript, native, and remote execution.
9. Useful generic fallback UI under asymmetric plugin installations.
10. Honest failure, partial-result, revision, undo, and atomicity semantics.
11. Pure explanation of binding and provider resolution.
12. Bounded presentation contracts for very large or highly specialized views.

## 4. Non-goals

The design explicitly does not introduce:

- a universal `Object`, `Subject`, or global semantic object registry;
- a stored universal `Facet` property bag;
- a `{ text, semantic }` workspace-entry content union;
- a free-form inter-plugin or peer-to-peer message bus;
- a closed core enum of action, resource, or facet kinds;
- Git, LSP, DAP, ACP, Vim, rendering, or menu policy in the runtime kernel;
- one universal undo stack;
- universal cross-resource atomic transactions;
- mandatory scene nodes for every domain element;
- automatic sharing of workspace entries or local presentation state;
- execution of provider code merely to render or explain a menu;
- magical keybindings for domain-specific verbs unknown to an input grammar;
- plugin code distribution or trust based on a remote plugin name; or
- compatibility wrappers that make migrated plugins retain both architectures.

## 5. Layering

### 5.1 Runtime kernel

The runtime kernel owns only mechanisms required by any composition:

- generation-checked handles and exact owner teardown;
- component and endpoint instance routing;
- canonical schema and version identifiers;
- principals, scoped grants, revocation, and effect attribution;
- cancellation, deadlines, backpressure, and invocation identifiers;
- pure provider eligibility and deterministic conflict resolution; and
- resolution traces produced by the same algorithm used for dispatch.

The kernel knows neither buffers nor menus. A headless formatter or service host
can use it without constructing a workspace.

### 5.2 Standard workspace composition

The standard workspace is a replaceable composition that owns:

- targets and opening;
- workspace entries;
- panes and viewports;
- focus, selection, and navigation;
- presentations and interactions;
- the contextual action catalog;
- input routing and binding description;
- history and transfer protocol packages; and
- generic table, tree, text, hex, form, and download presentations.

These are standard facilities, not hard-coded kernel ontology.

### 5.3 Protocol packages

Protocol packages declare namespaced, versioned contracts. The runtime treats
their identifiers and payload schemas as opaque. Standard packages can define:

- target activation and opening;
- hierarchy expansion and traversal;
- editable sequences and structural extents;
- navigation and history;
- transfer and clipboard operations;
- filesystem hierarchy, metadata, and permissions;
- VCS repositories, revisions, diffs, drafts, and mutations;
- language queries, diagnostics, and proposed changes;
- debugger sessions and breakpoint stores; and
- interactions, tasks, progress, and cancellation.

Novel plugin-specific protocols remain valid. They simply lack automatic key
placement until an input or UI plugin understands them; generic catalog UI still
exposes their self-describing actions.

### 5.4 Plugins

Plugins implement one or more scoped roles:

- model or resource provider;
- protocol endpoint;
- presentation provider;
- input grammar;
- interaction presenter;
- query/feed/task service;
- menu, toolbar, palette, pointer, or accessibility policy; or
- collaboration publication and share-sheet policy.

A code module is not a singleton service. Runtime instances have explicit
scopes: system, head, workspace entry, viewport attachment, interaction, task,
or service session.

## 6. Identity and reference types

### 6.1 Resource reference

`ResourceRef` is a generation-checked route to a provider-owned resource. It is
opaque outside the owning runtime or translated explicitly at a collaboration
membrane.

### 6.2 Revision token

`RevisionToken` is an opaque provider-defined equality or causal witness. It is
not assumed to be a globally ordered integer. A filesystem snapshot, CRDT
frontier, Git repository snapshot, and LSP document version have different
revision semantics.

### 6.3 Designation

A `Designation` identifies externally meaningful content:

```text
Designation {
  resource: ResourceRef
  revision: RevisionConstraint
  locator_protocol: ProtocolRef
  locator_payload: typed value
}
```

Examples include a file entry identifier, a commit OID, a snapshot-scoped Git
hunk locator, a source location, or a field in a structured document.

Designations may be durable, revision-scoped, leased, or ephemeral. Their
lifetime and comparison rules are declared by the locator protocol.

### 6.4 Focus reference

`FocusRef` is local to a presentation revision. It supports hit testing,
keyboard traversal, and best-effort focus restoration. It is not authority and
need not designate domain content.

A fold chevron, separator, placeholder, or easymotion label can have a focus
reference without becoming a domain object.

### 6.5 Endpoint reference

`EndpointRef<Protocol>` is a generation-checked behavioral address. Requests
are typed by the protocol, directed to one endpoint, and invoked with the
caller's authority. Possessing a reference does not confer permission.

Provider discovery selects or constructs endpoints. Ordinary endpoint requests
do not perform global provider lookup again.

### 6.6 Extent and selection

An `Extent` is a revision-stamped selection shape. It may be:

- a contiguous text range;
- a collection of designations;
- a structural range;
- a rectangular or spatial region; or
- a provider-defined, explicitly leased shape.

`Selection` is one or more extents plus anchor/focus posture. Operations declare
whether they require a whole set, can map independently over each item, require
a homogeneous set, or can operate on an explicitly disclosed subset.

No action silently operates on only the compatible portion of a selection.

## 7. Workspace model

```text
Workspace
  entries: WorkspaceEntryRef -> WorkspaceEntry

WorkspaceEntry
  represented target/resource
  presentation attachment policy
  title/lifecycle metadata
  no compulsory Editor

Head
  panes: PaneRef -> Viewport
  active pane
  interaction stack

Viewport
  workspace entry
  presentation instance
  focus and selection
  scroll and folds
  input-provider instance/state
  navigation history
```

The user-facing term "buffer" may remain as the conventional name for an open
workspace entry. It does not imply text, editability, storage ownership, or
service lifetime.

Workspace entries are local. Two collaborators may create different entries
and presentations for the same replicated or remotely exposed resource.

Titles derive from the current represented target or presentation metadata
unless locally overridden. Navigating a Files entry therefore updates its title
without renaming an unrelated editor buffer.

## 8. Protocol operations

Protocol operations use orthogonal metadata:

```text
cardinality: one | many
lifetime: finite | subscription
effect: observe | propose | mutate
composition: first | ordered_union | ranked_merge
```

Common SDK conventions are:

- **Action:** finite, normally one terminal outcome, one selected provider.
- **Query:** finite, one or many observations, optionally composed.
- **Feed:** a backpressured subscription producing many values.
- **Service:** an endpoint exposing multiple protocol operations.

These are conventions over the protocol machinery, not mutually exclusive
kernel object classes. An action may return a task that emits progress. A query
may be remote and cancellable. A finite feed may naturally terminate.

Provider fallback is resolved before invocation. There is no post-effect
`declined` chain. Once an endpoint begins work, failure is reported as failure,
not permission to try an alternative that might duplicate effects.

## 9. Contextual actions and resolution

### 9.1 Four distinct values

#### Action contract

An `ActionContract` defines semantic interoperability:

- namespaced protocol identity and compatible version;
- input and output schemas;
- required designation and extent shapes;
- selection cardinality rules;
- effect grade and authority requirements;
- reversibility and confirmation characteristics;
- concurrency or deduplication key; and
- possible result kinds.

#### Action offer

An `ActionOffer` is a contextual, revision-stamped applicability result:

- captured designations and extents;
- provider and provenance;
- availability or disabled reason;
- toggle, radio, or mixed state;
- required grants and effect scope;
- latency/lifetime hints;
- opaque endpoint/decision reference; and
- expiry and revision constraints.

Catalog visibility is never authority. Invocation rechecks grants, endpoint
generation, publication epoch, and revisions at the effect door.

#### Action presentation

`ActionPresentation` contains fallback UI metadata only:

- default label and description;
- compact label;
- icon token;
- logical category and search tags; and
- localization keys plus mandatory fallback strings.

It has no dispatch or authorization semantics.

#### Affordance contribution

An `AffordanceContribution` suggests stable placement on a menu, toolbar,
status area, or hover surface. It refers to action protocols or selectors, not
concrete plugin commands. It contains logical group identifiers, before/after
constraints, compactness, and overflow priority.

Presentation policy can override or ignore it.

### 9.2 Catalog API

Conceptually:

```text
catalog(context, designations, selection, include_disabled)
  -> CatalogSnapshot

resolve(snapshot, action_or_intent, parameters)
  -> Decision | NeedInput | Unavailable

invoke(decision, fresh InvocationContext)
  -> Outcome

explain(snapshot, binding_or_intent)
  -> ResolutionTrace
```

The catalog unions:

1. intrinsic offers from the addressed resource;
2. contributed operators whose protocol requirements match; and
3. contextual workspace/global offers.

A presentation owner may contribute intrinsic actions, but cannot monopolize
all operations on its designations.

Equal strongest providers are an explicit ambiguity. Resolution never depends
on plugin load order.

### 9.3 Availability

Availability is richer than a boolean:

```text
enabled
disabled { reason_code, fallback_message, remediation_action? }
checking { task_ref? }
```

Absence means nonapplicable. Disabled means relevant but currently impossible.
All UI styles expose the same state and sanitized explanation.

### 9.4 Parameters and outcomes

Parameter schemas support required and optional values, defaults, constraints,
enumerations, dynamic completion queries, validation, sensitive fields, and
schema versioning.

Missing information returns `NeedInput`, represented as an interaction. A
generic form plugin can render it. Specialized presentations may replace the
form without changing the action.

Outcomes may include:

- a completed typed result;
- an interaction;
- a task or service resource;
- a change proposal;
- a designation to activate; or
- a request to open a workspace entry.

Menus do not retain provider frames while asynchronous work runs.

### 9.5 Pure resolution traces

Explanation is not an executable authority token. A trace records:

1. physical binding resolution;
2. input-state transition or fallback intentions;
3. semantic action intention;
4. offer eligibility and provider selection;
5. selected endpoint and locus;
6. explicit workflow steps authored by the binding; and
7. rejected alternatives with safe reasons.

The trace comes from the same pure resolution functions used for dispatch.
Rendering or explaining it executes no provider callbacks and performs no
effects. Dynamic providers appear as such rather than being probed.

## 10. Input architecture

### 10.1 Separate physical input from text commits

```text
PhysicalInput
  key symbol, modifiers, pointer gesture, device metadata

TextCommit
  committed Unicode/IME text
```

An input provider is a scoped state machine that consumes physical input and
emits semantic intentions or explicit sequences. Editable content receives
`TextCommit` through an editable protocol endpoint.

Unhandled physical input remains unhandled. It never becomes editor insertion.

### 10.2 Binding shared intentions

Input plugins bind standard protocol intentions:

```text
Tab    -> hierarchy.toggle-expanded
Return -> first applicable [target.activate,
                            editing.insert-line-break]
q      -> navigation.back
u      -> history.undo
```

Fallback lists are authored by the input grammar and resolved before any
operation executes. Word motions apply only when an appropriate sequence or
structure protocol is available.

A novel domain operation is still discoverable through catalog UI. Input
plugins may additionally bind shared abstract gesture roles such as activate,
expand, promote, demote, discard, confirm, and cancel.

### 10.3 Binding description

Input providers expose pure forward and reverse descriptions:

```text
describe_prefix(input_state, prefix) -> binding traces
describe_action(action, context) -> local gesture hints
```

Which-key shows the winning key-to-intent-to-endpoint trace. Compact mode shows
one row plus an `...+N` indicator; a normal which-key action toggles the full
trace. Menus use reverse lookup to display the requesting head's local shortcut.

Buttons and menu items invoke offers directly and never synthesize keypresses.

## 11. Presentation and IDE UI

### 11.1 Presentation contract

A presentation maps resources/designations to visuals and maps hits, focus, and
selections back to focus references and designations. It publishes title and
navigation metadata independently of the workspace entry's original name.

The retained semantic scene remains one useful presentation format. It is not
the universal domain model.

### 11.2 Controls

Visual controls refer to semantic action protocols and optionally bound
parameters:

```text
Control {
  designation_or_selection
  action_protocol
  bound_parameters?
  accessible_name_override?
}
```

The same mechanism supports a Files expansion chevron, Git Stage button,
confirmation button, status chip, toolbar item, and accessibility activation.

### 11.3 UI policy plugins

The following remain plugins, not kernel policy:

- command palette;
- context menu;
- menu bar;
- toolbar and overflow policy;
- pointer gesture policy;
- generic form and dialog presenter;
- status and hover action presenters;
- icon packs and localization;
- platform accessibility bridge; and
- which-key.

Context menus and palettes enumerate applicable catalog offers automatically.
Stable menu and toolbar placement consumes affordance contributions. Missing
placement metadata never hides an action from generic discovery.

### 11.4 Conflict rules

- Multiple providers of one compatible action resolve to one semantic item with
  explainable alternatives.
- Same contribution identifier is tier-overridden; an unresolved same-tier
  cross-owner tie is an error.
- Ordering uses logical group IDs and before/after constraints. Cycles are
  rejected with provenance.
- Duplicate placement is deduplicated unless explicitly declared as a
  parameterized alias.
- Local configuration overrides plugin placement hints, which override fallback
  presentation metadata.
- Stale offers re-resolve against their captured designations or become
  unavailable; they never retarget current focus.

### 11.5 Accessibility

Portable presentation semantics include stable accessible identity, role,
name, description, value, checked/mixed/expanded/busy state, disabled reason,
focus order, relationships, and the same action reference used by pointer and
keyboard activation.

Custom/native presenters must supply an equivalent bounded accessibility view.

### 11.6 Rich and large presentations

A custom presenter may own layout, virtualization, and hit testing. It must
still expose:

- snapshot/delta revision;
- stable visible-item keys;
- lazy/windowed child requests;
- explicit total, unknown, or partial status;
- focus and hit mapping;
- designation and extent mapping where available;
- catalog context;
- title and navigation metadata; and
- a bounded semantic/accessibility window.

No renderer is required to materialize an entire repository, result set, or
debugger tree. Fixed limits must produce explicit partial/refused outcomes with
continuation or progress, never success-looking truncation.

## 12. Effects, change proposals, and history

Every invocation carries:

- invocation identifier;
- requesting principal;
- executing provider;
- designation and revision;
- delegated grant set;
- cancellation and deadline;
- requesting interaction port; and
- effect provenance recorder.

Effect grades include at least:

- atomic within one owning store;
- preflight then commit;
- compensatable;
- best effort; and
- irreversible remote.

A change proposal describes intended effects and their atomic scope. It does
not promise a transaction across a CRDT, filesystem, Git subprocess, debugger,
and remote service. Cross-store workflows are explicit sagas with preview,
per-step outcomes, and sound compensations where available.

History is a protocol owned by the mutated model:

- text history may invert attributed CRDT commits;
- a Files draft may undo pending rename, delete, or permission edits;
- an applied filesystem mutation may expose a revision-safe inverse;
- Git may expose `unstage`, but it does not masquerade as editor undo;
- processes and remote effects usually have no inverse.

The provenance record distinguishes the human initiator from the executing
plugin. Running during a keypress does not make a helper plugin "the user."

## 13. Collaboration

### 13.1 State classification

Sharing attaches to exported protocols, not an entire resource:

| Class | Meaning | Examples |
| --- | --- | --- |
| Private | Never exported implicitly | layout, keymaps, Vim mode, folds, clipboard, menus, picker state, easymotion |
| Replica | Explicitly synchronized canonical state | text CRDT, shared commit draft, review comments, collaborative plan |
| Endpoint | Owner-authoritative query/feed/action | Files hierarchy, Git status/stage, LSP, debugger |
| Derived | Recomputable local observation/presentation | syntax, local projections, toolbar layout, cached status rendering |

Presence is an optional lossy feed derived from private head state. Sharing text
does not enable it automatically.

### 13.2 Publications

```text
Publication {
  id
  owner: ParticipantId
  resource
  audience
  epoch
  lifetime
  exports[]
}

Export =
  Replica { protocol, admission_policy }
  Endpoint { protocol, operation, locus }
```

A publication is the authority and lifetime boundary. Unpublishing revokes its
exports, advances the epoch, and invalidates translated references.

Channels are transport details. Their meaning comes from versioned publication
descriptors, not a fixed text/graph/document-channel enum.

### 13.3 Local versus remote execution

1. Presentation and input always run on the requesting head locally.
2. Replica edits are authored locally and admitted by the replica protocol.
3. Effects over owner-authoritative resources run at the resource's locus.
4. Pure analysis may run locally when inputs and permission are local.
5. Queries and feeds run where their required world state exists.
6. Interactions render for the human who must answer them.
7. Dispatch traces disclose endpoint locus and relevant data movement.

Remote mutation uses an at-most-once key based on participant, publication,
epoch, and invocation ID. A reconnect can retrieve a cached outcome but cannot
repeat a commit, push, filesystem write, or debugger command.

### 13.4 Asymmetric plugin installations

Peers negotiate protocol identities, compatible version ranges, and canonical
schema digests. They do not exchange plugin names as interoperability claims.

- Rich compatible plugins on both sides yield independent preferred local UI.
- Missing specialized UI falls back to generic tree/table/text/form/catalog UI.
- A local presentation can consume a compatible remote standard protocol.
- A required owner-side endpoint that is absent makes the operation unavailable.
- A pure local plugin may analyze locally possessed replica data.
- Unknown optional presentation metadata is ignored.
- Unknown required semantics or incompatible schema versions fail closed.

Raw Git CLI, LSP, DAP, ACP, and JSON-RPC streams are not exported as generic
service tunnels. Collaboration exposes typed protocol subsets.

### 13.5 Grants

Connection-level roles may exist as user-facing presets or maxima. Effective
authority is per publication export:

```text
Grant {
  grantee: ParticipantId
  publication_and_epoch
  protocol_and_operation_set
  target/resource scope
  data-egress and effect rights
  lifetime, quota, and conditions
  provider-enforced attenuation
}
```

Remote authority is the intersection of:

```text
owner grant to authenticated peer
AND requester grant to the invoking local plugin
AND endpoint resource scope
AND live publication epoch and revision
```

The owner trusts the authenticated participant, not a remotely asserted plugin
name. Plugin identity remains provenance.

Grant knowledge distinguishes unknown, explicitly unconfined, and constrained.
Missing or malformed grant state never means unrestricted.

### 13.6 Low-prompt sharing UX

A collaboration UI plugin builds one preview from publishable interfaces:

```text
Share "parser.zig" with Maya until disconnect

[x] Edit this document
[x] See my cursor
[x] Code intelligence for this document
[ ] Read the rest of the project
[ ] Modify project files
[ ] Git status and diffs
[ ] Stage, commit, or push
[ ] Run processes or debugger
```

Presets compile to atomic grant bundles:

- **Look together:** selected resources read-only, optional presence.
- **Pair:** selected document edit, presence, document-scoped language service.
- **Review:** repository status/diff and shared review artifacts, no mutation.
- **Project work:** selected root read and code intelligence; writes, process,
  Git mutation, and debugger control remain explicit additions.

One confirmation approves the bundle. Allowed operations do not prompt again.
An unavailable action can request access; the resulting interaction shows one
batched delta rather than a sequence of per-call prompts. Grants may last once,
until disconnect, for this collaboration/project, or persist for a verified
participant. Every grant, escalation, denial, invocation, and revocation is
auditable, with secret parameters redacted.

### 13.7 Offline and version-skew behavior

- Replicas continue offline only when their grant permits offline authorship.
  Rejected reconnect edits become a visible recoverable fork.
- Session-scoped replicas become read-only while disconnected.
- Queries fail or select an eligible local fallback.
- Feeds suspend and resume from a cursor when replayable; otherwise they refresh.
- Remote mutation actions are never automatically queued.
- Cached owner data remains visible as stale with provenance.
- Unpublished endpoint references become stale.
- Protocol major or schema mismatch makes an offer unavailable with explanation.
- Compatible minor versions are negotiated before payload exchange.

## 14. Domain applications

### 14.1 Text

Text is a resource implementing sequence, edit, extent, persistence, and history
protocols. Its optimized CRDT model and renderer remain specialized.

Cursor, selection, folds, Vim mode, and easymotion are viewport-private. Text
replication, presence, diagnostics, and LSP are independent collaboration
exports. Editing text never requires other resources to pretend to be text.

### 14.2 Files

Files models filesystem entries with provider-owned entry identity and revision.
It exposes hierarchy, activation, metadata, permissions, draft, persistence,
and history protocols.

Expected generic behavior:

- Tab resolves `hierarchy.toggle-expanded` and never inserts text.
- Return activates the selected target.
- `q` resolves workspace navigation back.
- The title follows the currently represented directory.
- Permission editing invokes a typed action and generic or specialized form.
- Pending mutations use Files draft history; applied effects expose inverses only
  when revision-safe.
- A third-party provider can contribute `copy path` without modifying Files.
- Context menus enumerate row actions automatically.
- Toolbar contributions may place Refresh, New, Apply, and Revert.
- Remote hierarchy, byte reads, metadata writes, and semantic services require
  separate grants.

The public names are `files` and `file-browser`. Persisted `dired` terminology
must be removed during migration.

### 14.3 Git

Git is the deliberate rich-surface test:

```text
Repository
  immutable/snapshot status model
    ChangeSection
      ChangedFile
        Hunk
  Commit / Branch / Stash
  CommitDraft
  RebasePlan
  repository tasks and feeds
```

Identity rules differ by element:

- commit OIDs are durable designations;
- refs are revisioned names;
- working paths and hunks are snapshot-scoped;
- focus restoration may use correlation hints but never grants authority.

The status presentation is hybrid: semantic sections/files/hunks plus embedded
monospaced diff extents. It may use a custom virtualized presenter. It does not
create a global object for each diff line or parse rendered text to recover
identity.

Partial staging is offered only when the selected text extent translates
exactly through the current diff mapping. Stale snapshots disable or re-resolve
the action.

Commit and rebase drafts may be workspace entries or replicas. Confirmations
and option collection are interactions. Fetch, push, rebase, and refresh return
tasks. Stage, commit, worktree mutation, rebase, push, and force operations are
separate protocols and grants. Compensating operations are named honestly; Git
effects do not claim universal undo.

Generic VCS menus and UI work without Git-specific command names. Specialized
Git UI remains optional. The public name is `git`, not `magit`.

### 14.4 LSP and completion

Completion is a cancellable query. An LSP workspace is a service with concurrent
request identities, diagnostic feeds, typed locations, and change proposals.

Cross-file results carry designations and grants rather than being discarded or
forced into the active buffer. Workspace edits preflight each owning store and
report their real atomic scope.

Remote LSP exports typed language protocols, never JSON-RPC. Document-scoped
code intelligence filters results and opening to the granted document. Project
symbols, file reads, and workspace edits require explicit wider grants.

### 14.5 Pickers, palette, and which-key

A picker is an interaction presentation over typed candidate values or
designations. Candidate identity does not live in a parallel row-index array.

The palette enumerates action offers, not command strings. Which-key consumes
batched binding-resolution traces. Both can show unavailable reasons and invoke
stale-safe offer references.

### 14.6 Processes, results, console, and REPL

Shell, Run, Grep, and Make use process/session resources, output feeds, and typed
result or diagnostic sets. Locations are carried as values, not recovered by
parsing rendered output. Make does not depend on Run's private mode.

Console is a prompt field, output feed, and history composition. REPL is an
instantiable process session. Neither requires a singleton named output buffer.

### 14.7 Debugger, DAP, ACP, and agents

DAP exposes debugger-session resources with typed threads, frames, scopes,
variables, and an anchored breakpoint store. Observe, control, evaluate, memory
access, and process launch have distinct authority.

ACP conversations and tool calls are instantiable sessions. Concurrent tool
calls and permission interactions retain their own continuation identities.
Interactions render at the answering participant; transient UI is not
replicated.

### 14.8 Network, HTTP, project, direnv, and notes

Network and HTTP expose connection, byte-stream, request, and response resources
with generic text, hex, and download fallbacks.

Project resolves roots and project-scoped services. Direnv provides an explicit
project-environment protocol/feed consumed by processes and language services.
Notes is a target/capture/persistence workflow, not a copied file in an unrelated
scratch buffer.

## 15. Deliberate failure boundaries

Providers and UI fail honestly under these conditions:

1. No stable visual-to-designation mapping: expose only presentation/root
   actions; do not guess.
2. Selection cannot translate to the required extent: do not offer the action.
3. No safe inverse: do not offer `history.undo`.
4. Collection is partial: label it partial and expose continuation/progress.
5. Revision changes after resolution: re-resolve or return stale before effect.
6. Unknown domain action has no binding: retain catalog discovery; do not assign
   a magical key.
7. More information is required: return an interaction.
8. Async identity is stale: fail; never retarget active focus.
9. Cross-store atomicity is unavailable: disclose the saga/effect grade and
   per-step outcomes.
10. Specialized renderer is absent: use generic typed fallback.
11. Service outlives its view: detach the workspace entry; stop only under its
    declared lifetime policy.
12. Feed is high-rate: require incremental delivery and backpressure.
13. Grant is denied or revoked: invocation fails even if a cached offer remains.
14. Capacity is exceeded: return refused/partial, never truncated success.
15. Operation is plugin-specific: keep a typed opaque leaf with clear
    provenance.
16. Provider eligibility is dynamic: explain it as dynamic without executing it.
17. Remote owner is offline: do not queue mutations; show cached data as stale.
18. Protocol/schema is incompatible: fail closed with a compatibility reason.

## 16. Plugin conformance map

Every shipped plugin is in scope:

| Area | Plugins | Required seam |
| --- | --- | --- |
| Input grammar | `vim`, `emacs`, `helix`, `motions`, `textobjects`, `operators`, `modes` | Scoped input state and shared protocol intentions |
| Text/structure | `edit`, `structural`, `ts`, `region`, `comment`, `indent`, `whitespace`, `numbers`, `autopair`, `snippets`, `fmt` | Typed revisioned extents and transform protocols |
| Language | `complete`, `lsp` | Queries, feeds, typed locations, change proposals |
| Discovery/layout | `palette`, `consult`, `buffers`, `windows`, `which_key`, `project` | Typed candidates, catalog offers, workspace/viewports |
| Rich resources | `files`, `git`, `grep`, `run`, `make`, `notes`, `debug`, `dap`, `acp`, `llm`, `console`, `repl` | Resources, presentations, interactions, tasks, services |
| Environment/transport | `direnv`, `shell`, `net`, `http` | Explicit environment, process, stream, request/response endpoints |
| Shared libraries | `weft.zig`, `jsonrpc.zig`, `buffer_order.zig`, Files modules | SDK and transport implementation, not catalog objects |

Permission, filesystem-limit, schema-extension, and semantic-lifecycle fixtures
become conformance tests for the endpoint, publication, and authority contracts.

## 17. Migration plan

Each migrated plugin receives a clean cutover. Legacy v1 commands may remain
temporarily as explicitly opaque legacy entries, but no semantic compatibility
adapter may make a migrated plugin depend on both architectures.

### Phase 1: contracts and security

1. Ratify names, identity types, protocol versioning, operation/effect metadata,
   collaboration threat model, and plugin conformance matrix.
2. Unify principals, grants, revocation, provenance, and effect enforcement for
   WASM, JavaScript, in-process, and remote paths.
3. Introduce invocation IDs, cancellation, deadlines, and audit records.

### Phase 2: runtime endpoints and workspace separation

1. Add scoped endpoint/component instances and exact owner teardown.
2. Add pure provider resolution and traces.
3. Split workspace entries from editors.
4. Add pane-local viewport state and correct unfocused rendering.
5. Eliminate dummy editors and read-only/locked-mode type compensation.

### Phase 3: input and contextual actions

1. Separate physical key/pointer input from text commits.
2. Migrate Vim, Emacs, and Helix together without semantic-view branching.
3. Add action contracts, offers, availability, parameter schemas, resolution,
   invocation, and binding-description APIs.
4. Move dot-repeat, register grammar, and macros out of core.

### Phase 4: generic UI

1. Add semantic controls, pointer routing, and accessibility semantics.
2. Migrate palette and which-key.
3. Add generic context-menu and form/dialog plugins.
4. Add affordance contributions and menu/toolbar plugins.

### Phase 5: Files vertical slice

Migrate Files completely: hierarchy, activation, live title, navigation back,
permissions, multi-selection, drafts/history, persistence, third-party actions,
generic UI, two-pane behavior, and no input-plugin knowledge.

Delete its old view-owner dispatch path and all `dired` identifiers at cutover.

### Phase 6: connected text and Files

1. Add participant identity, publications, exports, grant bundles, epochs,
   unpublish/revoke, protocol negotiation, and remote handle translation.
2. Separate text replica, presence, diagnostics, and LSP exports.
3. Export Files hierarchy, bytes, metadata, and mutations independently.
4. Prove asymmetric plugin fallback and offline behavior.

### Phase 7: discovery and process/session plugins

Migrate pickers, buffers, project, shell, run, grep, make, console, REPL, net,
HTTP, direnv, notes, and LLM. Remove row/string identity, named-buffer async
routing, cross-plugin private commands, and singleton sessions.

### Phase 8: Git exemplar

Split Git into repository service, snapshot/model, hybrid presentation, patch
planner, interactions/workflows, drafts, and tasks. Prove large repositories,
two repositories, pointer and keyboard UI, generic fallback, collaborative
drafts, read-only review sharing, and separately granted mutations.

Delete locked Git modes/keymaps and remaining `magit` naming at cutover.

### Phase 9: language, debugger, and agent services

Migrate LSP, then Debug/DAP and ACP. Use their concrete requirements to finish
shared query/feed machinery, concurrent request/session handling, remote
interactions, and multi-resource change proposals.

### Phase 10: remaining plugins and demolition

Migrate remaining transforms and structural providers. Remove every legacy
semantic-buffer, active-editor, action-to-command trampoline, view-owner action,
fixed collaboration channel, and ambient authority path.

## 18. Acceptance gates

The architecture is not complete until all of these hold:

### Workspace and input

- A workspace entry contains no compulsory editor/document and no read-only or
  locked type flag.
- The same Text, Files, or Git resource can appear in two panes with independent
  focus, selection, scroll, folds, and input state.
- Two heads can focus different entries without a system-global active buffer.
- Tab on an expandable Files entry toggles it; otherwise Tab does not become
  text merely because hierarchy handling was unavailable.
- A synthetic third-party input grammar using only standard protocols gets the
  same Files behavior as Vim, Emacs, and Helix.

### Actions and UI

- A third-party provider contributes `copy path` to Files without modifying its
  presentation or routing through the Files owner.
- A button, menu item, palette row, toolbar control, accessibility activation,
  and keybinding resolve to the same semantic endpoint.
- Disabled reasons and multi-selection semantics agree across all presentations.
- Which-key compact mode shows key to intent to endpoint; full mode exposes the
  resolution trace, explicit sequences, alternatives, and rejection reasons.
- Explanation performs no provider callback or effect and conveys no authority.
- Parameterized actions open the same interaction schema from every UI style.
- Files and Git are each usable keyboard-only and pointer/menu-only.

### Identity and lifecycle

- Provider unload invalidates endpoints and cancels owned work safely.
- Revision changes between resolution and invocation produce no mutation.
- No rendered row, byte range, or parsed display string serves as durable domain
  identity.
- Two repositories, REPLs, DAP sessions, and ACP conversations remain isolated.
- Background callbacks never inspect the active editor or head.

### Effects and authority

- WASM, JavaScript, native, and remote effects pass through the same authority
  model and effect-door checks.
- Catalog visibility never authorizes invocation.
- Provenance records both human requester and executing provider.
- Files draft undo and text history work, while Git and remote effects do not
  claim false inverses.
- No plugin invokes another plugin through a private command name.

### Collaboration

- Sharing text emits no layout, input mode, clipboard, fold, easymotion,
  presence, diagnostics, or LSP data unless separately selected.
- Peers can use different input and presentation plugins over the same replica
  or remote resource.
- A peer without Files or Git UI receives usable generic presentation and
  catalog actions.
- A local action against a remote repository executes exactly once at the
  repository owner, never against a same-named local repository.
- Document-scoped LSP cannot reveal or open ungranted project content.
- Git review access cannot stage; staging authority cannot commit, push, spawn
  arbitrary processes, or read unrelated files.
- One approved grant bundle avoids subsequent prompts within its exact scope.
- Revocation invalidates cached offers and is checked during in-flight effects.
- Disconnect never queues a remote mutation for later surprise execution.
- Protocol/version skew degrades explicitly and safely.

### Scale and honesty

- A repository with at least 100,000 changed paths uses bounded visible-window
  work and reports partial/progress state explicitly.
- Large whitespace, picker, search, diagnostic, and process results do not
  silently truncate.
- High-rate feeds are incremental, cancellable, and backpressured.
- Generic fallback UI remains functional without specialized renderers, icons,
  localization, menus, or input plugins.

## 19. Demolition checklist

The following must be absent before declaring the migration finished:

- `semanticActive` branches;
- provider-authored literal interaction or navigation keys;
- domain keymaps or locked tool modes;
- core-owned Vim dot-repeat or fixed registers;
- compulsory editor storage in workspace entries;
- dummy editor and read-only-as-type compensation;
- view-owner-exclusive action dispatch;
- semantic-action-to-string-command trampolines;
- cross-plugin private command dependencies;
- async routing by buffer name;
- background access to ambient current head/editor;
- rendered text or row indexes used as identity;
- singleton state for instantiable sessions;
- silent fixed caps;
- JS/WASM/local/remote authority divergence;
- automatic presence or diagnostics bundled with text sharing;
- opaque remote service tunnels; and
- persisted `dired` or `magit` terminology.

## 20. Design review questions

Reviewers should concentrate on these remaining decisions:

1. What exact wire/value representation should `Designation` use while keeping
   provider-defined locators typed and schema-negotiable?
2. Which endpoint and offer references are snapshot values, leased handles, or
   reconstructible designations?
3. What is the minimum pure provider predicate language needed for explanation
   without reintroducing guest callbacks?
4. Where is the boundary between a standard protocol package and a
   plugin-specific protocol, and how is stewardship handled?
5. Which query/feed commonalities should remain SDK conventions until concrete
   LSP, debugger, and collaboration migrations prove a runtime primitive?
6. How are generic presentation fallbacks selected without introducing a new
   owner monopoly or expensive eager probing?
7. Which publication and grant data must be end-to-end authenticated versus
   advisory UI metadata?
8. How long may at-most-once remote outcomes be retained, and what user-visible
   state is required when the owner cannot determine a prior outcome?
9. Which accessibility semantics belong in the portable presentation ABI and
   which remain platform-specific?
10. What compatibility window is acceptable for opaque v1 plugins, and what
    repository gate prevents that window from becoming permanent?

The standard for answering these questions is not whether one built-in plugin
can be made to work. The answer must preserve independent ownership, explicit
cost, safe authority, and useful degradation across new plugins and connected
participants.
