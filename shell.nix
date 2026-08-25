{
  pkgs ? import (import ./npins).nixpkgs { },
}:
pkgs.mkShell {
  packages = with pkgs; [
    zig_0_16
    zls # LSP: Zig (0.16, matches zig_0_16)

    # Build-time tools.
    pkg-config
    perl # Hermetic JSON::PP peer for the spine's LSP protocol gate.
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

  # Grammar packages (parser shared object + queries/highlights.scm).
  # The parser paths are baked in for runtime dlopen; the queries are
  # embedded at build time. Pinned store paths, not ambient state.
  WEFT_TS_ZIG = "${pkgs.tree-sitter-grammars.tree-sitter-zig}";
  WEFT_TS_FENNEL = "${pkgs.tree-sitter-grammars.tree-sitter-fennel}";
  WEFT_TS_LUA = "${pkgs.tree-sitter-grammars.tree-sitter-lua}";
  WEFT_TS_NIX = "${pkgs.tree-sitter-grammars.tree-sitter-nix}";
  WEFT_TS_JAVASCRIPT = "${pkgs.tree-sitter-grammars.tree-sitter-javascript}";
  WEFT_TS_HTML = "${pkgs.tree-sitter-grammars.tree-sitter-html}";

  # Let the Vulkan loader find the host ICDs on NixOS.
  XDG_DATA_DIRS = "/run/opengl-driver/share";
}
