# weft's .zshenv — read because `launch` pointed ZDOTDIR here. It puts the
# user's ZDOTDIR back (unset, when they had none: zsh then reads $HOME), reads
# the user's own .zshenv, and loads weft's integration into an interactive
# shell. zsh goes on to read the user's .zshrc from the restored ZDOTDIR as
# it would have.
#
# Quoted throughout: aliases may already be defined when this is sourced.

if [[ -n "${WEFT_ZSH_ZDOTDIR+X}" ]]; then
	'builtin' 'export' ZDOTDIR="$WEFT_ZSH_ZDOTDIR"
	'builtin' 'unset' 'WEFT_ZSH_ZDOTDIR'
else
	'builtin' 'unset' 'ZDOTDIR'
fi

{
	'builtin' 'typeset' _weft_file="${ZDOTDIR-$HOME}/.zshenv"
	# zsh ignores an unreadable rc file; so do we.
	[[ ! -r "$_weft_file" ]] || 'builtin' 'source' '--' "$_weft_file"
} always {
	if [[ -o 'interactive' ]]; then
		# ${(%):-%x} is this file; :A:h its directory.
		'builtin' 'typeset' _weft_file="${${(%):-%x}:A:h}/weft-integration.zsh"
		[[ ! -r "$_weft_file" ]] || 'builtin' 'source' '--' "$_weft_file"
	fi
	'builtin' 'unset' '_weft_file'
}
