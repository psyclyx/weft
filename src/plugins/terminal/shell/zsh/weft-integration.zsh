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

_weft_deferred_init() {
	builtin emulate -L zsh -o no_warn_create_global
	# Last among the precmd hooks, so the marks stick to the prompt a
	# theme's own hook built.
	precmd_functions=(${precmd_functions:#_weft_deferred_init} _weft_precmd)
	preexec_functions+=(_weft_preexec)
	builtin local hook=${XDG_CONFIG_HOME:-$HOME/.config}/weft/shell/zsh
	[[ -r $hook ]] && builtin source -- $hook
	_weft_precmd
}

builtin typeset -ga precmd_functions preexec_functions
precmd_functions+=(_weft_deferred_init)
