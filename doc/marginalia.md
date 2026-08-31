# Pick annotation — and the introspection it actually needs

Status: in progress. Slices 1–3 (Phase 1, the read doors) are built and
green; 4–8 remain. §6 is the live checklist. Where implementation revised a
decision, the section says so rather than being quietly rewritten.

## 0. What this is

A spec for annotating pick rows the way Emacs' marginalia annotates
completion candidates — a file row gains size and mtime, a buffer row gains
its dirty flag and language, a command row gains the key that runs it — with
the annotator living in a plugin and core learning no policy.

It covers four phases. **Phase 1 is not about annotation at all**, and that
is the point of the document.

## 1. The finding that sets the order

A census of every pick producer in the tree (appendix, §8) says the pick
membrane can carry annotations with modest additions. But for the three
highest-value categories the annotation doors would open onto an annotator
that has nothing to say:

| target | what marginalia would show | what a guest can read today |
| --- | --- | --- |
| files | size, mtime, mode | `wl_fs_exists` → absent/file/dir/other. Nothing else. |
| buffers | dirty, path, language, size | count/id/name/active/readonly. `wl_path` and `wl_byte_len` are **active-buffer only**. |
| commands | the key that runs it | `wl_menu_binding_*`, which reads only the current head's resolved menu list. No command→key lookup, in any mode. |

Each gap is one small uninterpreted read door, and each is independently
useful to something that is not marginalia — a status line wants
buffer-dirty, a file browser wants stat, which-key wants command→key. So the
first slice is **widen introspection**, with marginalia as the consumer that
justifies the shape rather than the reason to build a subsystem.

Phase 2 is then small, because the annotation transport turns out to already
exist (§3.1).

---

## 2. Phase 1 — the read doors

Three independent slices. Each lands and ships on its own; none depends on
another or on Phase 2. Eight doors total, `expected_import_count`
221 → 229.

### 2a. `wl_fs_stat` — what a path is, beyond its kind

**One new door, `fs` group, `perm = .fs_read`.**

```zig
.{ .name = "wl_fs_stat", .params = &.{ .u32, .u32, .u32, .u32 }, .results = &.{.i32},
   .group = .fs, .perm = .fs_read,
   .doc = "a path's kind/mode/size/mtime as a fixed 32-byte record, resolved against the grant's bounds" },
```

`wl_fs_stat(path_ptr, path_len, out_ptr, out_cap) -> i32`.

**The record** — 32 bytes, little-endian, fixed layout, no framing:

| offset | width | field |
| --- | --- | --- |
| 0 | u32 | `kind` — `file.Kind` ordinal (0 absent, 1 file, 2 dir, 3 other) |
| 4 | u32 | `mode` — raw `st_mode` (the guest masks; core does not interpret) |
| 8 | u64 | `size` bytes |
| 16 | i64 | `mtime` nanoseconds since epoch |
| 24 | u32 | `nlink` |
| 28 | u32 | reserved, written as 0 |

Fixed binary rather than the group's usual newline/CSV text (`wl_fs_list`,
`wl_breakpoint_offsets`) because there is nothing here a text form would make
more readable and a size is not a string. Reserved word so one more field can
land without a second door.

**Returns** 32 on any permitted call — including an absent path, which is
`kind = 0` and zeroes, exactly as `fsExists` answers `.none` rather than
failing. `-1` when `out_cap < 32` or the write into guest memory fails. Traps
on the three refusals (`PermissionDenied` / `OutOfLimit` / `Machinery`),
identical to its five siblings.

**Confinement is not new work.** The semantic body is
`fsStat(gpa, id, path) PermError!Record`, and it goes through `gate` like
everything else in `wasm_host/fs.zig` — machinery carve-out first, then
possession, then bounds. The confined branch extends
`RootedFs.kind` (`src/core/rooted_fs.zig:187`), which is already
`openat2(RESOLVE_BENEATH|RESOLVE_NO_SYMLINKS)` + `statx(AT_EMPTY_PATH)` with
`.TYPE` requested; `RootedFs.stat` asks for `.TYPE|.MODE|.SIZE|.MTIME|.NLINK`
and returns the record. The unconfined branch is `file.statFull`, a new
sibling of `file.statKind`.

**The symlink rule follows for free and must be stated.** Because the
confined branch refuses any symlink in the chain, `wl_fs_stat` cannot report
the size of a file outside the root through a link planted inside it — the
same hole `fsExists` closed. The unconfined branch follows symlinks, exactly
as `statKind` does today. Both are the existing policy; neither is a new
decision.

**Tests** (mirroring the two that already guard `fsExists`):

- a symlink inside the root pointing out of it → `error.OutOfLimit`, not a
  size;
- a `root = "."` grant refuses `/etc/passwd` and answers `build.zig`;
- an absent in-root path answers `kind = 0`, not a refusal;
- `out_cap = 31` → `-1` (short destinations never truncate silently).

**Consumers other than marginalia:** the `files` plugin's size column and
size-sort; `git` deciding whether a working-tree file changed; `notes`.

### 2b. Buffer introspection — five doors

**`buffers` group, ungated**, exactly like the existing five. Every one is
indexed by `i` over the open-buffer walk, and every one answers about a
buffer that is *not* the active one — which is the whole gap.

```zig
.{ .name = "wl_buffer_path",     .params = &.{ .u32, .u32, .u32 }, .results = &.{.i32}, .group = .buffers, .doc = "the `i`-th buffer's backing path, into guest memory, or -1 if unnamed" },
.{ .name = "wl_buffer_dirty",    .params = &.{.u32},               .results = &.{.i32}, .group = .buffers, .doc = "whether the `i`-th buffer holds edits its file backing never received; -1 when unanswerable" },
.{ .name = "wl_buffer_lang",     .params = &.{ .u32, .u32, .u32 }, .results = &.{.i32}, .group = .buffers, .doc = "the `i`-th buffer's language (extension sans dot), into guest memory" },
.{ .name = "wl_buffer_byte_len", .params = &.{.u32},               .results = &.{.i32}, .group = .buffers, .doc = "the `i`-th buffer's document byte length, or -1 when it holds no text" },
.{ .name = "wl_buffer_tool",     .params = &.{ .u32, .u32, .u32 }, .results = &.{.i32}, .group = .buffers, .doc = "the projection the `i`-th buffer represents (`files`, `git`), or 0 bytes for a plain entry" },
```

Bodies, all in `wasm_host/buffers.zig` over the existing `bufferAtIndex`:

- **path** — `b.textEditor().?.backingPath()`, `-1` when there is no editor
  or no backing. This is `wl_path` (`edit.zig`, active-buffer only)
  generalized to an index; `wl_path` stays as the active-entry convenience.
- **dirty** — `b.hasUnsavedFile(gpa)` (`Buffers.zig:131`). Note what that
  already decides for us and do not re-decide it: a **tool projection is
  never dirty** (`tool.len > 0` returns false), because a projection has no
  file to write. An annotator therefore cannot mark the git status buffer
  "unsaved", which is correct and comes free. `-1` on the allocation failure
  path so "unknown" stays distinguishable from "clean".
- **lang** — `action.langOfName(b.name)`. Derived at the door, not stored;
  it is the same string `Facts.lang` and every `.lang` predicate use, so a
  guest annotating a row and a provider matching on that row agree by
  construction.
- **byte_len** — `b.textEditor().?.text().byteLen()`, `-1` for an entry that
  holds no text (a semantic view). Generalizes `wl_byte_len`.
- **tool** — `b.tool`, the field. Writes 0 bytes for a plain entry. This is
  what lets an annotator tell "a file" from "a projection" before it says
  anything about either.

**A cursor memo was specced here and deliberately NOT built.**
`bufferAtIndex` is an `O(i)` walk, so ten indexed doors over `n` buffers is
`O(n²)`. But `Buffers.slots` is a dense array with holes, the walk is a
pointer skip, and a buffer pick is built ONCE at open over tens of entries. A
memo on `WasmPlugin` would be core state bought with no measurement — the
opposite of the direction this document argues for everywhere else. If a
profile ever says otherwise, the dense view belongs on `Buffers`, not on the
plugin.

**What was built instead** is the reduction that was actually available: the
ten indexed doors were ten copies of the same walk-then-bail dance, and are
now three wrappers (`intDoor`/`boolDoor`/`bytesDoor`) over nine one-line
bodies. `boolDoor` exists because `wl_buffer_active`/`readonly` declare `u32`
results that their shims read as `!= 0` — a -1 there would make "no such
buffer" report TRUE. The bodies take `anytype` for the principal (`edit.zig`'s
shared-read-door pattern), so they are one implementation the JS plane can
wrap, and callable from a test with no guest behind them.

**Tests:** a two-buffer fixture where the *inactive* one is dirty, holds text,
and has a language — every door must answer about it while a different buffer
is active. That single assertion is the whole point of the slice. Plus a `git`
projection that holds unsaved text and is still not dirty.

These would have needed a fourth copy of the same test fixture, so instead
`core/TestHost.zig` is now the one: `core/tests.zig`'s `TestHost` and
`wasm_abi/tests.zig`'s `Env` were near-identical, each transcribing by hand
the init ORDER that actually matters (`caps`/`actions`/`slot_host` borrow
`&container` and may only be built once it sits at its final address).

### 2c. Keymap introspection — two listing doors

The missing lookup is command → key. `wl_menu_binding_*` cannot serve it: it
reads the current head's *resolved menu list* (`head.completions` /
`head.resolveBindings`), which is a head-scoped, mode-scoped, position-scoped
view. What is missing is a read of a **named mode's own table**.

```zig
.{ .name = "wl_mode_names",    .params = &.{ .u32, .u32 },              .results = &.{.i32}, .group = .keymap, .doc = "every mode with a binding table, newline-joined" },
.{ .name = "wl_binding_table", .params = &.{ .u32, .u32, .u32, .u32 },  .results = &.{.i32}, .group = .keymap, .doc = "mode `m`'s bindings resolved through its fallback chain, one `<key>\\t<command>` per line" },
```

**Two listing doors, not five indexed ones** (revised during implementation).
The indexed spelling — `mode_count`/`mode_name`/`binding_count`/
`binding_key`/`binding_cmd` — would re-run `resolveBindingsInto` once per
index. That is an allocating fallback-chain walk, so it is `O(n²)` plus an
allocation per call, and the only escape is a resolved-list cache in core
(exactly what `Head` keeps for the menu doors). Listings have neither
problem, and they put the parsing where the policy already is.

Both use the two-pass exact-read convention, so a table too big for the
caller's buffer says so (-2) rather than silently arriving half-length: half
a keymap looks exactly like a small keymap. That helper (`writeExact`) moved
out of `pick.zig`, which had invented it for `wl_pick_outcome_*` and was its
only user.

**Key notation.** `wl_binding_key` returns the *display* form
(`Keymap.displayKey` — `"SPC g s"`), matching `wl_menu_binding_key` exactly.
The canonical stored form is deliberately not exposed: no consumer needs it,
and shipping both spellings of the same key through the membrane is an
invitation to compare the wrong one.

**Why not a single `wl_command_binding(cmd)` door.** Because "the key that
runs this command" is not a fact — it is a fact *per mode*, and often more
than one key per mode. A door that returned one answer would have to pick a
mode and a winner in core, which is policy. With these five a guest builds
whatever index it wants (`marginalia` wants "in the mode this pick was opened
from"; which-key wants something else), and core has decided nothing.

**Follow-up, not this slice:** three of the seven `wl_menu_binding_*` doors
become expressible on top of these plus a read of the head's pending chord.
Retiring them is a separate change with its own consumer migration
(`which_key`), listed here so the duplication is on the record rather than
discovered later.

**Tests:** a mode with a fallback parent must enumerate the parent's
bindings too (that is what "resolved" means, and the difference from
`bindingAt`); a chord must come back as one entry (`"space g s"`), not three.

---

## 3. Phase 2 — the annotation membrane

### 3.1 The transport decision

Three transports were considered.

**A. Producer-pull.** The producer fires a slot with its rows and merges the
answers before `pickEnd`. Costs zero new core machinery — `wl_slot_fire` and
the whole `SlotHost` already exist, and providers answer synchronously
*inside* `fire` (`slot.zig:236`), so a static pick is fully annotated before
it opens. **Rejected as the whole answer:** every producer must be edited,
and rows that arrive after `pickEnd` — the file pick's streaming
`LocalFinder`, completion's `refresh` — are unreachable. Four of sixteen
sites grow rows asynchronously, and they include the flagship.

**B. Bespoke pick-annotate doors.** A pick-scoped session with
`wl_pick_annotate_count/row/key/category` to read it and `wl_pick_annotate(i,
text)` to answer. Simple, no schema. **Rejected:** it is the `wl_caps_*`
shape, which `doc/d2-schema-payloads.md` §5.3 has already named for
demolition. Building the new thing in the shape that is being retired is a
regression with a nice-looking diff.

**C. Core-mediated, over the existing slot membrane. Chosen.** The pick
carries an uninterpreted category; when its row set grows or is replaced,
core fires the `ui/pick-annotate` slot at every eligible provider and folds
the answers into a new per-row annotation column. Reuses `SlotHost` (the race,
the restamp, the eligibility walk, the teardown), reuses the schema
marshaller, needs **two** new pick doors, and covers async growth because the
fire is driven from `Pick.tick`, which the frame loop already calls every
frame.

What core learns under C: the string `"ui/pick-annotate"`, the *shape* of a
row-in/note-out exchange, and "fire when the rows changed". It learns nothing
about what a note says, who may write one, or what any category means. That
is the same line `edit/completion` already draws.

### 3.2 `Entry.key` and `Options.category` — the two core fields

```zig
// core/pick/types.zig
pub const Entry = struct {
    text: []const u8,
    doc: []const u8 = "",
    /// An uninterpreted PUBLIC key for this row, for an annotator that
    /// cannot read the label. Empty = the text IS the key (the common
    /// case: a path, a command name). Core never parses it.
    key: []const u8 = "",
};

pub const Options = struct {
    // …
    /// This pick's kind, uninterpreted (`"file"`, `"buffer"`, `"command"`).
    /// EMPTY MEANS NO ANNOTATION — the opt-in, not a default.
    category: []const u8 = "",
};
```

`Pick` gains `keys: ArrayList([]u8)` parallel to `items`, and `category: []u8`.

**Why the key is not the prompt.** The prompt is a label, not a kind: `git`'s
confirm prompt is a question, `lsp`'s reference pick is a title,
`buffers_cmds`' remote-dir prompt is `"dir host:path"`. Matching on prompt
substrings would let an annotator decorate a destructive yes/no. A separate,
explicitly-set category means **git's confirm and acp's permission prompt are
never annotated, structurally** — they set nothing, so nothing fires.

**Why the key exists at all.** For files and commands the row text *is* a
public key. For **buffers** it is not: the label is `"3: foo.zig [ro] *"`,
and the identity lives in `WasmBoundPick.buffer_keys` as a `Ref` the
annotator cannot resolve. `hPickAddBuffer` sets `Entry.key` to that buffer's
backing path (or `name` when unbacked), so the annotator gets something it
can act on while the `Ref` stays where it belongs — the accept path, which
needs an identity, not a path. One field, one real consumer, stated plainly.

Core producers set both directly: `complete_ui` (`category = "complete"`),
`buffers_cmds`' remote dir (`"dir"`), `collab_cmds`' shared list (`"shared"`),
the core palette fallback (`"command"`).

### 3.3 Two new pick doors

```zig
.{ .name = "wl_pick_category", .params = &.{ .u32, .u32 }, .results = &.{}, .group = .pick,
   .doc = "declare the kind of the pick being built; empty (the default) means no annotation" },
.{ .name = "wl_pick_add_keyed", .params = &.{ .u32, .u32, .u32, .u32, .u32, .u32 }, .results = &.{}, .group = .pick,
   .doc = "like `wl_pick_add`, but the row carries an uninterpreted public key an annotator can resolve" },
```

`wl_pick_category` sits between `begin` and `end` with `wl_pick_free_text`,
touches only the plugin's own scratch, and stays ungated for the same reason
those do. `wl_pick_begin` resets it to empty — each pick opts in for itself.

`wl_pick_add_keyed` has **no consumer among today's sixteen sites**, and is
included anyway: without it the membrane is usable only by core producers and
by the shipped plugins someone happens to edit, which contradicts the reason
for building it in a plugin. Marked speculative here so the justification is
not later misremembered as demand.

### 3.4 The slot: `ui/pick-annotate`

Declared by core at startup, on the same `Container` every capability slot
(`capability.zig:477`) and every `ui/*` mesh slot (`app/session.zig:159`'s
`ui_mesh.declareSlots`) already lands in — one flat namespace, as
`System.zig:125` describes it:

```zig
try container.declareSlot(.{
    .name = "ui/pick-annotate",
    .shape = .query,
    .composition = .ordered_union,   // every provider contributes; priority orders them
    .schema = &pick_annotate_schema,
});
```

**One schema, both directions.** `SlotHost` walks a result payload against
the same `SlotDecl.schema` it handed the request (`slot.zig:281`), so the
schema must describe both. Spell that as a `variant`, which is exactly what
the schema system's tagged union is for:

```
variant {
  ask:  struct { category: str, from: u32, rows: array(struct { text: str, key: str }) }
  tell: struct { from: u32, notes: array(str) }
}
```

Core encodes `ask`, each provider answers `tell`. A `tell` whose `from` does
not match the `ask`'s is dropped, not rebased — the same discipline
`wl_annotate_begin`'s revision stamp uses for a decorated entry
(`wasm_host/annotate.zig`): a set computed against a row range that has moved
is discarded, never guessed at.

`notes` shorter than `rows` annotates the prefix; longer is truncated. A
provider that has nothing to say pushes an empty array or declines, and
`ordered_union` means having nothing to say costs the others nothing.

**Composition.** Every provider's non-empty note for a row is joined in
Container priority order with two spaces. One string per row.

The alternative — a column per provider, which is what Emacs' marginalia
actually does — is deliberately not v1: `surface.Surface`'s column sizing
would need to become dynamic, and no shipped annotator wants a second column
yet. Written down so the join is understood as a choice, not an oversight.

### 3.5 The drive: rows-changed, in `Pick.tick`

`Pick` gains one counter:

```zig
/// How many rows have been offered for annotation. The rows-changed edge:
/// `items.len != annotated_len` is the ONLY thing that fires a round.
annotated_len: usize = 0,
annots: std.ArrayList([]u8) = .empty,   // parallel to items, "" when none
```

`Pick.tick` is called every frame from `app/frame.zig:349` regardless of
source; today it early-returns when `source == null` (`Pick.zig:257`). The
annotation drive goes **before** that return, so static picks are covered
too:

```
if (category.len > 0 and items.len != annotated_len and ctx.slot_host != null) {
    const hi = @min(items.len, annotated_len + max_annotate_batch);
    fire ask{category, from = annotated_len, rows = items[annotated_len..hi]};
    fold every tell into annots;
    annotated_len = hi;
}
```

Three bounded things, each for a stated reason:

- **`from`, not the whole set.** A 4000-row file pick that re-marshalled
  every row every frame would be `O(n)` per frame for the life of the pick.
  Only new rows are offered, and `from` makes that structural rather than a
  convention the provider has to honour.
- **`max_annotate_batch = 256`.** One frame never marshals an unbounded
  tree; the next frame resumes at `annotated_len`. A file pick annotates
  progressively, which is also what it looks like.
- **`refresh` resets `annotated_len = 0` and clears `annots`.** `refresh`
  *replaces* the row set (completion's race-and-refine), so every cached
  annotation is about rows that no longer exist. Resetting re-annotates the
  whole (small) set on the next tick. `appendItems` does not reset — its rows
  are additive, which is what `annotated_len` already tracks.

`clear` frees `annots`, `keys` and `category` with the rest.

**Facts.** The fire uses `intent.factsFor(ctx)`, the one fact builder
intention resolution uses. Note the consequence and write it in the plugin
docs: **while a pick is open, `facts.mode` is `"pick"`.** A provider binding
with `.mode = "normal"` will never fire. Annotators bind on the category (in
the payload) rather than on mode, or on `.mode = "pick"`.

### 3.6 Rendering

Two small edits in `Pick.zig`, no new render-layer knowledge:

- `buildCaretSurface` — the annotation becomes **column 2**, `.annotation`
  role, beside the existing column 1 note. The renderer already sizes columns
  from whichever rows carry them, so a partially-annotated list still aligns.
- `buildDockSurface` — appended to the joined line as ` · {annot}` after the
  doc, matching the existing `item  · doc` shape.

The producer's own `doc` is never touched. That is the boundary marginalia
itself draws (an annotator decorates from the candidate; the producer's own
affixation is the producer's), and here it is enforced by them being
different arrays.

### 3.7 Three prerequisites, and one hazard

**Prerequisite — nothing owns a `SlotHost` in the running editor.** This is
the one that has to be checked before anything else in Phase 2 is costed.
`command.Context.slot_host` is `?*SlotHost` defaulting to `null`
(`command.zig:128`), and `System.contextFor` (`System.zig:299`) sets every
other field and never sets that one — `System` has no `SlotHost` member at
all. The only construction anywhere is the wasm-membrane test harness
(`wasm_abi/tests.zig:656`). So D2 landed the membrane, the schema
marshaller and the end-to-end proof, and in the **shipped binary every
`wl_slot_*` door is a silent no-op**: `hSlotFire` returns -1, `hPayloadPush`
returns without pushing, and the `badge`/`badge_consumer` fixtures pass
because they bring their own host.

The fix is small and mechanical — a `slot_host: SlotHost` field on `System`,
initialised after `container` like `caps` and `actions` are (they borrow
`&self.container` and must be set after the struct literal for the same
reason), wired in `contextFor`, deinit'd beside `caps`, and re-pointed in the
system swap alongside `System.zig:576`'s `c.caps = &to.caps`. It is called
out as its own slice because it is a prerequisite for Phase 2 *and* it is a
standing bug worth fixing whether or not any of this gets built: today a
plugin can declare, bind, and fire a slot in the real editor and silently
get nothing.

**Prerequisite — the slot trampoline must route `active_ctx`.**
`wpSlotProvider` (`wasm_host/slot.zig:135`) calls `on_slot_fire` without
setting `p.active_ctx`, exactly as `wpCompletionProvider` does. That is fine
today because every existing fire happens *during* a dispatch where
`active_ctx` is already right. A fire from `Pick.tick` is in the frame loop,
not a dispatch, so a provider's `wl_payload_push` would reach
`p.activeCtx()` — its last-set context, which for a second head is the wrong
one. Fix: save/restore `active_ctx` around the `on_slot_fire` call, the same
three lines `wpPickAccept` uses.

**Prerequisite — and it must NOT set `in_dispatch`.** Leaving `in_dispatch`
false is the protection, not an omission: every head-gated door
(`requireDispatch`) refuses, so an annotator physically cannot set a mode,
open a pick, or echo from inside a fire. **Annotation conveys no authority**
— the same guarantee `wasm_host/annotate.zig` makes for decorators, obtained
here by not granting it rather than by checking for it. Assert it with a
fixture guest that tries and is refused.

**Hazard — re-entrancy into the pick.** The fire happens while `Pick` is
mid-tick. A provider cannot open a pick (head-gated, above), but it could
`wl_run` a command that dismisses one. `Pick.tick` already survives its
source's `poll` dismissing the pick; the annotate fold must re-check
`self.active` after the fire before writing into `annots`, and drop the round
if it is gone.

---

## 4. Phase 3 — the marginalia plugin

`src/plugins/marginalia/root.zig`, registered in `build.zig`'s plugin table
as `.{ .name = "marginalia", .import = "guest_marginalia_wasm", .install = true }`.

`init` declares nothing and binds one slot:

```
weft.slotBind("ui/pick-annotate", predicate = all, tier = .plugin, priority = 0)
```

`on_slot_fire` reads the `ask`, switches on `category`, and pushes a `tell`:

| category | note it writes | doors it uses |
| --- | --- | --- |
| `file` | `12.4K  2h ago` (dirs get an entry count later, not v1) | `wl_fs_stat` (2a) |
| `buffer` | `zig  42K  ●` (dirty dot), `files` for a projection | `wl_buffer_*` (2b) keyed by the row key |
| `command` | `SPC g s` — the key that runs it here | `wl_mode_*`/`wl_binding_*` (2c) |
| `dir` | as `file` | `wl_fs_stat` |
| anything else | declines | — |

Config, read at `init` via `weft.config`, so the plugin is policy and not
another set of hardcoded choices: `file = size,mtime|size|off`,
`buffer = lang,size,dirty|…`, `command = binding|off`.

**What the plugin explicitly does not do:** annotate `complete`. That row set
is core's (`complete_ui`) and Phase 4 is where it moves.

**Note the reach honestly.** Of the sixteen census sites, this plugin can say
something useful about seven (command ×2, file ×2, buffer ×2, remote dir).
The rest are either *intrinsic* — consult's line/symbol, lsp's
references/symbols, the shared list, completion: the row's meaning lives in
the producer's private parallel table, and no outside annotator can resolve
it, so the producer must supply the note, which it already can — or
deliberately excluded (git confirm, acp permission). That is marginalia's own
boundary, and it halves the reach. It does not shrink the value of Phase 1,
which is where the reach comes from.

## 5. Phase 4 — `complete_ui.kindTag` moves out

`CompletionUi.kindTag` (`core/complete_ui.zig:162`) maps LSP
`CompletionItemKind` numbers to `"fn"`/`"var"`/`"kw"`. It is an annotator, it
knows a protocol's number space, and it lives in core. It is also the one
case where the annotator already exists and is simply in the wrong place.

Once Phase 2 lands, completion picks carry `category = "complete"`, and the
`kind` number rides the row key (`Entry.key = "<kind>"` — uninterpreted by
core, which is the only way core is allowed to carry it). A `marginalia-lsp`
provider — or the `lsp` plugin itself, which is where the number space is
already understood — answers with the tag, and `kindTag`/`annotate` delete.

This is roadmap item 5 (completion UI as a plugin) and this work meeting in
the same place: both want `category`, both want the rows-changed signal, and
neither is a reason to build a second mechanism.

---

## 6. Sequence and gates

| # | slice | doors | gate |
| --- | --- | --- | --- |
| 1 | `wl_fs_stat` | +1 (222) | symlink + `root="."` confinement tests pass; `files` plugin shows a size column |
| 2 | buffer introspection | +5 (227) | every door answers about an **inactive** buffer; a projection is never dirty |
| 3 | keymap introspection | +2 (229) | fallback chain and chords enumerate correctly from a named mode |
| 4 | `System` owns a `SlotHost`; `contextFor` wires it | 0 | the `badge`/`badge_consumer` fixtures run against the **real** session, not only the test harness |
| 5 | slot trampoline `active_ctx` + no-`in_dispatch` | 0 | fixture guest is refused every head-gated door from `on_slot_fire` |
| 6 | `Entry.key` / `Options.category` / 2 doors / the tick drive / rendering | +2 (231) | a fixture annotator decorates a static pick and a **streaming file pick**; git-confirm and acp picks are untouched with a provider bound |
| 7 | `marginalia` plugin | 0 | the three flagship categories annotate; `weft.set` turns each off |
| 8 | `kindTag` out of core | 0 | `complete_ui.kindTag`/`annotate` deleted; completion rows still show `fn · fn (i32) i32` |

Slices 1–3 are independent of each other and of everything after; any of them
can ship alone. 4 stands alone too and is worth doing regardless (§3.7). 5
needs 4; 6 needs 5; 7 needs 1–3 and 6; 8 needs 6.

Each slice bumps `expected_import_count` by hand and adds the guest extern in
`src/plugin_sdk/root.zig` — the comptime tripwire fails the build otherwise,
which is the intended way to be reminded.

## 7. Out of scope, said plainly

- **The JS plane.** `weft.pick`'s options are a newline-joined string and
  every entry gets `doc = ""` (`quickjs.zig:1114`), so neither acp.js pick
  can carry an annotation at all. That is the qjs parity gap, not this work,
  and both acp picks are on the never-annotate list anyway.
- **Annotating intrinsic rows.** Consult's lines, lsp's references, the
  shared list. The producer already supplies notes; an outside annotator
  cannot resolve the row. No door fixes this.
- **Retiring `wl_menu_binding_*`.** Named in §2c as newly-duplicated surface;
  a separate change with a `which_key` migration.
- **Per-provider annotation columns.** §3.4.
- **Annotating anything that is not a pick.** The buffer list, the file tree
  and the git status buffer are entries, and §11.7's `wl_annotate_*` is
  already the door for those.

## 8. Appendix — the producer census

Sixteen call sites, ~12 kinds.

| kind | sites | plane | prompt | row → key | grows after open? |
| --- | --- | --- | --- | --- | --- |
| command | palette, core fallback | wasm/core | `"command"` | text is the key | no |
| buffer | palette, buffers | wasm | `"buffer"` | `Ref` via `pickAddBuffer` | no |
| file | vim, emacs | wasm→core | `"open"` | text = path | **yes** |
| line | consult | wasm | `"line"` | index → private CRDT table | no |
| symbol | consult, lsp | wasm | `"symbol"` | index → private table | no |
| reference | lsp | wasm | title (dynamic) | index → private table | no |
| confirm | git | wasm | the question (dynamic) | — | no |
| complete | complete_ui | core | `"complete"` | index | **yes** (replaces) |
| remote dir | buffers_cmds | core | `"dir h:p"` (dynamic) | text = path | **yes** |
| shared | collab_cmds | core | `"shared"` | index | no |
| agent perm / focus | acp.js ×2 | JS | dynamic | — | no |

Tiers: **extrinsic** (annotatable from a public key) — command ×2, file ×2,
buffer ×2, remote dir. **Intrinsic** (producer must supply the note) —
consult line/symbol, lsp references/symbols, shared, complete. **Never** —
git confirm, acp permission; protected by setting no category.
