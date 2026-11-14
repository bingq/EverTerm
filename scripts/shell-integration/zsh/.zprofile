# EverTerm shell integration (#23): load your .zprofile.
_everterm_dir="$ZDOTDIR"
ZDOTDIR="$EVERTERM_USER_ZDOTDIR"
[[ -f "$ZDOTDIR/.zprofile" ]] && source "$ZDOTDIR/.zprofile"
ZDOTDIR="$_everterm_dir"
unset _everterm_dir
