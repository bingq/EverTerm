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

## 2026-11-11: step 3, alternate-screen capture
- TerminalSession scans host output for alt-screen exits (ESC[?1049l, ?1047l, ?47l). Before feeding the exit, it copies the alt screen (terminalContentSnapshot(.all, .alt)); after the switch back, it writes that screen into the normal buffer between dim "EverTerm saved screen" markers, so it stays in scrollback.
- An exit sequence split across two reads is held back (max 7 bytes) and joined with the next read.
- Session dies while still in the alt screen (dropped ssh / et): finishScreen() saves the screen, resets modes, then prints the ended banner.
- Saved screen is plain text: SwiftTerm's ansiRepresentation() also emits palette changes that would recolour the terminal. Colour version later.
- The saved screen is also appended to output.txt; output.raw stays byte-exact.
- Switch: TerminalSession.captureAlternateScreen (preference UI comes with step 4/5).
- Mac test: `vim` some text, :q, then scroll up (saved screen above prompt). `ssh` somewhere, run `top`, kill the network or the ssh process; window should show the saved top screen + banner.

## 2026-11-11: fix, no scrollback after `et` dropped (first Mac test)
- Bing's test: Claude Code over `et`, session killed. ET printed "Session terminated", the local zsh prompt came back, but nothing scrolled.
- Cause: only the foreground program (et) died; EverTerm's own shell lived on, so the step 3 end-of-session rescue never ran. Claude's full-screen modes (alt screen, mouse tracking) stayed on, and the local prompt was drawn on the alt screen, which has no scrollback.
- Fix: TerminalSession now runs LocalProcess on its own serial queue and, before feeding each output chunk, checks the tty's foreground process group (tcgetpgrp on the pty). When it changes from a program back to the shell while the alt screen or mouse tracking is still on: save the alt screen into scrollback, reset modes (not bracketed paste, which the shell sets itself), then feed the shell's prompt on the normal screen.
- Added Shell → Reset Terminal (⌥⌘R): manual version of the same rescue.

## 2026-11-11: #8 verified, #9 alt-screen scroll capture
- #8 closed: Mac test 22:59 shows scrollback working after `et` dropped.
- #9: rescue held only Claude's last screen. Now each alt-screen frame (checked after 30 ms of quiet, at least every 300 ms) is compared with the last one; lines that scroll off the top go to an archive (cap 200k, de-duped by line + neighbours). Rescue replays archive + final screen. finishScreen now runs on the session queue.

## 2026-11-11: step 4a, session sidebar (issue #11)
- One main window: NSSplitViewController with a SwiftUI sidebar (SidebarView) and a container that shows one TerminalView at a time. Background sessions keep running.
- SessionModel = one session (terminal view, TerminalSession, names, status). SessionStore = list + selection + rename state; refreshes names once a second.
- Automatic name: the foreground program's title alone (#13 dropped the "ssh · " prefix); program name (tcgetpgrp -> proc_name) only if it sets no title; "local zsh" at the shell prompt. Subtitle: shell's current directory (proc_pidinfo PROC_PIDVNODEPATHINFO) + start time, or exit code + end time.
- Rename: double-click, context menu, or ⌘⇧R; Enter saves, Esc cancels; empty name or the automatic name clears it. Saved as customName in meta.json.
- Dots: green running, orange connection dropped (set by the foreground rescue, cleared when the next program starts), grey exit 0, red error or signal; blue unseen-output dot (TerminalSession.onOutput, at most every 0.5 s).
- TerminalWindowController removed; its delegate code moved into SessionModel.
- Build fix: main.swift (nonisolated top-level code) could not create the @MainActor AppDelegate. Replaced with an @main @MainActor entry point (EverTermMain.swift); delegate kept alive with withExtendedLifetime because NSApplication.delegate is weak.

## 2026-11-11: #12 always-visible scroll bar
- SessionModel sets terminalView.scrollerStyle = .legacy before the shell starts (SwiftTerm 1.99.3 default is .overlay: hidden until you scroll, takes no width).
- Checked in SwiftTerm 1.99.3 source: .legacy reserves NSScroller.scrollerWidth from the terminal width, so the column count shrinks and no text sits under the bar (R4). On the alternate screen canScroll is false and the knob size is 0, so the bar is disabled instead of scrolling the hidden normal buffer (R5). Knob, track and wheel use SwiftTerm's own scroller wiring (R2, R3).
- R6 (overlay style setting) waits for step 5 preferences. R7 (history view) comes with 4b.
- Not compiled here (the dev box is Linux). Mac test: checklist in issue #12.
