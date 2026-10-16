# Docs popups, completion docs and soft wrap

The plan for hover docs that wrap, intellisense-style completion and
signature help (2026-10-15). The rule it is held to is the one every arc
here is: core gets doors, plugins get policy (`plugins-not-core`). Core
knows no hover, no signature and no completion item; it can wrap text,
render a markdown document in a popup at the caret, and tell a plugin the
caret moved or the mode changed.

## What is wrong today

- Hover is a caret surface of one row per line of the server's text: no
  wrapping (a long sentence runs off the window), raw markdown, 16 rows.
- The completion docs panel (`Surface.info`) splits on newlines, caps at 64
  columns without wrapping, and flips left over the list it belongs to.
- Signature help echoes its label; there is no popup and no trigger.
- `completionItem/resolve` is never sent: a server that sends docs lazily
  shows none.
- The completion UI is core (`core/complete_ui.zig`) — the outstanding P4
  of doc/rendering.md.
- The text pipeline does not wrap at all; a long line is cut at the pane's
  edge.

## Phases

1. **Soft wrap, in the text pipeline.** One source line lays out as one or
   more `VisualLine`s (`linelayout.layoutLine`), broken at a word boundary
   where there is one, a character where there is not; a continuation line
   is indented past the gutter. The geometry map, the caret, selections,
   clicks and visual up/down read segments; scrolling keeps the caret's
   segment on screen. Wrap is the PANE's (`Pane.wrap`, toggled by
   `window.toggle-wrap`); a pane that has not said follows its entry — an
   entry-scoped `view.wrap` (`on` | `off`) any plugin or config may set,
   else an entry read as prose (markdown) wraps. Popups always wrap.
2. **A document popup door.** A plugin's caret surface carries a MARKDOWN
   body (`Surface.info`, set through `wl_surface_doc`), rendered by the same
   markdown pipeline a markdown entry uses (`core/markdown.zig` and
   `linelayout`), wrapped to the popup's width, its syntax markers hidden
   (a popup is read, not edited). A surface with rows shows it beside them
   (the completion docs panel), never over them; a surface with none IS it
   (hover). A flag asks for the popup above the caret (signature help).
3. **The `lsp` plugin's policy.** Hover hands over the server's markdown;
   signature help is a popup above the caret, the active parameter marked
   up, opened by the server's `signatureHelpProvider.triggerCharacters`
   while typing and refreshed as the arguments are typed; each popup closes
   when the plugin decides, over two new signals: `caret.moved` and
   `mode.changed`. Completion kinds are named here (protocol knowledge).
4. **The completion UI out of core.** `core/complete_ui.zig` becomes the
   `complete` plugin's: it fires the caps session, folds results into an
   inline pick, and composes an item's docs (its detail as a code block, then
   its documentation). `completionItem/resolve` rides a provider door
   (`on_resolve` → `wl_caps_item_doc`) for the selected item.

Each phase lands with its e2e test before the next starts.
