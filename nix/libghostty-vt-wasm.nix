# libghostty-vt for the terminal PLUGIN: ghostty's VT emulator built for
# wasm32-freestanding as a static archive, linked into the terminal plugin's
# own .wasm (doc/terminal.md §2). Ghostty's own nix expression builds it; this
# only retargets it (wasm32, no SIMD — a sandboxed guest has neither libc nor
# highway) and keeps the archive plus the C headers in one output.
{
  callPackage,
  ghostty-src,
}:
(callPackage "${ghostty-src}/nix/libghostty-vt.nix" {
  optimize = "ReleaseSmall";
  simd = false;
  revision = builtins.substring 0 7 ghostty-src.revision;
}).overrideAttrs
  (old: {
    pname = "libghostty-vt-wasm32";
    zigBuildFlags = map (
      f: if f == "-Dcpu=baseline" then "-Dtarget=wasm32-freestanding" else f
    ) old.zigBuildFlags;
    outputs = [ "out" ];
    # Upstream's freestanding logger imports `env.log` for a browser host to
    # answer. A weft guest may import nothing outside `weft:abi/*`, so the
    # logger calls an ordinary symbol instead, which the plugin that links the
    # archive defines (src/plugins/terminal/vt.zig).
    postPatch = (old.postPatch or "") + ''
      substituteInPlace src/os/wasm/log.zig \
        --replace-fail 'extern "env" fn log(' 'extern fn ghostty_wasm_log(' \
        --replace-fail 'JS.log(' 'JS.ghostty_wasm_log('
    '';
    # The archive is wasm, not ELF: nothing to strip or patch.
    dontStrip = true;
    dontPatchELF = true;
    postInstall = ''
      rm -rf "$out/bin"
      mkdir -p "$out/include"
      cp -r ${ghostty-src}/include/ghostty "$out/include/"
    '';
    postFixup = "";
  })
