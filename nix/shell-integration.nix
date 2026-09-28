# weft's shell integration (doc/terminal.md §7): the scripts the terminal
# plugin injects into zsh, bash and fish — prompt/command marks (OSC 133), the
# working directory (OSC 7), the title, and the command-line sync — as one
# directory, so they reach the runtime wherever weft is installed. The plugin
# bakes this path in at build time (`WEFT_SHELL_INTEGRATION`, build.zig); the
# same variable in the environment overrides it at spawn.
#
# These are weft's own scripts (MIT). Ghostty's (pinned in npins) were read
# for the injection technique, not copied: its zsh and bash integrations are
# GPLv3, derived from kitty's.
{ runCommand }:
runCommand "weft-shell-integration" { } ''
  cp -r ${../src/plugins/terminal/shell} $out
  chmod -R u+w $out
  chmod +x $out/launch
''
