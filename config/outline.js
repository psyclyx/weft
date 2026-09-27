// An outline docked on the right — a config FRAGMENT (`weft.use("outline")`),
// opt-in.
//
// Like the sidebar, "outline" is a named bundle of viewport attributes and one
// `weft.present` line: viewport + subject + projection (doc/model.md §2.4). The
// subject is the value of the `entry` context key — whatever the editor has in
// front of it — and `as: "symbols"` asks for that entry's SYMBOLS projection,
// which the `symbols` provider answers from the grammar's outline query (the
// same one the breadcrumbs read). Moving the editor to another entry presents
// that entry's symbols; a row jumps to its symbol in the editor.
weft.plugin("symbols");

weft.viewport("outline", {
  edge: "right",
  extent: 0.2,
  // Reached deliberately, never by cycling past it.
  cycles: false,
  // It owns its entry: a jump from a row lands in the editor, never here.
  persistent: true,
  // Focus landing here is not a primary-focus change, so the outline never
  // follows itself.
  followFocus: false,
});

weft.present("outline", { subject: { context: "entry" }, as: "symbols" });
