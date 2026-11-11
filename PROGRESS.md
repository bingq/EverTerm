# Progress log

## 2026-11-11: step 1
- Swift package, AppKit app without Xcode project (`swift run`).
- SwiftTerm pinned to 1.99.3; delegate API checked against that tag's source.
- On process exit: feed mode-reset sequences (1049l, mouse modes, 1007l, 2004l, cursor on), print an "ended" banner, keep the window.
- Scrollback set to 100,000 lines (step 2 replaces this).
- Written on a Linux dev box; not compiled yet. First Mac build is the test.
