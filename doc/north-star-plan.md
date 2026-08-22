# North-star build plan — the kernel, its interfaces, and the contradiction ledger

Status: PRE-BUILD DESIGN, REVISION 2 (2026-08-21). Revision 1 was subjected to
a three-lens adversarial review (internal consistency; fidelity to the
aspirations; feasibility against the code). It did not survive: two fatal
design errors, two aspiration betrayals, systematic phase underpricing. This
revision incorporates the repairs; §9 is the review record — what was found,
what changed, what remains genuinely open. Nothing is started until the forks
in §5 are decided.

Method note: everything here was checked against the code, not the docs. Where
a doc and the code disagree, the code wins and the drift is recorded (§1).

---

## 1. Ground truth — what exists vs what the frame assumes

The frame (`architecture.md`) claims "weft is most of the way here already."
Audited claim by claim (this table survived adversarial spot-checks cite-for-
cite; two hairline notes folded in below):

| frame claim | reality (checked) |
|---|---|
| "the caps registry is a DI container with named slots + composition + late binding" | Half. `Caps` exists (`capability.zig:306`) but slots are a **closed enum** (`Kind`, `:90-126`), composition is **hardcoded per name** (`:119-125`), the only context is **file-extension suffix match** (`:243-250`), and guests can provide exactly **one** capability (`edit/completion` — `wasm_host/capability.zig:19-29`, name hard-checked). Deeper than the enum: the **payload ABI is closed** — `capability.Payload` is a closed union of five shapes (`capability.zig:162-168`), marshalling is completion-shaped (`wl_caps_item`), host→guest dispatch is a hardcoded `on_complete`. Opening the *name space* without a generic payload story opens nothing (see C18). |
| "the in-process/wasm transport split — blobs, one contract, two transports" | **False today.** `src/core/abi.zig` does not exist — though `guest/weft.zig:1-3` and `wasm_host.zig:1` *document themselves as mirroring it*: the codebase's own comments cite a phantom file. Every plugin is wasm (quickjs config included). The mirror is 124 guest externs hand-synced against 123 host imports, plus **10 host→guest entrypoints** (`describe`/`init`/`run`/`on_command`/`on_complete`/`on_pick_accept`/`on_menu`/`on_activate`/`on_poll`/`on_fill`) and a **third hand-synced surface**: quickjs's own `qjs_*` import table (40 defineFn call sites, 25 unique imports) (`quickjs.zig:60ff`). |
| "stemma is already the object graph (lazy, holey, multi-gig)" | **Half-true, in the best possible way.** stemma contains `ObjectDoc` — a real collaborative object tree (maps/lists/text-nodes over one causal history, stable `ObjId` = creation event, honest conflict sets, portable id tokens, atomic-reject merge; `ObjectDoc.zig:1-25`). **weft imports none of it.** weft is text-primary (`Document.zig` wraps `TextDoc`); lazy/holey/multi-gig is true of the TEXT path only. ObjectDoc gaps (ledgered in its own header): no move op, no compaction, no in-node anchors, doc-local ids, and **no session/wire integration in weft** (the collab driver is TextDoc-shaped). |
| "collab already generalizes self/peer into principals" | True. `authority.Principal`, per-peer selective undo, wire grades, TOFU+SAS — real and shipping. Only `presence` replicates as a layer; every other `scope=replicated` claim traps (`layers.zig:229`, correctly per [FIX 10]). |
| "the membrane already gates by perm (a coarse grant)" | Very coarse: **5 global booleans** per plugin, self-declared in `describe()`, **no user prompt** (`runtime.zig:127` — approval exists only as a comment), and a denied effect is a **silent no-op** (bare `return`s in `fs.zig`/`proc.zig`) — violating the design's own no-silent-third-result rule ([FIX 10]) in shipping code. |
| "file extension — one crude level" (the context to generalize) | Understated: **nine** independent crude context mechanisms (`action.When {mode,lang,tool}`, caps extensions, keymap modes+global layer, `Editor.backing`, `isMarkdownPath`, `syntax.forPath`, caret styleFor, pane focus, tool resting/locked modes) — plus a **fourth resolver** the "three resolvers" framing missed: `core/registry.zig`, the live name-interning last-wins registry backing the command table. Meanwhile the generalized matcher exists as dead code: `mode.zig`'s `Predicate` union `{ext,shebang,glob,tag,locus,all,any,not}` (`:51-88`) + `Engine.reconcile` (`:165-194`), re-exported at `core.zig:49`, zero consumers. |
| Value ABI lacks identities (critique #1) | Partially fixed: `command.Value` has `anchor`/`range` (stamped, `command.zig:26-41`); the register ferry ships (`register.zig`); `wl_edit_as` gives transient sub-peer authorship. Pool anchor columns and `spawnPeer` proper remain open. |

Also: `doc/abstraction-audit.md` is referenced by two docs and a memory but is
not in the repo; the "7 producers bypassing the render membrane" exists only
as inference. And the **app layer is head-singleton-shaped to its bones**:
~11 interaction-state clusters assume one active buffer / one mode / one
focus (`Buffers.active_id` with a documented exactly-one invariant,
`command.Context`'s "always the ACTIVE buffer" contract, one `Keymap.mode`,
the `Pick` machine's mode save/restore, one echo list, one window layout
welded to the active buffer, `main()`-local overlay/blink state, file-scope
dot-repeat globals in `dispatch.zig:192-200`) — with call-site counts in the
hundreds. The guest ABI itself is implicitly active-buffer addressed. This is
C14's real size.

**Net:** the bones are better than the docs in two places (mode.zig,
ObjectDoc — both built, both unused) and worse in three (no in-process
transport; closed payload ABI; grants are 5 booleans). The plan is shaped
around exactly that.

---

## 2. The kernel, named precisely

Core becomes four things and nothing else:

1. **The Container** — ONE resolution engine (module name `core/container.zig`
   — `core/registry.zig` is taken by the existing command registry, which is
   itself the fourth crude resolver being replaced) subsuming the four that
   exist: caps, actions, keymap layers, command shadowing.
2. **The Membrane** — the blob contract: one comptime definition generating
   all transports and BOTH directions; grants as possessed, revocable,
   context-captured handles.
3. **Platform providers** — window/input/present/rasterizer/proc/net/fs/clock
   as *default providers of platform slots*. The mechanisms stay core-shipped
   (no plugin contains vulkan), but nothing above them can tell a default
   provider from a replacement — which is what makes a DRM/libinput
   compositor build (§2.7) expressible at all.
4. **The Substrate** — stemma (TextDoc now, ObjectDoc adopted), the scene
   ABI, projections.

Systems (editor, agent-UX, REPL) are **manifests** — values the Container
reconciles, not code paths.

### 2.1 Context — a captured value; scopes supply facts and lifetime, never rank

```zig
// core/ctx.zig
pub const ScopeKind = enum { workspace, system, head, buffer, subbuffer, mode, transient };

pub const Scope = struct {
    kind: ScopeKind,
    facts: Facts,   // ext, shebang, glob-path, tags, locus, lang, tool, backing,
                    // mode, buffer-id, head-id — DATA, no callbacks. The union of
                    // mode.zig's Resource and action.When's vocabulary (W1 work).
};

pub const Ctx = struct {   // IMMUTABLE VALUE. Captured at interaction/session start.
    scopes: []const Scope, // outermost → innermost; merged facts, innermost shadows
    principal: Principal,
    locus: Locus,          // captured — [FIX 4] holds by construction
    grants: []CapHandle,   // resolved AT CAPTURE against this stack (§2.4)
    epoch: u64,            // container version at capture (cache key)
};
```

Three rules, and the third is a revision-2 correction:

- **Facts merge across ALL live scopes** — the document axis
  (buffer/subbuffer, per-system, shared) and the interaction axis
  (head/mode/transient, per-head, private) both contribute; a headless
  context simply lacks the interaction facts and everything keeps working.
- **The stack is captured, bindings are live.** A background task never
  drifts onto another buffer/host/mode; re-binding a slot takes effect on
  the next resolution everywhere. `resolve(slot, ctx)` is a pure function of
  `(declaration set @ now, ctx @ capture)`.
- **Scopes do NOT rank bindings.** Revision 1 made scope depth dominate
  resolution — which structurally resurrected the exact bug extensibility.md
  [FIX 5] was written to kill (mode scope, the most *general* interaction
  state, outranked buffer scope's language identity, with the priority
  escape deleted; and cross-axis predicates had no home scope at all). The
  review killed it (§9, A1). Corrected: a scope's roles are exactly (a)
  supplying facts and (b) bounding LIFETIME — a binding or grant attached to
  a scope instance dies with it. Precedence comes from §2.2's order alone.

Mode is a head-scope FACT, and mode changes are **Ctx-scoped effects**:
`ctx.setMode(target)` exists — the imperative call stays (user decision, §5)
— but it lives on the interaction's Ctx, so only code on a dispatching
interaction's synchronous path can call it. A background task, a proc-fill
callback, a timer, a tool refresh — none of them HAVE an interaction Ctx, so
"shell forces normal mode from a fill" (the historical leak class) fails to
compile rather than failing in review. Commands may additionally DECLARE a
target mode as sugar (which feeds `explain` and the which-key hints), but
declaration is convenience, not the mechanism. Persistent modal state (vim's
insert, outliving any interaction) is legal and ordinary; transient/menu
modes are **structurally paired** (`ctx.push(transient)` returns a value
whose going-out-of-scope IS the pop); buffer switches restore resting-mode
facts.

### 2.2 The Container — full-fact predicates, one total order, declared composition

```zig
// core/container.zig
pub const Shape = enum { query, feed, action, value };
pub const Composition = enum { first_wins, ordered_union, merge_ranked };

pub const SlotDecl = struct {
    name: []const u8,          // "edit/completion", "ui/gutter-segment", "eval", "fs/read"
    shape: Shape,
    composition: Composition,  // declared at the slot, not hardcoded in core
    schema: SchemaRef,         // see C18 — a slot without a crossable schema is not open
};

pub const Tier = enum(i8) { core = -2, imported = -1, plugin = 0, config = 1, transient = 2 };

pub const Binding = struct {
    slot: []const u8,
    provider: ProviderRef,
    predicate: Predicate,      // over the MERGED fact set — any axes, any conjunction
    priority: i32,             // free within a tier
    owner: OwnerId,
    attached_to: ?ScopeRef,    // LIFETIME only: dies with the scope instance. No rank.
};
```

**The total order ([FIX 9], actually resolved this time):** eligible =
predicate holds against the merged facts. Order by

```
(tier, priority, specificity, owner fingerprint, declaration index)
```

- **Tier** is the dispatch.md ladder, kept and extended: `core < imported <
  plugin < config < transient`. An imported manifest's bindings sit one tier
  below the importer — which makes `weft.use("defaults")` + "my later binds
  override" the DOCUMENTED, deterministic contract it always claimed to be
  (review A3: revision 1 refused it as a collision).
- **Priority** is free within a tier — [FIX 5]'s repair restored: `mode.nix`
  declares its `=` binding at a priority that beats vim's, as data, because
  both are plugin-tier and nothing hardwires modal-beats-language.
- **Specificity** = conjunct count over the merged facts (the existing
  `When.specificity()` rule, generalized). Cross-axis conjunctions
  (`mode=normal AND ext=.nix`) are ordinary predicates — revision 1's
  single-scope eligibility made them inexpressible.
- **Collision, defined precisely** (revision 1 stated two incompatible
  rules): two bindings from DIFFERENT owners with equal
  `(tier, priority, specificity)` and overlapping predicates on the same
  slot = load-time error. Within ONE owner, declaration index decides —
  a manifest is a LIST, its internal order is authored data, not load order.
- **`explain(slot, ctx)`** is a first-class kernel query: which bindings were
  eligible, in what order, and why the winner won. Non-negotiable
  debuggability for a resolution system this expressive; ships with W1.

**Lazy activation, with its principal story stated** (review B3): a provider
may declare `activation: eager | lazy`; first resolution instantiates it —
under the PROVIDER's own manifest grants resolved against the binding's
declared context, never the consumer's. The consumer's resolution is merely
the trigger; the authority was approved at manifest time. "Register a route
on the http server, starting it if not running" is then a lazy first-wins
provider at workspace tier with routes as an ordered-union slot over it.

**Binding is itself authority** (review B3): interposing on `fs/read` or
`eval` by binding first-wins is power. A blob may bind only slots its
manifest declares (cross-checked at load, like commands today), and the
manifest's bindings ARE part of the approval surface — a third-party blob
binding effectful slots is exactly what the diff exists to show.

**Re-resolution per shape** (unchanged, now with the swap-matrix stated —
review B6): `query`/`value` re-resolve every fire; `feed`/`action` sessions
PIN their provider for the session's lifetime. Live: binding changes,
revocation, manifest reconcile, query/value resolution. Pinned until
restart: in-flight feeds and sessions (an LSP feed never migrates
mid-stream). Static: the kernel four. That is the honest extent of the
"live image" — liveness of resolution, not of in-flight streams.

The four existing resolvers become clients: `Caps` keeps its
session/restamp/race machinery (`fire`'s match loop at `capability.zig:425`
is the only part that swaps — verified adapter-clean); `action.resolve`
adapters once Facts absorb `mode`/`tool`/`lang` (W1 work, pulled forward from
revision 1's W2 — review C-F5); the Keymap stays a compiled flat table
(cache, invalidated by epoch — dispatch stays a table walk, C10); command
shadowing joins the same order.

### 2.3 Manifests — systems as values, and the value must be real

```zig
pub const Manifest = struct {
    name: []const u8,
    slots: []SlotDecl,
    bindings: []Binding,            // ordered — the list IS authored precedence data
    grants: []GrantDecl,
    imports: []const []const u8,    // imported bindings land one tier below ours
};
```

- **Config evaluation is SEALED** (review B4 — without this, "config is the
  manifest" was TOCTOU on the approval diff): the JS runs deterministically —
  no ambient env, injected clock, no I/O beyond declared `weft.*` — and the
  approved artifact is the manifest VALUE plus its hash. Re-evaluation that
  produces a different manifest invalidates the approval. Diffing two
  configs = diffing two values, never running two programs against live
  state.
- The reconcile engine is `mode.zig`'s, promoted from dead code: diff
  `want\have` / `have\want` on any manifest or fact change. Load order
  cannot matter because resolution is a function of the final declaration
  set under §2.2's total order.
- "Switching editor→agent-UX" = swapping the manifest bound at the system
  scope. One-shot = short-lived container, one manifest. Daemon = the
  container not exiting, hosting several.
- Later (post-W6): manifests stored AS ObjectDocs — collaborative,
  versioned, projectable config. Deliberately not v1.

### 2.4 Grants — resolved at capture, riding the Ctx, dying with their scope

Revision 1's powerbox ("context applies at wire time, use time is
possession") did not survive review (A2): buffer-scoped grants can't be
wired before buffers exist; continuous re-wiring is contextual resolution
renamed; and a blob holding a WALLET of context-handles chooses which to
present — confused deputy, structurally permitted. Corrected model:

- **Wire time** hands out only the manifest-static baseline (workspace/
  system-scope grants: fs roots, proc, net — what the approval diff shows).
- **Capture time is the powerbox.** When a Ctx is captured, the kernel
  resolves the principal's GrantDecls against the captured stack; the
  resulting handles are **part of the Ctx** delivered with the invocation.
  A blob servicing a notes-context request holds the notes-context handles
  and no others — there is no wallet to choose from. Same shape as [FIX 4]
  locus capture: resolution at a defined moment, immutable thereafter.
- **A handle's lifetime is bounded by the scope its GrantDecl matched.**
  Scope exit revokes; a stashed handle from a dead Ctx traps. Transient
  grants are thereby structurally paired exactly like transient scopes —
  a leaked authority becomes as inexpressible as a leaked chord (review B7).
- **Use time is possession**; the resource's guard checks the handle. No
  context-stack walk at use. Revocation = table invalidation, immediate for
  live handles; grant CHANGES reach every subsequent capture.
- Denied effects **trap** — the interim hard rule (current silent no-op is a
  shipping [FIX 10] violation), landing in W0a.

```zig
pub const GrantDecl = struct {
    capability: []const u8,      // "fs.read", "doc.edit", "proc", "net", "head/attach"
    predicate: Predicate,        // same matcher
    limit: Limit,                // fs subtree, net host, doc region (see below)
};
```

**Text-region limits are identity-anchored, not position-anchored** (review
B2 — position-keyed ranges are theater under adversarial concurrent edits:
content moves in or out and the range doesn't follow). A `doc` limit on a
text region is keyed by stemma **EventAnchors** (identity anchors — attached
to characters' insertion events, stable under concurrent edits, already in
TextDoc). If an endpoint's character is deleted or compacted away, the grant
**collapses and traps** — a loud "re-grant needed," never silent drift.
Wholesale cut+repaste mints new identity → collapse → trap: honest failure.
On graph docs, limits key on `ObjId` subtrees and are exact. The flagship
"agent may edit only this function" is thereby real on BOTH substrates, with
the text form failing loudly at its identity limits instead of silently
missing them.

**The head grant is named, because it is enormous** (review A5/B3):
`head/attach` = the right to originate input attributed to an attached
principal, to mint head scopes for its attachments, and to request presents.
Attaching IS the consent act — sitting down at a window, authenticating to a
web-head tab, binds YOUR principal to THAT head's input stream, explicitly
and revocably. Revoking a head detaches its attachments; its minted scopes
die, and every Ctx/handle bounded by them dies with them (consistent by
construction with the lifetime rule above). Revision 1's "first-party
confers speed, not extra authority" was false as stated; the honest form:
**first-party confers no UNNAMED authority** — the window-head's power is
the `head/attach` grant, visible in the diff like anything else. Likewise
the bundled catalog's implicit grant bundles (§8) are a TRUST ROOT the user
opts into — curation, named as such, not construction.

`weft.set` value namespaces are **closed by default**: only the owner binds
its keys unless it declares them open (review B3's open-write-namespace
hole).

The extensibility.md release blockers (grant-keying of sessions/layers,
action-result re-attribution + range clamping — the clamp now
identity-anchored per the above) remain release blockers for the remote
milestone, in W4.

### 2.5 The membrane contract — one definition, both directions, three surfaces, two trust models

Revision 1 priced "one comptime contract" as small; review C-F2 showed it is
two projects. Split accordingly:

**W0a — the drift killer (genuinely small).** One comptime table
`core/membrane/contract.zig` generates the 124 guest externs, the 123-entry
host import table, comptime arity/order checks, AND covers the
**host→guest direction** (the 10 exported entrypoints, today
MissingExport-tolerant by hand) plus the **third surface** revision 1
missed: quickjs's `qjs_*` table (40 call sites, 25 unique imports). Plus trap-on-deny. What W0a does
NOT claim: generating the ergonomic wrapper layer — `weft.zig`'s wrappers
encode ~8 real conventions (sentinel nulls, six aliasing-chosen scratch
buffers, out-pointer multi-returns, struct flattening) that stay
hand-written until the contract DSL earns them.

**W0b — the in-process transport (priced honestly: a refactor of the host
tree).** All ~123 host handlers interleave semantics with wasm marshalling
across ~2,700 lines of `wasm_host/*`; the in-process binding requires
splitting transport from semantics throughout. It lands WITH its first
client (the window-head, §2.7) rather than as untested speculative surface —
and it goes through the same handle tables and guards.

**AS-BUILT REVISION (W0b landed):** the window-head turned out to be the
transport's first client BY IDENTITY only — a named `InProcClient` with
perms and the dispatch bracket — not by consumption: its platform/render
wiring is core-privileged native code that calls no `wl_*` semantic body at
all. The split (shared `hasPerm`/`canDispatch` predicates + one semantic
body per import, proven on a representative six) is validated by
`InProcClient`'s own tests and the TestHead; the transport's first real
CONSUMERS are future native blobs and any core code migrating onto the
shared bodies. ~118 imports remain mechanically unsplit until a consumer
wants them.

**Native blobs are first-class loadables, with the trust split stated
plainly** (user direction: native code + heavy DRM/libwayland plugin work
should be able to make weft a compositor). The membrane's promise divides:
against MISTAKES, the structure holds on both transports — same handles,
same guards, same grants. Against MALICE, only wasm sandboxes. Loading a
native blob is a kernel-module-grade consent: explicit declaration,
provenance, version-locked to the exact kernel build (no stable native ABI
is promised). Pretending the membrane contains native malice would be the
silent-third-result sin; we do not.

### 2.6 The graph substrate, projections, and the path to the inversion

Adopt `ObjectDoc` federation-first (F1b) — but with the end-state REACHABLE,
which revision 1 failed to provide (review B1: no phase, gate, or trigger
ever ended federation; the keystone was quietly permanent-deferred):

```zig
// core/graph.zig
pub const NodeRef = struct { doc: DocId, obj: ObjectDoc.ObjId };

pub const Projection = struct {
    fill: fn (ctx: Ctx, root: NodeRef, view: Viewport) FillResult,
    //   FillResult = { scene rows/spans, map: []{ NodeRef, range } }
    reconcile: ReconcileMode,
};
pub const ReconcileMode = union(enum) {
    on_save: fn (ctx: Ctx, snapshot: IdMap, current: IdMap) []GraphOp,  // DESIGNED (editable-projection.md)
    live: fn (ctx: Ctx, region: ClosedRegion) []GraphOp,                // UNDESIGNED — see D1
    authoritative: struct {                                             // single writer / last-seen-wins
        command: fn (ctx: Ctx, intent: Intent) void,  // edits map to COMMANDS to the authority
        // state flows back as an ordinary latest-wins FEED; no merge, by design
    },
};
```

**Three authority modes, honestly labeled** (review A4 killed revision 1's
conflation; the user's media-player example added the third). `on_save` is
the shipped dired design — correct for fs-authority tools whose truth is
gathered and reconciled at commit points. `live` — required by genuinely
multi-writer shared models (C5) — is a different algorithm that must
interpret intermediate states; plausible shape: region-atomic commit points
(a row reconciles when it CLOSES: focus leaves, delimiter typed, timeout),
not per-keystroke. It gets its own design doc (**D1**) before W6, and W6's
gate is load-bearing on D1. `authoritative` is for models with one true
writer or honest last-seen-wins semantics — media-player controls, system
monitors, log tails: a seek is a COMMAND to the authority, the timeline
position is a latest-wins feed, and CRDT-merging it would be actively wrong.
This mode is not a fallback; it reuses the existing feed + action shapes and
is the CORRECT design for its class. Choosing the mode is part of a tool's
design (F2), stated per tool, never defaulted silently.

**The inversion has a mechanism now.** stemma delta 1 (doc-core unification)
makes TextDoc literally a graph document with one text node. At that point
every code buffer is IN the graph — degenerately, one node — with zero
migration, and granularity refines additively: syntax-driven node claims
(function/section nodes over the text node, the subbuffer machinery
graduated) arrive per-language without storage changes. **F1's end-state
trigger, named:** when doc-core unification + in-node identity anchors land
(stemma deltas 1+3), weft's `Document` re-bases onto the unified core, and
W7 runs. Until then federation is v1 truth; after it, "text is a projection"
is a theorem about the degenerate case rather than a slogan.

stemma delta (dependency order): 1. doc-core unification; 2. object
compaction + `openFromContent` for text nodes; 3. in-node identity anchors;
4. cross-doc refs (bless `exportId` as NodeRef's wire form); 5. **ObjectDoc
session/share integration** (the collab driver is TextDoc-shaped today —
review A7c found this scheduled nowhere; it is W5 work, and ObjectDoc's
version/eventsSince/merge already speak the same token model, so it is
binding work, not protocol work); 6. move op — deferred until a structural
editor client, but F3's representation question is decided first.

**Where the graph-side plugin code runs** (review C-F7): the shipped magit
guest cannot implement `Projection` (no graph ABI crosses the membrane, and
fn-pointer contracts don't survive wasm). Decision folded into W5: the first
graph client's model code runs HOST-SIDE/in-process (the agent transcript,
owned by agent-core machinery); a guest-facing graph ABI (`wl_graph_*` +
host→guest projection trampolines) is its own later, priced step — reopening
the membrane contract knowingly, not accidentally.

### 2.7 The daemon, heads, platform-as-providers — weft is not one thing

Direction (user): "the editor should just be an instance of a DI system…
one-shot for testing, daemonize in practice — swapping systems at runtime,
opening new instances… collab against a virtualized filesystem, check in on
an agent session remotely." And further: native DRM/libinput plugin work
should be able to make weft a wayland COMPOSITOR — not out of the box, but
never precluded.

- **The container hosts N systems**; "the editor" is one instance. Systems
  are values; the daemon is the container not exiting.
- **Headed-vs-headless is a composition fact.** A head is a ROLE a blob
  plays under the `head/attach` grant (§2.4): the first-party window-head
  (in-process, W0b — rendering.md P5's "bundled scene client" generalized to
  own the attachment), a web-head registering a route, a tty-head. A
  composition granted nothing head-shaped structurally cannot pop UI.
- **Platform mechanisms are slots; core ships the default providers.** The
  compositor case is the proof test: a build whose window/input providers
  are native DRM/KMS + libinput blobs, with nothing above the slots able to
  tell. (And the tease worth recording: a compositor's window tree is
  another object graph — foreign surfaces as nodes, pane layout generalized
  to window management. A named non-goal; the seams must merely not preclude
  it.)
- **Heads and systems have independent lifetimes.** Zero-head systems are a
  first-class resting state; a head re-binds between systems; N attachments
  = N head scopes (minted under the head's grant, dying with it).
- **A local head is a degenerate remote attach.** Attaching = joining the
  system's documents + firing its slots; loopback = in-process, remote = the
  session machinery. **Remote heads FIRE the UI slots over the wire** — the
  scene vocabulary is metric-free, hence wire-safe as capability
  results/feeds; each head lays out and rasterizes locally. This replaces
  revision 1's C15 "rule" (state must live in docs/layers or remote heads
  silently diverge — an institutionalized silent third result, review A6):
  remote and local heads now get scenes from the SAME providers, so the
  divergence class dies structurally. What remains of C15 is durability
  guidance: blob-private state dies with the blob — a loud, ordinary event.
- **The scenarios, derived:** agent check-in = attach over the wire to the
  headless agent-ux system; its transcript is a graph DOCUMENT (W5 —
  therefore the transcript, not magit, is W5's required first client;
  review A7b), its UI is slot-fired. Virtual-fs collab = `fs` is a slot; a
  system binds a virtualized provider; peers read/write through the slot
  with no `if virtual` anywhere.
- **The embryo:** `weft --headless --listen` is the proto-daemon; the e2e
  harness's Project runs are the one-shot mode.

**The loop, re-diagnosed** (review C-F4 corrected revision 1's C16): the
wayland pump is ALREADY fd-driven and non-blocking; `main()` owns the loop,
and the real couplings are (a) the vulkan fence wait inside `beginFrame`,
(b) unconditional present-per-iteration under FIFO, and (c) **five-plus
implicit timers** (key repeat, caret blink, which-key delay, backing polls,
per-frame `tick` servicing) that are clock-polled and correct only because
vsync guarantees wakeups. The source-driven scheduler therefore requires:
reifying the timers into timer sources, converting `tick` servicing to
sources, dirty-gating present, and moving the fence wait off the scheduler
thread (the window-head owns pacing; the kernel must never block on a GPU
fence). Deleting `headless.zig`'s loop is the trivial 5%. Priced as its own
workstream inside W2a.

---

## 3. What this dissolves (the payoff, stated as checks)

- The nine-plus-one crude context mechanisms (§1) become Container bindings
  over one Predicate, each a mechanical port with its own test gate.
- The UI mesh of `rendering.md` becomes ~9 `SlotDecl`s (needs C18's payload
  story for the guest side).
- `dispatch.md` survives: Tier 1 compiled, Tier 2 resolve = Container call,
  Tier 3 untouched, [FIX 5]'s repair restored by the tier/priority order.
- Magit-grade tools get models with real identity; `editable-projection.md`
  becomes `Projection.on_save`, unchanged in design.
- Agents: a principal + a manifest + GrantDecls + a graph-doc transcript;
  check-in falls out of heads-over-the-wire.
- Compositor-grade embedding: platform-as-providers + native blobs (§2.5's
  trust split) make it expressible without a fork of core.

---

## 4. The contradiction ledger (revision 2)

Entries revised in place; †marks resolutions replaced after review.

**C1 † — Object-capability vs contextual grants.** Ambient authority at use
time is out; but revision 1's wire-time powerbox was underspecified into
either brokenness or renamed ambient re-wiring (review A2). → Resolved as
§2.4: manifest-static baseline at wire time; **capture-time resolution with
grants riding the Ctx**; no wallets, no handle-choosing; lifetime bounded by
the matching scope; use = possession; revocation = invalidation. Residual:
grant-authoring UX — contained by grants-in-manifests + the approval diff +
the named catalog trust root (which is curation, and says so).

**C2 — Liveness vs capture.** Facts captured, bindings live, sessions pin;
the swap-matrix is stated in §2.2 (review B6 demanded the enumeration).
Grant additions reach the next capture; in-flight streams pin until restart.

**C3 † — Specificity vs determinism.** Revision 1's scope-depth dominance
was fatal (resurrected [FIX 5]'s bug; foreclosed cross-axis predicates;
its collision rule contradicted its own total order — reviews A1, A3). →
Resolved as §2.2: full-fact predicates; `(tier, priority, specificity,
owner, declaration-index)`; scope = lifetime only; imports one tier below
importer; collision defined on the `(tier, priority, specificity)` prefix
across owners; `explain()` ships with W1.

**C4 — Text-primary vs graph substrate.** Federate first — but with the
inversion trigger NAMED (§2.6, W7): doc-core unification makes text the
degenerate graph doc; nothing about v1 federation is permanent by
construction anymore (review B1).

**C5 † — Collaborative editable projections do not commute.** Still the
deepest open problem. Revision 1 claimed the dired reconcile covered it;
false (review A4). → Three authority modes (§2.6); `live` is undesigned and
gets D1 before W6; W6's gate is explicitly conditional on D1. Two honest
outs exist and are not the same: `authoritative` is the CORRECT mode for
single-writer models (user's media-player point, F2); single-writer-per-
projection on a genuinely multi-writer model is the FALLBACK if D1
disappoints — and if that is what ships, the plan says so rather than
shipping it silently under a collab banner.

**C6 — Graph move vs list CRDTs.** Unchanged: decide representation (F3)
before any client models structure; move op deferred. Structural form
(review B5): the graph facade's types expose NO list ops on structural
children — the containment is the API, not a review rule.

**C7 — In-process transport is fiction; mirror is hand-synced.** Confirmed
worse than stated: the code's own comments cite the phantom `abi.zig`; there
are TEN host→guest entrypoints and a THIRD surface (qjs). → W0a/W0b split
(§2.5), both directions covered, wrappers honestly out of scope for W0a.

**C8 — Open slots vs closed caps enum.** The enum was the shallow half; the
CLOSED PAYLOAD ABI is the real wall (review C-F1) → C18.

**C9 — Grant story vs 5 booleans.** Unchanged: trap-on-deny in W0a; real
grants W4; blockers stay blocking.

**C10 — Contextual resolution vs hot paths.** Unchanged (compiled tables,
epoch invalidation) — but the gate now has an instrument: the dispatch-
latency harness is BUILT in W0a (review C-F6: "unchanged latency" against no
baseline was unfalsifiable).

**C11 — Manifests vs imperative config.** Sealed, deterministic,
hash-approved evaluation (§2.3); startup effects run under the config
manifest's own principal and grants.

**C12 — Subtree grants vs merge determinism.** Host-authoritative admission
stays; limits are identity-anchored (§2.4), so admission checks are
functions of merged history over stable identities. Residual: reconnect UX
for ops rejected against a collapsed/revoked grant.

**C13 — Config values.** Per-key value bindings, owner-namespaced, closed by
default (§2.4).

**C14 — Head lifetime vs system lifetime.** Confirmed by inventory to be an
app-layer rewrite (~11 state clusters, hundreds of call sites, a guest ABI
that is implicitly active-buffer addressed — §1). → Its own phase (W2a),
not a fold-in. The W0a contract is versioned knowing W2a re-shapes
buffer-addressing.

**C15 † — What replicates on remote attach.** Revision 1's docs-or-layers
"rule" institutionalized a silent third result (review A6). → Dissolved
structurally: remote heads fire the same UI slots (§2.7); divergence class
gone; durability of blob-private state remains an honest, loud limitation.

**C16 † — The main-loop inversion.** Re-diagnosed (review C-F4): the fd
part is done; the work is timers-to-sources, tick-to-sources, dirty-gated
present, fence off the scheduler thread. Priced inside W2a.

**C17 (new) — Native blobs vs the membrane's security story.** Structure
against mistakes on both transports; sandboxing against malice on wasm
only; native = consent + provenance + version-lock, said plainly (§2.5).

**C18 (new) — Open slots need a crossable payload story.** A guest-declared
slot with a novel result shape has nothing to marshal it: `Payload` is a
closed union, `wl_caps_*` is completion-shaped, host→guest dispatch is
hardcoded. → Design deliverable **D2**, representation DECIDED (F6:
schema-directed marshalling): schemas are values on the SlotDecl; the host
marshals and RESTAMPS by interpreting the schema (anchors/ranges are marked
fields); guest SDKs codegen typed bindings from the same schema. Until D2
ships, "open slots" means host-side clients (the UI mesh) — the W1 gate is
scoped accordingly and the guest-side gate moves behind W0b+D2.

**C19 (new) — ObjectDoc replication is scheduled work, not an assumption.**
The session machinery is TextDoc-shaped; W6's remote-attach gate silently
assumed graph docs replicate (review A7c). → stemma delta 5, W5.

---

## 5. The forks — DECIDED (2026-08-21, user)

**F1 — Federate first, DECIDED — with the federation window named a COST.**
User: "federate first, but this isn't done until we unify, and the longer we
keep both paths around, the harder it will be to do a good job." So: W7 is
MANDATORY, not conditional — the plan is not complete until the inversion
runs — and the unification clock starts when federation ships: stemma deltas
1+3 begin alongside W5, not after it. Two substrates is scaffolding with a
demolition date, never an end-state.

**F2 — Authority modes per tool class, DECIDED.** Live reconcile is the
TARGET for genuinely multi-writer models (D1 must be designed). And the user
added the missing third mode: some models have a single authoritative
source or are honestly last-seen-wins — media-player controls being the
canonical example (nobody wants the timeline position CRDT-merged; a seek is
a COMMAND to the authority, the position is a latest-wins feed). §2.6 now
carries three modes: `on_save`, `live`, `authoritative`. Single-writer is no
longer only a fallback — for authoritative models it is the CORRECT design.

**F3 — Parent-register structure, DECIDED** (user delegated: "pick the
correct, robust thing we won't regret"). Parent-register + fractional order
keys for structural children; lists only for leaf sequences that never
reparent; enforced by the graph facade's types; stemma sketch + property
tests land before any W5 client models structure. Rationale for the record:
this is the only representation where identity-preserving move is a
register write and deletion composes as "trash is another parent" — lists
would wire the ferry disease into the substrate.

**F3 VALIDATED (2026-08-21)** — `lib/stemma/.../structure_sketch.zig`: 400
seeded multi-replica schedules converge, stay acyclic, stay reachable;
trash-resurrection preserves subtrees; no evidence against the decision.
Two caveats for the real implementation, adversarially verified:
1. *Cross-node cycle-breaking is a NEW mechanism, and its winner is not
   ObjectDoc's.* Resolving a tree of parent-registers requires a single
   replica-portable GLOBAL total order over all writes (Lamport per event,
   ties by agent-name then seq) replayed once with per-write cycle
   rejection — not the per-register MV rule ObjectDoc reuses for maps;
   budget it as new. The effective parent is the last write in that order
   whose application doesn't cycle — normally a causally-maximal
   conflict-set member, but when every causally-dominant write would cycle,
   the survivor is an earlier superseded write (in the limit, the create):
   deterministic and convergent, but outside the conflict set.
2. *Fractional order keys are not a free O(log N) lunch.* Random-scatter
   insertion keeps keys short, but same-locus insertion grows keys linearly
   (~N/8 bytes in the sketch); between two FIXED adjacent keys that Θ(N) is
   an information-theoretic floor no immutable-label scheme escapes without
   relabeling. A real implementation must periodically rebalance fragmented
   sibling runs during compaction — a cleverer encoding cannot substitute.

**F4 — DECIDED.** The seven scope kinds; `pane` is a fact on head scopes;
`principal` is identity, never a scope axis.

**F5 — Adapters, DECIDED.** In at W1, named deletion gate at W3.

**F6/D2 — Schema-directed marshalling, DECIDED** (user: "lean in to c").
Schemas are VALUES carried by the SlotDecl; both ends marshal by
schema-direction — the host interprets the schema (table-driven) for
runtime-declared slots, guest SDKs may additionally CODEGEN ergonomic typed
bindings from the same schema value. Anchors/ranges are schema-MARKED
fields, so the host restamps versions inside payloads it otherwise doesn't
understand — keeping the version-stamping invariant core-enforced without a
self-describing wire tax. Compact like bespoke marshalling, restampable
like a tagged encoding; D2's design doc specs the schema language (scalars,
strings, arrays, structs, anchor, range — deliberately small).

**W5 ordering — transcript first, DECIDED** (user delegated). The agent
transcript is W5's client (W6's check-in requires it); magit's model stays
on current tool-buffer machinery until the guest graph ABI or an in-process
port, whichever the magit thread reaches first.

**Trust root — DECIDED.** The bundled catalog's grant bundles are accepted
by `weft.plugin(name)`; curation, named as such.

**Mode changes — REVISED after user pushback** (see §2.1): the imperative
call STAYS; what changes is that it becomes a Ctx-scoped effect. The gain
was never "no call" — it is that background contexts structurally cannot
force a mode.

---

## 6. Phases, resequenced after review (each with a falsifiable gate)

Review C's verdict: the architecture survives; the sequencing as written did
not. Resequenced; in-flight work (rendering P1–P2, editable-projection 3–5)
continues on current machinery as clients-in-waiting.

- **W0a — contract codegen + instruments (small, honest).** One comptime
  table → guest externs + host imports + arity checks + the 10 host→guest
  entrypoints + the qjs table; trap-on-deny; **the dispatch-latency
  instrument** (baseline captured before anything moves). *Gate:* all guests
  rebuild on generated bindings, zero behavior change; a deliberately
  mismatched arity fails at comptime; a denied effect traps; a latency
  baseline exists in e2e.
- **W1 — the Container.** `container.zig`; Facts generalized to absorb
  `mode`/`tool`/`lang` NOW (pulled from old W2); total order + collision
  errors + `explain()`; Caps' match loop and `action.resolve` adapter-ized.
  *Gate:* existing caps/action/dispatch tests green through adapters; a
  HOST-side client declares a new slot end-to-end (guest-side waits on
  W0b+D2, stated, not fudged); `explain` answers the [FIX 5] scenario
  correctly (nix `=` beats vim reindent by declared priority); latency
  unchanged against the W0a baseline.
- **W2a — the head/system state split + the loop.** The ~11 interaction
  clusters move behind head-scoped state; the scheduler work as re-diagnosed
  (timers→sources, tick→sources, dirty-gated present, fence off-thread);
  `headless.zig`'s loop deleted. *Gate:* two heads on one system hold
  distinct modes/chords/picks; a system with zero heads runs the e2e suite;
  latency unchanged.
- **W2b — Ctx + manifests + the daemon.** Captured Ctx (facts + capture-time
  grants); sealed config eval-to-Manifest + hash approval; reconcile live;
  keymap compiled from bindings; paired transients + declared mode
  transitions. *Gate:* swap editor↔agent-ux at the system scope live; the
  container hosts two systems (one headed, one headless) with a head
  re-binding between them; override one slot in one buffer; menu-mode leaks
  inexpressible (the pairing test), vim insert works as an ordinary
  Ctx-scoped transition, and a background task attempting `setMode` fails
  to COMPILE (it has no interaction Ctx to call it on).
- **W3 — the UI mesh.** Rendering P1–P4 as `ui/*` SlotDecls (host-side
  providers); bespoke drawers deleted; W1 adapters for these paths deleted
  (F5's named gate). *Gate:* completion popup + statusline as slot
  providers; snapshots unchanged; adapter deletion done.
- **W0b — the in-process transport, with its client (DONE, as revised).**
  Transport/semantics split of `wasm_host/*` (representative six + the
  shared guard predicates; see §2.5's as-built revision — the window-head
  is a client by IDENTITY, not consumption; `head/attach` as a real
  capture-time grant is W4). *Gate met:* headed vs headless is
  `System.create` plus/minus the WindowHead (headless.zig converged onto
  the same construction, semantics traced identical); the TestHead attaches
  through the same client-identity contract with ZERO self-granted perms,
  making its denial tests non-tautological.
- **W4 — grants live.** Capture-time powerbox; handle lifetime = scope
  lifetime; identity-anchored doc limits; approval-as-manifest-diff;
  release blockers closed. *Gate:* revoke fs from a RUNNING plugin → next
  call traps; a function-scoped grant on a TEXT buffer survives concurrent
  edits elsewhere and TRAPS on identity collapse (not silently drifts); an
  action result outside the fired identity-range traps; scope exit kills
  its grants (stash-and-replay attack test).
- **W5 — the graph, transcript-first.** `graph.zig`; the AGENT TRANSCRIPT
  as the first ObjectDoc client (host-side model code — required by W6's
  check-in, review A7b); `Projection.on_save` formalized from dired;
  ObjectDoc session integration (stemma delta 5); **stemma deltas 1+3 begin
  here in earnest** (F1: the federation window is a cost; the unification
  clock runs from the moment federation ships, not after it); D1 (live
  reconcile) and D2 (schema-directed payload) designs written. *Gate:*
  transcript as a graph doc projected to text, edited, reconciled by id;
  the model replicates over a session.
- **W6 — structured collab + remote attach.** Share-model tools (F2, on
  D1); identity-anchored subtree grants at admission; heads over the wire
  firing UI slots. *Gate:* two principals, one model, different
  projections, converging, subtree grant enforced; the check-in scenario
  end-to-end (attach to the daemon's headless agent session, observe via
  slot-fired scenes, intervene under grant, detach, session unaffected).
- **W7 — the inversion (MANDATORY — the plan is not done until this runs;
  F1).** After stemma deltas 1+3:
  weft `Document` re-bases on the unified doc-core; text buffers become
  degenerate graph docs; syntax-driven node claims refine granularity.
  *Gate:* a function-level subtree grant on an ordinary CODE buffer, keyed
  by node identity, surviving a peer's concurrent refactor or trapping
  loudly — the flagship scenario on the substrate people actually use.

Explicitly NOT in this plan: new platforms/backends beyond the seams, QUIC,
P2P authority, manifest-as-ObjectDoc, the compositor build itself, stemma
move op until F3's client.

---

## 7. Where we could still get stuck (told straight)

1. **D1 (live reconcile) may not exist in a satisfying form** — region-
   atomic commit points are a hypothesis, not a design. Fallback: single-
   writer-per-projection, declared as such. W6 does not ship "collab" while
   quietly being turn-taking.
2. **D2 (generic payloads)** decides whether third-party UI is real or the
   mesh is first-party-only with extra steps. F6 must be decided before W3
   hardens shapes it would regret.
3. **W2a is the riskiest phase** — an app-layer rewrite with hundreds of
   call sites. Containment: it carries only the state split and the loop;
   manifests/Ctx wait in W2b; the latency instrument watches both.
4. **F3 could be wrong** in a way only a structural editor reveals;
   containment is the facade's types plus stemma property tests.
5. **Grant UX** could still drown users; containment: trust root + diff
   approval; if that fails, coarser profiles without changing mechanism.
6. **The catalog trust root is curation** — a standing human cost, named as
   such (review B3's contradiction, resolved by honesty rather than by
   pretending construction).

---

## 8. Forcing function: today's editor as a north-star config

`doc/north-star-config.js` is config/config.js under target semantics.
Result: **the degenerate case stays degenerate** — same ~250 lines, same
surface; semantics change invisibly (evaluates to a sealed manifest value;
manifest-internal order is authored data; import tier restores the
defaults.js override contract deterministically). Two visible edits, both
findings: (1) every config value needs an OWNER — the `"editor"` grab-bag
dissolves (`which-key-delay-ms` → `which_key`); per-key first-wins value
bindings need no new composition mode. (2) grant acceptance must be bundled
— the catalog trust root — or parity means enumerating grants for ~40
plugins. The second system (`weft.system("agent-ux", …)`) appears only in
the commented ACP block, exactly where today's config sprouts its agent
section.

---

## 9. Adversarial review record (2026-08-21)

Three independent reviews of revision 1: internal consistency (A), fidelity
to aspirations (B), feasibility against code (C). Verdict: **revision 1 did
not survive.** Dispositions:

| finding | disposition |
|---|---|
| A1/B-implied FATAL: scope-depth dominance resurrects [FIX 5]'s bug; cross-axis predicates homeless | **Repaired** — §2.1/§2.2: scopes = facts+lifetime, never rank; tier/priority/specificity restored; C3† |
| A2 FATAL: wire-time powerbox broken or ambient-renamed; confused deputy via handle wallets | **Repaired** — §2.4 capture-time grants riding the Ctx; lifetime = scope; C1† |
| A3: collision rule self-contradictory; defaults.js contract refused; import tier unspecified | **Repaired** — §2.2 collision prefix defined; imported tier; manifest order = data |
| A4/C5: "immediate reconcile" claimed as existing design | **Repaired honestly** — two modes; D1 named undesigned; W6 conditional; C5† |
| A5/B3: head authority unnamed (input origination, scope minting); "first-party = no authority" false | **Repaired** — `head/attach` named grant; attach-as-consent; "no UNNAMED authority"; trust root named as curation |
| A6/B5: C15's rule = institutionalized silent third result | **Repaired structurally** — remote heads fire UI slots; C15† |
| A7/C: phase inversions (W2 gate needs W3/W0b; W6 needs transcript; ObjectDoc replication unscheduled) | **Repaired** — resequenced §6; transcript mandatory in W5; stemma delta 5; C19 |
| A8: insert mode breaks "no imperative set-mode" | **Repaired** — declared mode transitions; narrower kill-claim |
| B1 BETRAYAL: no forcing function for the inversion | **Repaired** — W7 + named trigger (stemma deltas 1+3); C4 |
| B2 BETRAYAL: text subtree grants = position theater | **Repaired** — identity-anchored limits, trap-on-collapse; W4+W7 gates test it |
| B3: registry/lazy/startup/set ambient authorities | **Repaired** — binding-as-declared-authority; lazy principal story; sealed startup; closed value namespaces |
| B4: config-as-value TOCTOU | **Repaired** — sealed deterministic eval + hash approval |
| B6/B7: liveness overclaim; grant lifetime uncoupled | **Repaired** — swap-matrix stated; lifetime rule |
| C-F1 FATAL(gate): open slots blocked by closed payload ABI, not the enum | **Repaired** — C18/D2/F6; W1 gate rescoped |
| C-F2: W0 two projects in one label | **Repaired** — W0a/W0b split, both directions + qjs surface |
| C-F3: C14 is an app rewrite inside an overloaded W2 | **Repaired** — W2a/W2b split; C14 |
| C-F4: C16 misdiagnosed (timers/fence, not the wayland fd) | **Repaired** — C16† re-diagnosed |
| C-F5: When→Predicate vocabulary hole; Facts in wrong phase | **Repaired** — Facts pulled into W1 |
| C-F6: latency gate unfalsifiable | **Repaired** — instrument built in W0a |
| C-F7: W5 magit-guest can't implement Projection | **Repaired** — transcript-first, host-side; guest graph ABI its own later step |
| C-F8: `registry.zig` name occupied; fourth resolver missed | **Repaired** — `container.zig`; §1 amended |
| C-F9: §1 hairlines (core.zig re-export; phantom abi.zig cited by code) | **Folded in** |

Still genuinely open after repair: D1, D2/F6, F3 — the three named design
deliverables — and the standing curation cost of the trust root. These are
the honest frontier; everything else in this document is now either decided
or gated.

---

See `architecture.md` (the frame), `rendering.md` (the UI mesh + phases this
plan re-bases), `extensibility.md` + `extensibility-critique.md` (the grant
release blockers and identity-in-ABI principle — [FIX 5]/[FIX 9] now
actually honored), `editable-projection.md` (the `on_save` reconcile),
`dispatch.md` (survives intact, tier ladder extended), stemma
`ObjectDoc.zig`/`TextDoc.zig` (the substrate and its ledgered gaps).
