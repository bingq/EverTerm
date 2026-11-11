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
| 2 | Every session logged to `~/Library/Application Support/EverTerm/sessions/<id>/` (raw + plain text); unlimited scrollback | todo |
| 3 | Alternate-screen output copied into scrollback (Claude Code TUI history survives) | todo |
| 4 | Tabs + session sidebar (live/ended), reopen ended session read-only, search across sessions | todo |
| 5 | Restore windows and history after app restart; profiles (e.g. a remote host over `et`) with reconnect | todo |

See `PROGRESS.md` for the build log.
