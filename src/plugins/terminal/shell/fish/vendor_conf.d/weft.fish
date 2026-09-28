# weft.fish — found through XDG_DATA_DIRS, which `launch` put weft's
# directory at the front of. It puts XDG_DATA_DIRS back, then tells weft
# (doc/terminal.md §7):
#
#   OSC 133 A / B    a prompt starts / the command line starts
#   OSC 133 C        the command line was accepted
#   OSC 133 D;N      the command finished with status N
#   OSC 7            the working directory, file://host/path
#
# Then ${XDG_CONFIG_HOME:-~/.config}/weft/shell/fish is sourced when it
# exists — at the first prompt, after the user's config.fish.

if set -q WEFT_FISH_XDG_DATA_DIRS
    set -gx XDG_DATA_DIRS $WEFT_FISH_XDG_DATA_DIRS
    set -e WEFT_FISH_XDG_DATA_DIRS
else
    set -e XDG_DATA_DIRS
end

status is-interactive; or exit 0

function __weft_report_pwd
    printf '\e]7;file://%s%s\a' (hostname) (string replace -a ' ' '%20' -- (string replace -a '%' '%25' -- $PWD))
end

function __weft_prompt --on-event fish_prompt
    if set -q __weft_running
        printf '\e]133;D;%s\a' $__weft_status
        set -e __weft_running
    end
    __weft_report_pwd
end

function __weft_preexec --on-event fish_preexec
    printf '\e]133;C\a'
    set -g __weft_running 1
end

function __weft_postexec --on-event fish_postexec
    set -g __weft_status $status
end

# The prompt marks go around the prompt the user's config set, so they are
# added at the first prompt, after config.fish.
function __weft_init --on-event fish_prompt
    functions -e __weft_init
    if functions -q fish_prompt
        functions -c fish_prompt __weft_user_prompt
        function fish_prompt
            printf '\e]133;A\a'
            __weft_user_prompt
            printf '\e]133;B\a'
        end
    end
    set -l hook (set -q XDG_CONFIG_HOME; and echo $XDG_CONFIG_HOME; or echo $HOME/.config)/weft/shell/fish
    test -r $hook; and source $hook
end

# The title: the directory at a prompt, as the other shells say it — unless
# the user's config defined its own fish_title (fish's own lives under
# functions/, on disk or embedded).
function __weft_title_init --on-event fish_prompt
    functions -e __weft_title_init
    set -l src (functions --details fish_title)
    if test "$src" = n/a; or string match -q -- "*functions/fish_title.fish" $src
        function fish_title
            string replace -r -- "^$HOME" '~' $PWD
        end
    end
end

# ── The command line (doc/terminal.md §8) ─────────────────────────────
# As bash: fish has no redraw hook, so it reports when asked —
#   OSC 7780 ; line ; SEQ ; CURSOR ; HEX     (CURSOR in bytes)
# on ESC [ 7781 ~, and weft sets the line with ESC [ 7780 ~ SEQ;CURSOR;HEX BEL.
# Both keys are bound in every bind mode, so vi mode takes them too.
set -g __weft_seq 0

function __weft_hex
    printf %s $argv[1] | od -An -v -tx1 | string join '' | string replace -ra '\s' ''
end

function __weft_report_now
    set -l line (commandline | string collect)
    set -l pre (string sub -l (commandline -C) -- $line | string collect)
    set -l hex (__weft_hex $line)
    set -l prehex (__weft_hex $pre)
    printf '\e]7780;line;%s;%s;%s\a' $__weft_seq (math (string length -- "$prehex") / 2) "$hex"
end

# A key binding cannot read further input in fish, so weft sends the line
# IN BAND (hello version 2): ESC [ 7782 ~ empties the command line (and puts
# a vi mode into insert, where the payload types as text), the payload
# SEQ;CURSOR;HEX types in, and ESC [ 7780 ~ takes it back out of the
# command line and sets the real one. The payload is digits, hex and `;`:
# nothing an abbreviation or a completion acts on.
function __weft_line_begin
    set -g __weft_mode_was $fish_bind_mode
    # A vi mode other than insert would read the payload as commands.
    if test "$fish_key_bindings" = fish_vi_key_bindings; and test "$fish_bind_mode" != insert
        set -g fish_bind_mode insert
    end
    commandline -r ''
end

function __weft_set_line
    set -l parts (string split -m 2 ';' -- (commandline | string collect))
    if set -q __weft_mode_was[1]
        set -g fish_bind_mode $__weft_mode_was
        set -e __weft_mode_was
    end
    test (count $parts) -eq 3; or return
    set -g __weft_seq $parts[1]
    set -l hex $parts[3]
    set -l line (printf (string replace -ra '(..)' '\\\\x$1' -- $hex) | string collect)
    set -l pre (printf (string replace -ra '(..)' '\\\\x$1' -- (string sub -l (math $parts[2] \* 2) -- $hex)) | string collect)
    commandline -r -- $line
    commandline -C (string length -- "$pre")
    commandline -f repaint-mode
end

# Bound at the first prompt, after config.fish: a `fish_vi_key_bindings`
# there has set its modes up already, and our keys go into every one.
function __weft_bind_init --on-event fish_prompt
    functions -e __weft_bind_init
    for mode in default insert visual replace replace_one
        bind -M $mode ctrl-alt-shift-f12 __weft_set_line
        bind -M $mode ctrl-alt-shift-f11 __weft_report_now
        bind -M $mode ctrl-alt-shift-f10 __weft_line_begin
    end
    printf '\e]7780;hello;2\a'
end
