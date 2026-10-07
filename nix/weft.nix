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
  apple-sdk_15,
  quickjs-ng,
  libghostty-vt-wasm,
  weft-shell-integration,
  srcOnly,
  zig_0_16,
}:
let
  inherit (stdenv.hostPlatform) isLinux isDarwin;
in
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
  ]
  ++ lib.optionals isLinux [ wayland-scanner ];
  # Linux: Wayland + Vulkan + fontconfig. macOS: AppKit, OpenGL and CoreText
  # come from the SDK (build.zig reads SDKROOT, which apple-sdk exports).
  buildInputs = [
    harfbuzz
    skia
    tree-sitter
    wasmtime
  ]
  ++ lib.optionals isLinux [
    wayland
    wayland-protocols
    libxkbcommon
    vulkan-loader
    vulkan-headers
    fontconfig
    stdenv.cc.cc.lib
  ]
  ++ lib.optionals isDarwin [ apple-sdk_15 ];
  WEFT_WASMTIME_DEV = "${wasmtime.dev}";
  WEFT_WASMTIME_LIB = "${wasmtime.lib}";
  WEFT_DEFAULT_MONO = "${dejavu_fonts}/share/fonts/truetype/DejaVuSansMono.ttf";
  WEFT_QUICKJS_NG_SRC = "${srcOnly quickjs-ng}";
  WEFT_GHOSTTY_VT_WASM = "${libghostty-vt-wasm}";
  WEFT_SHELL_INTEGRATION = "${weft-shell-integration}";
  # The system libc++ Darwin Skia links (see shell.nix).
  WEFT_LIBCXX = lib.optionalString isDarwin "${stdenv.cc.libcxx}";
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
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
})
