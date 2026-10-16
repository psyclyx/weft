{
  buildPackages,
  callPackage,
  dejavu_fonts,
  expat,
  fontconfig,
  freetype,
  harfbuzz,
  lib,
  pkg-config,
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
  # buildPackages: the icon is rasterized on the build host (a cross build too).
  macos-icon = buildPackages.callPackage ./macos-icon.nix { };
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
    # Skia is compiled from source (build.zig.zon, fetched by
    # build.zig.zon.nix); FreeType and expat are the libraries it calls.
    freetype
    expat
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
  ]
  ++ lib.optionals isDarwin [ apple-sdk_15 ];
  WEFT_WASMTIME_DEV = "${wasmtime.dev}";
  WEFT_WASMTIME_LIB = "${wasmtime.lib}";
  WEFT_DEFAULT_MONO = "${dejavu_fonts}/share/fonts/truetype/DejaVuSansMono.ttf";
  WEFT_QUICKJS_NG_SRC = "${srcOnly quickjs-ng}";
  WEFT_GHOSTTY_VT_WASM = "${libghostty-vt-wasm}";
  WEFT_SHELL_INTEGRATION = "${weft-shell-integration}";
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
  # The reference configs ship beside the binary, so `--config
  # $out/share/weft/config/config.js` works from any directory (the
  # home-manager module defaults to exactly that). Their `languages.query-root`
  # names the repo's `assets`, which resolves against the working directory;
  # the installed copy names the installed queries instead, and fails the build
  # if a config stops saying it the way this expects.
  postInstall = ''
    install -Dm644 LICENSE $out/share/licenses/weft/LICENSE
    mkdir -p $out/share/weft
    cp -r config $out/share/weft/config
    install -Dm644 -t $out/share/weft/queries assets/*.scm
    for f in config helix ide; do
      substituteInPlace $out/share/weft/config/$f.js --replace-fail \
        'weft.set("languages", "query-root", "assets");' \
        'weft.set("languages", "query-root", "'"$out"'/share/weft/queries");'
    done
  ''
  # The bundle's icon (CFBundleIconFile in packaging/macos/Info.plist).
  + lib.optionalString isDarwin ''
    install -Dm644 ${macos-icon} $out/Applications/weft.app/Contents/Resources/weft.icns
  '';
  meta = {
    description = "Weft text editor";
    license = lib.licenses.mit;
    mainProgram = "weft";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
})
