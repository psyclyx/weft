{
  callPackage,
  dejavu_fonts,
  fontconfig,
  harfbuzz,
  lib,
  pkg-config,
  skia,
  stdenv,
  tree-sitter,
  vulkan-headers,
  vulkan-loader,
  wasmtime,
  wayland,
  wayland-protocols,
  wayland-scanner,
  libxkbcommon,
  quickjs-ng,
  srcOnly,
  zig_0_16,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "weft";
  version = "0.0.0";
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../build.zig
      ../build.zig.zon
      ../src
      ../config
      ../assets
      ../packaging
      ../LICENSE
    ];
  };
  deps = callPackage ../build.zig.zon.nix { };
  nativeBuildInputs = [
    zig_0_16.hook
    pkg-config
    wayland-scanner
  ];
  buildInputs = [
    wayland
    wayland-protocols
    libxkbcommon
    vulkan-loader
    vulkan-headers
    harfbuzz
    fontconfig
    skia
    tree-sitter
    wasmtime
    stdenv.cc.cc.lib
  ];
  WEFT_WASMTIME_DEV = "${wasmtime.dev}";
  WEFT_WASMTIME_LIB = "${wasmtime.lib}";
  WEFT_DEFAULT_MONO = "${dejavu_fonts}/share/fonts/truetype/DejaVuSansMono.ttf";
  WEFT_QUICKJS_NG_SRC = "${srcOnly quickjs-ng}";
  # Grammar and query selection belong to config or trusted language plugins.
  # A packaged editor has no built-in language set.
  WEFT_GRAMMAR_PATH = "";
  zigBuildFlags = [
    "--system"
    "${finalAttrs.deps}"
    "-Dcpu=baseline"
    "--release=fast"
  ];
  dontSetZigDefaultFlags = true;
  postInstall = ''
    install -Dm644 LICENSE $out/share/licenses/weft/LICENSE
  '';
  meta = {
    description = "Weft text editor";
    license = lib.licenses.mit;
    mainProgram = "weft";
    platforms = lib.platforms.linux;
  };
})
