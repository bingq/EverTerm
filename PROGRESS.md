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

## 2026-11-11: #14 shell history around full-screen apps
- Bing's test: several screens of zsh history, then Claude Code; the earlier history could not be reached.
- Two causes: Claude Code runs on the alternate screen (normal scrollback hidden, SwiftTerm disables scrolling there), and apps may send ESC[3J, which SwiftTerm handles by deleting the scrollback (Terminal.swift CSI 3 J -> trimStart).
- F1: TerminalSession drops ESC[3J before feeding (TerminalSession.keepScrollbackOnErase). output.raw still has it. The carry hold-back now also covers a split ESC[3J and starts at 2 bytes ("ESC[").
- F2: ShellHistoryPanel, a read-only NSTextView over the terminal with the normal buffer (terminalContentSnapshot(.all, .normal)), plain text, same font and colours, capped at 200k lines (older: output.txt), opened at the newest line. Opens on Shift + scroll up while the alternate screen is active (NSEvent local monitor: SwiftTerm's scrollWheel is public, not open; Shift on a mouse wheel reports deltaX) or Shell -> Show Shell History (⇧⌘H). Closes on Esc, scrolling down from the end (no momentum), switching session, or any non-navigation key, which is forwarded to the terminal.
- Not compiled here (the dev box is Linux). Mac test: checklist in issue #14.

## 2026-11-11: repos renamed
- Source: bingq/everterm -> bingq/EverTermSrc (private). Public site: bingq/EverTerm (GitHub Pages https://bingq.github.io/EverTerm/: home, support, privacy policy for App Store Connect).
- The old `everterm` redirect is gone because the public repo now has that name. Existing clones must run: git remote set-url origin https://github.com/bingq/EverTermSrc.git

## 2026-11-12: #9 capture fix, EverTermCore + unit tests
- Mac runs: streaming 300 lines kept every line but repeated one where the archive met the final screen; scrolling inside Claude while it printed added ~22 junk lines (the prompt Claude pins to the top row, re-saved on every scroll).
- New target EverTermCore (no AppKit/SwiftTerm): AltScreenTracker (scroll detection, archive, join), TerminalBytes (ESC[3J filter), HistoryPanelRules (#14 key/scroll rules). The app maps NSEvents to these.
- Fix: pinned top rows (identical in both frames) are skipped before looking for a scroll; de-dup key = line + the two lines after it; on capture, already-archived pinned rows are dropped and the archive/final-screen overlap appears once.
- Tests: `swift test` (EverTermCoreTests): made-up Claude-style streams (footer, pinned prompt, scrolling back, vim paging, join), and one rule test per #12/#14 behaviour already verified on the Mac. The pinned-prompt tests fail on the old logic and pass now.
- Replay of real session frames (ReplayTests) runs only when EVERTERM_REPLAY_DIR points at exported frames; session logs are private and not in the repo. On the two Mac runs: run 2 = 300/300 in order, no repeats; run 1 (scrolled inside Claude) = 299 lines, 2 missing, 1 repeated, no repeated prompt.
- App code not compiled here (the dev box is Linux); EverTermCore and its tests were built and run with Swift 6.1.2 on Linux.

## 2026-11-12: #9 second fix, repeated output was dropped
- Mac run 3 (same numbers printed in three batches, the last in slow chunks with shell commands between): the 2026-11-12 fix kept only the first and last lines of each chunk and repeated each prompt up to 9 times.
- Cause: the de-dup key (line + two lines after it) matched the earlier batches, so new repeated output looked like the app scrolling back over old lines.
- Fix: scrolling back is detected by direction instead. When the content moves down (you scrolled up inside the app), that many lines are skipped when it moves up again. Content matching is only a fallback for jumps the direction check misses, and only within the last 3 screens, so output repeated further apart is kept.
- Replay of the three Mac runs: run 1 = 1-300 once, prompt once; run 2 = 1-300 once; run 3 = every batch kept, each prompt once, 246 of 250 lines of the slow batch (a few lost or doubled where Claude collapses its tool output). The new tests fail on the previous fix and pass now.

## 2026-11-12: #9 third fix, half-drawn frames
- Mac run 4 (300 numbered text lines, no scrolling): 1-23, then 22-36 out of order, then 37-53 and 65-256 missing.
- Replay of that log through the real AltScreenTracker on complete frames gives exactly 1-300, so the tracker was right and the frames were wrong. Claude Code draws every frame inside a synchronized update (ESC[?2026h ... ESC[?2026l); EverTerm looked at the screen on a 30/300 ms timer, sometimes in the middle of one. A half-drawn screen looks like a scroll by the wrong amount. Sampling the same log at random read boundaries reproduces the Mac result (repeats, out of order, missing runs).
- Fix: new HostOutputScanner (EverTermCore) reports synchronized-update begin/end and alt-exit, and holds back sequences split across reads (replaces the old carry logic). The alt screen is looked at at the end of every update and never during one; the timer stays for apps that don't use synchronized updates.
- Debug log: `EVERTERM_DEBUG_CAPTURE=1 swift run` writes capture-debug.log in each session folder, one line per look (reason, sync state, rows, pinned rows, up/down shift, lines added/skipped, archive size, first/last line added, raw-log offset). It holds screen text, so it stays local.

## 2026-11-12: #16 copy across screens (history panel shows the app's output so far)
- Shift + scroll up / ⇧⌘H over a full-screen app: the panel shows the shell history, a divider `── <name> (live, captured so far) ──`, then what the app has shown so far (archived lines + the last complete frame). Select with drag (auto-scrolls), Shift-click, ⌘A; ⌘C copies. Snapshot taken on open.
- EverTermCore: AltScreenTracker.peek() (changes nothing, so the save on exit is unchanged), HistoryPanelContent (panel text and header). The session builds the list on its own queue and hands it to the main thread.
- Also fixed: while you are scrolled back inside the app, its screen shows older lines; peek and the save on exit now use the last frame seen at the live bottom (quitting while scrolled up used to append the older lines below the newest).
- Kept from #14: plain scroll goes to the app, Esc / typing / wheel past the end close the panel, ⌘ keys and paging stay in it. A selection drag auto-scrolls without going through the wheel handler, so it does not close the panel.
- Tests: 39 (peek = capture and changes nothing; peek mid-stream; scrolled back at exit; panel text; replay: peek every 25 frames of the Mac runs is correct so far). All 48 sampling replays still exact.

## 2026-11-12: #16 panel lost the line under Claude's pinned prompt
- Mac panel test: after Claude finished, scrolling up and back down left line 256 out of the panel, with the prompt in its place. The save on exit was right (Claude unpins before exiting).
- Cause (replay of the session, frame 468 -> 469): back at the bottom, Claude keeps the prompt pinned on row 0, over the line that was at the top of the last screen before you scrolled up. That line never scrolled off, so it was never saved; coming back down it was skipped as already seen.
- Fix: AltScreenTracker remembers the live screen just before you scroll up. Back at the bottom, it adds the line(s) a pinned row now hides: at most one per pinned row, only the ones just above the first visible line, never a pinned row itself, never one already saved.
- Checks: the panel is right after every frame of Mac runs 1, 4 and 5; 40 tests pass (new: synthetic pinned-after-scroll-back case, run 5 replay); all sampling replays still exact. A first, broader attempt re-added pinned rows in run 3 and was dropped.

## 2026-11-13: release 0.9 without an Apple account
- No Mac App Store (sandbox would remove the local shell); issue #20 closed as not planned.
- scripts/release.sh now needs no Apple account: universal build, ad-hoc signature, zip in dist/. Runs with no warning on the Mac that built it.
- Next step (#21): signed and notarized download, so other people can open it without the "unidentified developer" block.

## 2026-11-14: #18 reconnect a dropped or ended session (⌘R)
- Saved per session in meta.json (local only): the last connect command run in it (`ssh`, `et`, `mosh`, `autossh`, `telnet`; read from the process with KERN_PROCARGS2 when it takes the terminal), the local directory it started from, and Claude Code's `claude --resume <id>` line when it prints one on exit. Other programs (vim, claude, make) are not saved.
- ⌘R (Shell → Reconnect, sidebar menu, and named in the "session ended" banner): shell alive at its prompt: a dim `── reconnected HH:mm ──` line, then the command is typed and run in the same session (history above untouched). Ended: a new session in the same directory runs it and keeps the custom name. Connection still up, or nothing saved: beep. The first time, an alert shows the exact command, because a command line can hold a secret; Forget Reconnect Command clears it.
- ⌃⌘R types the saved resume command without Enter, so you can check it first. The reconnect line mentions it when one is saved.
- The reconnect line goes to the screen and output.txt; output.raw stays host bytes only.
- EverTermCore: ReconnectRules (what ⌘R does, which commands are saved, mosh's Perl wrapper unwrapped), ShellCommand (quoting), ProcessArguments (KERN_PROCARGS2 parser), ResumeHintScanner; AnsiStripper moved here from the app so the resume hint is tested on the same strip-then-scan path. The resume test uses the bytes Claude Code writes on exit in a real Mac session, at read sizes 1 to the whole block.
- Tests: 50, all pass on Linux (Swift 6.1.2). App code not compiled here.
- Not done: sessions from earlier app runs (needs the on-disk session list, #11 4b); the remote directory.

### #18 Mac run 1 fixes
- Mac run 1: history kept after an `et` drop, but no orange dot and ⌘R silent. Two causes: (1) the dot only turned orange when a program died in full-screen mode; (2) the connection was started through a launcher command, so the job's program was the launcher, not `et`, and nothing was saved (meta.json had no reconnectCommand).
- Now: the whole job is looked at (process group plus children, once a second for up to a minute while a launcher signs in). A launcher that runs a connect program underneath is saved as typed. ssh run by another tool for one remote command (git push, rsync, scp) is not. A program outside PATH keeps its full path.
- When a connect job ends and the shell takes the terminal back, the dot turns orange ("connection ended · ⌘R reconnects").
- ⌘R with nothing saved shows a short "Nothing to reconnect" message instead of a silent beep.
- Tests: 55, all pass on Linux. App code not compiled here.
- Mac run 2: orange dot and the first-reconnect alert work. The alert showed the launcher's inner command line (`<runner> <cached script file> <args>`), not what was typed. Now: when the job is `<runner> /path/<name>[.ext] <args>` and `<name>` is a command on PATH, `<name> <args>` is saved. Sidebar subtitle shortened to "connection ended · <dir>" (it was cut off); the dot's tooltip names ⌘R.
- Mac run 3: the alert showed the typed launcher command. While a connection has ended, the session is now named after the saved command (sidebar and alert: "Reconnect “et host”?"), not "local zsh". Back to the automatic name when the next program starts.

## 2026-11-14: #22 ⌘R restarts an ended session in place
- After the #18 Mac checks (all 4 passed on 4eb13c3, #18 closed): ⌘R on an ended (grey) session now starts the new shell inside the same session instead of adding a second sidebar entry. The old history stays above in the same terminal, then the dim reconnect line; same name, same directory, saved command runs. A new log folder is started, as for any new shell.

## 2026-11-14: #23 App Store edition, step 1 (branch app-store)
- Sandboxed test build: `EVERTERM_SANDBOX=1 scripts/release.sh 0.9` makes dist-sandbox/EverTerm.app (bundle ID + `.sandboxtest`), ad-hoc signed with the App Sandbox (network client, user-selected files, app-scoped bookmarks), a copy of ssh in Contents/Helpers (sandbox + inherit), and scripts/sandbox-probe.sh in Resources.
- In the sandbox only: Shell > Grant Folder Access… (security-scoped bookmarks, restored at launch); the shell gets the real HOME, SSH_AUTH_SOCK, EVERTERM_SANDBOX=1 and EVERTERM_PROBE. The normal build is unchanged (SandboxAccess does nothing unsandboxed).
- The probe prints PASS/FAIL for folders, ssh-agent, programs (system ssh, bundled ssh, git, Homebrew, et), network (ssh to github.com with your key, local listen for port forwarding).
- Step 1 result (75832b7, macOS 26.7.1): the App Sandbox blocks terminal control calls (ioctl) on the pty, so zsh gets no job control: "can't set tty pgrp", Ctrl-C does nothing, no line editor (pasted text shows bracketed-paste markers), tcgetpgrp fails with EPERM (so EverTerm can't see the foreground program either). The refusal is not written to the system log. With a test exception allowing ioctl, all of it works. Also: setuid programs (ps) can't run in the sandbox.
- EVERTERM_SANDBOX_TTY=narrow: the same exception limited to /dev/ptmx and /dev/ttysN, the smallest rule to ask App Review for.
- Narrow exception (b80d2be) works: no tty error, Ctrl-C works, tcgetpgrp returns the foreground group. Probe on it: ssh-agent reachable (21 keys), bundled ssh runs; folders fail until granted; `git` fails (`xcrun: cannot be used within an App Sandbox`); PATH was not the macOS one; local listen fails.
- Now: network.server entitlement (local listen, ssh -L); the sandboxed shell's PATH is built from /etc/paths, /etc/paths.d and Homebrew, with the real developer tools first (so git is not the xcrun stub); probe: sandbox detected from the container working directory, network check with nc instead of ping.
- With home and /opt/homebrew granted: zsh reads ~/.zprofile and ~/.zshrc and sources files from /opt/homebrew, but running /opt/homebrew/bin/brew is refused ("operation not permitted"): a granted folder gives read/write, not exec. Now testing the public entitlement com.apple.security.files.user-selected.executable; the probe separates read, run-through-bash, run-directly (script) and run-directly (compiled program).
