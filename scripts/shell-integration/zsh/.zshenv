# EverTerm shell integration (#23). EverTerm starts zsh with ZDOTDIR pointing here; each file
# loads your own one from EVERTERM_USER_ZDOTDIR (your ZDOTDIR or home), and .zshrc then adds
# two small hooks that report each command line and its exit status to EverTerm.
_everterm_dir="$ZDOTDIR"
ZDOTDIR="${EVERTERM_USER_ZDOTDIR:-$HOME}"
[[ -f "$ZDOTDIR/.zshenv" ]] && source "$ZDOTDIR/.zshenv"
EVERTERM_USER_ZDOTDIR="$ZDOTDIR"      # your .zshenv may have moved it
ZDOTDIR="$_everterm_dir"
unset _everterm_dir
