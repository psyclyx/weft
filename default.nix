let
  npins = import ./npins;

  # No nix package yet: weft's Zig dependencies (snail, stemma) are path
  # deps into the monorepo checkout, which a sandboxed nix build cannot
  # reach. Once psyclyx/stemma is pushed, both become npins pins consumed
  # via `zig build --system` (the goop pattern) and a nix/weft.nix package
  # lands here. Until then: `nix-shell` + `zig build` is the build.
  mkPackages = _pkgs: { };

  overlay = final: _prev: mkPackages final;
in
{
  nixpkgs ? npins.nixpkgs,
  pkgs ? import nixpkgs { },
}:
let
  finalPkgs = pkgs.extend overlay;
in
{
  packages = mkPackages finalPkgs;
  inherit overlay;
  shell = import ./shell.nix { pkgs = finalPkgs; };
}
