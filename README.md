# EverTerm

A personal macOS terminal (Swift + [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)) whose sessions
keep their scrollback locally, in memory and on disk, even after the remote host is gone.

## Build and run (on the Mac)

Requires Xcode 26 / Swift 6.2 or later (SwiftTerm 1.99.3 needs it).

```sh
git clone https://github.com/bingq/everterm && cd everterm
swift run            # first run downloads SwiftTerm
# or: open Package.swift   (opens in Xcode, then Run)
```

## Roadmap

| Step | Feature | Status |
|---|---|---|
| 1 | Window runs login shell; stays open + scrollable after exit; resets stuck terminal modes on exit | done, untested on Mac |
| 2 | Every session logged to `~/Library/Application Support/EverTerm/sessions/<id>/` (raw + plain text + meta); 1M-line scrollback in memory, disk unlimited; Shell → Show Session Logs (⇧⌘L) | done, untested on Mac |
| 3 | When a full-screen app (vim, less, top, a TUI) leaves the alternate screen, or the session dies inside it, its last screen is copied into scrollback and output.txt | done, untested on Mac |
| 4 | Tabs + session sidebar (live/ended), reopen ended session read-only, search across sessions | todo |
| 5 | Restore windows and history after app restart; profiles (e.g. a remote host over `et`) with reconnect | todo |

## Where history lives

```
~/Library/Application Support/EverTerm/sessions/<UTC time>-<id>/
  output.raw   every byte from the host (replay with: cat output.raw, or less -R)
  output.txt   same output, escape codes stripped (grep-able)
  meta.json    command, title, directory, start/end time, exit code
```

Search all history: `grep -r "text" ~/Library/Application\ Support/EverTerm/sessions/*/output.txt`

See `PROGRESS.md` for the build log.
