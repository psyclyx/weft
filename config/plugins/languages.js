// Sample language setup. This trusted JS plugin registers parser packages and
// chooses Weft's query files; the editor package itself ships no grammars.
// `WEFT_GRAMMAR_PATH` locates the parser packages. The config value
// `languages.query-root` points at the directory containing Weft's .scm files.
const root = weft.config("query-root") || "assets";
const query = name => root + "/" + name + ".scm";

weft.run("syntax.add-grammar", ".zig", "zig", "tree_sitter_zig", "", query("zig-outline"));
weft.run("syntax.add-grammar", ".fnl", "fennel", "tree_sitter_fennel", query("fennel-highlights"));
weft.run("syntax.add-grammar", ".lua", "lua", "tree_sitter_lua", "", query("lua-outline"));
weft.run("syntax.add-grammar", ".nix", "nix", "tree_sitter_nix");
weft.run("syntax.add-grammar", ".js,.jsx,.mjs,.cjs", "javascript", "tree_sitter_javascript", "", query("javascript-outline"));
weft.run("syntax.add-grammar", ".html,.htm", "html", "tree_sitter_html");
