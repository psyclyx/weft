# weft.bash — bash's rc file in a weft terminal (`launch` passes --rcfile):
# the user's ~/.bashrc first, as an interactive bash would have read it, then
# what bash tells weft (doc/terminal.md §7):
#
#   OSC 133 A / B    a prompt starts / the command line starts (around PS1)
#   OSC 133 C        the command line was accepted (PS0)
#   OSC 133 D;N      the command finished with status N
#   OSC 7            the working directory, file://host/path
#   OSC 2            the title: the directory at a prompt
#
# Then ${XDG_CONFIG_HOME:-~/.config}/weft/shell/bash is sourced when it
# exists.

if [[ -f ~/.bashrc ]]; then
	builtin source ~/.bashrc
fi

if [[ $- == *i* && -z ${_weft_loaded-} ]]; then
	_weft_loaded=1
	_weft_ran=0

	_weft_prompt_command() {
		local st=$?
		# PS0 said a command started; a line with no command writes none.
		if ((_weft_ran)); then
			builtin printf '\e]133;D;%s\a' "$st"
		fi
		_weft_ran=1
		local enc=${PWD//\%/%25}
		builtin printf '\e]7;file://%s%s\a' "${HOSTNAME}" "${enc// /%20}"
		builtin printf '\e]2;%s\a' "${PWD/#$HOME/\~}"
		# Wrap the prompt the user's config set — again, if it changed it.
		if [[ -z ${_weft_marked_ps1-} || $PS1 != "$_weft_marked_ps1" ]]; then
			_weft_ps1=$PS1
		fi
		PS1='\[\e]133;A\a\]'"$_weft_ps1"'\[\e]133;B\a\]'
		_weft_marked_ps1=$PS1
	}

	# First, so it sees the command's status before anything else runs.
	PROMPT_COMMAND="_weft_prompt_command${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
	PS0=$'\e]133;C\a'"${PS0-}"

	_weft_hook=${XDG_CONFIG_HOME:-$HOME/.config}/weft/shell/bash
	if [[ -r $_weft_hook ]]; then
		builtin source "$_weft_hook"
	fi
	unset _weft_hook
fi
