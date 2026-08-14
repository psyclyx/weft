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
    ]
  );

  # Let the Vulkan loader find the host ICDs on NixOS.
  XDG_DATA_DIRS = "/run/opengl-driver/share";
}
