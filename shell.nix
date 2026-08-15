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

  # Let the Vulkan loader find the host ICDs on NixOS.
  XDG_DATA_DIRS = "/run/opengl-driver/share";
}
