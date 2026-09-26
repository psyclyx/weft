// Sample language setup. This trusted JS plugin registers parser packages and
// chooses Weft's query files; the editor package itself ships no grammars.
// `WEFT_GRAMMAR_PATH` locates the parser packages. The config value
// `languages.query-root` points at the directory containing Weft's .scm files.
const root = weft.config("query-root") || "assets";
const query = name => root + "/" + name + ".scm";

weft.run("grammar-add", ".zig", "zig", "tree_sitter_zig", "", query("zig-outline"));
weft.run("grammar-add", ".fnl", "fennel", "tree_sitter_fennel", query("fennel-highlights"));
weft.run("grammar-add", ".lua", "lua", "tree_sitter_lua", "", query("lua-outline"));
weft.run("grammar-add", ".nix", "nix", "tree_sitter_nix");
weft.run("grammar-add", ".js,.jsx,.mjs,.cjs", "javascript", "tree_sitter_javascript", "", query("javascript-outline"));
weft.run("grammar-add", ".html,.htm", "html", "tree_sitter_html");
