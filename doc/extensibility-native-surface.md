# weft Native Host ABI — Definitive Specification

The complete WIT-world-shaped surface the native host exposes to guest plugins. One runtime (wasmtime); JS/TS run via shipped `quickjs.wasm` against the *same* ABI. Everything below is a host import unless marked as a guest export.

## 0. Cross-cutting rules (true of every function)

- **LOCUS is carried in handles, never passed per-call.** A guest opens a URI (or, far more often, uses a locus-inheriting wrapper) and thereafter holds an opaque `resource` handle with the locus baked in. The guest *cannot* pass a wrong locus. Host dispatch reads `resource.locus`, switches on `Tier {here, peer, shell}`, and routes. The only place a guest names a locus is `loci.resolve(uri)` when it deliberately wants a host *other than the buffer it is editing*.
- **GRANT is implicit in the invoking Principal, never a parameter.** A guest cannot name a principal or a grade, so it cannot spoof or escalate. Effective power = `host_caps(granted at load)` × `min(owner_grant(doc), manifest_grant)`. Two boundaries, one Principal, one approval dialog. `caps` gate authority *out* of the sandbox; `grant` gates authority *into* replicated document state; they divide exactly at the CRDT line.
- **PLANE is a declared parameter only where density/authority genuinely varies** (`layers.Scope {local|host|replicated}`). For document text the plane is implicit-and-singular (the only text API is the CRDT one); for local UI it is implicit-and-local (no wire method exists).
- **VERSION stamping is core-enforced end to end.** No bare offset crosses a public boundary without the version it is valid at. You rebase through the commit log (→ anchor or `null`); there is no third result.
- **Everything async degrades identically.** A non-`here` locus can never register `Latency.instant`; a dead locus/provider/slow disk all collapse to "the result never arrived." A plugin written to the async contract gets remote+multiplayer correctness for free.

Legend: **[E]** exists today · **[N]** new/planned · **⌖** carries a LOCUS · **⚿** carries/implies a GRANT or PLANE.

---

## 1. `core` — the ungated handshake surface (always present, zero authority)

Two required guest **exports**; everything else the guest does is through gated imports.

```
export describe() -> Manifest        [E-ish] runs with ALL caps gated OFF. Returns:
     { perms: HostCapSet,            // fs.read, fs.write, net, proc, timer, …
       grant_max: Grade,             // most it will ever want on a doc (view<edit<own)
       commands:  [CommandDecl],     // names it provides (late-bound)
       capabilities:[ProviderDecl],  // cap providers it will register (kind+placement+predicate)
       activations:[ActivationDecl], // predicate→contribution declarations (§7)
       deps, activation_events }
export init()      -> void           [N]    runs AFTER user approves; grants flipped on.
```

Handshake: `describe()` (no authority) → host reads manifest → user approves → grants flip on → `init()`. **Runtime registrations are cross-checked against the manifest; using an ungranted capability traps.** Runtime escalation prompts are possible. No manifest index/cache yet (deferrable). No plugin repository yet — `.wasm`/JS files are already in place at startup.

Host imports available ungated:

```
log(level, msg)                                       [N] structured log to host
inspect() / active_layers() -> [name]                 [N] derived introspection, no state stored
now() -> ns                                           [E] injectable clock (Caps.now / task.nowNs)
```

---

## 2. `document` — CRDT text & editing  ⚿(grant, implicit) ⌖(via buffer's locus)

The **only** text-mutation surface, and it is the CRDT one — you cannot make a "local document" or a "local insert." Every mutator is a peer; "buffer changed under me" is inexpressible.

```
snapshot(buf) -> Version                    [E] immutable versioned read handle
readRange(buf, ver, off, len) -> bytes      [E] read against a stamped version
edit(range@ver, bytes) -> Commit            [E core; ⚿ NEW gate] insert/delete/replace.
      // Routes to ctx.principal's peer (peerInsert/peerCommit); author=principal, NOT .user.
      // Checks grantOf(principal).canEdit() → error.Unauthorized (closes Hole #1 & #2).
commit(range@ver, bytes) -> Commit          [E] explicit multi-op batch, same gate
addAnchor(pos@ver) -> Anchor                [E] PLANE=local (per-replica auto-shift bookkeeping)
exportAnchor(pos@ver) -> PortableAnchor     [E] PLANE=replicated (resolvable on any replica)
resolve(anchor, ver) -> ?pos                [E] rebase; null if unrebasable — no third option
undo(peer_scope) -> Commit                  [E] per-peer SELECTIVE undo (op inverse, keyed PeerId).
      // own peer freely; others require `own` grade (reserved hook, deferred).
version(buf) -> Version                      [E]
```

`Principal = {agent (CRDT authorship), owner (24-byte fingerprint, accountability), role {user|plugin|agent|remote}, caps, grant(doc)}`. One fingerprint backs many agents (your user peer, your `plugin.fmt` peer, your `agent.claude` peer). A remote human and a local agent are the same object differing only in placement + whether `owner` came off the wire. **[N] `command.Context` gains `principal: *Principal`** — implicit, never caller-supplied.

---

## 3. `buffers` — open set, backing, windows/regions  ⌖(backing tier)

```
openUri(uri) -> Buffer          [N] ⌖ picks backing by tier: here→file, shell→shell, peer→session.Collab
open(path) -> Buffer            [E] via ctx.here_locus (inherits active buffer's locus, §5)
active() -> Buffer              [E]
list() -> [Buffer]             [E]
switchTo(buf)                   [E] saves/restores modal mode + active_layers
backing(buf) -> {kind: none|file|shell|tool, locus}   [E] ⌖
save(buf) -> Task               [E] fallible poll task (may never complete = degrade path)
tag(buf, name, on)              [N] resource tag → triggers mode reconcile (§7)
```

**Windows/regions [E]** (`gfx`): carve rects via the region tree; never offset-math. One-layout model; layout maps offset↔geometry. Region ops are local render surface per peer; remote cursors arrive via `session` presence union. (Full window ABI can be **deferred** — plugins rarely carve the frame; expose region read + a minimal split first.)

---

## 4. `command` + `keymap` — late-binding registry & layered input  (local plane, implicit)

Late binding is load-bearing: names resolve at CALL time, so config can reference commands a plugin defines later, and anything can shadow a built-in by rebinding.

```
// commands
register(name, handler)         [E] namespaced plugin.<name>/…; auto-teardown by prefix
run(name, args) -> Value        [E] typed Value ABI: nil|bool|int|number|string.
      // NOTE: builtin editors route through ctx.edit()→principal's peer, never ctx.document().insert
call(name, args) -> Value       [E] resolve-at-call-time (shadowing, forward refs)

// keymap — TWO orthogonal axes, never merged
bind(layer_or_mode, key, cmd)   [E] modal axis (normal/insert/visual) OR language layer (§7)
setFallback(mode, parent)       [E] fallback chains
lookupLayered(key, layers)->cmd [N] modal mode+chain first, THEN buffer language layers, then null
textCommand(mode, cmd)          [E] per-mode text-input command (pick mode → pick-input)
menuMode(spec) / whichKey(spec) [E] menu / which-key modes
```

Keymap/modal state is per-peer local by construction (no wire on `Keymap`). The **language axis** (what `=` does in a nix buffer) is a *buffer-scoped layer list*, most-specific-first, contributed by activations (§7) — the one genuine keymap gap, closed by `lookupLayered` + per-buffer `active_layers`.

---

## 5. `capability` — providers, race sessions, profile  ⌖(placement+locus) ⚿(read-free, write-gated)

The composition heart. Consumers FIRE sessions = races over all matching providers; results land incrementally with provider identity + latency; a dead provider degrades, never hangs.

```
register(spec: ProviderSpec)              [E] ⌖⚿ local-only act; id-namespaced plugin.<n>/<cap>
     ProviderSpec = { name, id, latency: instant|fast|slow, priority,
                      placement: local|host,              [E]
                      locus: Locus = .here,               [N] ⌖ host@peer = remote weft services it
                      predicate: Predicate }              [N] generalizes `extensions` suffix match
registerFeed(name, scope, provider)       [E] ⚿ PLANE param: local|host|replicated
fire(kind, doc, path, opts) -> ?session   [E] ⌖ read-only vs snapshot; NO grant needed to fire.
      // remote providers = forwarded sessions clamped to ≥ .fast; results land by session id
poll(session) / best(session)             [E] request/response vs snapshot version
mergedCompletion(session)                 [E] merge-ranked composition
     // Composition: merge-ranked | union | first-wins
push(session, payload)                    [E] host deep-copies + RE-STAMPS version (restamp)
```

**Shapes:** *query* (request/response or snapshot-version — pure read, renders in local UI), *feed* (continuous version-stamped annotations into a provider-owned named layer), *action* (returns a Replacement batch vs a stated version, applied through the ordinary edit path → hits the §2 grant gate for free → merges like a peer).

**Read/write asymmetry is structural:** a `view` peer may *fire* format (compute the diff) but the *apply* fails `canEdit()`. Zero action-specific permission code.

**Profile v1 [E]:** completion, hover, definition, references, diagnostics, highlight, format, rename, symbols-document.
**Extensions [N]:** code-actions, signature-help, inlay-hints — inherit base readiness; **must add grant-keying** (see Footgun/holes).

**GRANT GAP to close:** capability sessions and `replicated` layers are not yet keyed to `secure` peer grants. Fix at substrate before any *remote/shared* provider is trusted per-peer.

---

## 6. `layers` — feed substrate: virtual text, gutter, faces  ⚿(scope param)

```
claim(doc, name, scope, provider)         [E] scope: local|host|replicated — the PLANE param
publishSpans(layer, [anchored_span])      [E] sparse anchored spans; checks "am I this layer's owner"
publishBulk(layer, per_byte_paint)        [E] dense per-byte bulk paint
```

Feeds are droppable + provider-owned (last-writer-wins) → **not** gated by the document edit grant; gated only by "am I an admitted peer and do I own this layer name." A `view` peer legitimately publishes its own presence (a replicated feed). A rogue annotation is low-harm and self-correcting.

**[N] richer decoration atop layers:** virtual/overlay text, gutter marks, richer face attributes (foldable/invisible/clickable). These ride `layers.Scope` and inherit its locus/grant story — no new plane.

**Presence [E]** is the one deliberate local→replicated bridge — a *named, dedicated* path (`relayPresence`/`unionPresence`, presence layer at base+1), never a general "local layer that happens to sync."

---

## 7. `activate` — mode = orthogonal contributions, no join  (per-peer local)

There is no `nix-mode` object. A buffer has *facts* (`Resource`); independently-predicated *contributions* each match and stack. The one new primitive:

```
activate(predicate, contribution) -> activation_id   [N]  the whole mode model
tag(name|buf, on)                                     [N]  set resource tag → reconcile trigger
fact(name) -> value                                   [N]  priority-resolved over active set; never stored
active_layers() / describe_mode() -> [name]           [N]  DERIVED view, nothing stored as "the mode"
grammar_add(ext, dir, symbol)                         [E]  data (already a command)
```

`Resource = {locus {local|remote|tool|none}, host?, path?, name, first_line (bounded sniff), tags, size}` — `Resource.of(buffer)`, recomputed per buffer per replica, `locus` first-class so predicates gate on where bytes live.
`Predicate` (host-evaluated data, O(contributions), no guest callback): `{ext}|{shebang}|{glob}|{regex (bounded to first_line)}|{locus}|{tag}` + `all|any|not`. Generalizes `Provider.extensions`; one matcher shared by capability fire, keymap-layer activation, fact resolution.
`Contribution =` `{keymap_layer}` | `{grammar}` (first-wins by priority — the only genuinely singular one) | `{capability: ProviderSpec}` | `{facts: {...}}` | `{on_activate,on_deactivate}` (escape hatch, discouraged).

**Reconcile engine [N] (replaces the imperative `attachProviders`):** core keeps per buffer `active = {a : a.predicate matches Resource.of(buf)}`; on any fact change it *diffs* (React-style), activating want\have and deactivating have\want with the **same** contribution. Triggers: open, rename/save-as, save (shebang appears), tag change, locus change (reconnect), **plugin load** (retroactively applies to open buffers — no reopen ritual, order cannot matter because result depends only on the final declaration set). Every activation reversible by construction.

**Remote/multiplayer free:** grammar activates locally (every peer holds the replica); LSP predicate includes `locus=local` so it activates only where files are real, and remote viewers *consume* results via `placement=host`. Mode is per-peer, never replicated; what crosses is chosen per contribution via `layers.Scope`.

---

## 8. `pick` — candidate/pool seam & the guest matcher  ⌖(pool locus) ⚿(scope, default local)

Append-only columnar pool is the single native primitive; append-only makes "the set changed under the matcher" inexpressible (same inversion as the CRDT).

```
// native/source side
open(spec) / openWith(source)             [E] pick loop stays native (pick.tick)
Pool.appendBatch(blob, spans, meta)       [N] ⌖ sources ALWAYS batch, NEVER one item across boundary
     Pool = {blob, spans, docs, meta{source_id,key}, version, generation, locus, scope=.local}
refresh() / queryChanged()                [E] bumps generation for regenerate sources (grep)

// guest matcher: capability `pick/matcher` (first-wins; absent → built-in refilter). Additive.
import weft_pool_push(pool, blob*,len, spans*, meta*, n) -> i32   [N] JS-side source contributes bulk
import weft_pool_stat(pool) -> u64                                [N] {version,count} staleness poll
export match_reserve(n_spans, n_blob) -> {blob_ptr, spans_ptr}    [N] guest sizes its mirror
export match_rank(count, query*, out*, out_cap) -> n              [N] ONE call/keystroke → ranked u32[]
```

**Boundary budget:** source→pool native only; pool→matcher mirror = one bulk memcpy of the delta when `version` advances; matcher→host = one bulk call/keystroke returning `u32[]`. The bright line (host invoking guest N=full-candidate-set times) is never crossed — the guest scans its own mirror once.

**Emacs-lineage features (bright line respected):** *vertico* = native view rendering the ranked array (restyle paints only ~30 visible rows). *marginalia* = capability `pick/annotate` fired only over the visible index window (bounded N). *cape* = many sources, one pool, distinct `source_id`. *embark* = accepted `Meta{source_id,key}` resolves the real target on `locus` and dispatches via the capability `action` shape → ordinary edit path → merges like a peer.

**Remote/multiplayer free:** `Pool.locus` stamped once (remote source ships byte batches over `ShellFs`/subprocess, no per-candidate RPC); `Pool.scope=.local` (your palette is not my palette) — what's shared is only the *consequence* of accepting (a versioned edit the CRDT merges). Going native later = register the built-in as the `pick/matcher` provider; one-line swap.

---

## 9. `async` + `timer` — event loop & clocks  (local, [N])

```
spawn(task_fn) -> Task            [N] guest-driven task on the pool
timer(ns, sink) -> Timer          [N] debounce/animation
clock() -> ns                     [E] Caps.now / task.nowNs already injectable
cancel(task|timer)                [N]
```

Born locus-blind; local only. (This is the smallest gated cap; safe to ship early.)

---

## 10. `proc` — subprocess  ⌖(locus at spawn) ⚿(cap: proc)  [N]

```
spawn(argv, opts) -> Proc         [N] ⌖ here→std.process; peer→forward; shell→run in serial channel
spawnHere(argv) -> Proc           [N] ⌖ inherits ctx.here_locus (the correct default)
stdio(proc) / write / kill        [N] off-thread; feeds pool sources (ripgrep/formatters/repls)
```

`locus` MUST be taken at spawn or remote gets bolted on. On `shell` tier, argv runs through the one serial shell channel.

---

## 11. `net` — TCP + TLS  ⌖(dials FROM the locus) ⚿(cap: net)  [N]

```
connect(addr) -> Sock             [N] ⌖ socket opened FROM `at` — R4: dials from the peer's vantage.
                                      // the locus IS the tunnel; reach a DB visible only inside a host, zero SSH config
listen / send / recv / close      [N]
```

Shape like wasi-sockets / wasi-http so guest stdlibs light up unmodified. TLS is native (carve rule b — one impl for safety).

---

## 12. `fs` — read / stat / list / watch / guarded write  ⌖(locus in handle) ⚿(cap: fs.read/fs.write)

Unifies today's `std.Io.Dir`, `ShellFs`, and the planned stat/watch gap into one tier-switched surface. `fs_source`'s Local/Remote finders collapse into one `Finder(loci, at, root)`.

```
open(path, flags) -> Resource                     [E core] ⌖
readAll(path) -> bytes                             [E] ⌖ ShellFs.readAll ∪ here
readRange(path, off, len) -> bytes                 [E] ⌖
stat(path) -> Stat                                 [N] ⌖ planned gap
list(path) -> Listing                              [E] ⌖ ShellFs.list / LocalDir
watch(path, sink) -> Watch                         [N] ⌖ inotify (here) / peer forwards / shell polls hashToken
hashToken(path) -> token                           [E] ⌖ sha256 for here; change-detection
writeGuarded(path, bytes, expect_token) -> token   [E] ⚿ test-and-set; error.Stale → merge-and-retry
```

Guarded write makes a concurrent remote writer a merge, not corruption. `openSibling(name)` / `spawnHere` / `lspHere` convenience wrappers inherit `ctx.here_locus` — the accidental default is the correct default; hardcoding `weft://here/…` reads as a review smell.

---

## 13. `syntax` — tree-sitter tree queries  (local compute, tree stays host-side)  [N]

Today only `HighlightClass` bytes cross the ABI into a bulk layer; the tree is NOT exposed. Planned:

```
nodeAtOffset(buf, off@ver) -> NodeRef        [N] version-stamped
parent / children / siblings(node) -> …      [N] navigation, host-side tree
query(buf, ver, query_src) -> [Capture]      [N] captures cross the ABI; the tree does not
highlightClasses(buf, ver) -> bulk layer     [E]
```

Local pure compute over a local tree; feeds `layers` (which carry scope). Node handles are version-stamped like everything else.

---

## 14. `lsp` — LSP client  ⌖(locus before argv) ⚿(deferred to cap gate)

```
create(loci, at, argv, path, doc, environ) -> Lsp   [E core; ⌖ NEW] 
     // peer tier: LSP runs on the peer next to the code it indexes (servers want local disk);
     // results forward as capability pushes. shell tier: spawned via the shell channel.
```

Backs the `edit/*` capability providers; nothing else in the fire/session/compose path changes — a remote LSP is just a provider that answers later.

---

## 15. `locus` — the locality primitive  ([N], `src/core/locus.zig`)

Rarely touched by guests directly (inheritance §5 handles the common case); present for deliberate cross-host reach.

```
resolve(uri_authority) -> Locus        [N] dial/attach lazily; idempotent per authority
attachPeer(conn) -> Locus              [N] promote authenticated weft connection
attachShell(fs) -> Locus               [N] promote persistent coreutils shell
tier(l) -> {here|peer|shell}           [N]
liveness(l) -> {connecting|connected|degraded|offline}   [N] == session.Liveness
fingerprint(l) -> ?[24]u8              [N] peer identity (relocation-proof)
label(l) -> str                        [N] for the view
```

URI grammar: `weft://<authority>/<kind>/<ref>`, authority ∈ `here | <fingerprint> | <alias> | shell:<id>`, kind ∈ `file|dir|proc|lsp|sock|buf`. **R1:** a path is meaningless without its locus. **R2:** the fingerprint is identity, the address is a hint (`Conn.rebind` re-points without changing the `Locus` value or any Resource built on it).

`command.Context` gains `loci: *Loci` and `here_locus: Locus` (the active buffer's backing locus — the ambient "cwd host"). Reuses as-is: `session.Conn/Collab/Liveness`, `hub`, `identity`/`known_peers`, `ShellFs`, `backing.Sync`, `capability.fire`. No new transport, trust, or sync mechanism.

---

## 16. `identity` / `secure` — authority administration  ⚿(grade param, keyed by fingerprint)

Not a plugin's daily surface, but part of the host ABI for agent/collab tooling.

```
setPeerAccess(fingerprint, grade)   [E] Hub.overrides; keyed by identity, live-updatable ⚿
forget(fingerprint)                 [E] severs links AND grant simultaneously (one accountability root)
liveness / presence                 [E] union relay
```

`grant(plugin, doc) = min(owner_grant(doc), manifest_max_grant)` — authority flows down from the human who ran the plugin, never up. Enforced authoritatively where an untrusted peer's ops enter (`handleFrame`), advisorily at origin so honest peers stay truthful (`peerCommit`/hot path).

---

## FOOTGUN LIST — what the host REFUSES to expose, and which invariant it protects

| Refused | Why it would break an invariant |
|---|---|
| **A bare offset/position crossing any public boundary without its version** | Positions are version-stamped anchors; a bare offset silently breaks under concurrent edits. You rebase → anchor or `null`. Protects the CRDT-peer inversion. |
| **A bare path that silently means the local FS** | R1: a path is meaningless without its locus. A local-default path re-bolts remoteness on (TRAMP's sin). Protects invariant 1 (remote not second-class). |
| **A locus argument on effect calls** | The guest could pass the wrong one. Locus rides *inside* the resource handle so the guest literally cannot mis-target. Protects invariant 1. |
| **"Local document" / "local insert"** | The only text API is the CRDT one, which always logs a syncing `Commit`. Makes "keep a shared edit local" inexpressible. Protects invariant 2. |
| **A grant/grade/principal parameter on edit calls** | A plugin could then name a principal it isn't, laundering attribution (Hole #2) or escalating. Grant is implicit in `ctx.principal`. Protects authority model + selective undo. |
| **"Act as the user" for plugins** | Collapses attribution → breaks per-peer selective undo and the honest commit log. A plugin acts as *itself*, bounded by its owner's grant. |
| **A per-candidate guest callback over the full candidate set** | The bright line. N = full set invoked by the host = death by boundary crossings. Only bulk pool + one `match_rank`/keystroke, or callbacks bounded by visible/selected rows (marginalia ~30, preview 1). Protects the plugin-matcher perf carve. |
| **`set cursor` / broadcast-able local UI** | Cursor/selection/pick/echo/keymap live in modules with *no wire method*. Broadcasting requires the dedicated presence path on purpose. Prevents accidental leakage of local UI state. |
| **A general per-buffer key/value variable bag (emacs `make-local-variable`)** | Order-dependent, invisible, drifts. Replaced by derived facts + tags + active-set. Protects mode-model determinism (result depends only on final declaration set). |
| **One-way activation hooks (add-only mode hooks)** | Emacs's core defect. Every contribution is reversible by construction via reconcile diff. Prevents load-order fragility. |
| **A singular replicated "major mode"** | Two peers legitimately run different grammars/keymaps/LSPs on one buffer. Mode is per-peer local. Protects invariant 2. |
| **The tree-sitter tree object across the ABI** | Only captures/nav results cross; the tree stays host-side (one impl, perf, lifetime safety). Carve rule (b). |
| **A synchronous-infallible fs/proc/net call** | Would be wrong for local slow disk before you ever go remote. Everything is async/fallible so remote degrades exactly like a dead provider (R5). Protects invariant 3. |
| **Ambient authority of any kind** | A plugin touches the world only through gated capability imports; ungranted use traps. The privilege boundary between config and plugin is dissolved (config is a plugin with no special powers). |
| **General expression language in predicates** | Predicate eval must stay host-side O(contributions) data (suffix/glob/bounded-regex/tag). Arbitrary logic → the discouraged `on_activate` hook, and that friction signals a bad slice. |

---

## DEFERRABLE (simplicity bias — build later)

- Manifest index / caching; plugin repository (files are already in place at startup).
- Full window-carving ABI beyond region-read + minimal split.
- `own` grade semantics (administrative undo-of-others, grant delegation) — hook parsed, "treated as edit" today; leave until needed.
- `layers.Scope` wire fan-out — the param exists at the API now so plugins declare correctly and get replicated behavior for free when the wire lands.
- Moving the matcher native — the pool + `u32[]` contract make it a one-line provider registration whenever measurably needed.
- Capability-profile extensions (code-actions/signature-help/inlay-hints) — ship profile v1 first.

## MUST-FIX HOLES the ABI depends on (current code)

- **Hole #1:** `Document.peerCommit` and the `.user` hot path are ungated → ghost edits on `view` clients. Add `grantOf(author).canEdit()`.
- **Hole #2:** `command.Context` has no principal → plugins launder edits as `.user` via `run("insert-text")`. Add `Context.principal` + `Context.edit()`; builtins must never call `ctx.document().insert` directly.
- **Grant-keying gap:** capability sessions and `replicated` layers not yet keyed to `secure` peer grants — close before any remote/shared provider is trusted per-peer.