# The grammar tree weft searches at runtime (`WEFT_GRAMMAR_PATH`): one
# directory per grammar NAME, each laid out the way the nixpkgs packages are
# (`parser` plus `queries/highlights.scm`). Which languages exist is decided
# HERE and in config — weft itself has no list, and adding one is a name in
# grammar-names.nix plus a line in config/plugins/languages.js, not a change to
# any Zig source.
{
  linkFarm,
  tree-sitter-grammars,
  names ? import ./grammar-names.nix,
}:
linkFarm "weft-grammars" (
  map (n: {
    name = n;
    path = tree-sitter-grammars."tree-sitter-${n}";
  }) names
)
