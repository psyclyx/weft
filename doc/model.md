# The workspace model: one set of nouns

Status: ACCEPTED (2026-09-26); decisions in §6. Written after the three-configs arc
(doc/configs.md) shipped a toolbar, a sidebar, panels, multiple selections and
a context menu. Each worked, and each grew its own small mechanism. This
document names the few nouns those mechanisms are all instances of, so the
next round of plugin work builds on one model instead of adding a sixth
mechanism.

Nothing here is new in spirit. doc/architecture.md already says text is a
projection of a graph, and resolution happens against a context stack.
doc/contextual-workspace-architecture.md (CWA) already specifies designations
(§6.3), extents (§6.6), entries versus viewports (§7) and offers (§9).
doc/place.md already specifies where effects run. What is new is holding the
shipped code to those specs, and three shifts that make the pieces compose.

## 1. What the arc exposed

Five places where the code solved one problem twice, or solved it in a way
that stops composing:

| Symptom | Where | The missing noun |
|---|---|---|
| The sidebar presents `"."` (relative to launch); `files` presents `placeRoot()` (absolute); a peer's tree opens as a located target | `config/sidebar.js`, `plugins/files`, `collab_cmds.zig` peer-files | **designation**: one name for content anywhere |
| Scratch, tool, REPL and terminal buffers have no name outside a live slot; viewports and jumplists held raw slot ids (two review bugs) | `Buffers.Ref`, `viewport.zig`, `jumplist.zig` | **designation**, and **entry** as distinct from it |
| Three "follow the primary context" mechanisms: the Zig-only focus feed, `on_offers_changed`, and a sidebar that follows nothing | `focus_feed.zig`, toolbar, sidebar | **context**: one observable, keyed, open |
| `Facts` is a closed struct; a plugin can't say "a REPL is connected here" | `facts/root.zig` | **context** with open keys |
| Every multi-selection bug the review found was a plugin looping (or not looping) over selections itself | ide, surround, find, helix | **extent set** with mapping declared on the action |
| The toolbar owns a viewport, a scene and a redraw loop; the context menu, palette and which-key are separate presentations of the same offers | `plugins/toolbar`, `contextmenu`, `palette`, `which_key` | **projection** |
| A draw-time allowlist refuses mutating calls while plugins answer gutter/status requests mid-layout | `contract.render_safe` | **snapshot**: frames drawn from a version |

## 2. The nouns

Seven nouns. Everything a plugin touches is one of them.

### 2.1 Designation: what

A durable name for content anywhere: `weft://<authority>/<kind>/<ref>` plus
optional view parameters (CWA §6.3, `semantic_model/durable.zig`). Authority is
the locus (`here`, a peer fingerprint, `shell:<id>`); a path without one means
nothing (substrate §7, R1).

The shift: **a designation is the only way to name content across the ABI.**
`open`, `present`, `reveal`, jumplist entries, embeds, context values and
viewport subjects all take one. A bare absolute path is accepted as sugar for
`weft://here/file/…`. A relative name a person types (`open foo.txt`, `:e`,
the command line, a stored recent that predates designations) is resolved
once, at the user-facing door, against the place the command runs in
(`designation.resolveRelative`), so nothing downstream ever holds one. The
only place a relative name is refused is a config `present` subject: config
has no dispatch to take a place from, and `{context: "place"}` says what
`"."` used to mean.

Every kind of thing an entry can show gets a designation, in honest tiers:

| Tier | Kind | Example | Survives |
|---|---|---|---|
| Stored content | `file`, `dir` | `weft://here/file/…/main.zig` | restart, collab |
| Documents | `doc` | `weft://here/doc/<id>`, `weft://<peer>/doc/<id>` | restart, collab |
| Projections | a synthetic kind per producer | `weft://here/git.status/<place>`, `weft://here/offers/primary` | re-run on present |
| Live resources | `proc` | `weft://here/proc/<id>` | only while the process lives |
| Positions | a locator in the view parameters | `…/main.zig?at=<anchor>` | rebases under edits |

A scratch buffer is a document with no file. A file-backed buffer is a
document that also designates a file. A tool buffer is a projection.

**Document identity is minted, not derived.** There is no stable document
identity today, and the history root can't be one. stemma derives a bulk-loaded
document's root from its content hash (`TextDoc.openFromContent`, `base-<sha256>`)
on purpose, so divergent checkouts of one file can sync. But two different
files with identical bytes (any two empty files) then share a root: it is a
sync-compatibility witness, not a name. Collab names a share with a `u64`
allocated per connection (`Conn.announceShare`), which a reconnect loses.

So a document gets a random 128-bit id at creation. A shared document's id
travels in the share announcement, so `weft://<peer>/doc/<id>` is stable
across reconnects. The history root stays what it is, for sync. Identity and
revision stay separate, the same split doc/place.md makes for places. A
file-backed entry is still named by its file; the minted id matters for
scratch and shared documents.

### 2.2 Entry: a local opening of a designation

An entry (the user-facing word stays "buffer") is a local, per-workspace
opening of a designation: the designation it represents, its presentation,
its title and lifecycle (CWA §7). Entries are local; designations are shared.
Two collaborators open different entries for the same `doc`.

The shift: **state that outlives an entry holds the designation, never the
entry id.** A jumplist entry is `(designation, anchor)`, so it survives closing
the buffer and reopens it. A viewport holds the designation it presents, so a
reused slot can't be captured. Lane O's generation-checked `Buffers.Ref` fixed
the symptom; this removes the class.

### 2.3 Viewport: where

A pane with attributes (edge, extent, cycles, takesFocus, persistent,
statusLine…), the entry it shows, and that view's own state: extents, scroll,
folds, navigation history (CWA §7). "Sidebar", "toolbar" and "panel" stay
attribute bundles in config, never workspace kinds.

The shift: **a viewport's subject is a designation or a context key.** See
§2.5.

### 2.4 Projection: how content becomes a view

A provider that turns a designation of some kind into a view model: a text
document, a scene tree of rows and action nodes, or a strip of buttons.
Editable projections write back (the files listing already does).

The shift: **every piece of chrome is a projection, and no plugin owns a
viewport.**

| Today | As a projection |
|---|---|
| toolbar plugin owns the `toolbar` viewport and redraws on `on_offers_changed` | a provider for `offers` designations; `toolbar` is a viewport presenting `weft://here/offers/primary` as a strip |
| context menu | the same provider, presented as a transient surface at the pointer, for `offers/at-pointer` |
| palette, which-key | the same offers (plus commands, plus pending chords) presented as a picker and as a hint |
| problems panel | a provider for `diagnostics/<place>` |
| sidebar | the files provider (or a places provider) presented in a docked viewport |
| outline, breadcrumbs | a provider for `symbols/<entry>` presented as a tree, or as a status segment |

This is the answer to "the sidebar isn't special": the sidebar and the toolbar
are the same composition, **viewport + subject + projection**. They differ
only in which designation they present and how the view is laid out.

### 2.5 Context: what is true here

A stack (workspace → place → entry → mode → transient) of keyed values, with
most-specific-wins resolution (architecture.md, CWA §9). Actions, bindings,
grants and config values all resolve against it.

The shift: **context keys are open.**

- Core owns a few keys it alone can compute: `entry`, `place`, `mode`,
  `posture`, `locality`, `offers` (a revision), `places` (a revision of
  the workspace's places: it moves when an entry opens in a new place or a
  peer shares a tree, though the primary `place` stays put).
- Any plugin can publish a value at a scope: `weft.contextSet("repl.session",
  "weft://here/proc/7", .place)`. It is retracted when the plugin unloads or
  sets it empty.
- Predicates test any key (`{ context: { "repl.session": "*" } }`), so a
  provider can be offered only where a REPL is connected. The toolbar grows a
  "Send to REPL" button with no toolbar change.
- **The primary context** is the context at the primary viewport (the last
  focus source). One event, `on_context_changed(keys)`, fires at most once per
  frame after layout, listing which keys moved. It replaces both
  `on_offers_changed` and the Zig-only focus feed.

`Facts` becomes the typed view of the builtin keys over this open map, not
the only thing context can hold. Named signals (events, lane M) stay for
things that are occurrences rather than state.

**Following is a subject bound to a context key**, not a plugin and not an
expression language:

```js
weft.present("sidebar", { subject: { context: "place" }, reveal: { context: "entry" } });
weft.present("outline", { subject: { context: "entry" }, as: "symbols" });
weft.present("panel",   { subject: { context: "repl.session" } });
weft.present("toolbar", { subject: "weft://here/offers/primary", as: "strip" });
```

A subject is a designation, or the current value of one context key. `as`
picks the projection when a designation has several. `reveal` expands to and
highlights a designation inside what's presented, without taking focus.
The highlight is literal: it is the view's own *revealed* node, drawn
beside the selection. A reveal never touches a selection — no head's focus,
no entry's marked rows — so revealing is never navigating. There are no
functions, no composition, and no evaluation order to define.

`as` has two readings, and which one applies is decided by registration, not
by the config author: if a plugin claims the name as a projection kind
(`symbols`), the subject is opened *through that plugin*; otherwise the
subject's own provider reads it as a layout (`strip`, `menu`). `reveal` is
an unlisted request (`view.reveal`) rather than a node action, because listed
node actions become offers and would appear as toolbar buttons.

This revisits D2 (doc/cwa-config-decisions.md), which rejected
`subject: follows(focused, lang.symbols)` as an expression language. That
rejection holds for expressions. It doesn't hold here, because designations
for projections turn "the symbols of the focused entry" from a function into
a key plus a view parameter. What D2 feared needed evaluating now just needs
reading.

### 2.6 Extent set: what the user has selected

A selection is one or more extents, and an extent is a text range, a set of
designations (rows in a listing), a structural range, or a provider-defined
shape (CWA §6.6).

The shifts:

- **Text selections and listing focus are one thing.** Today `Editor`
  selections and `semantic_focus` are separate states with separate doors.
  Selecting three rows in the files listing and pressing delete is the same
  act as three carets and delete.
- **The action declares how it maps over the set; dispatch does the mapping.**
  CWA §6.6 already says: "Operations declare whether they require a whole set,
  can map independently over each item, require a homogeneous set … No action
  silently operates on only the compatible portion." Every multi-selection bug
  the review found was a plugin getting that loop wrong by hand. Declare
  `.each`, `.whole` or `.homogeneous` on the command, and let dispatch run
  `.each` once per extent inside one undo unit. Plugins stop writing
  per-selection loops.

As built (phase 4, `core/selection.zig`):

- **Extent** `{kind, anchor, head}`: `text` (byte offsets, an `Editor`
  selection) or `rows` (a range of a scene's focusable rows). A tree-sitter
  node selection stays a text extent — nothing yet needs a node's identity to
  outlive an edit. A scene's selection is `Head.SceneSelection` (what was
  `semantic_focus`): the focus path is its primary extent, grown from
  `anchor` (`selection.start-rows`, vim's `V`), and `others` are marked rows
  (`pointer.add-selection`, C-click). Both kinds cross the same door record
  (`wl_selections_get/set`: `[primary, kind, anchor, head, …]`; rows by their
  place in the view's focus order) and the same SDK `Selection`.
- **Arity**, declared per command (`Command.arity`; guests through
  `wl_declare_arity`, the SDK's `CommandEntry.arity`, JS's fifth
  `weft.command` argument). The SDK field is required and there is no
  table-wide default: a plugin-wide `.whole` was a guess about commands its
  author never looked at, and ran snipe's `d f` on the primary alone. The
  SDK spells refusal `.one` (declared by declaring nothing):
  - `.each` — dispatch (`command.run` → `selection.run`) visits every extent,
    last first, inside one undo unit; in a run the single-selection API and
    the selection doors address the visited extent alone. Register yanks are
    staged one value per extent and land joined when the mapping ends, a
    paste reads its own value, a flash joins one set. `.each` with `over`
    names a target command: each extent's target is found on the untouched
    text (edits are refused meanwhile), identical targets run once, nested
    ones each run, partially overlapping ones refuse the command (`merge`
    unions them — line blocks); the command then runs per target with it as
    its range argument. This is what surround's `md(` over two carets in one
    pair, and two carets on one line under `>`, need: a per-extent view of
    the untouched text and a whole-set dedupe, which is exactly target
    finding plus settling, so no command needs both views itself.
  - `.whole` — once; the command reads the set (split, add-next-match,
    align) or never looks at it (save, a picker whose accept does not move
    the caret, a command that only runs another — which then maps by its
    own declaration). A row transfer is
    `.whole`: copy and cut send every selected row (ranges and marks, in
    view order; a text projection's rows under every caret) as ONE request
    and get ONE transfer back — several rows are a set
    (`transfer.Item.members`; codec transfer v3, request v4, written only
    for a set), which a paste lands in order. Mapped per extent, each run
    would replace the one captured value. A one-row verb (rename, insert
    beside, step out) declares nothing and is refused on several rows. A
    grammar's transfer key (vim's `yy`, `p`, `dd`) is two verbs: it is
    `.whole` and only routes — to the view's transfer when one is offered,
    else to its text half, a command of its own that maps `.each`.
  - `.homogeneous` — once, refused when the extents differ in kind.
  - `.one` — refused on several: it reads THE caret or row and has no
    per-extent reading (a labelled search, a goto from the word at point, a
    row's own action, a picker that jumps).
  - A dispatch handed an explicit range runs once: its subject is the
    argument — but on several extents only where a run chose it: inside a
    visit, or under a `.whole`/`.homogeneous` command that took the set on
    (`Context.reading_set`). Anywhere else (a callback, a bare dispatch)
    the range is one extent's among several, picked by no declaration, and
    is refused like an undeclared command.
- **The default is refusal.** An undeclared command on several extents is
  not run; it says `<name>: acts on one selection; several are selected`.
  Running it once on the primary is precisely the bug every review finding
  was, and running it per extent would repeat commands that were never
  per-selection (a picker, a save). Refusal is the only default that can
  never do the wrong thing silently; a command that is safe says so in one
  word. Core's own tables are audited, so a core `Command` defaults to
  `.whole` and each selection-touching builtin says `.each`; a guest's
  arity is only ever what it declared.
- **Availability agrees.** A catalog offer carries its command's arity; a
  snapshot for a selection it cannot map over reports it disabled with the
  same reason code (`one-selection`, `mixed-selection`), so the toolbar
  greys it, the context menu drops it, explain/which-key show it blocked,
  and a key that reaches it echoes the reason. A scene node's own action
  says nothing about several rows, so it is refused on them.

### 2.7 Snapshot and frame: when

A frame is a pure function of a workspace snapshot at version *v*: document
snapshots (rope snapshots are O(1)), plus entry and viewport state, which is
small and copied.

The shift: **plugins answer for a version, off the frame path.** Gutter,
status, breadcrumb and highlight answers are requested for *v* and cached
per version. A frame draws the latest answer it has, even if it's a version
behind. A plugin that makes an edit while answering just makes an edit, which
becomes *v+1*. The torn-frame bug can't happen, and `contract.render_safe` is
deleted. The same move lets highlighting run off the frame path, and lets a
head render a peer's view from a snapshot it received.

## 3. How the pieces compose

A single example touching every noun: you open `src/main.zig` from a peer's
shared tree.

1. The sidebar presents `{context: "place"}`. The place is now the peer's
   shared root, `weft://<peer>/dir/…`, so the files projection lists it.
   `reveal: {context: "entry"}` highlights `main.zig` in it.
2. The entry represents `weft://<peer>/doc/<id>`. Its jumplist entry records
   that designation, so jumping back later reopens it even after the buffer
   was closed.
3. Context: `locality = remote`, `place = <peer root>`. The build action's
   provider is gated on `locality = local`, so the toolbar (presenting
   `offers/primary`) drops "Build" with no toolbar code involved.
4. You select three occurrences and rename them. Rename is declared `.each`,
   so dispatch runs it three times as one undo unit, and the edits go to the
   peer as your authored ops.
5. The frame for the result is drawn from a snapshot. The gutter's answer for
   the previous version shows for at most one frame.

## 3.5 Open gaps found while building

- **Remote places, what is left.** A shell's tree lists and reveals but is
  not edited through a listing's draft (its provider refuses `apply`; its
  files open and save through their own backing). Listing a shell's or a
  peer's directory is still one round trip on the thread that asks, as
  peer listings always were. A shell listing's revisions are `ls -l` stamps,
  minute-grained (substrate §2's mtime+size fallback). Only the outbound
  connection binds a peer locus; hub peers share no tree to be a place.
- **An answer's QUESTION key** still holds the local buffer ref and a local
  revision (`Context.revisionOf`: the log length and the tree generation), so
  a peer-rendered view needs an opaque remote version. What an answer is
  about — the key a pane's lookup names — is the designation.
- **The problems list** hears its source's signal, not its documents: a
  diagnostic is an occurrence the source reports, not a function of the
  text, so it does not watch subjects; `problems.refresh` stays for a source
  that raises no signal.
- **A JS plugin** declares no capabilities (no `describe()`), so it claims
  projection kinds only in its own namespace; it registers its
  `onContextChanged`/`onSubjectChanged` handlers from JS, which the host
  cannot see, so every loaded JS plugin is delivered the context event.

*Landed (2026-09-27): remote places.* `locus.Loci` is wired (on `System`,
`Context.loci`) and keyed by identity — a peer by its fingerprint, a shell by
its id — with the transport a rebindable binding (R2); a published
container's place is on the locus its designation names
(`designation.placeOf`), so peer and shell entries read `locality = remote`
by locus, `Buffer.locality()` is the one reading, and ide.js offers
build/test/debug/run in local source only. The coreutils tier is a
filesystem provider (`ShellProvider`, mounted under `Router.freshAuthority`):
`open weft://shell:<id>/dir/…` lists, a shell file is in its directory's
place, the sidebar follows and reveals, and the status line reports a remote
place's liveness (R5; `ShellFs` no longer blocks its spawn on the far side).
A peer's file is editable: `Backing.remote` is one `backing.Remote` seam for
the shell and peer tiers — guarded save (temp, then rename with
`expected = .entry`, else STALE → merge → retry) and external changes merged
as the backing peer's ops — and without the peer's write surface the entry is
read-only with the reason (`Buffer.read_only` holds it).

## 4. What retires

- `on_offers_changed` and the focus feed's `Companion` → `on_context_changed(keys)`.
- The toolbar and contextmenu plugins as viewport owners → one `offers` projection provider.
- Path subjects and `weft.placeRoot()` as a browsing root → designations.
  Done for names and pickers: a plugin hands a typed name to `open`
  (`weft.openTyped`; `openUnder`, the guest-side join, is deleted) and
  `openFilePick` names no directory — core lists the dispatch's place and
  resolves the accepted name against the same place.
- Raw entry ids in state that outlives entries → designations.
- `semantic_focus` as a second selection model → extent sets.
- Per-plugin selection loops, and the `put`/`surround.plan` style workarounds → declared mapping.
- `contract.render_safe` → snapshot frames.
- `weft.follow`-style plugins before they're written → context-key subjects.

## 5. Phases

Each phase ends green and leaves the tree coherent, with no dual mechanism
kept alive past its phase.

1. **Designations everywhere.** `doc` and `proc` kinds, projection kinds, paths
   as sugar, designations in jumplists, viewports and embeds. The files
   plugin and peer filesystem answer the same `dir` kind. Fixes the
   relative/absolute split as a side effect.

   *Landed (2026-09-26, branch `arc/model`).* The grammar
   (`semantic_model/durable.zig`) owns its kinds: `file`, `dir`, `doc` (a
   `DocId`, 32 lowercase hex), `proc`, and any lowercase dotted name as a
   producer's projection; a path kind's ref is absolute by construction (the
   kind's separator is the path's root), so no relative designation can be
   spelled. `durable.Spec` is the one reading of what `open`/`present` are
   handed: a designation, an absolute path as sugar, or a refusal
   (relative, malformed). Every `Document` mints 128 random bits at `init`;
   a bulk load, an edit, a save and a reload keep them, and a joined
   replica adopts the sharer's. The share announcement carries the id as a
   second additive trailer after the kind byte (doc/wire.md): an older
   receiver stops at the kind byte, an older sender's offer opens and names
   the receiver's own replica; the wire version is unchanged, as with every
   additive field before it. `core/designation.zig` answers an entry's
   designation — what was declared for it, else its file, else its
   document — finds the live entry for one, and routes `open` for the kinds
   core can answer: a live entry, a parked document (closing a scratch
   document with text parks it in `Buffers.parked`, bounded at 16), a
   projection's producer re-run (`Openers`: a producer claims its kind and a
   command; the grammar's kinds cannot be claimed; a plugin claims only its
   own name, kinds under it and `proc.<name>`, or a kind its manifest
   declares as `designation/<kind>`, and a refused claim fails its load; an
   unloaded producer's kind is refused as such), a live process
   reattached by the producer of its namespace (`proc.<ns>`), else a refusal
   by name. The shell's `open` adds `here` paths, `shell:` files, and peer
   authorities (`collab_cmds.openPeer`: a peer's `dir` walks down the shared
   tree by the provider's own listing and is presented as every directory
   is; a peer's `doc` opens the offer carrying that id, across reconnects;
   a peer's `file` is refused, see below); `collab.peer-files` is now `open
   weft://<fingerprint>/dir/`. Doors: `wl_entry_designation`,
   `wl_entry_designate` (only on an entry the plugin made — `Buffer.creator`,
   stamped from the guest call it was made in — only `proc` in its own
   namespace or a projection kind it claimed, and never on a file-backed
   entry),
   `wl_designation_opener`; SDK `designation`, `designate`,
   `designationOpener`, `openDesignation`, `openUnder` (since deleted, §4),
   `placeProjection`,
   `placeDesignation`, `contextSetAt`. Trusted publishers name what they
   bind (`Router.designate`, never the guest-writable descriptor), and a
   child row's designation is its parent's plus the provider's leaf — so
   `Session.openWorkspaceEntry` opens a file row by its designation, with
   one provider-identity check on the containing directory and the bytes
   read by the provider relative to that directory's handle (`openat`, no
   link followed, at the listed revision — `Editor.openFileContent`), and the
   container walk f3fd272 added is gone (its tests pass unchanged). Titles
   read the designation (`designation.title`, `$HOME` as `~`, a peer by the
   address it was reached at); the status line shows a file relative to its
   place, else absolute. Jumps are `(designation, anchor, offset)` and
   reopen closed entries; a viewport holds the designation it shows and
   reopens it when it docks again. git status, grep, make, the dashboard
   and problems declare projection kinds; repl, terminal and console
   declare `proc`. Phase 2's placeholders are closed: `entry` and `place`
   are designations, a place scope is keyed by the place's designation, and
   `contextSet` may name a place, so repl and terminal retract where they
   published. The sidebar presents `{command: "files"}` (the place's
   directory) until phase 3's `{context: "place"}`.
   Still open: a peer's file cannot open as an entry — there is no remote
   file backing, only shared documents; a peer is titled by the address we
   connected to, since peers announce no name; scratch documents do not
   outlive the process (nothing persists them), and a designation with `?`
   in a path is not formed; JS plugins have no designation doors (the
   `.tool` group is wasm-only); projection producers can re-run only in the
   place they ran in (a spawn runs where the dispatch is), and say so; the
   answer cache's question key still holds `Buffers.Ref` (phase 5's note).
2. **Open context.** Keyed values with scopes, `weft.contextSet`, predicate
   leaves, `on_context_changed(keys)`. Migrate the toolbar and delete
   `on_offers_changed` and `Companion`. The repl plugin publishes
   `repl.session`.

   *Landed (2026-09-26, branch `arc/model`).* The open keys live in
   `weft_facts`' `context.Store`: `(owner, scope, key, value)`, scope
   entry (the entry's generation) | place (the place's identity, packed
   exactly) | global, resolved entry → place → global. A published key must
   be namespaced (contain a dot), so no builtin can be shadowed, and its
   namespace is its publisher's name (`repl.session` is repl's), so a key
   has one possible owner whatever loads first; a value
   is retracted when set empty or when its plugin unloads. `Facts` carries
   a reader into the store (`Facts.context`), and `Facts.get(key)` is the
   one reader over the whole map — builtins from the typed fields, the rest
   from the store — so `Facts.merge` stays reflective. Predicates gained a
   `context` leaf (`{ context: { "repl.session": "*" } }`, wire tag 13); an
   unset key matches nothing. Doors: `wl_context_set`, `wl_context_get`
   (the primary context, readable by any plugin), `wl_context_changed`;
   `qjs_context_set/get` run the same bodies. `core/context.zig` computes
   the primary context's per-key fingerprints once per frame after layout
   and delivers `on_context_changed` (and Zig `Listener`s) with the keys
   that moved. It reads focus only from `Head.primary_focus`, so a
   companion taking focus moves no key: the focus feed's `Companion` filter
   is unnecessary, and deleted with `focus_feed.zig` and
   `on_offers_changed`. The toolbar redraws when `offers` or `mode` moves;
   repl and terminal publish `repl.session`/`terminal.session`; ide.js's
   "Send to REPL" is gated on the key, and the strip shows it only while a
   REPL is live.
   Still open: `entry`/`place` values are paths and packed coordinates
   until phase 1's designations; `scope: "place"` means the calling entry's
   place, so a publisher cannot later name a different one; a REPL that
   exits on its own is retracted at the plugin's next command, not at the
   exit; JS plugins can publish and read but have no `on_context_changed`.
3. **Chrome as projections.** Context-key subjects, `as`, `reveal`. The
   `offers` provider replaces the toolbar and contextmenu plugins; the
   palette and which-key read the same offers. Sidebar, outline, problems
   and breadcrumbs are rewritten as compositions.

   *Landed (2026-09-26, branch `arc/model`).* `weft.present(viewport,
   {subject, as, reveal})`: subject and reveal are a designation or
   `{context: key}` (`viewport.Binding`), refused where written
   (`viewport.validate`); `as` is a projection name. The workspace reads the
   frame boundary's per-key comparison — the one `on_context_changed`
   delivers — through `Registry.follow`, and the application runs a second
   layout pass in the same wake, so a follower is on the new value in the
   frame its key moved. A key re-read to the same value keeps the pane (and
   whatever the user navigated to inside it); a key with no value presents an
   explicit empty state (core's own one-line view per viewport); the entry
   the previous presentation made is closed through the shell's close once
   nothing shows it — the refusing close, so an entry holding unsaved work
   stays as a tab: a listing says it holds a draft by offering `view.apply`
   enabled (`Services.holdsDraft`), which `buffer.close-unmodified` refuses like a dirty
   file; and a presentation drops the placement an `open` from a
   tool entry asks for. `as` rides to `open` as the `?as=` view parameter:
   `designation.openHeld` routes `?as=<a claimed kind>` to that producer with
   the subject's entry active (the projection OF the subject), otherwise the
   subject's own producer reads it, and a live entry satisfies an open only
   with the same `as`. `reveal` is the standard `view.reveal` action, whose
   request now carries an `argument` (scene codec v3, additive); core asks it
   unadvertised (`action.Registry.ask` — advertising is what makes an action
   an offer) and marks the node it answers as the VIEW's revealed node
   (`view.Registry.reveal`, drawn as an accent bar beside the selection's
   wash). `Services.reveal` is handed no selection, so it cannot move one:
   it first moved the entry's focus, which made a revealed row the primary
   while marked rows stayed marked beside it (a later Delete ran twice on
   one row). The files listing answers it from its own
   designation, which trusted publishers now state on the directory
   descriptor (`fs.target.designation_fact_name`), by one (parent, name)
   lookup per path level. It never reads in the layout pass that asks: a
   reveal behind an unopened folder answers `.handled` (accepted, pending),
   the provider reads every folder on the way at its own `files.reveal`
   signal (the frame boundary) and publishes once, and the viewport, which
   waits on the view's next revision (`Declaration.reveal_waits`), asks
   again in the same wake. Folders a reveal opened fold again when a later
   reveal does not pass through them, unless the user has toggled them.
   `{command}` presenting is deleted.
   The `offers` plugin is the provider for kind `offers` (`primary`,
   `active`, `at-pointer`; `as` strip, list, menu) and replaces the toolbar
   and contextmenu plugins, both deleted; `plugin_lib/offers` is the one
   reading (pinned entries, grammar words, hidden prefixes, disabled kept or
   omitted), which the palette's offer rows read too, and the index-addressed
   `wl_offer_count/name/provider/reason` doors are deleted. Compositions, in
   config: the sidebar (`{context: "place"}`, reveal `{context: "entry"}`),
   the outline (`config/outline.js`, `{context: "entry"}` as `symbols`,
   answered by the new `symbols` plugin from the grammar's outline), the
   problems list as the `diagnostics` projection of a place
   (`weft://here/diagnostics/<place>`, rows scoped to it), and the `places`
   projection (`weft://here/places/all` from the files plugin over the new
   `wl_places`: every entry's place, then every tree a peer shares), the
   sidebar's documented alternative. A peer's listing and shared documents
   are in the peer tree's place (`ShareCtx.remotePlace`), and a peer's FILE
   now opens as a read-only entry read once through the tree — so the
   sidebar follows onto a peer's tree and reveals the file there. The gutter
   answer can be a formula over the frame's snapshot (`core.gutter.Rule`:
   a line's number, or its distance from the caret line); the caret left the
   question, and linenumbers answers rules, so relative numbers are right on
   the frame the caret moves.
   Still open: the breadcrumbs stay a status-segment answer — a status
   segment answers a per-pane, per-frame question and is no viewport, so it
   has no subject to present; which-key still asks what a key would run
   (`menuBindingIntent`), a different question from what a context offers;
   the outline reads the tree an entry has when it is presented (no event
   for a document's revision yet, so a parse or an edit landing later shows
   at the next presentation or `symbols-refresh`) and asks no language
   server; a `shell:` locus lists no directories and a shell file has no
   place of its own, so the sidebar cannot follow a remote shell; a peer's
   file is read-only, and a peer place's locus is `here` (its locality reads
   local).
4. **Extent sets.** Unify text selections and listing focus; declared
   mapping; dispatch-owned `.each`. Migrate vim, helix, ide, surround, find
   and files; delete their hand loops.

   *Landed (2026-09-27, branch `arc/model`).* See §2.6 "As built". Every
   guest command declares its arity or is refused on several extents; core's
   selection-touching builtins say `.each`. helix's and ide's verbs are
   one-selection programs (their `load`/loop/`store` bodies, `putEach`, the
   `put` library and surround's `plan`/`apply` are deleted); line verbs and
   surround's delete/replace map over targets; `&`, `%`, `C`, `(`, the
   tree-sitter trail, C-d/C-S-l, find's replace-all and select-all-matches
   are `.whole`. The doors `wl_run_range_each`, `wl_run_range_arg_each`,
   `wl_yank_each`, `wl_register_paste_value` and `wl_paste_value_at` are
   gone; `wl_declare_arity`, `wl_visit` (whether a dispatch is a run, and
   how many are still scheduled), the optional export `on_mapping_end` (a
   guest epilogue — helix's count, a typed register — runs there, exactly
   once per mapping: a run cannot know it is the last, since an earlier run
   may merge the extents still to come) and `qjs_declare_arity` are new
   (imports 259 → 256, exports 20 → 21, semantic operations 279 → 277).
   A user edit lifts
   only the anchor of the selection it replaced (typing over it), not every
   selection's, so runs do not collapse their siblings. In a listing,
   C-click marks rows, `V j` grows a range, Delete/`d` remove every selected
   row (the files controller takes a range as one delete request), and the
   view washes selected rows.
   Still open: vim keeps its clearing count (`consumeCount`), so a count
   typed before a vim verb on several extents applies to the first run only
   (vim makes no multi-selections); `mixed` shape is always false today —
   no entry yet holds text and rows at once (a listing's focused name field
   is text *inside* the primary row, not an extent), so `.homogeneous` is
   exercised by unit tests only; a paste beside several marked rows is
   refused as ambiguous (a set lands beside one row); row navigation
   moves the primary and keeps marks, as a file manager does; `.each` over a
   target is text-only.
5. **Snapshot frames.** Versioned provider answers, highlight off the frame
   path, delete `render_safe`. Can run alongside phases 3-4, since it touches
   the render path rather than plugins.

   *Landed (2026-09-26, branch `arc/model`).* A frame is two halves:
   `FrameBuilder.capture` takes a `FrameInput` — per pane a
   `core.TextSnapshot` (the O(1) rope snapshot, selections and folds
   resolved to offsets, the revision) and a `Hud` whose layers are
   `layers.Snapshot`s (spans resolved, messages and bulk paint copied,
   clipped to the pane's window) — and `draw` builds every pane from that
   input alone. `View.build` accepts only snapshots, so it cannot read a
   live `Editor` or `Layer`. No guest runs in either half: gutter cells and
   status segments come from `app/answers.zig`, a cache keyed by
   (pane, entry, revision, `Facts.digest`, ask), drawn even when one version
   behind — but only for the same SUBJECT: a pane looks answers up by the
   digest of its entry's designation (`answers.Subject`), so a pane moved to
   another entry draws none of the last one's cells; the questions a frame lacked are asked by a new lifecycle phase
   after the build (`answerRequests`, `piawpobr`), and answers that land
   damage the view and wake the loop (`AdvanceResult.redraw`,
   `loop_sources.redrawDue`). `contract.render_safe`, `answerGate` and
   `WasmPlugin.answering` are deleted; a provider may act while answering,
   and its edit is the next version. `Syntax` caches paint per
   (tree generation, window), so an unchanged frame runs no highlight query.
   `on_context_changed` still fires from `applyWindowIntents`, before the
   build, as phase 2 left it. Measured (`bench-syntax`, ReleaseFast, an
   11.6k-line JS buffer): taking a frame's input costs p50 0.5 µs, p99
   1.3 µs; a redraw that changes nothing the text shows went from 0.36 ms
   to 0.09 ms.
   Still open: the initial parse is all-or-nothing (tree-sitter yields no
   partial tree), so a large file still paints once the whole parse lands;
   an answer's question key holds the local `Buffers.Ref` and revisions are
   the local log length, so a peer-rendered view needs an opaque remote
   version (its subject is already the designation); the `Hud`'s strings, surfaces and semantic scenes
   are borrowed for the frame (safe: nothing mutates them between capture
   and draw) but a view sent to a peer would need them owned.

*Gaps closed (2026-09-27, branch `arc/model-gaps`).* A projection hears its
subject change: a producer watches a designation (`wl_subject_watch`, 64 per
plugin), and at the frame boundary, beside `on_context_changed`, core compares
each watched subject's revision (`Context.revisionOf`: the opening, the text,
and the grammar tree via the app's `Context.derived`) and fires
`on_subject_changed` once per moved subject, bound to the subject's entry. The
outline watches what it presents (`symbols-refresh` is deleted); the chrome
answer cache keys on the same revision, so the breadcrumbs are asked again
when a parse lands (their private cache is deleted). Scratch documents
outlive the process: past the parked bound, and at shutdown for every open or
parked scratch with text, a document goes to `Buffers.documents` (`DocStore`:
32 records, histories up to 1 MiB else the text alone, `documents.kv` beside
`plugins.kv`), and `open weft://here/doc/<id>` or a jump restores it on
demand — no session restore, since weft has none; a record is forgotten only
once its entry stands, and a document ever bound to a peer
(`Document.bound_to_peer`) is never stored. JS plugins reach the tool and
context groups whole through the same bodies (`qjs_designation`,
`qjs_designate`, `qjs_designation_opener`, `qjs_tool_backing`,
`qjs_context_changed`, `qjs_places`, `qjs_subject_watch`;
`weft.onContextChanged`, `weft.onSubjectChanged`), and a JS call is an acting
bracket, so the creator rule holds for JS-made entries. vim's visual `y`/`d`/`p`
over `V`'s rows are one row transfer, as `yy`/`dd`/`p` are, and visual
linewise holds for every caret.

Phases 1-2 are foundations and touch every plugin lightly. Phase 3 is most of
the visible payoff. Phase 4 is the largest and riskiest; it is where the
review's bug class dies.

## 6. Decisions (2026-09-26, all accepted)

1. **D2 is revisited** as §2.5 argues: a viewport subject may be bound to one
   context key. No expressions.
2. **Dispatch owns selection mapping** (§2.6). Actions declare `.each`,
   `.whole` or `.homogeneous`; plugins stop writing per-selection loops.
3. **Chrome plugins become projection providers** (§2.4). The toolbar and
   contextmenu plugins from the three-configs arc are rewritten.
4. **Document identity is a minted id** (§2.1), not the history root.
