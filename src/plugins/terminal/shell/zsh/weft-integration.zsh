# weft-integration.zsh — what a zsh running in a weft terminal tells it
# (doc/terminal.md §7). Loaded by weft's .zshenv into an interactive shell;
# set up at the first prompt, after the user's .zshrc, so the marks wrap the
# prompt the user's config chose.
#
#   OSC 133 A / B    a prompt starts / the command line starts (around PS1)
#   OSC 133 C        the command line was accepted: its output follows
#   OSC 133 D;N      the command finished with status N
#   OSC 7            the working directory, file://host/path
#   OSC 2            the title: the directory at a prompt, the command while
#                    it runs
#
# Then ${XDG_CONFIG_HOME:-~/.config}/weft/shell/zsh is sourced when it exists.
#
# Everything is a function or a local: nothing here leaks into the user's
# options. `builtin` throughout, so a user function of the same name is not
# run instead.

builtin typeset -gi _weft_state=0 # 0 fresh, 1 a command runs, 2 at a prompt

_weft_osc() { builtin print -rn -- $'\e]'"$1"$'\a'; }

# The working directory as a file:// URI: `%` and a space percent-encoded
# (weft decodes any %XX; other bytes may stand as they are).
_weft_report_pwd() {
	builtin local enc=${PWD//\%/%25}
	_weft_osc "7;file://${HOST}${enc// /%20}"
}

_weft_precmd() {
	builtin local -i st=$?
	builtin emulate -L zsh -o no_warn_create_global
	if (( _weft_state == 1 )); then
		_weft_osc "133;D;$st"
	fi
	_weft_state=2
	_weft_report_pwd
	_weft_osc "2;${(%):-%~}"
	# The marks go around the prompt the user's config set: restore what we
	# wrapped last time unless something else has changed PS1 since.
	if [[ -z ${_weft_marked_ps1-} || $PS1 != $_weft_marked_ps1 ]]; then
		_weft_ps1=$PS1
	fi
	PS1=$'%{\e]133;A\a%}'"${_weft_ps1}"$'%{\e]133;B\a%}'
	_weft_marked_ps1=$PS1
}

_weft_preexec() {
	builtin emulate -L zsh -o no_warn_create_global
	# Other preexec hooks see the prompt as the user set it.
	[[ $PS1 == ${_weft_marked_ps1-} ]] && PS1=$_weft_ps1
	_weft_osc "133;C"
	_weft_state=1
	_weft_osc "2;${1//[[:cntrl:]]}"
}

# ── The command line (doc/terminal.md §8) ──────────────────────────────
# At the prompt weft edits the command line with its own grammar. The line
# editor reports its buffer and cursor whenever it redraws —
#   OSC 7780 ; line ; SEQ ; CURSOR ; HEX     (CURSOR in bytes, HEX its bytes)
# — and weft hands a line back as a key bound in EVERY keymap, so it lands
# whatever keymap the user is in (vi mode included):
#   ESC [ 7780 ~ SEQ ; CURSOR ; HEX BEL      set BUFFER and CURSOR
#   ESC [ 7781 ~                             report now
# SEQ is the last line weft set that this shell applied: an older report is
# stale, and weft ignores it.

builtin typeset -gi _weft_seq=0
builtin typeset -g _weft_last=''

# REPLY: $1's bytes as hex.
_weft_hex() {
	builtin emulate -L zsh -o no_multibyte
	builtin local s=$1 c out=''
	builtin local -i i
	for ((i = 1; i <= ${#s}; i++)); do
		c=$s[i]
		out+=${(l:2::0:)$(( [##16] #c ))}
	done
	REPLY=${(L)out}
}

# REPLY: how many bytes $1 is.
_weft_bytes() {
	builtin emulate -L zsh -o no_multibyte
	REPLY=${#1}
}

_weft_report_line() {
	builtin emulate -L zsh -o no_warn_create_global
	# The cursor in bytes: the characters before it, counted as bytes.
	_weft_bytes "${BUFFER[1,CURSOR]}"
	builtin local -i bytes=$REPLY
	[[ $1 != force && "$_weft_seq;$bytes;$BUFFER" == $_weft_last ]] && return
	_weft_last="$_weft_seq;$bytes;$BUFFER"
	_weft_hex "$BUFFER"
	_weft_osc "7780;line;$_weft_seq;$bytes;$REPLY"
}

_weft_line_redraw() { _weft_report_line; }
_weft_report_now() { _weft_report_line force; }

_weft_set_line() {
	builtin emulate -L zsh -o no_warn_create_global
	builtin local c payload=''
	builtin local -i n=0
	while builtin read -rk 1 c; do
		[[ $c == $'\a' ]] && break
		payload+=$c
		((++n > 1048576)) && return
	done
	builtin local seq=${payload%%;*}
	payload=${payload#*;}
	builtin local -i cur=${payload%%;*}
	builtin local hex=${payload#*;} esc=''
	builtin local -i i
	for ((i = 1; i < ${#hex}; i += 2)); do esc+="\\x${hex[i,i+1]}"; done
	builtin local line pre
	builtin print -v line -n -- "$esc"
	builtin print -v pre -n -- "${esc[1,cur*4]}"
	_weft_seq=$seq
	BUFFER=$line
	CURSOR=${#pre}
}

_weft_line_init() {
	builtin emulate -L zsh
	builtin autoload -Uz add-zle-hook-widget 2>/dev/null || return
	builtin zle -N _weft_line_redraw
	add-zle-hook-widget line-pre-redraw _weft_line_redraw
	builtin zle -N _weft_set_line
	builtin zle -N _weft_report_now
	builtin local km
	for km in emacs viins vicmd; do
		builtin bindkey -M $km $'\e[7780~' _weft_set_line
		builtin bindkey -M $km $'\e[7781~' _weft_report_now
	done
	_weft_osc "7780;hello;1"
}

_weft_deferred_init() {
	builtin emulate -L zsh -o no_warn_create_global
	# Last among the precmd hooks, so the marks stick to the prompt a
	# theme's own hook built.
	precmd_functions=(${precmd_functions:#_weft_deferred_init} _weft_precmd)
	preexec_functions+=(_weft_preexec)
	# After the user's .zshrc: a `bindkey -v` there has chosen its keymap
	# already, and our keys go into every one.
	_weft_line_init
	builtin local hook=${XDG_CONFIG_HOME:-$HOME/.config}/weft/shell/zsh
	[[ -r $hook ]] && builtin source -- $hook
	_weft_precmd
}

builtin typeset -ga precmd_functions preexec_functions
precmd_functions+=(_weft_deferred_init)
