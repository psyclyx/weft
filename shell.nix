{
  pkgs ? import (import ./npins).nixpkgs { },
  # The terminal plugin's VT emulator: ghostty's libghostty-vt, built for
  # wasm32 and linked INTO the plugin (doc/terminal.md). default.nix's overlay
  # supplies the same derivation; standalone `nix-shell` builds it here.
  libghostty-vt-wasm ? pkgs.callPackage ./nix/libghostty-vt-wasm.nix {
    ghostty-src = (import ./npins).ghostty;
  },
}:
let
  # The grammar tree weft searches at runtime: one directory per grammar
  # NAME, each laid out the way the nixpkgs packages are (`parser` plus
  # `queries/highlights.scm`). Which languages exist is decided HERE and in
  # config — weft itself has no list, and adding one is a change to this
  # attrset, not to any Zig source.
  grammarNames = [
    "zig"
    "fennel"
    "lua"
    "nix"
    "javascript"
    "html"
  ];
  # The shell names upstream parser packages for the sample config. Query
  # selection lives in config/plugins/languages.js, which passes its own files to
  # grammar-add where an upstream package does not supply the desired query.
  grammarDir = pkgs.linkFarm "weft-grammars" (
    map (n: {
      name = n;
      path = pkgs.tree-sitter-grammars."tree-sitter-${n}";
    }) grammarNames
  );
in
pkgs.mkShell {
  packages = with pkgs; [
    zig_0_16
    zls # LSP: Zig (0.16, matches zig_0_16)

    # Build-time tools.
    pkg-config
    perl # Hermetic JSON::PP peer for the spine's LSP protocol gate.
    # Shells and a pager the terminal e2e tests run on a real pty: the shell
    # integration is injected into each (doc/terminal.md §7), so each is a
    # test dependency, not whatever the host happens to have.
    zsh
    fish
    less
    wayland-scanner
    # No renderer shader compiler is needed; Skia is the sole production
    # renderer.

    # Libraries Weft links against.
    wayland
    wayland-protocols
    libxkbcommon
    vulkan-loader
    vulkan-headers
    vulkan-validation-layers
    harfbuzz
    fontconfig # runtime font-family resolution (sans/mono, weight, slant)
    dejavu_fonts # deterministic embedded default mono face

    # Skia: the C++ 2D library. Ships a skia.pc, so build.zig
    # resolves it through pkg-config (include for the g++ shim, -L/-lskia for the
    # link) — as a buildInput its pkgconfig is on PKG_CONFIG_PATH automatically.
    skia

    # Syntax (milestone 7): incremental parsing + highlighting.
    tree-sitter

    # Wasm plugin runtime (milestone 5): wasmtime's C embedding API. The CLI
    # here compiles/inspects guest .wasm; build.zig links libwasmtime via the
    # dev/lib outputs below (wasmtime ships no pkg-config, so we point at the
    # paths directly — the same idiom as the grammar packages).
    wasmtime

    # Language servers for the sample config (phase 2: zls is already
    # above for dev; fennel-ls is the second-server demonstration).
    fennel-ls

    # Formatting / dev ergonomics (treefmt.toml drives nixfmt + zig fmt).
    treefmt
    nixfmt
    deadnix
    statix
    nixd
  ];

  LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath (
    with pkgs;
    [
      wayland
      libxkbcommon
      vulkan-loader
      harfbuzz
      fontconfig
      wasmtime.lib # libwasmtime.so at runtime (test + run)
      skia # libskia.so at runtime (the renderer shim links it)
      stdenv.cc.cc.lib # libstdc++.so.6 for the Skia C++ shim at runtime
    ]
  );

  # Wasmtime C embedding API: headers (dev) + libwasmtime.so (lib). No
  # pkg-config is shipped, so build.zig consumes these paths directly.
  WEFT_WASMTIME_DEV = "${pkgs.wasmtime.dev}";
  WEFT_WASMTIME_LIB = "${pkgs.wasmtime.lib}";

  # Renderer-independent default font bytes. Keeping this in the pinned Nix
  # environment makes layout/test geometry deterministic on Linux and Darwin;
  # the runtime provider remains free to resolve optional prose faces natively.
  WEFT_DEFAULT_MONO = "${pkgs.dejavu_fonts}/share/fonts/truetype/DejaVuSansMono.ttf";

  # QuickJS-ng source (milestone 5 / 06B): user config runs as `config.js` in
  # `quickjs.wasm`. build.zig compiles the engine to a wasm32-wasi reactor with
  # `zig cc` from this unpacked source (srcOnly → the .c/.h tree), then embeds
  # the module. Pinned store path, same env-var idiom as the grammars.
  WEFT_QUICKJS_NG_SRC = "${pkgs.srcOnly pkgs.quickjs-ng}";

  # libghostty-vt for wasm32: the archive build.zig links into the terminal
  # plugin, and the C headers it is compiled against.
  WEFT_GHOSTTY_VT_WASM = "${libghostty-vt-wasm}";

  # The shell integration the terminal plugin injects (nix/shell-integration.nix):
  # build.zig bakes this path into the plugin.
  WEFT_SHELL_INTEGRATION = "${pkgs.callPackage ./nix/shell-integration.nix { }}";

  # Where weft looks up a grammar BY NAME (colon-separated, like PATH). One
  # variable, not one per language: weft ships no list of languages, so the
  # set that exists is whatever this directory holds and config asks for.
  WEFT_GRAMMAR_PATH = "${grammarDir}";

  # Let the Vulkan loader find the host ICDs on NixOS.
  XDG_DATA_DIRS = "/run/opengl-driver/share";
}
