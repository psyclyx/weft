// The undo history as a tree, docked on the right — a config FRAGMENT
// (`weft.use("undo")`), opt-in.
//
// Like the outline, "undo" is a named bundle of viewport attributes and one
// `weft.present` line (doc/model.md §2.4): the subject is the `entry` context
// key — whatever the editor has in front of it — and `as: "undo-tree"` asks
// for that entry's undo tree, which the `undo_tree` provider draws as a graph:
// a dot a step, a branch wherever a step followed an undo, the step you are
// at marked. Moving the editor to another entry presents that entry's tree;
// a click on a dot, or Return on it, brings the entry to that step
// (doc/undo.md). It starts hidden; `undo-tree.open` shows and hides it.
weft.plugin("undo_tree");

weft.viewport("undo", {
  edge: "right",
  extent: 0.22,
  // Reached deliberately, never by cycling past it.
  cycles: false,
  // It owns its entry: moving to a step moves the editor, never this.
  persistent: true,
  // Focus landing here is not a primary-focus change, so the tree keeps
  // describing the editor while you walk it.
  followFocus: false,
  shown: false,
});

weft.present("undo", { subject: { context: "entry" }, as: "undo-tree" });

// Which viewport `undo-tree.open` shows — the name above.
weft.set("undo_tree", "viewport", "undo");
