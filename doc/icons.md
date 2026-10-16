# weft's icons

weft draws chrome icons from a bundled set chosen by `theme/icons`:
`lucide` (the default, Lucide's upstream files), `weft` (this set), or `none`.
An icon is stroke-style SVG in a 24-unit box, parsed once into scene path
commands (`src/gfx/icons.zig`) and drawn as one stroked path tinted by the
theme. The renderer ignores fill, colour, stroke width and transforms, so
everything below about the look is a rule for whoever draws, not something
the code enforces. The tests enforce what they can (§5).

This document is the weft set's style guide (§1-§3), the completion-kind
table (§4), and how the set is checked (§5).

## 1. Style

### 1.1 Grid and stroke

- **Box.** `viewBox="0 0 24 24"`. The root element always carries
  `fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"
  stroke-linejoin="round"`. The parser ignores these, but an SVG viewer
  needs them to show the file as weft does.
- **Stroke.** 2 units, round caps, round joins. No fills: a solid mark (a
  dot, a bullet) is built from strokes (§1.3).
- **Live area.** Centrelines lie in **3..21**, so ink lies in 2..22: two
  units of padding on every side. Round and pointed shapes (a full circle,
  a triangle's apex, an arrowhead) may overshoot by **one** unit (centreline
  2..22) to look as big as the square ones. Nothing goes further. The test
  holds every point, control points included, to 2..22.
- **Keylines.** Use these unless the subject needs otherwise:
  - circle: `r=9` about (12, 12), or `r=8` when something hangs off it;
  - square: 16×16 at (4, 4), `rx=2`;
  - landscape frame (window, panel, keyboard): 18×16 at (3, 4), `rx=2`;
  - portrait page: x 5..19, y 3..21.
- **Coordinates.** Use whole units for straight horizontal and vertical
  strokes. At 24 px and 48 px a whole-unit centreline gives a 2 px stroke
  exactly on the pixel grid, and at 14-16 px it spreads evenly. Use half
  units only where a circle or diagonal needs them.
- **Corners.** Containers 12 units or larger take `rx=2`. Small boxes take
  `rx=1` to `1.5`. Every other corner is the round join's (radius 1).

### 1.2 Optical sizing: what reads at 14 px

At the default UI size an icon is about 14 px, so one unit is 0.58 px and
the stroke is about 1.2 px. The rules that follow from that:

- **Clear space.** Two parallel strokes have at least **2 units** of clear
  space between their ink (centrelines 4 apart). Where the two must read as
  separate things, such as rows of a list or the panes of a layout, give them
  3 (centrelines 5-6 apart). Less than that merges into one grey bar at 14 px.
- **Counters.** An enclosed hole is at least 2 units across inside its ink
  (a circle of `r=2.5` or more), or it fills in.
- **Detail budget.** At most about five distinct strokes in one glyph.
  Anything that only reads at 48 px (ticks on a dial, the teeth of a key
  beyond two) is left out.
- **Sizes of a thing.** A glyph's main body fills the live area in at least
  one direction. A small glyph does not look "lighter", only lost.
- **Badges.** A modifier (plus, check, lens) sits in the lower-right
  quadrant. The base shape keeps 2 units of clear space around it, cut back
  where it has to be, so the badge never sits on another stroke.

### 1.3 Marks built from strokes

- **Stroke dot.** A zero-length stroke, `M x y h.01`: a round dot as wide as
  the stroke (2 units). Use it for bullets and the dots of `!` and `i`.
- **Small dot.** `circle r=.5`: a disc 3 units across, for several dots
  close together (`palette`).
- **Solid dot.** `circle r=1`: a disc 4 units across.
- **Large dot.** `circle r=1` plus `circle r=2` about the same centre: a
  disc 6 units across (`dot`, the middle of `circle-dot`).

### 1.4 The weft character

weft is weaving: threads, warp and weft, a line of text that wraps. The set
carries this only where it also helps the meaning, and plainly beats
ornamental every time.

- **The wrap.** The brand mark is a line that runs, turns and runs back.
  `format` is that line.
- **Threads and beads.** `settings` is three threads, each with a bead
  (sliders) instead of a gear. It reads at 14 px where a toothed gear turns
  into a smudge.
- **The crossing.** Where two strokes pass each other rather than join
  (the blades of `scissors`), the under stroke breaks. Its cap ends at
  least 3 units from the over stroke's centreline, which leaves one unit of
  clear space on each side. Use a crossing only where the strokes meet at
  45° or more; a shallow crossing needs a gap so long the shape falls
  apart. An interlaced `link` (two chain links over and under) was tried
  and dropped for that reason: at a link radius that fits the box, the two
  gaps eat most of each link's end.
- **The gap.** Two things that belong together but are apart keep a clear
  gap rather than a slash: `unplug` is the plug and its socket pulled
  apart on the diagonal.
- **Open ends.** Lines end in round caps, never in arrows or blobs that
  aren't part of the meaning.

## 2. Vocabulary

The same thing is drawn the same way in every glyph that has it:

| Element | Geometry | In |
| --- | --- | --- |
| page | `M15 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V7z`: a cut corner, no fold line | `file`, `file-text`, `file-plus`, `file-search`, `kind-file` |
| folder | `M3 6a2 2 0 0 1 2-2h4l2 3h8a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z` | `folder`, `folder-plus`, `folder-open` (its back), `kind-folder` |
| frame | `rect x=3 y=4 width=18 height=16 rx=2` | `split-right`, `split-down`, `sidebar`, `panel-bottom` |
| circle | `circle cx=12 cy=12 r=9` | `error`, `info`, `circle`, `circle-dot`, `globe` |
| chevron | arms of 6 at 45°: `m9 6 6 6-6 6` | `chevron-*` |
| arrow | 14-unit shaft, head arms of 5 to 6 | `arrow-*`, `upload`, `download`, `log-out` |
| tray | `M4 15v3a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-3` | `upload`, `download` |
| lens | ring `r=6` to `r=7` with a 45° handle to (20, 20) | `search`, `zoom-*`; smaller as the badge in `text-search`, `file-search` |
| plus badge | `M12 10.5v7`, `M8.5 14h7` (arms of 3.5) inside a container | `file-plus`, `folder-plus` |
| node | `circle r=3` on a branch line | `git-*`, `share-2` |
| bracket | open sides of a box: `[ ]`, `{ }`, `< >` | `kind-variable`, `kind-module`, `kind-type-parameter` |
| text line | a horizontal stroke; ragged right means prose | `file-text`, `kind-text`, `text-search`, `list*` |

## 3. Drawing a new icon

1. Start from the vocabulary. If the subject has a page, a folder or a
   frame, use that geometry unchanged.
2. Author with the elements the parser supports: `path` (all commands),
   `circle`, `ellipse`, `rect` (`rx`/`ry`), `line`, `polyline`, `polygon`.
   No `<g transform>`, no `<use>`, no comments with `>` in them.
3. Save it as `src/gfx/icons/weft/<chrome-name>.svg` and add
   `weftIcon("<chrome-name>")` to `icons.weft`.
4. Look at it at 14 px on the contact sheet (§5). If two strokes merge or a
   counter fills in, the drawing is wrong, not the size.

## 4. Completion kinds

LSP's `CompletionItemKind` is a number from 1 to 25. `icons.kind_names` maps
kind `k` to `kind_names[k - 1]`, and `icons.kindIcon(k)` does the lookup.
Kinds are told apart by silhouette first and by interior second, because at
14 px the interior is about four pixels across.

| # | LSP kind | Icon | Drawing |
| --: | --- | --- | --- |
| 1 | Text | `kind-text` | three ragged text lines |
| 2 | Method | `kind-method` | a cube (hexagon with its three edges) |
| 3 | Function | `kind-function` | an `ƒ` |
| 4 | Constructor | `kind-constructor` | the method's hexagon with a plus in place of its edges |
| 5 | Field | `kind-field` | a tag |
| 6 | Variable | `kind-variable` | `[x]` |
| 7 | Class | `kind-class` | a hierarchy: one box feeding two (sideways, so it is not `network`) |
| 8 | Interface | `kind-interface` | a lollipop: a ring on a stem (UML's provided interface) |
| 9 | Module | `kind-module` | braces `{ }` |
| 10 | Property | `kind-property` | an open-end spanner |
| 11 | Unit | `kind-unit` | a ruler |
| 12 | Value | `kind-value` | a diamond |
| 13 | Enum | `kind-enum` | a bulleted list |
| 14 | Keyword | `kind-keyword` | a key |
| 15 | Snippet | `kind-snippet` | a puzzle piece |
| 16 | Color | `kind-color` | a drop |
| 17 | File | `kind-file` | the page |
| 18 | Reference | `kind-reference` | a hooked arrow pointing on |
| 19 | Folder | `kind-folder` | the folder |
| 20 | EnumMember | `kind-enum-member` | one bullet in a pill |
| 21 | Constant | `kind-constant` | `=` in a box |
| 22 | Struct | `kind-struct` | three blocks, two over one wide |
| 23 | Event | `kind-event` | a lightning bolt |
| 24 | Operator | `kind-operator` | `±` |
| 25 | TypeParameter | `kind-type-parameter` | `<T>` |

## 5. Checks

`zig build test-gfx-only -Dtest-filter=icons` runs:

- every bundled set parses, with every icon inside its box;
- the weft set has every chrome name the Lucide table has, every `kind-*`
  name, and no name twice;
- every weft icon's points, stroke included, keep at least one unit inside
  the 24-unit box (§1.1);
- `kindIcon` maps 1 to 25 and nothing else;
- every icon in both sets leaves ink at 14 px when drawn through the raster
  harness. This test also writes the contact sheets to
  `.zig-cache/tmp/weft-icons-<set>.ppm`.

The View's test `theme/icons: ...` covers the switch: unbound gives Lucide,
`weft` and `lucide` pick their set, `none` turns icons off, and a misspelt
name changes nothing.

The reviewed sheet is `assets/icon-sets/weft-contact-sheet.png`, and
`lucide-contact-sheet.png` beside it is the same layout for Lucide, for
comparison. It shows
every icon at 14, 16, 24 and 48 px, light on the editor's background, drawn
by weft's own renderer. To regenerate it, run the test, then
`magick .zig-cache/tmp/weft-icons-weft.ppm assets/icon-sets/weft-contact-sheet.png`.
