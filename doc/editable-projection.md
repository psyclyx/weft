# weft — editable projections (dired in-place, and the general model)

A **projection** is a buffer whose text is a rendered view of a model (a
directory tree, a git staging set, the buffer list). You edit the text and
**save reconciles** the model. dired is the first instance; the design is
deliberately general (magit staging, an editable buffer-list, a config editor).

## The reframe: name-is-content, metadata-is-decoration

A dired row today flattens three structurally-distinct things into one line of
bytes — and that flattening is why every requirement is hard:

| part | e.g. | nature | in the buffer text? |
|---|---|---|---|
| **identity** | "the file currently at `src/a.zig`" | a hidden id | **no** — never typed |
| **name** | `a.zig` | real document text | **yes** — the ONLY text |
| **decoration** | `-rw-r--r-- 4.0K`, `▾`/`*`, indent | display only | **no** — drawn beside |

So the `*dired*` buffer's text is *just the editable name tree*. Metadata is
**decoration** (`virtual_before`/`gutter` placement, which the layer system
already supports). One buffer, **always editable, no edit-mode split**; expand a
fold to splice child lines in; **`save` reconciles**. Because the name is the
only text, `yy` yanks exactly the name in vim *or* helix *or* modeless — no
editor learns the word "dired".

## The decisive fact (why the register is the crux)

An id **cannot** ride copied bytes: a yank is raw `slice` → bytes, a paste is a
fresh `edit` insert → new CRDT identities; anchors (and the subbuffers/spans
built on them) are keyed by POSITION, not bound to characters, so none of them
travel with content (`lib/stemma/.../AnchorSet.zig`). The ONLY thing spanning a
cut-in-A → paste-in-B is the **register**. So the register must capture and
restore the id payload — and that is exactly what makes identity path- and
text-independent: typing `o foo` or pasting raw text creates no span → no id →
**create**; only a payload-aware paste of a killed dired line restores the id →
**move**. Structurally impossible for retyped text to acquire an id.

## Identity + reconcile (path-independent)

Each name carries a hidden **id span** — a subbuffer with facts `{id, kind}`
(this primitive already exists, `subbuffer.zig`, and rebases under edits for
free; dired just doesn't use it). The initial gather snapshots `{id → (parent,
name, kind)}`. Reconcile diffs snapshot → current-buffer-ids, purely by id,
**across all open dired buffers** (a moved file leaves one, appears in another):

- same id, name+parent unchanged → untouched
- same id, new name, same parent → **rename**
- same id, new parent → **move**
- id in snapshot, in no buffer → **delete**
- line with no id → **create** (dir if it ends `/`)

The editing path is irrelevant — only initial→current matters.

## Fold expansion — already free

Fold-aware vertical motion is core: `Editor.rowHidden`/`nextVisibleRow` skip
`invisible` fold spans for ANY editor, and dired's `j`/`k` are core
`cursor-down`/`up`. So "expand a fold in normal mode and keep moving" needs no
editor cooperation. Expand-a-new-dir must SPLICE children in place (a `render`
insert), not re-gather (which discards edits) — anchored spans rebase the rest.

## The seam: projection owns STRUCTURE, editor owns EDITING

- **Projection plugin** (dired/magit/…): what a row means, which bytes are the
  name, the hidden id, the snapshot, the initial→current diff, the ordered op
  list, execution. Never names an editor.
- **Editor** (vim/helix/modeless): motions, operators, and the **register**.
  Never names a projection.

## The primitives (3 new core, 1 reused)

1. **Register/kill service (core)** — NEW, replaces vim's private `reg_buf`
   (which helix free-rides by name, so a helix-only build has no register at
   all). `src/core/register.zig`: `{ text, linewise, payloads: []{offset, len,
   facts} }`. ABI: `weft.yankRange(range, linewise)` (copy bytes + snapshot the
   facts of any id-span overlapping the range), `weft.registerText()` /
   `registerLinewise()` (editor keeps its own paste-positioning policy),
   `weft.pasteAt(offset)` (insert + re-claim a subbuffer with the ferried facts).
   vim + helix delete their private register logic and bind to these; modeless
   gets a real register for the first time. dired never touches it — it just
   claims id-spans; the register mechanically ferries whatever a yank overlaps.
2. **Decoration door (core)** — NEW. `weft.decorate(anchor, placement, role,
   text)` / `decorateClear`, over the placement layer support that already
   exists (`layers.Placement.{virtual_before, eol, gutter}`) but has no guest
   door. Turns metadata into non-text → `yy`-name-only is structural. (It's
   DECORATION spans that earn their keep here, not read-only spans — read-only
   guards edits, not yanks.)
3. **Tool-backed save hook (core)** — NEW dispatch. `save` on a `.tool` buffer
   fires the owner's `on_save` export (mirroring `on_fill`) instead of the
   current no-op; `on_save` returns an ordered op list; core shows a **generic
   pending-changes popup** (rename/move/delete/create in apply order, from
   initial→current) gated y/n, then calls `on_save_apply`. Catches `C-s`/`:w`/
   `:wq`/palette-save — every route, any editor. Deletes the whole
   `dired-edit`/`dired-reconcile`/`*dired-plan*` mode split (the code already
   laments the missing save hook). The popup is a general editable-projection
   affordance, not dired-specific.
4. **Subbuffer facts (reuse)** — the per-row id already has a home; dired starts
   using it.

## What's mis-layered today (and how this fixes it)

- Register is vim-private guest state; helix free-rides `paste` by name → hoist
  to core.
- dired's editable mode is a separate posture + `*dired-plan*` preview + a
  documented mode-leak → one always-editable buffer + save-hook reconcile.
- Metadata baked into the line as bytes (offset bookkeeping) → decorations.
- Identity heuristic (path/position) → hidden id-spans (real, exact).
- dired redraws via `edit`, never engages render/read-only → structure via
  `render`, name edits via `edit`.

## Generalizes

magit staging (hunk rows + `{hunk-id}` + ordered `add -p`/`reset`); editable
buffer-list (delete a line → close that buffer); config editor; grep-writeback.
None touch the editor; each supplies structure + reconcile.

## Build order

1. **Core register + payload ferry** (keystone; fixes the vim mis-layering).
   Wire vim + helix to it, prove `dd`/`p` still work. Validate the thesis in one
   assertion: yank a line with an id-span, paste it → the pasted range carries
   the id; a typed line does not.
2. **Decoration ABI door** — metadata non-text; prove `yy`-name-only.
3. **Per-row id-spans + initial→current reconcile in dired.**
4. **Tool-backed `on_save` dispatch + the generic ordered-diff confirm popup.**
5. **Delete the `dired-edit`/`reconcile`/`revert`/`*dired-plan*` machinery.**
