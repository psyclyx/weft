# weft's icons

weft draws chrome icons from a bundled set chosen by `theme/icons`:
`weft` (this set, the default), `lucide` (Lucide's upstream files), or `none`.
An icon is stroke-style SVG in a 24-unit box, parsed once into scene path
commands (`src/gfx/icons.zig`). The parser reads the root's `stroke-width`,
`stroke-linecap` and `stroke-linejoin`. Elements marked `class="accent"`
become a second path, drawn in the theme's accent colour
(`palette/accent`). Everything else is drawn in the colour the chrome
tints it.

An icon file never names a colour. The main strokes are `currentColor`,
and the accent is whatever the user's theme says.

This document is the weft set's design language (§1), its vocabulary
(§2), the completion-kind table (§3), and how the set is checked (§4).

## 1. The language

The set is drawn from the brand mark (`assets/brand/weft-mark.svg`): a
line of text that runs, wraps twice and ends at an insertion caret. Every
rule below is read off that mark.

### 1.1 Box and stroke

- **Box.** `viewBox="0 0 24 24"`. Centrelines live in **3..21**. The root
  carries `fill="none" stroke="currentColor" stroke-width="1.75"
  stroke-linecap="square" stroke-linejoin="round"`.
- **Stroke.** 1.75 units: a little lighter than Lucide's 2, close to the
  UI face's stem, because an icon sits beside a label.
- **Caps square, joins round.** These are the mark's own: a stroke ends
  like a cut thread, and bends inside a stroke are soft.
- **No fills.** Solid marks are built from strokes (§1.4).

### 1.2 One curve: the wrap turn

The mark turns with `c23 0 34 11 34 33`: a quarter turn of radius r whose
handles sit at **0.7 r**. A circular arc's handles sit at 0.552 r, so the
wrap turn is squarer than an arc. **It is the set's only curve.**

- A quarter turn from heading h1 to heading h2 with radius r, starting at
  p, ends at e = p + r·h1 + r·h2. Its handles are p + 0.7r·h1 and
  e − 0.7r·h2.
- **No circular arcs, ever.** Round things are squircles: four wrap turns
  around a square. The lens, the nodes, the rings and the dome are all
  squircles. A squircle's 45° point lies 0.7625 r out on each axis, which
  is where a lens's handle starts.
- A turn joins two strokes at a right angle. A bend at any other angle
  (a chevron's tip, a triangle's corner) is a round join, not a curve.

### 1.3 Ratios

- **Radii come from one scale**, multiples of 0.75:

  | name | r | used for |
  | --- | --: | --- |
  | corner | 1.5 | the corners of boxes, pages, frames, slots |
  | node | 2.25 | git nodes, loops, small lenses, the eye's pupil |
  | turn | 3 | the wrap at row pitch 6, brackets, small squircles |
  | wide | 4.5 | the page's curled corner, undo/redo's turn, the plug |
  | lens | 6 | the search lens, the bell's dome, the bulb |
  | ring | 7.5 | status rings (`circle`, `error`, `info`), `history` |
  | globe | 9 | `globe` |

- **Rows are 2r apart**, so one U-turn of radius r joins two rows exactly,
  as in the mark. Text rows use pitch 3, 4.5 or 6.
- **The page is 3:4** (x 5.25..18.75, y 3..21), with its top-right corner
  a wide wrap turn rather than a dog-ear.
- **Arrowheads** are open chevrons with 45° arms. The arm is 4.5 units on
  a full arrow, and 2.25 to 3 units on a badge or a turn's end.

### 1.4 Marks built from strokes

- **Dot.** A zero-length stroke, `M x y h0`. With square caps it is a
  square as wide as the stroke: the dots of `!`, `i` and the keyboard's
  keys.
- **Bead.** A squircle of radius corner or node (`more`, `dot`, the centre
  of `circle-dot`).

### 1.5 The thread and the accent

- **The thread.** Where a line changes direction, it stays one stroke
  through wrap turns. `undo` and `redo` are the thread doubling back;
  `list-tree` and `folder-tree` branch by turning.
- **The accent.** At most **one** element per icon is `class="accent"`.
  It marks where the action lands:
  - the caret in `terminal`, `rename`, `text-cursor-input`,
    `clipboard-paste` and `notebook-pen`;
  - the plus in `file-plus` and `folder-plus`;
  - the new divider in `split-right`, `split-down`, `sidebar` and
    `panel-bottom`;
  - the replacement row in `replace`;
  - the centre of `circle-dot` and `crosshair`;
  - the third swatch in `palette`.

  The caret is the mark's: an I-beam, a stroke with a serif at each end.
  **Completion kinds carry no accent.** A list of them stays calm.

### 1.6 Optical sizing

Chrome draws an icon at `round(min(ui line − 2, 0.95 × ui em))`, about
13 px at the default size. There one unit is about 0.54 px and the stroke
is about 0.95 px. So:

- two parallel strokes keep centrelines **at least 3 apart**;
- an enclosed counter is at least 2 units across inside its ink;
- about five distinct strokes at most in one glyph;
- a glyph's main body fills the live area in at least one direction.

## 2. Vocabulary

The same thing is drawn the same way in every glyph that has it:

| Element | Geometry | In |
| --- | --- | --- |
| page | 3:4, corners r 1.5, top-right a wide turn | `file`, `file-text`, `file-plus`, `file-search`, `kind-file` |
| folder | a tab stepping down through two corner turns | `folder`, `folder-plus`, `folder-open` (its back), `kind-folder` |
| frame | 18×16.5 at (3, 3.75), corners r 1.5 | `split-*`, `sidebar`, `panel-bottom`, `layout-dashboard`, `kind-class`, `kind-struct`, `kind-enum` |
| slot | 18×7.5 at (3, 8.25), corners r 1.5 | `kind-variable`, `kind-field`, `kind-property`, `kind-enum-member` |
| lens | squircle r 6 at (10.5, 10.5), handle from its 45° point to (20.25, 20.25) | `search`, `zoom-*`; smaller in `text-search`, `file-search` |
| ring | squircle r 7.5 at (12, 12) | `circle`, `circle-dot`, `error`, `info` |
| node | squircle r 2.25 | `git-*`, `share-2`, `scissors`, `command` |
| brackets | `( )` of two turn-radius turns | `kind-function` (a dot), `kind-method` (a row), `kind-constructor` (a plus) |
| tray | a U of corner turns | `upload`, `download` |
| caret | the I-beam (accent) | see §1.5 |
| text row | a horizontal stroke; ragged right means prose | `file`, `file-text`, `kind-text`, `format`, `list*`, `text-search` |

## 3. Completion kinds

LSP's `CompletionItemKind` is a number from 1 to 25. `icons.kind_names` maps
kind `k` to `kind_names[k - 1]`, and `icons.kindIcon(k)` does the lookup.
Kinds are told apart by silhouette first and by interior second.

| # | LSP kind | Icon | Drawing |
| --: | --- | --- | --- |
| 1 | Text | `kind-text` | three ragged rows |
| 2 | Method | `kind-method` | `( )` with a row inside |
| 3 | Function | `kind-function` | `( )` with a dot inside |
| 4 | Constructor | `kind-constructor` | `( )` with a plus inside |
| 5 | Field | `kind-field` | a slot with a dot |
| 6 | Variable | `kind-variable` | a slot holding a row |
| 7 | Class | `kind-class` | a frame with a header and one member row |
| 8 | Interface | `kind-interface` | a lollipop |
| 9 | Module | `kind-module` | braces `{ }` |
| 10 | Property | `kind-property` | a slot split key \| value |
| 11 | Unit | `kind-unit` | a ruler |
| 12 | Value | `kind-value` | `=` |
| 13 | Enum | `kind-enum` | a frame holding two rows |
| 14 | Keyword | `kind-keyword` | brackets `[ ]` |
| 15 | Snippet | `kind-snippet` | text around a placeholder box |
| 16 | Color | `kind-color` | three overlapping squircles |
| 17 | File | `kind-file` | the page |
| 18 | Reference | `kind-reference` | an arrow onto a node |
| 19 | Folder | `kind-folder` | the folder |
| 20 | EnumMember | `kind-enum-member` | a slot with a dot and a row |
| 21 | Constant | `kind-constant` | `=` in a box |
| 22 | Struct | `kind-struct` | a frame in three compartments |
| 23 | Event | `kind-event` | a lightning bolt |
| 24 | Operator | `kind-operator` | `±` |
| 25 | TypeParameter | `kind-type-parameter` | `<T>` |

## 4. Checks

`zig build test-gfx-only -Dtest-filter=icons` runs:

- every bundled set parses, with every icon inside its box;
- the weft set has every chrome name the Lucide table has, every `kind-*`
  name, and no name twice;
- every weft icon's points, stroke included, keep at least one unit inside
  the 24-unit box;
- `kindIcon` maps 1 to 25 and nothing else;
- every icon in both sets leaves ink at 14 px when drawn through the raster
  harness, each stroked as its root says, with its accent in the theme's
  accent. This test also writes the contact sheets to
  `.zig-cache/tmp/weft-icons-<set>.ppm`.

The View's test `theme/icons: ...` covers the switch: unbound gives weft,
`weft` and `lucide` pick their set, `none` turns icons off, and a misspelt
name changes nothing.

The reviewed sheet is `assets/icon-sets/weft-contact-sheet.png`, and
`lucide-contact-sheet.png` beside it is the same layout for Lucide, for
comparison. It shows every icon at 14, 16, 24 and 48 px, light on the
editor's background, drawn by weft's own renderer. To regenerate it, run
the test, then
`magick .zig-cache/tmp/weft-icons-weft.ppm assets/icon-sets/weft-contact-sheet.png`.
