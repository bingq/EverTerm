# Progress log

## 2026-11-11: step 1
- Swift package, AppKit app without Xcode project (`swift run`).
- SwiftTerm pinned to 1.99.3; delegate API checked against that tag's source.
- On process exit: feed mode-reset sequences (1049l, mouse modes, 1007l, 2004l, cursor on), print an "ended" banner, keep the window.
- Scrollback set to 100,000 lines (step 2 replaces this).
- Written on a Linux dev box; not compiled yet. First Mac build is the test.

## 2026-11-11: renamed to EverTerm
- Name checked on the US App Store (Mac + iOS): no app called EverTerm. GoodTerm was taken (PLAYSTONE, id1639847451).
- Repo renamed bingq/keepterm -> bingq/everterm (GitHub redirects the old URL).
- Before App Store upload: reserve the name in App Store Connect, trademark search (USPTO, J-PlatPat).

## 2026-11-11: step 2, history on disk
- Dropped LocalProcessTerminalView: its output hook passes no bytes and its host logging writes one file per chunk. EverTerm now runs LocalProcess itself (TerminalSession) and feeds a plain TerminalView, so every byte passes through our code: log first, then screen.
- SessionLogger: per-session folder with output.raw, output.txt (streaming escape stripper, state kept across chunks), meta.json. All disk work on a serial queue.
- Scrollback 1,000,000 lines per window in memory (SwiftTerm preallocates ~8 bytes/line of slots, about 8 MB); disk log unlimited.
- Closing a window terminates its process; the log is closed with end time and exit code.
- Menu: Shell → Show Session Logs in Finder (⇧⌘L).
- Not compiled yet (the dev box is Linux). Mac test: run `ls`, quit the shell with `exit`, check the window still scrolls and the folder has the three files.
