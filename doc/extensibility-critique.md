# Adversarial critique — weft extension design

Ranked most-severe first. Each: **claim → concrete failure → fix.**

---

## 1. The `Value` ABI has no `anchor`/`range` type — so positions cross boundaries through *side-channels*, which is the exact anti-pattern the design claims to forbid

**Claim.** `command` Value ABI is `nil|bool|int|number|string`. The footgun list bans "a bare offset crossing a boundary" — correct — but the *sanctioned* thing that may cross is a version-stamped **Anchor**, and the ABI provides no way to return one. An Anchor exists only as a `document` resource handle, never as a `Value` or a pool column. This single omission forces two independent domains into ugly workarounds that reintroduce mutable global state:

- **vim/operators**: a motion "cannot return a range" (Value ABI), so it *mutates the shared Editor cursor as a side effect* and the operator reads it back after `command.call`. That is emacs-style action-at-a-distance through global mutable state — precisely what §"Design goal" says to avoid.
- **pick/cape/consult**: `meta.key` is `u32`, "too small to carry a version-stamped anchor," so **every** position-referencing source (`cape`, `consult.line/grep/imenu/mark`, `nav`, `notes.agenda`) must hand-maintain a `key → PortableAnchor` side-table. Both domain authors independently flagged this as "the one place the seam costs the author a discipline." They are the *same* root cause.

**Failure scenario.** An author lazily stuffs a line number into `meta.key`; a collaborator edits above; accept jumps to the wrong line — silently, no `null`. The footgun the design says is "impossible" is in fact one lazy cast away, in five plugins.

**Fix.** Add opaque handle types to the Value ABI: `anchor` and `range` (each a version-stamped resource handle, not an offset). Then `motion.word-fwd` *returns* a `range`; the operator needs no cursor read-back and no shared-cursor side-channel; `Pool` carries an `anchor` column instead of `u32 key` + side-table. This collapses two domains' worst friction into one core addition and makes the anti-corruption guarantee structural instead of disciplinary.

---

## 2. Multiplayer edit-safety does not exist in the shipping artifact, and the read/write asymmetry is a *content-laundering* vector, not a feature

**Claim.** Every domain asserts "a `view` peer's write fails `canEdit()` for free" as the load-bearing multiplayer story. But the MUST-FIX list admits **Hole #1** (`peerCommit`/`.user` hot path ungated), **Hole #2** (no `ctx.principal`, so plugins launder edits as `.user`), and the **grant-keying gap** are all *open in current code*. So right now Invariant 2 is simply false: there is no gate. The "free" grant-correctness that six domains lean on is aspirational.

Worse, the **read/write asymmetry is actively dangerous** once you combine "fire is grant-free" with remote `action` providers. `capability.fire("edit/format" | "edit/rename" | "edit/code-actions")` against a `placement=host` provider on an *untrusted* peer returns a Replacement batch; the local user applies it through `ctx.edit()` **as themselves, under their own grant**. A malicious host provider returns a diff that inserts a backdoor; it lands as the victim's authored, signed, selectively-undoable commit. The design frames the unkeyed feed/session gap as "low harm, droppable, self-correcting" — that is true for *presentation* feeds and false for *action* results the victim re-authors.

**Failure scenario.** I edit a shared repo with an `edit`-grade collaborator whose weft is the format authority (`{locus=local}` on their side). I hit `gq`/`format-buffer`. Their provider returns a batch that edits far outside the formatted region. `fmt` applies it via `ctx.edit()`. My commit log now shows *me* authoring their payload.

**Fix.** (a) Close #1/#2/grant-keying *before* any remote provider is enabled — treat them as release-blocking invariant work, not "friction." (b) An applied `action` result must be re-attributed to (or co-signed by) the *provider's* principal, not the firing user, and clamped to the range the consumer fired against; a batch touching bytes outside the fired range must trap. "Fire is free" must not imply "apply is trusted."

---

## 3. Motion→operator composition breaks on async / interactive / remote motions

**Claim.** The operator mechanism is `a = cursor@snap; command.call(motion); b = cursor@snap; edit(a..b)`. This assumes `command.call` is synchronous and that the motion has fully moved the cursor by the time it returns. But `run/call -> Value` is a scalar sync return, while the world is async (§0: "everything degrades to *the result never arrived*").

**Failure scenario.** `d/foo<CR>` (delete to next search match) and `d}` where `}` on a remote buffer must read bytes over a `peer` locus. `motion.search-fwd` is *interactive* (reads a query line) and `motion` over remote content is *async*. `command.call("motion.search-fwd")` cannot synchronously leave the new caret in place, so the operator samples `b == a` and deletes nothing — a core vim feature silently no-ops. This is the same shared-mutable-cursor smell as #1: the range is smuggled through global state that isn't ready yet.

**Fix.** Fold into #1: motions/textobjects *return* a `range` value (possibly a pending/async range handle the operator awaits), instead of mutating a shared cursor the operator races to read. This also makes the operator work identically for `here`/`peer`/`shell` motions — currently remote motion composition is accidental, not designed.

---

## 4. `here_locus` is an ambient, mutable "cwd host" — it re-bolts on the exact ambient locality the handle-in-resource design killed

**Claim.** §0 makes locus explicit-in-handle so "the guest cannot pass a wrong locus." Then §5/§12 reintroduce `ctx.here_locus = active buffer's backing locus` as the ambient default for `open(relative)`, `spawnHere`, `lspHere`. This is a global mutable variable (it changes every time `active()` changes) read implicitly by effectful calls. That is ambient authority with a friendly name.

**Failure scenario.** `agent-core` starts a session defaulting `locus = ctx.here_locus`. During the (slow, async) turn the human switches to a buffer on a different host. `agent.tool.grep {root?}` with no root re-reads `here_locus` → ripgrep spawns on the *wrong peer*, greps the wrong tree, and the agent reasons over foreign code. Same bug hits `format-on-save` timers and any `async.spawn`ed task that outlives the active-buffer selection. The design's own footgun table bans ambient authority, then ships it as the "correct default."

**Fix.** `here_locus` must be *captured* into a Context/session at creation, never re-read ambiently by background work. Make `spawnHere`/`openSibling` take the captured locus from the invoking `Context` snapshot, and forbid reading `active()`-derived locus from any task not on the interaction's synchronous path.

---

## 5. Keymap: vim policy is smuggled into core (`switchTo` persists "modal mode"; `lookupLayered` hardcodes modal-beats-language)

**Claim (this is the matcher test-case, for keymap).** Two leaks:
- `buffers.switchTo` "saves/restores **modal mode** + active_layers." *Modal mode* (normal/insert/visual) is a `vim`-plugin concept. Core has baked in the notion that every buffer has a singular "modal mode" that persists across switches. A non-modal (emacs-style) or structural-mode config has no such thing; core is privileging one paradigm.
- `lookupLayered` resolves "modal mode+chain first, THEN buffer language layers." That fixed precedence is policy. It directly breaks the design's own example: vim binds `=` in normal mode (reindent), and `mode.nix` binds language-layer `=`→`format-buffer`. Modal-first means the nix `=` never fires. The two axes the design calls "orthogonal, never merged" are (a) merged into one `bind(layer_or_mode, …)` parameter and (b) ordered by a core-hardcoded rule.

**Failure scenario.** User loads `mode.nix` expecting `=` to format; gets vim reindent forever, with no diagnostic, because precedence is core policy not declared data.

**Fix.** Core keymap should store *opaque, plugin-named* per-buffer state slots (vim stores its mode there; core doesn't know what "modal mode" is). Precedence between layers must be a *declared* order (a priority on each contributed `keymap_layer`), not a hardwired modal>language rule. Per your own MEMORY note: "mechanism in core, policy in std plugin/config; declare, don't infer."

---

## 6. Presence is a bespoke core wire for local UI — a premature special-case that should be a grant-keyed replicated layer

**Claim.** `hub.relayPresence`/`unionPresence` + "presence layer at base+1" is a dedicated hardcoded channel for one feature (cursors). The footgun table proudly refuses "broadcast-able local UI," yet presence *is* local UI (cursor/selection) given a private core wire. The stated justification — "replicated layers aren't grant-keyed yet" — means presence is a **workaround for an unfinished substrate, promoted to permanent core primitive.** Meanwhile `layers.Scope=replicated` exists as a parameter but "wire fan-out is deferred," i.e. today a plugin declaring `scope=replicated` gets *silent local behavior* — a lie (see #10).

**Failure scenario.** A plugin author wants to share fold state, or agent "thinking region" highlights, or collaborative annotations. They correctly reach for `layers.claim(scope=replicated)` — and it silently doesn't replicate. The only thing that actually crosses is cursors, via a different, closed API they can't reuse. Two things that should be one (replicated layer + presence) are two; and the general one is a no-op.

**Fix.** Make the generic path work: grant-key `layers.Scope=replicated` to `secure` peers, then presence becomes an ordinary plugin claiming a replicated layer with a well-known name. Delete the bespoke `relayPresence`/`unionPresence` special case. Until the wire works, `scope=replicated` should **trap**, not silently degrade.

---

## 7. `Pool.locus` is single-per-pool, but real sources are multi-host — marginalia and embark then target the wrong machine

**Claim.** §8: "`Pool.locus` stamped once." But `consult.line-multi` (lines across *all* buffers), `consult.buffer`, `embark.collect`, and `nav`/workspace-symbols legitimately contain candidates from `here` + multiple peers + shell in one pool. Locus is per-*pool*, so it cannot describe per-candidate locality. `marginalia` runs `fs.stat` "against `Pool.locus`," and `embark` "delete file" runs `fs.writeGuarded` on `Pool.locus`.

**Failure scenario.** `consult.buffer` lists a local buffer and a `weft://peerZ/…` buffer. Marginalia stats both against the pool's single locus → wrong-host stat for half the rows (blank/incorrect size/mtime). `embark.act → delete` on the remote row runs `writeGuarded` on the wrong host, or refuses. The design's "locus rides in the handle so you can't mis-target" guarantee is violated precisely for heterogeneous pools, which are common.

**Fix.** Locus must be per-candidate: either a `locus` column in the pool (cheap, one small int per row indexing a pool-local locus table) or per-`source_id`. `Pool.locus` as a scalar is a carve-at-the-wrong-granularity.

---

## 8. Sub-peer minting is missing — and it breaks more than the agents domain admits (repl tool-peer, repl output)

**Claim.** The agents domain flags `document.spawnPeer`/`ctx.asPeer` as "the one real gap." It undersells the breadth. **`repl-comint`** claims output is appended "as a `role=tool` peer via `peerCommit`," and `repl.core`/`project.repl` append output "as the `plugin.repl` peer." None of these are expressible: the ABI gives no way to mint a distinct authoring peer, and `document.edit` authors as `ctx.principal` (the plugin's single peer). So *today* every REPL's streamed output, every agent's edits, and the plugin's own edits collapse to one PeerId.

**Failure scenario.** Two agents (`claude#1`, `codex#2`) in one session → `agent.review.reject` can't separate them (one PeerId). REPL `repl/clear` = "undo the tool peer's commits" undoes the *user's* typing too, because tool and user share the plugin peer. Per-peer selective undo — the headline benefit of the inversion — is unavailable for exactly the multi-identity cases the design was built to serve.

**Fix.** Add `document.spawnPeer(name, grant_max) -> Peer` (owner = plugin's fingerprint, grant = `min(owner_grant, grant_max)` — no spoofing) and `ctx.asPeer(peer)`. Scope tool-dispatch/agent-turn/REPL-output inside the sub-peer's principal. This is a hard prerequisite for the REPL *and* agent domains, not an agent nicety.

---

## 9. "Order cannot matter" is asserted everywhere but is false — no tiebreak is defined for the many first-wins/priority mechanisms

**Claim.** The design repeatedly claims determinism: "result depends only on the final declaration set." Yet resolution is governed by *priority + registration order* in at least six places with **no defined tiebreak or conflict rule**:
- `command.register` — two plugins register `op.delete` / `motion.word-fwd`; "anything can shadow by rebinding" ⇒ last-writer-wins by *load order*, contradicting order-independence.
- `grammar` (first-wins by priority), `lsp/locate` (first-wins), `edit/format` (first-wins), `pick/matcher` (first-wins), `fact` ("priority-resolved") — all silent on equal-priority ties.

**Failure scenario.** Config shadows `op.delete` to also copy to OS clipboard. Whether it wins depends on whether config loads after `operators` — i.e. load order, the very thing "reconcile is a pure function of the final set" promised to eliminate. Two language plugins both claiming priority-90 grammar for `.ts` resolve nondeterministically.

**Fix.** Define one explicit conflict rule for *all* name/priority resolution: total order by `(priority, owner-fingerprint, id)` with ties an error surfaced at load, not silent. And distinguish "shadow" (explicit, declared intent) from "collision" (accidental, must warn). Determinism claims are only true once ties are total-ordered by something other than load order.

---

## 10. Speced-but-unimplemented params (`scope=replicated`, `ProviderSpec.locus`) silently no-op — violating both "no third result" and the simplicity bias

**Claim.** §5 `ProviderSpec.locus` [N] and §6 `layers.Scope=replicated` are exposed "so plugins declare correctly and get it free later," but the wire/impl is deferred. So a plugin declaring replicated behavior today gets *local* behavior with no error. §0 insists there is no third result — you get an anchor or `null`, connected or degraded. A no-op replicated scope is exactly the forbidden third result: neither replicated nor a failure.

This *also* violates "keep it simple / defer optimization." Shipping the parameter surface for machinery that doesn't exist is building forward-compat plumbing now — the opposite of the stated bias ("NO manifest index, NO repo, defer").

**Fix.** Don't expose a capability's parameter until its semantics exist; a declared-but-unimplemented `scope=replicated`/remote `locus` must **trap at register time**, not silently localize. Forward-compat via silent degradation is a latent correctness bug in every plugin that trusts the declaration.

---

## 11. Buffer is the wrong unit for language regions — nested sub-buffer languages have no home (confirmed carve failure)

**Claim.** Both `mode.html` and `mode.markdown` flag it: `Resource`/`Predicate`/activation are *whole-buffer*, so an embedded js/css region or a fenced code block gets *highlight* (local tree) but cannot activate a *range-scoped* LSP/formatter/keymap-layer. The core sliced at the buffer; language regions are sub-buffer. This is a genuine carve-at-joints failure, not deferral.

**Failure scenario.** Editing `<script>` in HTML or a `\`\`\`clojure` fence in a note: no completion, no format, no eval for the inner language — the persona explicitly wants html+embedded and markdown-with-code.

**Fix.** Introduce a range-scoped locus/resource — a "virtual sub-buffer" (an anchored range that carries its own `Resource` with its own language facts and its own `here`-relative locus). Predicates then match sub-buffer resources; capability `fire` and keymap layers scope to the range. This is a real new primitive the current model cannot fake.

---

## 12. `fs.watch` is planned, but four plugins rely on it for *correctness*, and its shell-tier fallback is O(files)

**Claim.** `lsp-locate`, `direnv`, `git`, `notes`, `project` all depend on `fs.watch`; today they degrade to manual refresh or `hashToken` polling. On `shell` tier, `watch` "polls `hashToken`" — that is per-path sha256 polling. For a `notes` vault or a repo tree that is O(files) hashing per interval.

**Failure scenario.** Remote notes vault of thousands of `.md` over a `shell` locus: agenda/backlink freshness requires polling every file's hashToken — a per-tick storm over the serial shell channel. "Remote is the degenerate case" becomes "remote is quadratically slower," making the primitive a burden (Invariant 3).

**Fix.** Ship `watch` with a *tree/recursive* watch handle (one inotify watch per dir, one shell-side `find -newer`/inotifywait bridge) rather than per-path polling, before the notes/git domains are considered viable remotely. Until then, cap watch to change-token on a *directory*, not N files.

---

## 13. The matcher is clean, but persistent selection history (frecency) has no home — the "zero-authority" claim is only true by dropping state emacs keeps

**Claim.** `sel.match` is `perms:{}` — genuinely the cleanest plugin, good. But frecency "lives in the guest mirror," which is dropped with the pool and lost on restart. To persist/sync it, the matcher needs `fs.write` (losing zero-authority) or a host store that doesn't exist.

**Failure scenario.** Every restart resets ranking history; the stack is strictly worse than the vertico/prescient lineage it emulates. The "cleanest plugin in the stack" is clean only because it silently drops a feature the persona expects.

**Fix.** Either accept frecency is `fs.write` (and stop advertising the matcher as the zero-authority exemplar), or add a small host-provided per-plugin key-value *persistence* cap (locus-aware, so a peer's frecency stays with the peer). Note this is a *new* primitive the whole catalog implicitly wants (recent-files ring, kill-ring across restarts, project recents in `project.forget`) and none has — several plugins quietly assume durable local state that the ABI never grants.

---

### Cross-cutting note
Three of the top four findings (#1, #3, and the pool half of #7/#8) share one root: **the ABI can express *bytes* and *scalars* crossing the boundary, but not *identities* (anchors, ranges, peers) as first-class values.** The design correctly banned bare offsets — then failed to provide the stamped-identity types that were supposed to replace them, so every domain reinvents them as mutable side-channels and side-tables. Adding `anchor`/`range` to the Value+Pool surface and `spawnPeer`/`asPeer` to the document surface would dissolve more friction than any other change, and would make the remote+multiplayer-for-free promise actually structural rather than disciplinary.