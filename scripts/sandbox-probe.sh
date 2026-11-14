#!/bin/bash
# #23 step 1: what works for programs started inside the sandboxed EverTerm.
# Run in a session of the sandboxed test build:   "$EVERTERM_PROBE"   (or with a host: "$EVERTERM_PROBE" myhost)
# Prints one line per check; paste the whole output back.
host="${1:-}"
me="$(id -un)"
real_home="$(eval echo "~$me")"
here="$(cd "$(dirname "$0")" && pwd)"
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; }
info() { printf 'INFO  %s\n' "$*"; }
check() {   # check "<name>" <command...>
    local name="$1"; shift
    local out
    if out="$("$@" 2>&1)"; then pass "$name"; else fail "$name: $(printf '%s' "$out" | head -1)"; fi
}

echo "== EverTerm sandbox probe ($(date '+%Y-%m-%d %H:%M'))"
[ -n "${APP_SANDBOX_CONTAINER_ID:-}" ] && pass "running sandboxed ($APP_SANDBOX_CONTAINER_ID)" || fail "not sandboxed (APP_SANDBOX_CONTAINER_ID unset)"
info "HOME=$HOME  real home=$real_home  pwd=$(pwd)"
info "PATH=$PATH"

echo "== 1. folders (granted ones should PASS)"
check "list real home folder" ls "$real_home"
check "read ~/.ssh" ls "$real_home/.ssh"
check "write in real home (create+delete a temp file)" sh -c "f=\"$real_home/.everterm-probe-\$\$\"; : > \"\$f\" && rm \"\$f\""
check "read ~/Library/Caches" ls "$real_home/Library/Caches"

echo "== 2. ssh-agent"
info "SSH_AUTH_SOCK=${SSH_AUTH_SOCK:-<unset>}"
if [ -n "${SSH_AUTH_SOCK:-}" ]; then
    out="$(ssh-add -l 2>&1)"; code=$?
    case $code in 0) pass "agent reachable, keys: $(printf '%s\n' "$out" | wc -l | tr -d ' ')";;
                  1) pass "agent reachable, no keys loaded";;
                  *) fail "agent: $(printf '%s' "$out" | head -1)";; esac
fi

echo "== 3. programs"
check "system ssh runs" ssh -V
check "ssh inside the app bundle runs" "$here/../Helpers/ssh" -V
check "zsh runs" /bin/zsh -c true
check "git runs" git --version
if [ -d /opt/homebrew/bin ] || [ -d /usr/local/bin ]; then
    check "list /opt/homebrew/bin or /usr/local/bin" sh -c 'ls /opt/homebrew/bin 2>/dev/null | head -1 || ls /usr/local/bin | head -1'
fi
for tool in et mosh brew; do
    if p="$(command -v "$tool" 2>/dev/null)"; then check "$tool runs ($p)" "$p" --version; else info "$tool not on PATH"; fi
done

echo "== 4. network"
check "DNS lookup github.com" sh -c 'host github.com >/dev/null 2>&1 || nslookup github.com >/dev/null 2>&1 || ping -c1 -t3 github.com >/dev/null'
out="$(ssh -T -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new git@github.com 2>&1)"
case "$out" in *"successfully authenticated"*) pass "ssh to github.com with your key";;
               *) fail "ssh to github.com: $(printf '%s' "$out" | tail -1)";; esac
if command -v nc >/dev/null; then
    (nc -l 127.0.0.1 18023 >/dev/null 2>&1 &) ; sleep 1
    check "listen on a local port (needed for ssh -L port forwarding)" nc -z 127.0.0.1 18023
    pkill -f "nc -l 127.0.0.1 18023" 2>/dev/null
fi
if [ -n "$host" ]; then
    check "ssh to $host (BatchMode)" ssh -o BatchMode=yes -o ConnectTimeout=8 "$host" true
fi

echo "== 5. by hand (not checked here)"
info "sidebar shows a program's name while it runs: run 'sleep 20' and look at the sidebar"
info "your usual connect or launcher command: run it, then exit, then press Command-R"
echo "== done"
