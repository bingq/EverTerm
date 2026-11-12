# EverTerm

A personal macOS terminal (Swift + [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)) whose sessions
keep their scrollback locally, in memory and on disk, even after the remote host is gone.

## Build and run (on the Mac)

Requires Xcode 26 / Swift 6.2 or later (SwiftTerm 1.99.3 needs it).

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
  meta.json    command, title, directory, start/end time, exit code
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
| ⌥⌘R | Reset Terminal (rescue a stuck screen) |
| ⇧⌘L | Show session logs in Finder |
| ⇧ + scroll up (in a full-screen app), ⇧⌘H | Show the shell history from before the app started (read-only; Esc, scroll down past the end, or type to go back) |

Sidebar dots: green running, orange connection dropped, grey ended (exit 0), red ended with an error; small blue dot = new output not yet seen.

See `PROGRESS.md` for the build log.
