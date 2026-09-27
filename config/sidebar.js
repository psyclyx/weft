// A docked files sidebar — a config FRAGMENT (`weft.use("sidebar")`).
//
// "Sidebar" is a named BUNDLE of viewport attributes, not a kind the
// workspace knows (doc/cwa-config-decisions.md D1). Every line here is
// manifest data: declarations the resolver and explain() read, with no
// interposing behavior anywhere — no hook in the keystroke path, no
// window-management code, no plugin of its own.
weft.viewport("sidebar", {
  edge: "left",
  extent: 0.25,
  // Out of `focus-other`'s rotation: you reach it deliberately, never by
  // cycling past it.
  cycles: false,
  // It owns its entry — an open that lands elsewhere never drags it off its
  // root, and what you navigate to inside it stays until what it follows
  // moves.
  persistent: true,
  // Focus landing here is not a primary-focus change, so nothing that
  // follows the primary context hears it (and cannot chase itself).
  followFocus: false,
});

// What the sidebar shows FOLLOWS the editor, as data (doc/model.md §2.5): the
// subject is the current value of ONE context key, never an expression. The
// `place` key is the designation of the place the editor's entry is in — a
// local project (`weft://here/dir/…`), a peer's shared tree
// (`weft://<peer>/dir/`) — so the files provider lists wherever you are
// working, and moves when you move. `reveal` highlights the editor's own
// entry inside that tree (opening the folders above it) without taking the
// keys from the editor. Where there is no place (a scratch buffer), the
// sidebar says so instead of showing the last one.
weft.present("sidebar", { subject: { context: "place" }, reveal: { context: "entry" } });

// The alternative: the PLACES you are working in — the places of your open
// entries, the trees connected peers share with you — as one list, each a
// row that opens that tree. Swap it in for the line above:
// weft.present("sidebar", { subject: "weft://here/places/all", reveal: { context: "place" } });
