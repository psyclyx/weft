let
  npins = import ./npins;

  mkPackages = pkgs: {
    weft = pkgs.callPackage ./nix/weft.nix { };
    # The terminal plugin's VT emulator (doc/terminal.md).
    libghostty-vt-wasm = pkgs.callPackage ./nix/libghostty-vt-wasm.nix { ghostty-src = npins.ghostty; };
    # The scripts the terminal plugin injects into a shell (doc/terminal.md).
    weft-shell-integration = pkgs.callPackage ./nix/shell-integration.nix { };
  };

  overlay = final: _prev: mkPackages final;
in
{
  sources ? npins,
  nixpkgs ? sources.nixpkgs,
  # External dep — stemma is consumed as a Zig *source* via
  # `zig build --system` (the goop pattern); default to weft's own pin.
  stemma ? npins.stemma,
  pkgs ? import nixpkgs { },
  ...
}:
let
  # Surface stemma by name so build.zig.zon.nix's `stemma` callPackage arg
  # resolves it (the shoal pattern).
  finalPkgs = (pkgs.extend (_: _: { inherit stemma; })).extend overlay;
in
{
  packages = mkPackages finalPkgs;
  inherit overlay;
  # `programs.weft`: weft wrapped to run config/config.js (or a config of your
  # own), with its grammars and language servers — and weft.app on macOS.
  homeManagerModules.default = import ./nix/hm-module.nix;
  shell = import ./shell.nix {
    pkgs = finalPkgs;
    inherit (finalPkgs) libghostty-vt-wasm;
  };
}
