{
  pkgs ? import (import ./npins).nixpkgs { },
}:
pkgs.mkShell {
  packages = with pkgs; [
    zig_0_16
    zls # LSP: Zig (0.16, matches zig_0_16)

    # Build-time tools.
    pkg-config
    wayland-scanner
    shader-slang # slangc, for snail shader compilation (render milestone)

    # Libraries scion (and snail through it) links against.
    wayland
    wayland-protocols
    libxkbcommon
    vulkan-loader
    vulkan-headers
    vulkan-validation-layers
    harfbuzz

    # Scripting (milestone 5): per-plugin Lua VMs, fennel compiled in.
    lua5_4
    lua54Packages.fennel

    # Syntax (milestone 7): incremental parsing + highlighting.
    tree-sitter

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
      lua5_4
    ]
  );

  # build.zig embeds fennel.lua from the pinned package (hermetic: the
  # path always comes from the npins nixpkgs, never ambient state).
  SCION_FENNEL_LUA = "${pkgs.lua54Packages.fennel}/share/lua/5.4/fennel.lua";

  # Grammar packages (parser shared object + queries/highlights.scm).
  # The parser paths are baked in for runtime dlopen; the queries are
  # embedded at build time. Pinned store paths, not ambient state.
  SCION_TS_ZIG = "${pkgs.tree-sitter-grammars.tree-sitter-zig}";
  SCION_TS_FENNEL = "${pkgs.tree-sitter-grammars.tree-sitter-fennel}";
  SCION_TS_LUA = "${pkgs.tree-sitter-grammars.tree-sitter-lua}";
  SCION_TS_NIX = "${pkgs.tree-sitter-grammars.tree-sitter-nix}";

  # Let the Vulkan loader find the host ICDs on NixOS.
  XDG_DATA_DIRS = "/run/opengl-driver/share";
}
