# Build weft for macOS from Linux: the same `zig build` a Mac runs, linked
# against the real thing — the macOS SDK and nixpkgs' Darwin builds of Skia,
# HarfBuzz, Tree-sitter and Wasmtime, all substituted from the binary cache
# (nothing here is built for Darwin locally). It cannot RUN the result; it
# proves the macOS port compiles, links, and resolves every symbol.
#
#   nix-shell nix/macos-cross.nix --run 'zig build -Dtarget=aarch64-macos'
#   nix-shell nix/macos-cross.nix --run 'zig build -Dtarget=aarch64-macos test --skip-foreign-checks'
#
# `darwinSystem` picks the architecture (x86_64-darwin for Intel Macs); pass
# the matching `-Dtarget`.
{
  sources ? import ../npins,
  pkgs ? import sources.nixpkgs { },
  darwinSystem ? "aarch64-darwin",
}:
let
  darwin = import sources.nixpkgs { system = darwinSystem; };
  native = import ../shell.nix { inherit pkgs; };
  # Every library the build links, as Darwin binaries: only their pkg-config
  # files and store paths are used here, so substitution is all it takes.
  darwinLibs = with darwin; [
    skia
    harfbuzz
    tree-sitter
  ];
in
pkgs.mkShellNoCC {
  packages = with pkgs; [
    zig_0_16
    pkg-config
  ];

  # pkg-config answers with the Darwin libraries, and only those: nothing from
  # the Linux toolchain may leak into a Mach-O link.
  PKG_CONFIG_PATH = pkgs.lib.makeSearchPathOutput "dev" "lib/pkgconfig" darwinLibs;
  PKG_CONFIG_LIBDIR = "";
  SDKROOT = "${darwin.apple-sdk_15.sdkroot}";
  # The system libc++ (headers + the /usr/lib/libc++.1.dylib stub) that
  # nixpkgs keeps beside the SDK, and Darwin Skia links.
  WEFT_LIBCXX = "${darwin.stdenv.cc.libcxx}";
  WEFT_WASMTIME_DEV = "${darwin.wasmtime.dev}";
  WEFT_WASMTIME_LIB = "${darwin.wasmtime.lib}";

  # Target-independent inputs — a font file, sources compiled to wasm, data —
  # are the native shell's own.
  inherit (native)
    WEFT_DEFAULT_MONO
    WEFT_QUICKJS_NG_SRC
    WEFT_GHOSTTY_VT_WASM
    WEFT_SHELL_INTEGRATION
    WEFT_GRAMMAR_PATH
    ;
}
