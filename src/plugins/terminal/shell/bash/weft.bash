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

	# The command line (doc/terminal.md §8): weft edits it with its own
	# grammar at the prompt. readline has no redraw hook, so bash reports its
	# line when asked — ESC [ 7781 ~ — and weft hands a line back as
	# ESC [ 7780 ~ SEQ;CURSOR;HEX BEL; both are bound in every keymap, so vi
	# mode and emacs mode alike take them. The report:
	#   OSC 7780 ; line ; SEQ ; CURSOR ; HEX
	_weft_seq=0
	_weft_hex() {
		local LC_ALL=C s=$1 out='' h i
		for ((i = 0; i < ${#s}; i++)); do
			printf -v h '%02x' "'${s:i:1}"
			out+=$h
		done
		REPLY=$out
	}
	_weft_report_now() {
		_weft_hex "$READLINE_LINE"
		builtin printf '\e]7780;line;%s;%s;%s\a' "$_weft_seq" "$READLINE_POINT" "$REPLY"
	}
	_weft_set_line() {
		local payload='' esc='' i
		IFS= builtin read -r -d $'\a' payload
		_weft_seq=${payload%%;*}
		payload=${payload#*;}
		local cur=${payload%%;*} hex=${payload#*;}
		for ((i = 0; i < ${#hex}; i += 2)); do esc+="\\x${hex:i:2}"; done
		builtin printf -v READLINE_LINE '%b' "$esc"
		READLINE_POINT=$cur
	}
	for _weft_km in emacs vi-insert vi-command; do
		builtin bind -m "$_weft_km" -x '"\e[7780~": _weft_set_line'
		builtin bind -m "$_weft_km" -x '"\e[7781~": _weft_report_now'
	done
	unset _weft_km
	builtin printf '\e]7780;hello;1\a'

	_weft_hook=${XDG_CONFIG_HOME:-$HOME/.config}/weft/shell/bash
	if [[ -r $_weft_hook ]]; then
		builtin source "$_weft_hook"
	fi
	unset _weft_hook
fi
