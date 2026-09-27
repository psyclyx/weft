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
`weft://here/file/…`; a relative path is refused rather than resolved against
the process directory.

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
  `posture`, `locality`, `offers` (a revision).
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
There are no functions, no composition, and no evaluation order to define.

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

## 4. What retires

- `on_offers_changed` and the focus feed's `Companion` → `on_context_changed(keys)`.
- The toolbar and contextmenu plugins as viewport owners → one `offers` projection provider.
- Path subjects and `weft.placeRoot()` as a browsing root → designations.
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
2. **Open context.** Keyed values with scopes, `weft.contextSet`, predicate
   leaves, `on_context_changed(keys)`. Migrate the toolbar and delete
   `on_offers_changed` and `Companion`. The repl plugin publishes
   `repl.session`.

   *Landed (2026-09-26, branch `arc/model`).* The open keys live in
   `weft_facts`' `context.Store`: `(owner, scope, key, value)`, scope
   entry (the entry's generation) | place (the place's identity, packed
   exactly) | global, resolved entry → place → global. A published key must
   be namespaced (contain a dot), so no builtin can be shadowed; a key at a
   scope has one owner (a second writer is refused, never raced); a value
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
4. **Extent sets.** Unify text selections and listing focus; declared
   mapping; dispatch-owned `.each`. Migrate vim, helix, ide, surround, find
   and files; delete their hand loops.
5. **Snapshot frames.** Versioned provider answers, highlight off the frame
   path, delete `render_safe`. Can run alongside phases 3-4, since it touches
   the render path rather than plugins.

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
