# Toolchain for the weft e2e suite. The suite drives weft as a human would, so it
# shells out to the same real tools an editor session uses: a language server
# (zls) for hover/goto-definition, a Debug Adapter (lldb-dap) for a real debug
# session, plus the subprocess tools the proc-backed plugins rely on (ripgrep,
# git, node) and zig itself (build + `zig fmt` for the format action).
#
# Enter it before running the suite so the tools are on PATH for the proc
# children (which inherit weft's environment):
#
#     nix-shell src/e2e/shell.nix --run 'zig build test'
#
# Tests that need a specific tool probe for it and skip cleanly when it is absent,
# so `zig build test` still passes outside this shell — but LSP/DAP coverage only
# runs with the toolchain present.
#
# `zig` itself is intentionally NOT pinned here: the project tracks a specific zig
# (0.16) that a channel would shadow/downgrade, so the build uses the repo's zig
# and this shell only supplies the tools weft shells out to at runtime.
{
  pkgs ? import <nixpkgs> { },
}:

pkgs.mkShell {
  packages = [
    pkgs.zls # zig language server → LSP hover / goto-definition / symbols
    pkgs.lldb # provides lldb-dap → a real Debug Adapter Protocol server
    pkgs.nodejs # run .js programs; the DAP/ACP JS plugins
    pkgs.ripgrep # the grep plugin's backend
    pkgs.git # the git plugin / magit
  ];
}
