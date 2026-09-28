// semantic.js — the structured-view group, `SPC v`, as a config FRAGMENT
// (`weft.use("semantic")`). config.js and helix.js both import it, so the
// group is the same keys under either grammar.
//
// Only generic structural scenes get this group. Dedicated tool modes (git,
// output, picker) keep their own smaller maps, so these actions do not appear
// in source files or generated listings. A scene may still decline a relevant
// intention it does not offer. Dialog inputs belong to the active interaction.
//
// WHICH MODES. A fragment is evaluated on its own, as its own manifest, and
// takes no arguments — it cannot be told which grammar the importing config
// loads. So it binds into every grammar's STRUCTURAL LAYER: the mode each
// grammar declares (`weft.bindingVariant`) that its resting mode binds
// through in a listing. A layer whose grammar is not loaded is never looked
// up, so the rows for it are inert. Adding a grammar is one more name here.
var layers = ["normal-structural", "helix-structural"];

// Both groups are eval-time code building manifest data: adding another view
// action is one row, and a plugin never needs to know which tool or config
// supplied the binding.
function bindActionGroup(mode, prefix, bindings) {
  for (var i = 0; i < bindings.length; i++) {
    var binding = bindings[i];
    // Semantic action names are an open plugin/view protocol; declaring the
    // command here keeps the table data-shaped.
    weft.semanticAction(binding[1]);
    weft.bind(mode, prefix + " " + binding[0], binding[1]);
  }
}

// An open action name is declared HERE, not by a plugin, so what a person
// reads for it is said here too: `weft.command(id, {…})` describes any
// command at the config tier (doc/chrome.md §1.2). The standard names
// (`view.refresh`, `selection.delete`, …) are core's and describe themselves.
weft.command("workspace.set-working-target", { label: "Use as Working Target", summary: "Make the focused target this head's working location." });
weft.command("fs.edit-permissions", { label: "Edit Permissions", summary: "Edit the focused entry's permissions." });
weft.command("fs.create-file", { label: "New File", icon: "file-plus", summary: "Create a file beside the focused entry." });
weft.command("fs.create-directory", { label: "New Folder", icon: "folder-plus", summary: "Create a directory beside the focused entry." });

// Where a standard intention already covers the operation, the key binds the
// INTENTION: the focused view's own vocabulary publishes the offer, so no
// trampoline command has to exist for the name at all.
function bindIntentionGroup(mode, prefix, bindings) {
  for (var i = 0; i < bindings.length; i++) {
    weft.bind(mode, prefix + " " + bindings[i][0], [bindings[i][1]]);
  }
}

layers.forEach(function (mode) {
  weft.group(mode, "SPC v", "Structured actions");
  weft.bind(mode, "SPC v j", "cursor.down");
  weft.bind(mode, "SPC v k", "cursor.up");
  bindIntentionGroup(mode, "SPC v", [
    ["o", "std.target.activate"],
    ["-", "std.hierarchy.step-out"],
    ["TAB", "std.hierarchy.toggle-expanded"],
    ["y", "std.transfer.yank"],
    ["x", "std.transfer.delete-to-register"],
    ["p", "std.transfer.paste"],
  ]);
  // The residue: operations no standard intention names yet, still reached by
  // their open action name. This list shrinks as the vocabulary grows.
  bindActionGroup(mode, "SPC v", [
    ["c", "workspace.set-working-target"],
    ["e", "field.edit"],
    ["d", "selection.delete"],
    ["m", "fs.edit-permissions"],
    ["n", "fs.create-file"],
    ["N", "fs.create-directory"],
    ["P", "selection.paste-before"],
    ["r", "view.refresh"],
    ["R", "view.revert"],
    ["a", "view.apply"],
  ]);
});
