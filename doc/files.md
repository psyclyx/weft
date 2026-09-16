# Files explorer

The explorer presents filesystem objects with the compact dired appearance:
muted permissions and size, colored names, directory suffixes, and inline fold
arrows. Narrow panes hide metadata to leave room for names. Those decorations
are never part of a filename or an editable document.

Return on a directory changes the location of the current explorer entry.
Minus goes to its container; Tab expands or collapses a directory inline.
Each visited directory retains its draft, expanded rows, and field state; the
entry remembers a cursor for each view. Return on a file uses ordinary workspace
placement, including opening from a sidebar into the primary pane. Navigation
does not apply or discard drafts. Apply/save uses the existing confirmation;
revert discards the current directory's draft.

`plugin_lib/files/model.zig` owns drafts and filesystem plans. The adapter
publishes retained scenes, fields, and revision-stamped targets. The presenter
in `gfx/view/semantic.zig` supplies rows, scrolling, selection, and caret geometry.
Every pane receives its own scene, including unfocused panes. A files workspace
entry has no `Editor`, text document, or text projection to parse back.

A view's advertised activation gets first refusal before the generic linked
resource opener. A provider's target/container navigation outcome reuses the
current semantic entry; direct workspace opens retain their normal semantics.
Targets, directory drafts, workspace entries, and viewport placement have
independent lifetimes.

Run `zig build test-explorer test-files-model` for the focused regressions and
`zig build test` for the full suite. Tests cover object-only entries, buffer count,
drafts and cursor restoration across navigation, field editing, folding,
transfers, permissions, sidebar placement, and scrolling past one screen.
