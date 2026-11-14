# EverTerm shell integration (#23): load your .zshrc, then add the hooks. After this file
# ZDOTDIR is yours again, so zsh reads your .zlogin and nested shells behave as usual.
ZDOTDIR="$EVERTERM_USER_ZDOTDIR"
[[ -f "$ZDOTDIR/.zshrc" ]] && source "$ZDOTDIR/.zshrc"

if [[ -o interactive ]]; then
    # ESC ] 6973 ; C ; <base64 command line> BEL   when a command starts
    _everterm_preexec() { printf '\e]6973;C;%s\a' "$(printf '%s' "$1" | /usr/bin/base64 | tr -d '\n')"; }
    # ESC ] 6973 ; D ; <exit status> BEL           when the prompt comes back
    _everterm_precmd() { local s=$?; printf '\e]6973;D;%s\a' "$s"; }
    preexec_functions+=(_everterm_preexec)
    precmd_functions=(_everterm_precmd $precmd_functions)   # first, so $? is still the command's
fi
