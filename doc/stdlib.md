# The standard library: plugins that compose into an editor, or into something else

Status: PLAN (2026-09-03), rewritten after an adversarial review refuted most of
its first draft. What the first draft got wrong is recorded here rather than
deleted, because the wrong turns are the load-bearing part of the finding.

Forcing statement (user): *"we want to ship a rich but decomplected set of
plugins that compose cleanly to an extensible editor through plugin-defined
interfaces. The plugins we ship are in a sense the standard library — so it's
really really important that it's decomplected properly. We need a functioning
editor, where all the bits can be reused without much fanfare, to make something
that isn't an editor at all. Like, I should be able to cobble together an IRC
client and get my vim bindings for free, despite none of these pieces knowing
about each other, especially not core."*

## 0. The verdict

**"Vim bindings for free" already ships. It is one line.**

    pub fn installMode(mode: []const u8, visit_cmd: []const u8) void {
        weft.setFallback(mode, "normal");   // ← vim bindings, free
    // plugin_lib/output/root.zig:46

Every `run`/`make`/`grep` buffer already inherits vim's entire normal-mode
table, by keymap fallback, with no subject and nothing from this plan. `git`
deliberately does **not** — `restingMode("git")` with no fallback
(`git/root.zig:350`), rebinding `j`/`k` to fold-aware moves. Two shipped tool
surfaces, opposite answers, decided by whether the author typed one line.

So the acceptance test as originally posed is **non-discriminating**: it passes
on day zero. That is a good result — the composition property the forcing
statement asks for is real and already works — but it means IRC cannot be used
to falsify anything, and a plan justified by it is a plan justified by nothing.

**The blockers are DOORS and one real bug, not extractions.** Nothing in the
standard library needs extracting yet; two things need deleting, five doors need
opening, and undo through a projection is broken today.

**A better acceptance test: the debugger.** It is half-built already
(`plugins/debug` 87 lines, `config/plugins/dap.js` 223), it is irreducibly
*multi-surface* (source + stack + variables + watch + REPL, live at once), and
every way it fails is individually diagnostic. Multi-surface is the axis IRC
lacks and the axis the interfaces are silent on.

## 1. What the acceptance test found

The IRC client was designed in full against the real guest API. Every
requirement was traced to a door or to its absence.

**Works today, unchanged:** the channel list (the projection membrane, with
per-row keys, roles and verbs); `/`-command routing (`plugin_lib/invoke`);
asking for a line (`plugin_lib/prompt`); connecting (`weft.netConnect`, native
TLS); **and vim motions over the message log**, because a projection *is* a real
buffer with a real cursor and a tool mode falls through to `normal`.

**Fatally missing:**

1. **A guest cannot read a socket.** The doors are connect/send/close
   (`externs.zig:244-246`); the reader thread appends bytes into a host buffer
   (`net_session.zig:120-148`) and the guest never sees one. There is no
   `wl_buffer_slice` either, so a guest cannot read a non-focused buffer. **An
   IRC plugin cannot parse a single line of RFC 1459.**
2. **`on_poll` never fires for a socket.** `notifyPollIfReady` scans
   `resources.streams` — raw *proc* streams only (`wasm_host/activation.zig:26-33`,
   `plugin_resources.zig:82`). Net sessions live in a different registry that is
   never consulted.

   *(1 and 2 are one defect, and the fix is subtraction, not addition — see §5a.
   Three `Slots` registries of one shape become one, net inherits the stream
   doors that already exist, and the wake follows because there is one registry
   to scan. The first draft's "add `wl_net_read`" was the wrong instinct.)*
3. **No append, and no incremental projection.** Every commit rewrites the whole
   buffer — `renderInto(..., .{ .start = 0, .end = end })`
   (`wasm_host/projection.zig:275-280`) — and then repositions the cursor
   (`:294`). One inbound message on a 10k-line channel re-renders 10k lines
   through the CRDT and yanks your caret out of the scrollback.
4. **No in-view editable text subject.** `plugin_lib/prompt` is a fixed guest
   byte array painted with `weft.echo` (`prompt/root.zig:304-317`). It is not a
   document, so it has no cursor, no motions, and no completion — and while it
   is open the log's keymap is inactive.
5. **No way to make the log read-only.** Consequence: `x`/`dd`/`p` mutate the
   projected text until the next commit silently wipes it.

Plus: completion is welded to `ctx.buffer().textEditor()` so it cannot fire in
an input line (`complete_ui.zig:52-80`); there is **no mouse door at all**
(a click only places the caret); and background code cannot `echo` — it traps
(`wasm_host/dispatch.zig:15-16`), so every async plugin copies LSP's
defer-through-a-command workaround.

**And the meta-finding, which matters more than the list:** the IRC test
exercises the *membrane* far harder than it exercises the plugin libraries.
Passing it would prove the doors were fixed, not that `listing`/`stream`/`draft`
were carved correctly. **IRC is the right acceptance test and the wrong design
test.** The design test is §5's wgrep.

## 2. Three claims in the first draft that were false

Recorded because each was the premise of a move.

**"vim is already decomplected; it needs only cursor/lineAt/slice/byteLen/edit."**
False. `plugins/vim` calls **39 distinct SDK symbols** and binds or runs ~40
commands it does not own: `save`, `quit`, `open`, `buffer-close`, `find-file`,
`window-split`, `focus-other`, six `scroll-*`, `goto-definition`, `complete`,
`undo`, registers, `set-mark`, and the file picker. `plugin_lib/ex`, which vim
instantiates unconditionally, hardcodes `:w`→`save` and `:q`→`quit`
(`ex/root.zig:162-220`). Point vim at an IRC log and `/w` saves a file.

The honest restatement: **the text-verb core — `motions`, `operators`,
`textobjects`, and about a third of vim's own commands — needs only a text
subject, and already has one. The rest of vim is an editor composition and
always was.** An IRC client gets motions for free. It does not get "vim" for
free, and no amount of extraction changes that, because the file and window
verbs are what vim *is*.

**"`listing` is trapped inside `plugin_lib/files`, ~4,000 of 5,305 lines."**
False, and arithmetically impossible: 1,519 of those lines are tests. The
generic middle **already left**, into `plugin_sdk/projection.zig` (289 lines)
and the host, and already has three independent consumers —
`plugins/git/render.zig`, `plugin_lib/output/root.zig`,
`plugin_lib/files/adapter.zig`. Classified function by function, ~91% of what
remains is filesystem-specific. What is actually left is dired **plus a dead
plane** (§5, L1).

**"git and dired share an `authority`/`draft` shape."** False. git makes **zero**
`semanticField`/`View`/`Target`/`Action` calls — verified across every file. Its
rows are read-only and its "draft" is a text buffer read on save, about six
lines. git is async/opaque-bytes/whole-model-staleness/fire-and-forget; dired is
sync/typed/per-row-staleness/dependency-DAG-plan with rollback. The only shared
element is the sentence "run something external, re-read, republish."

## 3. What core actually is

The earlier census said 26% of core is "editor policy that should leave." That
reading was wrong, and the moves built on it are infeasible:

- **`Buffers` and `Editor` are substrate, not policy.** Undo lives on `Editor`
  (`Editor.zig:30`), so does save/backing (`:44`). And **collab identifies a
  shared document by BUFFER ID on the wire** — `sc.primary_tag = buffers.active_id`
  (`collab.zig:569`), resolved inbound by `sc.buffers.get(col.tag)` (`:732`).
  Splitting Buffers out means re-versioning the collab wire.
- **There is a hard cycle.** `command.Context` needs `*Buffers`
  (`command.zig:78`); loading a plugin needs a `*command.Context`
  (`main.zig:255`). If Buffers were a plugin there is no bootable state.
- **`Head` is not the keymap's other half** — it is the per-head everything
  (pick session, echo, semantic focus, interaction stack, working target,
  focused pane, transient stack), and `Context.head` is core's only door to any
  of it (`Head.zig:7-8`). Moving `Head` moves the command ABI.
- **Moving `pick` out drops no doors.** Its 14 doors are guest→host and stay
  whatever core does; core is itself a pick consumer at ~12 sites including a
  frame-loop phase, a window-layout region and a scheduler source.

**The reframe: core is not an editor with policy bolted on. It is a substrate
whose types are named after editor concepts.** An IRC client wants open
document sessions, wants a document with a cursor and undo, wants per-client
view state. `Buffers`, `Editor` and `Head` are exactly those things. They are
correctly in core; they are badly *named*, which is what made them read as
editor policy in a census.

What genuinely can leave is narrower than 26%: the **presentation** halves
(`Pick.buildSurface` is Vertico sitting inside `completing-read`), and the dead
planes.

## 4. The layering

Four layers, not one. The first draft collapsed them and produced a wrong
dependency rule.

    ┌─ composition ───────────────────────────────────────────────┐
    │  editor    git    dired    IRC    agent-UX   (manifests)     │
    ├─ presentation ──────────────────────────────────────────────┤
    │  vertico   viewport   minibuffer   gutter   statusline       │
    ├─ service (swappable, racing) ───────────────────────────────┤
    │  matcher   annotator   actions   syntax   completion         │
    ├─ protocol (the substrate interfaces) ───────────────────────┤
    │  text  rows  stream  choose  draft  authority  instances     │
    ├─ kernel (core) ─────────────────────────────────────────────┤
    │  plugin runtime │ CRDT object store │ graphics adapter       │
    └──────────────────────────────────────────────────────────────┘

**The dependency rule: presentation may depend on service and protocol; service
may depend on protocol; protocol may depend on nothing above it.** That
direction is what makes a presentation swappable without the substrate noticing
— the Vertico/`completing-read` split, generalized.

It is already mechanically enforceable: `build.zig:48`'s `Library` enum declares
the standard library, `importName()` guarantees a library "cannot be reached
under two names", and `deps()` declares what each may import. A library
physically cannot reach what the build did not hand it. What is missing is only
a *layer* field to check the direction against.

Today's graph is nearly flat, which is what this protects:

    annotate  jsonrpc  output  prompt  rowkey  sessions   ← no deps
    invoke ← prompt
    ex     ← invoke, prompt
    files  ← files_{model,projection,actions,text_rows,workspace}, fs, semantic

## 5. The plan

### Doors first — D1–D5 are the actual blockers

**D1 — RETRACTED by the census (§5a). Net becomes a stream instead.** The three
`Slots` registries merge into one, so net gains `wl_proc_read`/`send`/`close`
rather than growing its own, and `on_poll` fires for a socket because there is
one registry to scan. Was:
Without them no protocol client can exist without shelling out to `nc`, giving
up the audited native TLS that `core/net.zig` exists to provide. Highest value
in the document.

**D2 — re-admit `wl_readonly_span`.** Core's `readonly_layer` already exists and
its doc names this exact case: *"a comint's produced output is read-only, its
input line editable"* (`command.zig:490-505`). Nothing in production claims it;
the only claim in the tree is a unit test.

This door was **deliberately demolished** and is pinned gone
(`demolition_test.zig:91`) under the rule *"a mechanism shipped ahead of its
consumer, and the consumer never arrived."* Re-adding it is that rule firing
correctly in the other direction — the consumer has arrived — and the
demolition list must be amended openly, with the consumer named, not quietly.

It turns "read-only log above, editable input below, one buffer, vim over both"
from impossible into the default.

**D3 — append / incremental projection, and a follow-tail that does not move the
cursor.** The whole-buffer rewrite is both a performance bug and a usability one.

**D4 — an explicit subject on the text doors.** Narrower than the first draft's
M1: the host already has `Context.bindEntry` and uses it for background fills
(`command.zig:177-189`); no guest door exposes it. Note this is *not* needed for
vim-over-a-log, which already works — it is needed for reading and completing
against a buffer that is not focused.

**D5 — completion against a subject that is not the focused file buffer.**

**D6 — a mouse door.** Belongs to the presentation arc (`presentation.md`), not
here; recorded so the omission is not lost.

### Then the library work

**L1 — finish the migration `files` is stuck in.** It runs the scene plane and
the text plane simultaneously; glyphs, depth, visibility, mode formatting and
row identity each exist twice, and `publishDraft` (`adapter.zig:1016`) drives
both with five rollback paths woven through. Delete the scene plane: ~810 lines
out, one plane, one concurrency model. Then point `files` at the `sessions` and
`rowkey` libraries it currently reimplements. **No new library, nothing frozen.**

**L2 — fix two library-factoring bugs the IRC design exposed.**
`plugin_lib/ex` bakes vim's file/window verbs, so no non-editor `:`-line can
reuse it. `plugin_lib/sessions` is keyed by a filesystem *place* (`forRoot`
refuses an empty root) so it cannot serve "a session per network" — the reusable
half is `weft.Instances`. Also lift the two-argument ceiling on
`runArgs`/`invoke`.

**L3 — wgrep, the DESIGN test.** An editable grep buffer: rows from many files,
edit the row text, save applies across N files. Dired's twin on a different
authority — many authorities not one directory, `path:line` identity not entry
refs, mtime conflict not revisions, no dependency DAG. **If a draft abstraction
survives both dired and wgrep, it is real.** The row source already exists in
`plugin_lib/output`, so only the draft half is new. Cheaper than IRC and a far
better test of the libraries.

**L4 — split `choose` from `vertico`.** `Pick.zig` fuses them: `open`/`tick`/
`appendItems`/`selection` is `completing-read`; `buildSurface` (`:598`) is
Vertico. Split first; move the presentation half out after. `pick/match.zig`
becomes a swappable matcher slot; `ui/pick-annotate` (marginalia) and
`action_here.zig` (embark) already exist and stay.

### Two more doors the debugger proves are load-bearing

**D7 — an incremental projection commit.** `stream` cannot be extracted without
it (`output` is a completion continuation that rebuilds every node —
`output/root.zig:131-135`), and everything append-shaped is O(n²) today, shipping
the whole buffer per line over collab.

**D8 — an `on_fold` guest export.** Folding is deliberately a *view* state: a
collapsed node still renders its children, because the alternative loses a draft
made under a collapsed directory (`projection.zig:322-328`). That reasoning is
right, and it means **lazy expansion is inexpressible** — which kills a debugger
variables tree (each expansion is a DAP request), a large filesystem tree, and a
database browser. The fix is not to change fold; it is to let a producer be
*told* so it can materialize before the render.

### Then the acceptance test

**A1 — the debugger**, against D1–D8. Multi-surface is the property nothing else
tests: it is the only target that requires a plugin to **act on a buffer that
does not have focus** — mark a stopped line in a source file while focus is in
`*debug*`. That is impossible today (`layers.zig:44,57` bind decorations to
`activeCtx().document()`), it is a ~20-line change to an 87-line plugin, and it
falsifies the subject work in a day.

**A2 — the IRC client**, as a demo rather than evidence. Kept because it is the
user's stated goal and because D1–D3 are what make it possible.

## 5a. The door census (231 doors, censused 2026-09-03)

The worry that prompted this: the ABI grows about one door per idea, and the
plan above proposed adding five more. `plugin-api.md` §2 diagnosed the cause —
the only generic spine (slots + schema payloads) is used for plugin-to-plugin
traffic and never for the built-ins.

**The rule the census tests: a door should name an OPERATION, not a KIND.** If
you can say "read from X" for three different X, that is one door taking a
handle, not three doors.

Splitting each of the 231 names into `<kind>_<verb>`, the verbs that recur
across kinds:

    close  10   len  7   count 6   read 5   begin 5   span 4   send 3

**That histogram is misleading, and the correction is the finding.** Checked
against actual signatures, most of those are different operations that share a
word:

- **`count` (6) does not unify.** `wl_arg_count`, `wl_command_count`,
  `wl_buffer_count`, `wl_offer_count` are all `() -> u32` but ask different
  questions about different collections. Merging them needs a "what am I
  counting" parameter — the kind moved from the name into an argument, which is
  not a win.
- **`close` (10) is three families, not one.** `wl_surface_close()` takes **no
  handle** (a plugin has one ambient surface). The six `wl_semantic_*_close`
  take `(u32,u32,u32) -> u32` — a name-and-revision shape, not "close handle H".
  Only `proc`/`net`/`annotate` are `(handle)`.
- **`len` (7) is four families.** `wl_byte_len()` is ambient; `wl_annotate_len`
  and `wl_buffer_byte_len` take an id; three `wl_semantic_*_request_len()` are
  identical and ambient.

### What genuinely unifies

| merge | doors | net |
|---|---|---|
| `wl_proc_send` + `wl_net_send` + `wl_repl_send` → `wl_send(handle,ptr,len)` — identical signatures over three `Slots(T)` registries | 3 → 1 | **−2** |
| `wl_proc_close` + `wl_net_close` (+ `wl_annotate_close`, with care — it is `Handles` not `Slots`) | 3 → 1 | **−2** |
| three `wl_semantic_*_request_len()` — byte-identical | 3 → 1 | **−2** |
| `wl_byte_len` / `wl_buffer_byte_len` — the ambient/explicit pair of one question; collapses when the subject is explicit | 2 → 1 | **−1** |
| six `wl_semantic_*_close`, *if* the semantic plane has one id space (unverified) | 6 → 1 | −5 |

**Firm: −7. With the semantic id space: −12.** Against 231 that is 3–5%, not
the 20+ the histogram implied. Recording the smaller number because the larger
one was my own and was wrong.

### The structural win is bigger than the arithmetic

    streams:      handles.Slots(proc_stream.ProcStream)
    sessions:     handles.Slots(repl_session.Session)
    net_sessions: handles.Slots(net_session.Session)

Three registries of one shape (`plugin_resources.zig:82-87`). That is *why*
there are three sets of send/close doors — and it is also why
`notifyPollIfReady` scans only `streams`, so **a socket never wakes a guest**.
Merging them fixes the door duplication and the wake bug as one change.

It also deletes D1 from the plan above. Net does not need a read door; net needs
to be a stream, and streams already have one. **The highest-value item in §5 was
a door that should not exist.**

`handles.zig` already learned this lesson one layer down — its own doc: *"Seven
such registries were written out by hand … and each re-derived the same
invariants — badly, in the places nobody thought to look twice."* The storage
was unified; the ABI was not.

### Where doors actually accumulate

`semantic` 34 and `edit` 34 are 68 of 231 — nearly 30% in two groups. Any
serious ratchet goes there, and `semantic` is the plane §2 of this document
already found is only 4/39 presentation.

## 5b. A real bug the design process found

**Undo through a projection is broken today, and nothing tests it.**

A projection rebuild is one whole-buffer replacement — `renderInto(..., .{ .start
= 0, .end = end })` (`wasm_host/projection.zig:286-289`). Undo rebases each
inverse through later commits with `mapOffset` (`position.zig:53-69`). Against a
patch with `offset = 0, removed = end`, **every offset maps to 0**. So for a user
edit predating a rebuild:

- an **insertion** collapses to a zero-width no-op, is dropped
  (`undo.zig:233`), and is *still* pushed onto the redo stack (`:158-165`) —
  `u` silently does nothing and eats a history entry;
- a **deletion** re-inserts its bytes **at offset 0**, the top of the buffer.

`error.Collapsed` is declared in `Refusal` (`undo.zig:48`) and never returned.
No e2e covers undo in a projection. Dired escapes only by never syncing until
`:w`; git's rebase plan escapes by not being a projection. **Both consumers the
first draft leaned on for `draft` avoid the bug rather than solve it**, so the
editable-span contract has no working precedent under undo.

This is the highest-value finding in the review and it is not an architecture
question. Fix `mapOffset` collapse, or refuse with the error that is already
declared.

## 5c. Governance: the rule, and four gates that fail today

`build.zig:48`'s `Library` enum already declares the graph and Zig's module
roots already enforce it. What is missing is a **law**: `deps()` is a free-form
DAG, and nothing stops `.output => &.{.files}` tomorrow.

**The rule — a strict tier, checked at comptime:**

    0  text, location, rowkey                       ABI doors only
    1  stream, listing, draft                       may use tier 0
    2  authority, session                           may use tier ≤ 1
    3  prompt, invoke, ex, annotate, transient      asking the user

Answering the two questions this immediately raises: **`listing` may not depend
on `pick`** — a collection of rows must not know how you choose one; after the
Vertico split the temptation is acute and a tier check refuses it at build time.
**`stream` may not depend on `listing`** — same tier; fusing them re-creates
`files` one layer down, which is the exact failure this plan exists to undo.

**Four mechanical gates**, extending `demolition_test.zig` (which already scans
`src/` for banned spellings). **All four fail on the current tree, which is the
point — they are a to-do list with a build error attached.**

1. **No editor vocabulary in `plugin_lib/`** — no `"normal"`, `"insert"`,
   `"cursor-up"`, `"undo"`, `"buffer-"`. Fails at `output/root.zig:46,50` — and
   that failure names the exact line by which the old acceptance test was
   already passed. Forces "which mode does this rest in?" to be a parameter of
   the consumer, not a constant in the library.
2. **No command-name literals in `plugin_lib/`** — a library reaching another
   module by a global string has an undeclared dependency the build graph cannot
   see. This closes the tier rule's escape hatch.
3. **No module-global mutable state in `plugin_lib/`.** Fails at
   `output/root.zig:38` — `var slots: [4]Slot`, a hard ceiling of four streams
   per wasm instance. An IRC client with five channels does not fit the library
   meant to be its message log.
4. **Door-budget monotonicity** — assert the `wl_*` count in `externs.zig` is
   `<= N`, ratcheting down. Today N = 231. This is the only honest test of
   "did moving X out of core actually remove anything."

## 6. Cut

- **Extracting a `listing` library.** It already exists with three consumers.
- **Extracting `authority`/`draft` now.** One candidate, not two. Revisit after
  L3.
- **`Keymap` + `Head` leaving core.** Head is the per-head everything and
  `Context.head` is core's only door to it; a plugin-backed key router costs ~8
  guest calls per keystroke on the hot path that is explicitly fenced as
  non-blocking, and needs a bootstrap keymap in core anyway.
- **`Editor` + `Buffers` + `builtins` leaving core.** The collab wire tags by
  buffer id, and `Context`↔`Buffers`↔plugin-loading is a cycle.
- **"Core keeps no pick."** Its doors are guest-facing and stay. Only the
  Vertico half moves.

## 7. Open

- The fourth review (a harder second target than IRC — a debugger, a
  spreadsheet, an email client) is outstanding. It should be read before L3 is
  scheduled, since it may name a better design test than wgrep.
- **Naming.** If `Buffers`/`Editor`/`Head` are substrate rather than editor
  policy, they are misnamed, and the misnaming is what made a census read them
  as policy. Renaming is cheap and clarifies the boundary; it is not scheduled
  here.
- **A layer field in `build.zig`'s `Library`**, so the §4 dependency rule is
  checked rather than merely stated.

See `architecture.md`, `plugin-api.md` (§1's A–K grid, and its
"deliberately NOT extracted" rule, which the first draft of this doc broke while
citing it), `presentation.md` (D6 and the rendering arc), and
`contextual-workspace-architecture.md`.
