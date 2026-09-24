let
  npins = import ./npins;

  # No nix package yet: weft's Stemma Zig dependency is a path dep into the
  # monorepo checkout, which a sandboxed nix build cannot reach. Once
  # psyclyx/stemma is pushed, it becomes an npins pin consumed
  # via `zig build --system` (the goop pattern) and a nix/weft.nix package
  # lands here. Until then: `nix-shell` + `zig build` is the build.
  mkPackages = _pkgs: { };

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
  shell = import ./shell.nix { pkgs = finalPkgs; };
}
