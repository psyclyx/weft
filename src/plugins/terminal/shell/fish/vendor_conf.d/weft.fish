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
