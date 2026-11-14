# EverTerm

A personal macOS terminal (Swift + [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)) whose sessions
keep their scrollback locally, in memory and on disk, even after the remote host is gone.

## Build and run (on the Mac)

Requires a recent Xcode with Swift 6.4 or later (checked: 6.4.2 builds; 6.2.3 fails to compile SwiftTerm 1.99.3). Check with `swift --version`.

```sh
git clone https://github.com/bingq/EverTerm && cd EverTerm
swift run            # first run downloads SwiftTerm
swift test           # unit tests for the core logic (EverTermCore)
EVERTERM_DEBUG_CAPTURE=1 swift run   # also write capture-debug.log in each session folder
# or: open Package.swift   (opens in Xcode, then Run)
```

## Roadmap

| Step | Feature | Status |
|---|---|---|
| 1 | Window runs login shell; stays open + scrollable after exit; resets stuck terminal modes on exit | done, untested on Mac |
| 2 | Every session logged to `~/Library/Application Support/EverTerm/sessions/<id>/` (raw + plain text + meta); 1M-line scrollback in memory, disk unlimited; Shell → Show Session Logs (⇧⌘L) | done, untested on Mac |
| 3 | When a full-screen app (vim, less, top, a TUI) leaves the alternate screen, or the session dies inside it, its last screen is copied into scrollback and output.txt. #14: erase-scrollback (ESC[3J) is ignored; Shift + scroll in a full-screen app shows the shell history behind it | done, untested on Mac |
| 4 | Session sidebar (issue #11): 4a live sessions, auto name + rename, status dots, shortcuts; 4b history from disk + reconnect; 4c search | 4a done, untested on Mac |
| 5 | Restore windows and history after app restart; profiles (e.g. a remote host over `et`) with reconnect | todo |

## Where history lives

```
~/Library/Application Support/EverTerm/sessions/<UTC time>-<id>/
  output.raw   every byte from the host (replay with: cat output.raw, or less -R)
  output.txt   same output, escape codes stripped (grep-able)
  meta.json    command, title, directory, start/end time, exit code;
               the last connect command (ssh, et, mosh...) and Claude Code resume command, for ⌘R
```

Search all history: `grep -r "text" ~/Library/Application\ Support/EverTerm/sessions/*/output.txt`

## Shortcuts

| Keys | Action |
|---|---|
| ⌘T / ⌘N | New session (starts in the selected session's directory) |
| ⌘W | End the selected session (it moves to Ended); on an ended session, remove it from the list |
| ⌘⇧R or double-click | Rename (empty name = back to the automatic name) |
| ⌘1–⌘9, ⌘} / ⌘{ | Jump to session N, next / previous |
| ⌃⌘S | Show / hide the sidebar |
| ⌘R | Reconnect (#18): connection dropped, shell back at its prompt: runs the saved `ssh`/`et`/`mosh` command again in the same session. Ended session: new session in the same directory running it, same name. The command is shown once before it first runs |
| ⌃⌘R | Type the saved `claude --resume <id>` at the prompt, without pressing Enter |
| ⌥⌘R | Reset Terminal (rescue a stuck screen) |
| ⇧⌘L | Show session logs in Finder |
| ⇧ + scroll up (in a full-screen app), ⇧⌘H | Show the shell history from before the app started (read-only; Esc, scroll down past the end, or type to go back) |

Sidebar dots: green running, orange connection dropped, grey ended (exit 0), red ended with an error; small blue dot = new output not yet seen.

See `PROGRESS.md` for the build log.
