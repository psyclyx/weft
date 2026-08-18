# weft — Definitive Extension Architecture

The build-from document. It integrates the four foundations (locality, identity/authority, mode, pick seam), the native host ABI, and the reference plugin catalog, and it **applies the adversarial critique**: all 13 findings are adopted (§8 records the two nuances where adoption is qualified rather than rejected). Where a fix changes a signature or an invariant, it is folded in-line and marked **[FIX n]**.

---

## 1. Thesis

A buffer is a **CRDT replica** and every mutator — the user, a plugin, a host agent, a remote collaborator — is a **peer**. Solo local editing is the degenerate case: one replica, no sync. From this one inversion, four classically-bolted-on problems dissolve into one substrate:

- **Concurrency** dissolves because there is only one text API and it is the CRDT one. "The buffer changed under me" is inexpressible: you read an immutable versioned snapshot, submit ops against that version, and the log merges them like a concurrent collaborator. No bare offset ever crosses a public boundary without the version it is valid at — you rebase to an anchor or you get `null`, never a stale third result.
- **Locality** dissolves into a **Locus**: a first-class runtime handle answering "whose side effects are these?" `here` is the sentinel value `Locus 0`, not a code path. A file/proc/LSP/socket/buffer is a `Resource = (Locus, kind, ref)`; the locus rides *inside* the handle, so a plugin cannot mis-target it and does not branch on local-vs-remote. Remote is just "the peer that owns this resource is not me" — the same peer machinery multiplayer already uses.
- **Identity** dissolves into a **Principal** `= {agent (CRDT authorship), owner (fingerprint, accountability), role, caps, grant}`. One fingerprint backs many agents (your user peer, your `plugin.fmt` peer, your `agent.claude` peer). A remote human and a local agent are the same object, differing only in placement and whether `owner` arrived over the wire.
- **Authority** dissolves into two enums on the Principal that divide exactly at the CRDT line: **host capabilities** (`fs`/`net`/`proc`/…, granted once at the manifest handshake, gate authority *out* of the sandbox) and **document grant** (`view<edit<own`, granted per-document by its owner, gates authority *into* replicated state). Effective power = `host_caps × min(owner_grant(doc), manifest_grant)`. Authority flows *down* from the human who ran the plugin, never up.

The design's promise is that **remote + multiplayer correctness come for free** when a plugin uses the primitives correctly, and are *hard to break*. The critique's central lesson is folded into the thesis: the ABI must be able to express **identities** — anchors, ranges, peers — as first-class values, not just bytes and scalars. Bare offsets were correctly banned; the stamped-identity types that replace them are now first-class (§4), so the anti-corruption guarantee is *structural*, not disciplinary.

---

## 2. The Place/Locality model and the Identity/Authority model

### 2.1 Locality — the Locus

```zig
pub const Locus = enum(u32) { here = 0, _ };
pub const Tier  = enum { here, peer, shell };   // how effects route
```

`Loci` (host-side only; owns `Conn`/`ShellFs`) resolves a portable URI authority to a live handle, dialing/attaching lazily and idempotently. A guest never inspects a meaningful `Locus.here`; it holds opaque `Resource` handles with the locus baked in.

**URI grammar** (config/human-facing; runtime form is always a handle):

```
weft://<authority>/<kind>/<ref>
authority ∈ here | <fingerprint> | <alias> | shell:<spawn-id>
kind      ∈ file | dir | proc | lsp | sock | buf
```

- **R1 — a path is meaningless without its locus.** `/etc/hosts` under authority `k7q2…` is that path on *that* peer. A bare path never silently means the local FS. This is the same rule as "a bare offset never crosses without its version."
- **R2 — the fingerprint is the identity; the address is a hint.** `Conn.rebind` re-points a locus at a new session without changing its `Locus` value or any Resource built on it. Handles survive network flaps.
- **R3 — relative resources inherit the *invoking Context's captured* locus** (see the [FIX 4] correction below).
- **R4 — `net.connect(addr)` dials from the locus's vantage.** The locus *is* the tunnel: reach a DB or inference endpoint visible only inside a remote host with zero SSH config.
- **R5 — every remote effect degrades exactly like a slow/dead provider, because it *is* one.** A non-`here` locus can never register `Latency.instant`; `fire` clamps forwarded providers to `≥ .fast`. A dead locus maps to `session.Liveness` `connecting→connected→degraded(>3s)→offline(>10s)` — the same degrade path as a dead capability provider.

**What runs where.** Guest bytecode *always* runs in the local wasm sandbox (moving it would move its grants across a trust boundary). A remote formatter is a plugin *installed on the remote weft*, invoked here as a `placement=host, locus=peer` capability provider; the remote weft services it with its own native+guest stack under *its own* permission gate. `ShellFs` is the degenerate remote (coreutils only): fs works natively, `proc`/`lsp` are synthesized over the one serial channel.

**[FIX 4] — `here_locus` is captured, never ambient.** The original design made `ctx.here_locus = active buffer's backing locus`, re-read implicitly by `spawnHere`/`openSibling`/`lspHere`. That is ambient authority: a background task (agent turn, format-on-save timer, `async.spawn`ed grep) that outlives the active-buffer selection would re-read a *different* host's locus and act on the wrong tree. **Rule:** `here_locus` is captured into a `Context`/session snapshot at creation and is immutable for that context's lifetime. `spawnHere`/`openSibling`/`lspHere` read the *captured* locus. Reading an `active()`-derived locus from any task not on the interaction's synchronous path is forbidden — the convenience wrappers take the captured value, so the correct default is preserved without ambient re-reads.

### 2.2 Identity & Authority — the Principal

```
Principal = { agent:  []const u8,          // CRDT authorship, undo key, tiebreak
              owner:  [24]u8,              // fingerprint — accountability root
              role:   {user, plugin, agent, remote},
              caps:   HostCapSet,          // fs/net/proc… granted at load
              grant:  fn(*Document) Access } // view<edit<own, derived per-doc
```

- **Authorship ≠ authentication.** One `owner` fingerprint backs many `agent`s. `Document.Peer` gains `owner` and `grant` alongside `replica`/`name`.
- **A plugin acts as *itself*, bounded by its owner.** `grant(plugin, doc) = min(owner_grant(doc), manifest_max_grant)`. If I am `view` on your doc, my formatter is `view` too — capped, never additive. "Act as the user" is refused (it would collapse attribution and break selective undo).
- **Two boundaries, one Principal, one approval dialog.** `caps` (values: a set; grantor: the user, once, at the handshake; enforced at the host-import call — ungranted use traps) vs `grant` (values: an ordered grade; grantor: the doc owner, per-doc, live via `Hub.setPeerAccess(fingerprint, grade)`; enforced at the commit/merge gate). Revoking trust (`known_peers.forget(fp)`) severs both at once.

**Enforcement map** (grant/plane are *implicit in the invoking Principal or declared as a parameter*, never a caller-supplied argument a plugin could spoof):

| action | function | check |
|---|---|---|
| user types / plugin edits | `Context.edit()` → `Document.insert/peerCommit` | `grantOf(principal).canEdit()` |
| remote batch arrives | `Session.Collab.handleFrame` | authoritative re-check `access.canEdit()` |
| action applied (format/rename) | consumer → `Context.edit()` | inherits the edit gate for free |
| fire query (completion/hover/…) | `Caps.fire` | none (read-only) |
| publish annotation/feed | `Layer.publish*` | owns-this-layer + admitted-peer; scope routes |
| set peer authority | `Hub.setPeerAccess(fp, grade)` | keyed by fingerprint |
| host capability | wasm host-import shim | granted-at-load cap; trap if absent |

**Two planes.** Document text is *implicitly and singularly* replicated (the only text API is the CRDT one — you cannot make a "local insert"). Local UI (cursor/selection/pick/echo/keymap) is *implicitly local* (those modules have no wire method — you cannot accidentally broadcast). The one place the plane is a *declared parameter* is `layers.Scope {local|host|replicated}`, because annotation density/authority genuinely varies.

**[FIX 2] (release-blocking) — the grant gate must exist before any remote provider is enabled.** The following are treated as invariant work, not "friction," and gate the multiplayer/remote milestone:
- **Hole #1:** `Document.peerCommit` and the `.user` hot path are ungated → ghost edits on `view` clients. Add `grantOf(author).canEdit()`.
- **Hole #2:** `command.Context` has no principal → plugins launder edits as `.user` via `run("insert-text")`. Add `Context.principal` + `Context.edit()`; builtins never call `ctx.document().insert` directly.
- **Grant-keying:** capability sessions and `replicated` layers are not keyed to `secure` peer grants.
- **Action-result laundering (new, from the critique):** "fire is grant-free" must **not** imply "apply is trusted." An applied `action` result (format/rename/code-action) from a `placement=host` provider is **re-attributed to (or co-signed by) the provider's principal**, not the firing user, and is **clamped to the range the consumer fired against**. A returned batch that touches bytes outside the fired range **traps**. This closes the vector where a malicious host formatter returns a backdoor that lands as the victim's signed commit.

**[FIX 8] — sub-peer minting** (hard prerequisite for the REPL *and* agent domains, not an agent nicety):

```
document.spawnPeer(name, grant_max) -> Peer   // owner = plugin's fingerprint (no spoofing),
                                              // grant = min(owner_grant, grant_max)
ctx.asPeer(peer) -> Context'                  // scoped; ctx'.edit() authors as that peer
```

Without it, every REPL's streamed output, every agent's edits, and the plugin's own edits collapse to one `PeerId` — so two agents can't be told apart on review, and `repl/clear` (undo the tool peer) would undo the user's typing. You may only mint peers under *your own* owner, capped by *your own* grant — exactly Foundation 2's "one fingerprint backs many agents."

**[FIX 6] — presence is an ordinary replicated layer, not a bespoke wire.** Once `layers.Scope=replicated` is grant-keyed (above), delete `relayPresence`/`unionPresence` as special cases; presence becomes a plugin claiming a replicated layer with a well-known name (`presence`, at `base+1`) whose payload is exported-anchor cursors. Cursors are local UI *until published* — publishing is the one deliberate, explicit local→replicated bridge, and it now reuses the general mechanism instead of a closed API no other plugin can touch. Until the wire lands, `scope=replicated` **traps at claim time** (see [FIX 10]).

---

## 3. The Mode model

**A "major mode" is a materialized JOIN.** Emacs bundles ~a dozen orthogonal concerns behind one symbol; every one already has its own primitive in weft. So the mode model **does not materialize the join**: there is no `nix-mode` object to turn on. A buffer has *facts*; independently-predicated *contributions* each match and stack.

Orthogonality is *forced*, not merely nice:
- **Remote splits the bundle at a real seam:** a remote `.nix` file has grammar (bytes are in our replica) but no local LSP (the server needs real files on that host). A single object would be torn along the locality seam anyway.
- **Multiplayer forbids a single winner:** two peers legitimately run different grammars/keymaps/LSPs on one buffer.
- **Composition needs stacking:** `flake.nix` is nix *and* a flake; markdown embeds code.

**The Resource** (recomputed per buffer per replica; `locus` first-class):
```zig
Resource = { locus {local|remote|tool|none}, host: ?[]u8, path: ?[]u8,
             name, first_line (bounded sniff), tags: [][]u8, size }
```

**The Predicate** (host-evaluated data, O(contributions), no guest callback; generalizes `Provider.extensions`):
```
{ext} | {shebang} | {glob} | {regex (bounded to first_line)} | {locus} | {tag}
all=[…] | any=[…] | not={…}
```

**The Contribution** (each a thing the substrate already installs):
```
{keymap_layer} | {grammar} | {capability: ProviderSpec} | {facts:{…}} | {on_activate,on_deactivate (discouraged)}
```

**The one new primitive** — `activate(predicate, contribution) -> id`. A "mode" is sugar: one predicate, many contributions.

**The reconcile engine** (replaces the imperative `attachProviders`): per buffer, `active = {a : a.predicate matches Resource.of(buf)}`. On any fact change it *diffs* (React-style), activating `want\have` and deactivating `have\want` with the **same** contribution. Triggers: open, rename/save-as, save (shebang appears), tag change, locus change (reconnect), and **plugin load** (retroactive — no reopen ritual; order cannot matter because the result is a pure function of the final declaration set — modulo the tiebreak rule of [FIX 9]).

**[FIX 5] — keymap: mechanism in core, policy declared.**
- Core stores **opaque, plugin-named per-buffer state slots**. `vim` stores its modal string (`normal`/`insert`/`visual`) in *its own* slot; **core does not know what "modal mode" is**, so `switchTo` saves/restores opaque slots + `active_layers`, privileging no paradigm (a non-modal config simply uses no such slot).
- Layer precedence is **declared, not hardwired**. Each contributed `keymap_layer` carries a priority; `lookupLayered` walks layers in `(priority, owner-fingerprint, id)` order ([FIX 9]). The original "modal mode always beats language layer" rule is removed — it silently broke the design's own example (vim binds `=`→reindent, `mode.nix` binds `=`→format; modal-first meant nix `=` never fired). Now `mode.nix` declares its `=` binding at a priority that wins, as data.
- The modal axis (global keyboard state) and the language axis (buffer-scoped layer list) remain distinct; both reuse `bind`/`setFallback`/mode tables.

**[FIX 11] — virtual sub-buffers for nested language regions.** The buffer is the wrong unit for embedded js/css in HTML or fenced code in markdown: highlight works (local tree) but a *range-scoped* LSP/formatter/keymap-layer has no home. New primitive:

```
subbuffer.claim(buf, range@ver, language_facts) -> SubResource   // anchored range with its own Resource
```

A `SubResource` carries its own `Resource` (its own `first_line`/`tags`/language facts) and inherits the parent's `here`-relative locus. Predicates match sub-buffer resources; capability `fire` and keymap layers scope to the range; the range is an anchor so it rebases under edits. This is a genuine new primitive the whole-buffer model cannot fake, and it is what the persona's html-with-embedded and markdown-with-code needs.

**Remote/multiplayer:** grammar activates locally (every peer holds the replica); LSP predicates include `{locus=local}` so servers spawn only where files are real, and remote viewers *consume* `placement=host` results. Mode is per-peer, never replicated; what crosses is chosen per contribution via `layers.Scope`.

---

## 4. The complete Native Surface

**Cross-cutting rules.** Locus rides in handles, never passed per-call. Grant is implicit in `ctx.principal`, never a parameter. Plane is a declared parameter only in `layers.Scope`. Version stamping is core-enforced end to end. Everything async degrades identically.

**[FIX 1/3/7] — the ABI can now express *identities*, not just bytes/scalars.** This is the single change that dissolves the most friction. The `Value` ABI gains two opaque, version-stamped handle types, and the pick pool gains an anchor column:

```
Value = nil | bool | int | number | string | anchor | range   // anchor/range are handles, NOT offsets
```

An `anchor` is a version-stamped position handle; a `range` is a version-stamped `(anchor, anchor)` (optionally *pending/async* — see §6/§5 of the plugin catalog). This lets a motion **return a range** (killing the shared-cursor side-channel) and lets the pool **carry an anchor column** (killing the `key→PortableAnchor` side-table in five plugins).

Legend: **[E]** exists · **[N]** new/planned · **⌖** carries a locus · **⚿** carries/implies a grant or plane.

### Group A — `core`: the ungated handshake surface (zero authority)

```
export describe() -> Manifest   [E-ish]  runs with ALL caps gated OFF.
     Manifest = { perms: HostCapSet, grant_max: Grade,
                  commands:[CommandDecl], capabilities:[ProviderDecl],
                  activations:[ActivationDecl], deps, activation_events }
export init() -> void           [N]  runs AFTER user approves; grants flipped on.
log(level, msg)                 [N]
active_layers()/describe_mode() [N]  derived introspection, nothing stored
now() -> ns                     [E]  injectable clock
```
Handshake: `describe()` (no authority) → host reads manifest → user approves → grants flip → `init()`. Runtime registrations are cross-checked against the manifest; using an ungranted capability traps.

### Group B — read-only / view-plane surface

**`document`** ⚿(grant implicit) ⌖(via buffer)
```
snapshot(buf) -> Version                     [E]
readRange(buf, ver, off, len) -> bytes       [E]
version(buf) -> Version                       [E]
addAnchor(pos@ver) -> Anchor                 [E]  PLANE=local (auto-shift bookkeeping)
exportAnchor(pos@ver) -> PortableAnchor      [E]  PLANE=replicated (resolvable on any replica)
resolve(anchor, ver) -> ?pos                 [E]  rebase → pos or null; no third result
```

**`syntax`** [N] — local compute; the tree stays host-side, captures/nodes cross:
```
highlightClasses(buf, ver) -> bulk layer     [E]
nodeAtOffset(buf, off@ver) -> NodeRef        [N]
parent/children/siblings(node) -> …          [N]
query(buf, ver, scm) -> [Capture]            [N]
```

**`capability` — fire/read half** ⌖⚿:
```
fire(kind, doc, range@ver, opts) -> ?session [E; range now carried as a `range` Value]
     // remote providers = forwarded sessions clamped to ≥ .fast; land by session id; NO grant to fire
poll(session) / best(session)                [E]
mergedCompletion(session)                     [E]   Composition: merge-ranked | union | first-wins
```
Profile v1 [E]: completion, hover, definition, references, diagnostics, highlight, format, rename, symbols-document. Extensions [N]: code-actions, signature-help, inlay-hints.

**`fs` — read side** ⌖ ⚿(cap: fs.read):
```
open(path, flags) -> Resource   [E core]
readAll(path) -> bytes          [E]
readRange(path, off, len)       [E]
stat(path) -> Stat              [N]
list(path) -> Listing          [E]
hashToken(path) -> token        [E]  sha256 for here; dir-scoped change token
watch(path, sink) -> Watch      [N]  [FIX 12] RECURSIVE/tree watch: one inotify per dir here /
                                      peer forwards / shell bridges `inotifywait`|`find -newer` —
                                      NEVER per-path hashToken polling (that was O(files) on shell tier)
```

**`pick` — pool** ⌖ ⚿(scope, default local):
```
Pool = { blob, spans, docs, meta{source_id:u16, anchor:AnchorCol}, [FIX 1]  // anchor column, not u32 key
         locus_col: []LocusRef,  [FIX 7]                                    // PER-CANDIDATE locus
         version, generation, scope=.local }
Pool.appendBatch(blob, spans, meta, loci)    [N]  sources ALWAYS batch, NEVER one item across boundary
weft_pool_stat(pool) -> {version,count}      [N]  staleness poll
```
[FIX 1] The pool carries an `anchor` column (version-stamped handle), so position-referencing sources no longer maintain a `key→PortableAnchor` side-table. [FIX 7] `locus` is **per-candidate** (a small `locus_col` index into a pool-local locus table), because heterogeneous pools (`consult.buffer` mixing `here`+peers+shell, `embark.collect`) are common; a scalar `Pool.locus` mis-targeted marginalia `stat` and embark `writeGuarded` on half the rows.

### Group C — write / edit-plane surface ⚿(grant gated)

**`document` — write half:**
```
edit(range@ver, bytes) -> Commit    [E core; ⚿ gate]  routes to ctx.principal's peer; author≠.user;
                                     checks grantOf(principal).canEdit() → error.Unauthorized
commit(range@ver, bytes) -> Commit  [E]  same gate
undo(peer_scope) -> Commit          [E]  per-peer SELECTIVE (op inverse, keyed PeerId)
spawnPeer(name, grant_max) -> Peer  [N]  [FIX 8]  owner = plugin fingerprint, grant = min(owner, grant_max)
```

**`capability` — register/apply half** ⌖⚿:
```
register(spec: ProviderSpec)        [E]  id-namespaced plugin.<n>/<cap>
     ProviderSpec = { name, id, latency, priority, placement: local|host,
                      locus: Locus,      [N] ⌖  — [FIX 10] TRAPS at register if remote wire absent
                      predicate }        [N]  generalizes `extensions`
registerFeed(name, scope, provider) [E]  scope: local|host|replicated — [FIX 10] `replicated` TRAPS until wired
push(session, payload)              [E]  host deep-copies + RE-STAMPS version
```
Shapes: *query* (pure read), *feed* (version-stamped annotations into a provider-owned layer), *action* (Replacement batch vs a stated version → applied through `ctx.edit()` → hits the grant gate for free → merges like a peer). [FIX 2] applied action results are re-attributed to the provider principal and clamped to the fired range.

**`layers`** ⚿(scope param):
```
claim(doc, name, scope, provider)   [E]  scope=replicated TRAPS until grant-keyed wire lands [FIX 10]
publishSpans(layer, [anchored_span])[E]  checks layer ownership
publishBulk(layer, per_byte_paint)  [E]
```
Plus [N] virtual/overlay text, gutter marks, richer faces (foldable/invisible/clickable) riding the same scope.

**`fs` — write side** ⚿(cap: fs.write):
```
writeGuarded(path, bytes, expect_token) -> token  [E]  test-and-set; error.Stale → merge-and-retry
```

### Group D — effects (each cap-gated, locus in handle)

```
proc.spawn(argv, opts) -> Proc      [N] ⌖ ⚿proc   here→std.process; peer→forward; shell→serial channel
proc.spawnHere(argv) -> Proc        [N] ⌖         inherits the CAPTURED here_locus [FIX 4]
net.connect(addr) -> Sock           [N] ⌖ ⚿net    dials FROM the locus (R4); TLS native
lsp.create(loci, at, argv, path, doc, environ) -> Lsp  [E core; ⌖]  peer→runs on peer; shell→serial channel
async.spawn(fn)/timer(ns,sink)/cancel  [N]        local event loop; born locus-blind
```

### Group E — administration & persistence

```
loci.resolve/attachPeer/attachShell/tier/liveness/fingerprint/label   [N]  src/core/locus.zig
secure.setPeerAccess(fingerprint, grade)  [E] ⚿   Hub.overrides, live
secure.forget(fingerprint)                [E]      severs links AND grant
subbuffer.claim(buf, range@ver, facts) -> SubResource   [N]  [FIX 11]
kv.get(key)/kv.put(key, bytes)/kv.del(key)  [N]  [FIX 13] ⌖ per-plugin persistence, locus-aware
```

**[FIX 13] — a per-plugin persistence capability.** Several plugins quietly assume durable local state the ABI never grants: matcher **frecency**, recent-files ring, kill-ring, `project.forget` recents. `kv.*` is a small locus-aware key/value store scoped per plugin (a peer's frecency stays with the peer). This lets `sel.match` persist frecency without `fs.write`, keeping it the zero-authority exemplar (it holds only `kv` for its own namespace, no filesystem reach).

### The refusal / footgun list

| Refused | Invariant protected |
|---|---|
| A bare offset/position crossing a boundary without its version | CRDT inversion — you get an anchor or `null`. |
| A bare path that silently means the local FS | R1 — locality not second-class. |
| A locus argument on effect calls | locus rides in the handle; can't mis-target. |
| "Local document" / "local insert" | only the CRDT text API exists. |
| A grant/grade/principal parameter on edit calls | no attribution laundering / escalation. |
| "Act as the user" for plugins | preserves attribution + selective undo. |
| **Applying an action result outside the fired range, or as the firing user** | **[FIX 2]** — no content laundering via remote providers. |
| A per-candidate guest callback over the full candidate set | the bright line — bulk pool + one `match_rank`/keystroke only. |
| `set cursor` / broadcast-able local UI | cursor/pick/echo/keymap have no wire; presence is explicit. |
| A general per-buffer key/value variable bag | mode determinism — facts + tags + active-set only. |
| One-way (add-only) activation hooks | reversible-by-construction reconcile. |
| A singular replicated "major mode" | per-peer mode. |
| The tree-sitter tree object across the ABI | one impl / lifetime safety — captures only. |
| A synchronous-infallible fs/proc/net call | remote degrades like a dead provider (R5). |
| Ambient authority of any kind, **including ambiently re-read `here_locus`** | **[FIX 4]** — capture the locus into the Context. |
| General expression language in predicates | host-side O(contributions) data only. |
| **A speced-but-unimplemented param that silently no-ops** | **[FIX 10]** — `scope=replicated` / remote `locus` TRAP at register, never silently localize (no forbidden third result). |

---

## 5. The candidate/pick seam

One append-only, columnar, native-owned **Pool**; append-only makes "the set changed under the matcher" inexpressible (the same inversion as the CRDT). The matcher lives in a guest plugin under capability `pick/matcher` (first-wins by priority; absent → the built-in `refilter`, so it is purely additive and hot-swappable).

**Boundary budget (the bright line):**
- source → pool: **native only**, zero guest involvement.
- pool → matcher mirror: **one bulk memcpy** of `[since_version..version)` when `version` advances (during the native fold), gated by `match_reserve`. Amortized O(new bytes), never per-candidate.
- matcher → host: **one `match_rank` call per keystroke** returning a bulk `u32[]` of ranked indices (+ optional highlight spans). The guest scans its own mirror once; the host never invokes the guest N=|candidates| times.

```
export match_reserve(n_spans, n_blob) -> {blob_ptr, spans_ptr}   guest sizes its mirror
export match_rank(count, query_ptr, query_len, out_ptr, out_cap) -> n
import weft_pool_stat(pool) -> {version,count}
```

**[FIX 1] applied here:** the pool's `meta` carries an **anchor column**, not a `u32 key`. Position-referencing sources (`cape`, `consult.line/grep/imenu/mark`, `nav`, `notes.agenda`) stamp a version-stamped anchor per candidate and resolve via `document.resolve` at accept time — no hand-maintained side-table, no lazy-line-number footgun. **[FIX 7] applied here:** locus is a per-candidate column, so heterogeneous pools resolve marginalia `stat` / embark `writeGuarded` on the *right* host per row.

**Emacs-lineage features, bright line respected:** *vertico* = the native view rendering the ranked array (restyle paints only ~30 visible rows). *marginalia* = capability `pick/annotate` fired only over the visible index window (bounded N). *cape* = many sources, one pool, distinct `source_id`. *embark* = accepted `meta{source_id, anchor, locus}` resolves the real target and dispatches via the capability `action` shape → ordinary edit path → merges like a peer.

**Remote/multiplayer:** a remote source ships byte *batches* over `ShellFs`/subprocess into `appendBatch` (no per-candidate RPC); `scope=.local` (your palette is not my palette) — what's shared is only the *consequence* of accepting (a versioned edit the CRDT merges). Going native later = register the built-in as the `pick/matcher` provider; one-line swap.

---

## 6. The reference plugin catalog

Every plugin is `.wasm` (or JS via `quickjs.wasm`) at the same ABI. Config is a plugin with no special powers. All edges are **late-bound names** or **capability kinds** — no code dependencies.

**[FIX 9] — one conflict rule for all name/priority resolution** (`command.register` shadowing, `grammar`, `lsp/locate`, `edit/format`, `pick/matcher`, `fact`, keymap layers): total order by `(priority, owner-fingerprint, id)`. **Shadow** (explicit, declared intent) is distinguished from **collision** (accidental equal-priority) — a collision is surfaced as a load-time error, never silent load-order-dependence. This is what makes "reconcile is a pure function of the final declaration set" actually true.

### 6.1 Editing / vim / buffers / windows / presence (7 plugins)

**Load-bearing decision [FIX 1/3]:** motions and textobjects **return a `range` Value** (possibly a *pending/async* range handle the operator awaits) — they no longer mutate a shared cursor that the operator races to read back. This kills the global-mutable-cursor side-channel *and* makes `d/foo<CR>`, `d}` over a `peer` locus, and any async/interactive motion compose correctly (the operator awaits the range before applying). A new tiny `editor` surface (local plane, anchor-typed) backs it:

```
editor.cursor(buf) -> (Anchor, Version)     editor.setCursor(buf, Anchor)
editor.selection(buf) -> ?(Anchor,Anchor,Version)     editor.setSelection(buf, ?range)
editor.step(buf, dir, kind) -> Anchor       // NATIVE goal-x/layout vertical motion (carve rule b)
editor.viewport(win) -> (Anchor, rows, cols)
```

| plugin | commands (representative) | provides / consumes | perms · grant_max | remote+multiplayer free because |
|---|---|---|---|---|
| **vim** | `vim.normal/insert/visual/visual-line/visual-block/replace`, `vim.append/append-eol/open-below/open-above/insert-bol`, `vim.count-digit`, `vim.set-register`, `vim.operator`, `vim.repeat`, `vim.macro-record/play`, `vim.mark-set/jump`, `vim.jump-back/fwd`, `vim.undo/redo` | provides keymap layers `vim/{normal,insert,visual,op-pending}` + the operator-calls-motion convention; consumes `motion.*`/`textobj.*`/`op.*`/`editor.*` | `{}` · edit | marks/jumplist are anchors (auto-shift under peers); `vim.undo` = per-peer selective undo; modal state in vim's **opaque core slot** [FIX 5], per-peer |
| **motions** | `motion.left/down/up/right` (native `editor.step`), `word-fwd/back/end`, `WORD-*`, `bol/first-nonblank/eol`, `goto-line`, `top/mid/bot`, `para-*`, `sentence-*`, `match-pair`, `find-char`+repeat, `search-*` | provides `motion.*` (each **returns a `range`/target**); consumes `document.snapshot/readRange`, `editor.*`, `layers` (search hl, scope local) | `{}` · view | reads a version-stamped snapshot → concurrent edit can't corrupt; search hl is local; read-only ⇒ grant irrelevant |
| **textobjects** | `textobj.inner/a-word`, `inner/a-WORD`, quotes/parens/braces/brackets/angle/tag, `inner/a-paragraph/sentence`, `inner-indent` | provides `textobj.*` (**return a `range`**); consumes `editor.setSelection`, `syntax.query` (degrades to byte scan) | `{}` · view | tree-backed via captures (tree host-side), computed per-replica-local |
| **operators** | `op.delete/change/yank/paste`, `op.indent/dedent`, `op.upper/lower/toggle-case`, `op.format` (fires `edit/format`), `op.comment` (reads `comment_line` fact); `x/s/D/C/Y` specializations | provides `op.*`; consumes `motion.*`/`textobj.*` (by name, **await returned range**), `ctx.edit`, `capability.fire` | `{}` · edit | edits route through `ctx.edit()` → `canEdit()` (view peer's `op.delete` fails, `op.yank` works — zero permission code); range resolved @snap.version → rebases; author = principal → selective undo |
| **buffers** | `buf.open` (inherits captured locus), `buf.open-uri`, `buf.pick`, `buf.next/prev/alt`, `buf.close`, `buf.save`, `buf.save-as`, `buf.write-all/reload`, `buf.scratch`, `buf.tool`, `buf.share {grade}`, `buf.tag` | provides `buf.*` + `pick/annotate` (locus label/liveness/peers); consumes `pick`, `loci.*`, `secure.setPeerAccess` | `{fs.read,fs.write}` · edit | one path; `here`=Locus 0; degraded host = degraded buffer (reads stale, writes queue); reconnect rebinds without invalidating handles; sharing keyed by fingerprint |
| **windows** | `win.split-h/-v`, `win.focus {dir}`, `win.close/only`, `win.resize/balance/rotate`, `win.scroll`, `win.center/top/bottom`, `win.jump-to-buffer`, `win.new-tab/next-tab` | provides `win.*`; consumes `gfx` region tree (carve, never offset-math), `document.addAnchor` (viewport anchor), `layers` (peer cursors, scope local) | `{}` · view | local by irrelevance (no wire); viewport is an anchor → auto-shifts under concurrent edits; window over remote buffer identical to local |
| **presence** | `peer.list`, `peer.follow/unfollow/goto`, `peer.grant/revoke`, `peer.toggle-cursors/names` | **provides a replicated `presence` layer** [FIX 6] (ordinary `layers.claim(scope=replicated)`, well-known name); consumes `document.exportAnchor/resolve`, `loci.*`, `secure.*` | `{}` · view | portable anchors resolve on any replica + rebase; a `view` peer publishes presence (feeds gated by ownership+admission, not edit grant); an agent shows up as just another cursor |

Composition: `keys → vim → op.* → (await) motion.*/textobj.* → ctx.edit (gate+attribution+rebase)`. A user adding `motion.next-hunk` gets `d]c`/`c]c`/`y]c`/`v]c` for free (operators invoke motions by name and await the returned range). Shadowing is explicit via [FIX 9].

### 6.2 Language tooling (engines + thin modes)

Rule used throughout: **`grant_max` constrains only *autonomous* edits.** A user-invoked command edits as `ctx.principal == user` under the user's grant; the plugin's grant is irrelevant. Only self-driven mutation (format-on-save, REPL output, an agent) needs `edit`.

| plugin | commands (representative) | provides / consumes | perms · grant_max |
|---|---|---|---|
| **ts** | `ts-select-node`, `ts-expand/shrink-selection`, `ts-select-function/class/param/comment`, `ts-next/prev-sibling`, `ts-goto-parent/first-child`, `ts-swap-next/prev`, `ts-fold-toggle/all/unfold-all`, `ts-comment-dwim`, `ts-indent-line`, `ts-node-at-point`, `ts-query` | provides `edit/highlight` + `ts/fold` feed + structural motion/textobject commands; consumes `syntax.*`, `layers`, `document`, `activate.fact` | `{fs.read}` · view |
| **lsp-locate** | `lsp-which`, `lsp-locate-server`, `lsp-locate-refresh` | provides `lsp/locate` (first-wins); consumes `fs.stat/list/hashToken/watch`, `proc.spawn` (direnv env, `command -v`) | `{fs.read,proc}` · view |
| **lsp** | `lsp-start/stop/restart/status`, `goto-definition/-type-definition/-declaration/-implementation`, `lsp-hover`, `find-references`, `lsp-rename`, `lsp-code-action`, `lsp-signature-help`, `document-symbols/workspace-symbols`, `lsp-inlay-hints-toggle` | provides all `edit/*` providers + `lsp.spec(lang,kinds,{placement,locus})`; consumes `lsp/locate`, `lsp.create(loci,at,…)`, `capability.push`, `async.timer` | `{proc,fs.read,net,timer}` · view |
| **fmt** | `format-buffer`, `format-region`, `format-on-save-toggle`, `format-set-formatter` | provides a subprocess `edit/format` (first-wins by priority over LSP); **shadows the late-bound `save`** when the `format-on-save` tag is set; consumes `proc.spawnHere`, `document`, `buffers.tag` | `{proc,timer}` · edit (autonomous format-on-save authored by `plugin.fmt`) |
| **diag** | `diagnostics-next/prev/show/list`, `diagnostics-toggle-inline`, `diagnostics-filter`, `diagnostics-copy` | provides local decoration layers + a pick source; consumes the `edit/diagnostics` (host-scoped) feed, `layers`, `document.resolve`, `pick` | `{}` · view |
| **nav** | `nav-references`, `nav-symbols`, `nav-workspace-symbols`, `nav-diagnostics`, `nav-embark-act` | provides pick sources stamped with `meta{source_id, anchor, locus}`; consumes `capability.fire`, `pick`, `pick/annotate`, `buffers.openUri` | `{}` · view |
| **modes** (`mode.nix/jsts/html/clojure/markdown`) | language commands (e.g. `nix-flake-check`, `ts-organize-imports`, `html-close-tag/emmet-expand`, `clj-slurp/barf/wrap/splice/raise`, `md-toggle-heading/checkbox/insert-link/follow-link/table-align/preview-toggle`) | provide `grammar_add` + `activate(pred,[grammar,keymap_layer,facts,capability])` + `bind`; consume `ts`/`lsp`/`fmt`/`diag`/`repl` by name | mostly `{}` (some `{proc}`) · view |

**Remote/multiplayer for the LSP crux:** the mode is loaded on *both* wefts. Where the file's backing is local (`{locus=local}`), that weft launches the server (`placement=local`). Every other peer registers a `placement=host, locus=peer` **forwarding** provider. Any peer `fire`s; the authoritative host answers once; results land as `push`es rendered in each peer's *local* UI. One backing → one server → no contention, identical features across peers, computed once. A `view` peer may `fire` rename/format but the *apply* fails `canEdit()` — and [FIX 2] additionally re-attributes/clamps the applied batch so a hostile host provider can't launder a payload as the victim.

**html/markdown embedded languages** now activate real sub-language tooling via `subbuffer.claim` [FIX 11], not just highlight.

### 6.3 REPLs / interactive eval

A REPL session is three things at three seams: the **connection is a Resource with a locus**; **evaluation is a capability** (`eval/send`, feed shape — firing is a grant-free read); **output into a comint buffer is a Document peer write** (via `spawnPeer` [FIX 8], `role=tool`). `eval-region` never mutates the source; the two mutating verbs (`eval-and-replace`, `insert-result`) go through `ctx.edit()` → the grant gate. Sessions are keyed by `(locus, project_root)` — Clojure's whole-project REPL falls out.

| plugin | commands (representative) | provides / consumes | perms · grant_max |
|---|---|---|---|
| **repl-core** | `repl/eval-region/-top-form/-last-form/-buffer/-line/-string`, `repl/eval-and-replace`, `repl/insert-result`, `repl/eval-to-repl`, `repl/interrupt`, `repl/switch-context/set-context-from-buffer`, `repl/connect/disconnect/list-sessions`, `repl/open-repl-buffer`, `repl/clear-results`, `repl/toggle-result-overlay`, `repl/inspect-last` | consumes `eval/send`, `eval/context`, `syntax.query`, `fact("project.root")`, `pick`; provides `repl/*` + the local `repl/results` layer | `{timer}` · edit |
| **repl-clojure** | `clj/jack-in/connect/connect-uri`, `clj/switch-ns/require-ns/reload-ns/load-file`, `clj/run-tests/run-test-at-point`, `clj/doc/source/apropos/macroexpand/pprint-last`, `clj/interrupt/quit` | provides `eval/send`+`eval/context`+`edit/{hover,definition,completion,symbols,diagnostics}` (one nREPL socket powers repl AND LSP-shaped domain), fact `eval.top_form_query`, `clojure` keymap layer; consumes `net.connect` (bencode, dialed from locus, R4), `proc.spawnHere` (jack-in), `fs` | `{net,proc,fs.read,timer}` · edit |
| **repl-nix** | `nix/repl-start/load-flake/load-file/eval-attr/reload/build-at-point/quit` | provides `eval/send`+`eval/context`, form-query fact, `nix` layer; consumes `proc.spawnHere`, `syntax` | `{proc,fs.read,timer}` · edit |
| **repl-js** | `js/repl-start/connect-inspector/eval-module/eval-in-context/reload-module/quit` | provides `eval/send`+`eval/context`, `js` layer; consumes `proc.spawnHere` or `net.connect` (inspector, R4), `syntax` | `{proc,net,fs.read,timer}` · edit |
| **repl-inspector** | `inspect/open/push/pop/def/copy/to-repl` | provides `repl/inspect` + embark action `pick/action:inspect`; consumes `eval/send` (each drill = one eval — no object graph crosses the scalar ABI), `pick`, `layers` | `{}` · view |
| **repl-comint** | `comint/send-input/previous-input/next-input/interrupt/clear/associate` | provides a `tool`-backed buffer whose evaluator is a **spawned tool peer** [FIX 8]; consumes `eval/send`, `document.edit` via `ctx.asPeer(tool)`, `keymap` | `{}` · edit (output authored by the tool peer, so `repl/clear` = undo the tool peer only) |

**Remote free:** `net.connect` dials the nREPL socket *from the project's locus* — the socket may be reachable only inside the remote host and the locus *is* the tunnel; `spawnHere` runs `nix repl`/`node` next to the store/code. Stale results are free: eval reads @V, the result overlay anchor is stamped V, `resolve` marks it stale/drops it if a peer edited the form. Policy left to config (honest default: per-peer-local session, `scope=local` output).

### 6.4 Completion / selection stack

Built entirely on the pool seam + capability profile. Ordering is dependency order.

| plugin | commands (representative) | provides / consumes | perms · grant_max |
|---|---|---|---|
| **sel.match** | `match.set-style {orderless\|flex\|substring\|prefix\|initialism}`, `match.toggle-case`, `match.add-dispatcher {prefix,style}`, `match.set-priority` | provides `pick/matcher` (exports `match_reserve`/`match_rank`); consumes `weft_pool_stat` **and `kv.*` for persistent frecency** [FIX 13] | `{kv:self}` · view (the zero-authority exemplar — no fs) |
| **sel.vertico** | `vertico.next/prev/first/last`, `scroll-up/down`, `next/prev-group`, `accept/accept-input/exit`, `set-count`, `toggle-grid` | provides a `pick` keymap layer + display commands; consumes the core pick loop | `{}` · view |
| **sel.marginalia** | `marginalia.toggle/cycle-annotator/set-field` | provides `pick/annotate` (fired over the ~30 visible rows only); consumes `fs.stat` (per-candidate locus [FIX 7]), `hover`/`symbols`, `buffers.backing` | `{fs.read}` · view |
| **sel.cape** | `cape.complete`, `-symbol/-file/-dabbrev/-line/-keyword/-snippet`, `cape.set-sources`, `next/prev-source` | provides completion sources (per `source_id`); consumes `completion` profile, `pick/matcher`, `Pool.appendBatch` (anchor column [FIX 1] — no side-table), `document`, `fs.list` (via captured locus) | `{fs.read}` · edit (accept inserts) |
| **sel.consult** | `consult.buffer/line/line-multi/grep/git-grep/find-file/recent-file/imenu/outline/mark/yank/command/diagnostic`, `preview-toggle`, `grep-here`, `narrow`, `buffer-other-window` | provides the `consult.*` family (each a pool source with anchor+locus columns); consumes `proc.spawnHere` (rg), `fs` finders, `syntax`/`symbols`, `pick`, **`kv.*` for recent/mark/kill rings** [FIX 13] | `{fs.read,proc,kv:self}` · view |
| **sel.embark** | `embark.act/dwim/act-all/mark/unmark/export/collect/become/define-action` | provides a `pick/action` dispatch registry; consumes capability `action` shapes, `command.call` (late-bound), `menuMode`/`whichKey`, `document.edit`, `fs.writeGuarded` | `{fs.read,fs.write,proc}` · edit |

Preview is N=1 (selected row); marginalia is N≤~30 (visible window) — both inside the bright line. Accept is an action → `ctx.edit()` → grant gate (view peer browses but can't insert). [FIX 1] removes the `key→anchor` side-table from `cape`/`consult`; [FIX 7]'s per-candidate locus fixes heterogeneous pools; [FIX 13] gives frecency/rings durability.

### 6.5 Agents

An agent is a Document peer. One neutral protocol, `agent/provider` (a `.slow` capability, first-wins on model predicate), so `agent-core` never names a vendor. Two data shapes cross as typed `Value` batches (never per-token callbacks): `Turn` and a stream of `Event`. The network-touching adapters hold `net`/`proc` and **zero document grant**; the document-touching core holds `edit` and **zero net** — Foundation 2's two boundaries become two plugins.

| plugin | commands (representative) | provides / consumes | perms · grant_max |
|---|---|---|---|
| **agent-core** | `agent.start/send/interrupt/stop/retry/end/list/switch`, `agent.set-model/set-grant`, `agent.attach-buffer/detach-buffer`, `agent.checkpoint` | consumes `agent/provider`, `agent/context`, `pick`; **mints a session agent peer via `document.spawnPeer` and dispatches tools/turns via `ctx.asPeer`** [FIX 8]; captures `here_locus` at `start` [FIX 4] | `{timer,async,now}` · edit (no net/fs/proc — a compromised backend can't touch disk) |
| **agent-{claude,codex,pi,deepseek,hermes}** | `agent.<vendor>.auth`, `agent.<vendor>.models` | each provides an `agent/provider` (predicate on model glob); consumes `net.connect` (wasi-http shape, dials from session locus, R4) or `proc.spawnHere` (CLI) | HTTP: `{net,now}` / CLI: `{proc,fs.read}` · **none** (adapters never edit) |
| **agent-tools** | `agent.tool.read-file/list-dir/grep/find/read-buffer/edit/create-file/format/lsp-def/lsp-refs/lsp-hover/diagnostics/tree/run/shell` | provides the tool catalog (data → `Turn.tools`) + `agent.tool.*`; consumes the whole command registry via `command.call` (late-bound, open-world), `fs`, `proc`, `capability.fire`, `document.edit` **in the session peer's scope** | `{fs.read,fs.write,proc}` · edit |
| **agent-context** | `agent.context.selection/buffer/region/symbol/diagnostics/tree/project/add-file/clear/show` | provides `agent/context`; consumes `capability.fire`, `syntax.query`, `fs.list/readAll`, `pick`, `document.exportAnchor` (portable blocks rebase) | `{fs.read}` · view |
| **agent-review** | `agent.review.diff/next/prev/accept/reject/accept-all/reject-all/jump/blame` | provides a local diff feed; consumes `document.undo` (keyed by agent PeerId), commit log, `layers`, presence | `{}` · view (reject = selective undo of own-owner agent peer) |
| **agent-transcript** | `agent.transcript.fold-tools/unfold/copy-code/apply-code/rerun-from/goto-source` | provides a transcript mode via `activate` (markdown grammar, `agent` keymap layer, role faces); consumes `layers`, `syntax`, markdown analyzer | `{}` · edit (`apply-code` only) |

**Free:** the session peer rides the presence union ("claude is typing here"); a `view`-grade collaborator's `agent.start` yields a `view` agent (reads+chats, tool edits fail `canEdit()`); tool edits merge with concurrent human edits; `net.connect` from the session locus reaches internal endpoints. `agent.review.reject` uses per-peer selective undo — now able to separate `claude#1` from `codex#2` *because* [FIX 8] mints distinct peers. Read/write asymmetry is safe *because* [FIX 2] re-attributes/clamps applied action results.

### 6.6 Projects / direnv / git / notes

`project` is the locus+root provider the other three consume by late-bound name; `here_locus` inheritance + `spawnHere` + CRDT edits make all four remote- and multiplayer-correct without any of them knowing what remote or multiplayer *is*. A project boundary is *derived* (nearest ancestor marker at the buffer's locus), with a `loose` fallback so nothing is ever "outside a project"; markers are data contributed via `activate`.

| plugin | commands (representative) | provides / consumes | perms · grant_max |
|---|---|---|---|
| **project** | `project.root/root-of/kinds/locus`, `project.switch`, `project.find-file`, `project.grep`, `project.switch-buffer`, `project.dired`, `project.shell`, `project.repl`, `project.repl-eval-region/-form`, `project.repl-ns`, `project.compile`, `project.forget`, `project.reroot` | provides `project.root/locus/kinds` + `project/root` query + pick sources; consumes marker predicates (data), `pick/matcher`, `direnv.env-for` (late-bound), **`kv.*` for recents** [FIX 13] | `{fs.read,proc,timer,kv:self}` · edit (only its own tool buffers) |
| **direnv** | `direnv.env-for/env/reload/allow/status/edit` | provides `direnv.env-for` (memoized by `(root, locus, .envrc hashToken)`) + facts; consumes `project.root/locus`, `proc.spawnHere` (`direnv export json` **at project locus**), `fs.watch` (recursive [FIX 12]) | `{fs.read,proc,timer}` · view |
| **git** | `git.status/refresh/stage/unstage/stage-all/unstage-all/discard/commit/commit-finish/-amend/-fixup/diff-file/-staged/-range/next-hunk/prev-hunk/visit-hunk/log/log-current-file/show/checkout/branch/branch-create/switch/blame/blame-popup/stash/stash-pop/stash-list/fetch/pull/push/merge/rebase-onto/rebase-abort/file-history` | provides `git/blame` feed + `vcs/status` query + modeline facts; consumes `project.root/locus`, `direnv.env-for`, `proc.spawnHere` (at repo locus), `fs.watch` (`.git/*`), `document.edit` (hunk discard on open buffers → merges), `layers` (blame gutter), `syntax` (snap region staging) | `{fs.read,proc,net,fs.write,timer}` · edit |
| **notes** | `notes.capture/-finish/-abort`, `notes.agenda/-today/-week`, `notes.todo-cycle/-set`, `notes.schedule/deadline`, `notes.backlinks`, `notes.follow-link/insert-link`, `notes.new/refile/search/toc/narrow-to-subtree/tags/filter-tag` | provides `notes/backlinks` + `notes/agenda-items` queries + pick sources + `notes` keymap layer/facts; consumes `project.root/locus`, `markdown` analyzer, `syntax`, `pick`, `fs_source` finder + `fs.watch` (recursive [FIX 12]), `document` (capture/todo/refile are CRDT edits; agenda anchors are `exportAnchor`) | `{fs.read,timer}` · edit |

**Free:** project walk at captured `here_locus`; grep/repl/compile `spawnHere` at project locus; direnv `export` at locus (essential — remote `PATH`/store paths are meaningless locally); git at repo locus (blame feed `scope=local`); notes are CRDT docs → a shared vault is inherently multiplayer, concurrent captures into `inbox.md` merge, a `view` peer reads the agenda but can't cycle a TODO. Git's index is not a CRDT, so two concurrent commits surface git's own lock error (inherent, not a mis-slice). [FIX 12] makes remote notes/git viable (tree watch, not O(files) hashToken storms). `direnv.allow` executes arbitrary code on the target host → requires `proc` + a runtime escalation prompt on `.envrc` hash change (TOFU-shaped).

---

## 7. The persona walkthrough

The persona: vim bindings; edits nix / js-ts-html / clojure (project-scoped cross-file repl) / markdown-org notes; tree-sitter + LSP local/project/remote; multi-provider agents; low-overhead projects; direnv; git; the vertico/marginalia/cape/consult/embark stack; good buffer management. Remote + multiplayer first-class throughout.

**Startup / config.** The user's `config.wasm` (a plugin, no special powers) runs `describe()` → declares its perms, then `init()` binds vim keys and sets layer priorities. It loads: `vim`+`motions`+`textobjects`+`operators`+`buffers`+`windows`+`presence`; the language engines `ts`/`lsp-locate`/`lsp`/`fmt`/`diag`/`nav` + modes; `repl-core`+`repl-clojure`/`repl-nix`/`repl-js`+`repl-inspector`+`repl-comint`; the `sel.*` stack; `agent-core`+adapters+`agent-tools`/`-context`/`-review`/`-transcript`; `project`/`direnv`/`git`/`notes`. Order is irrelevant — reconcile is a pure function of the final declaration set, ties total-ordered by [FIX 9].

**Vim.** `vim` puts its modal string in an opaque core slot [FIX 5]; `buffers.switchTo` saves/restores that slot + `active_layers` without core knowing what "modal" means. `dw` → `op.delete` awaits the `range` returned by `motion.word-fwd` [FIX 3] and applies it via `ctx.edit()`. The user adds `(bind "vim/normal" "]c" "motion.next-hunk")` and `d]c`/`y]c` work instantly.

**Open a nix file with direnv + project-local server.** `:e flake.nix` → reconcile fires: `mode.nix` `activate {ext=".nix"}` attaches grammar + `nix` keymap layer + facts; `activate {all:[{ext=".nix"},{locus=local}]}` attaches the nixd LSP provider. `lsp-locate` walks up at the captured locus, finds `.envrc`, calls `direnv.env-for` (runs `direnv export json` **at the file's locus**), discovers the flake-pinned nixd, and `lsp.create(loci, at=here, argv, environ)` launches it. `=` is bound in the `nix` layer at a priority that beats vim's reindent [FIX 5] → `format-buffer` runs nixfmt via `fmt`. `K`→hover, `gd`→definition, `]d`→`diagnostics-next`.

**JS/TS/HTML.** `mode.jsts` finds `node_modules/.bin/typescript-language-server` via `lsp-locate`; prettier registers a subprocess `edit/format` outranking the LSP formatter [FIX 9]. In an HTML file, `subbuffer.claim` [FIX 11] marks the `<script>` range as a js sub-resource → real js completion/format inside the tag, not just highlight.

**Clojure cross-file project REPL.** `clj/jack-in` spawns nREPL at the project locus; `repl-clojure` provides `eval/send` keyed by `(locus, project_root)`. Evaluating a form from *any* `.clj` under the root sends to the **one** session, tagged with that file's ns (`clj/switch-ns` from the buffer's `ns` form via `ts-query`). Output appends to a comint buffer authored by a spawned `role=tool` peer [FIX 8], so `repl/clear` undoes only the tool.

**Markdown/org notes.** `notes` treats the vault as a `notes`-kind project; `notes.capture` appends via CRDT edit; `notes.agenda` batches TODO/SCHEDULED items into a pool (anchor+locus columns) with `exportAnchor` targets; `notes.backlinks` fires over a bounded window; `fs.watch` (recursive [FIX 12]) keeps the index fresh.

**Vertico stack everywhere.** `buf.pick`, `project.find-file`, `consult.grep`, `cape.complete`, `nav-references`, `notes.agenda` all fill one pool → `sel.match` ranks (persistent frecency via `kv` [FIX 13]) → `sel.vertico` renders → `sel.marginalia` annotates the visible rows (per-candidate locus [FIX 7]) → `sel.embark` acts on the accepted `meta{source_id, anchor, locus}` via the action shape.

**Agents, multi-provider.** `agent.start {model:"claude-*"}` mints a session agent peer [FIX 8] and captures the current locus [FIX 4]; `agent-core` fires `agent/provider`; the claude adapter wins on the model predicate; the deepseek adapter is one more `.wasm`, no core change. Tool edits merge as the agent peer; `agent.review.reject` selectively undoes `claude#1` without touching `codex#2` or the user.

### Concrete remote + multiplayer scenario

The user opens a Clojure project that lives on host `k7q2…` (`weft://k7q2…/dir//srv/svc`) via `project.switch`. A collaborator `Bob` holds `edit` grade on the buffers; an `agent.claude` session is also present.

- **Buffers/locus.** `:e src/core.clj` resolves relative to the captured project locus → a `session.Collab`-backed Document replica of the remote file. `here` is just Locus 0; nothing branches.
- **LSP.** `mode.clojure`'s `{locus=local}` predicate matches only on `k7q2…` (where the files are real), so *that* weft runs `clojure-lsp`; the user's and Bob's wefts register `placement=host, locus=peer` forwarding providers. Everyone's completion/hover/diagnostics are computed once at `k7q2…` and pushed; each renders in local UI.
- **REPL.** `clj/connect` dials the remote nREPL socket **from the project's locus** (R4) — the socket is visible only inside `k7q2…`, and the locus is the tunnel; zero SSH config. All three peers evaluating forms from any of the project's files hit the one project-scoped session.
- **Concurrency.** The user's `op.delete` resolves its range @snap.version; Bob's concurrent insert above merges via the log — no clobber. The agent's `agent.tool.edit` lands as the agent peer; the user reviews it with `agent.review.diff` (a local layer) and rejects one hunk via per-peer selective undo without disturbing Bob's or their own edits.
- **Authority.** If Bob were `view`, his `op.change` would fail `canEdit()` at the document gate (and his forwarded format-action results would be clamped/re-attributed [FIX 2]). `secure.setPeerAccess` promotes him live; `secure.forget` severs link and grant together.
- **Presence.** All cursors (user, Bob, agent) ride the ordinary replicated `presence` layer [FIX 6]; git status/diff buffers stay `scope=local` (each peer views `k7q2…`'s working tree privately). `git.discard` on an open shared buffer is a CRDT edit → a `view` peer's discard fails, an `edit` peer's merges with concurrent typing.

Every remote/multiplayer property above is the degenerate application of peer machinery — no plugin contains an `if remote` branch.

---

## 8. Open questions and deliberate deferrals

**Critique fixes — adoption record.** All 13 findings are adopted. Two are adopted with a scoping nuance rather than rejected:
- **#6 (presence as generic layer):** adopted, but *sequenced* — presence collapses into an ordinary `scope=replicated` layer only *after* the grant-keyed replicated wire lands. Until then presence is the single sanctioned replicated feature, implemented against the same API that will generalize, and `scope=replicated` traps for everyone else [FIX 10] so no plugin ships a silent no-op. We do not keep `relayPresence`/`unionPresence` as a permanent primitive.
- **#13 (persistence):** adopted as a *minimal* `kv.*` cap, not a general database. It is locus-aware and per-plugin-namespaced; anything richer (indices, queries) stays a plugin over `kv` + `fs`.

No fix is rejected. The critique's cross-cutting insight — *the ABI must express identities (anchor/range/peer) as first-class values* — is elevated to a thesis-level principle and realized by [FIX 1] (`anchor`/`range` in `Value` + pool columns), [FIX 3] (motions return ranges), [FIX 7] (per-candidate locus), and [FIX 8] (`spawnPeer`/`asPeer`).

**Release-blocking invariant work (must precede the remote/multiplayer milestone).** Hole #1, Hole #2, grant-keying of capability sessions + replicated layers, and action-result re-attribution/clamping [FIX 2]. Until these land, remote providers and `scope=replicated` **trap** rather than silently degrade [FIX 10]. Multiplayer edit-safety is not "free" until the gate exists.

**Open questions.**
1. **Async range handles [FIX 3]:** the exact await/cancel semantics of a *pending* `range` (interactive `d/foo`, remote `d}`) — is it a future the operator blocks on, or does the operator itself become a resumable task? Recommend a resumable operator on the interaction's synchronous path, so cancellation is `vim.escape`.
2. **Virtual sub-buffers [FIX 11]:** whether a `SubResource` can host its *own* nested collaborators/loci (a remote code fence?) or is strictly parent-local. Recommend parent-local for v1.
3. **Shared REPL / shared prompt policy:** "one project REPL for all peers" vs "one per peer," and "whose input is the next form" — the CRDT merges text but cannot decide turn-taking. Core refuses to decide; config chooses (honest default: per-peer-local).
4. **`own` grade semantics:** administrative undo-of-others and grant delegation — the hook is parsed and "treated as edit" today; specify when needed.
5. **Globally-consistent shared agenda/index:** notes/backlink indexes are per-peer local projections; a team agenda spanning files no single peer has open needs either a designated indexer peer or a replicated index. Deferred; a shared agenda is just a note everyone edits.
6. **Conflict UX for [FIX 9] collisions:** how a load-time equal-priority collision is surfaced and resolved interactively.

**Deliberately deferred (simplicity bias).**
- **Matcher stays a plugin** — the pool + `u32[]` contract make going native a one-line `pick/matcher` registration whenever measurably needed.
- **No manifest index / cache; no plugin repository** — `.wasm`/JS files are already in place at startup; optimize startup later.
- **Full window-carving ABI** beyond region-read + minimal split.
- **Project-root memo** — the one "push native later if measurably slow" item: a host memo keyed by `(buf, tree-version-token)` to keep `project.root` O(1). Everything else stays plugin.
- **Capability-profile extensions** (code-actions/signature-help/inlay-hints) ship after profile v1.

**Carve verdict.** The catalog is thin because the core provides the right things: the CRDT inversion (concurrency), the Locus-in-handle (locality), the Principal with two boundaries (authority), the reconcile engine (mode), the append-only columnar pool with a bulk matcher seam (pick), and — after the critique — first-class stamped *identities* (anchor/range/peer) plus a per-candidate locus and a minimal persistence cap. With those, "an autonomous agent editing your remote Clojure project alongside a human collaborator at `edit` grade, through a project-scoped remote REPL, in vim, with vertico completion" is the degenerate application of machinery that already exists for peers — which is the whole point.