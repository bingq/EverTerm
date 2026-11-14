import Foundation
import SwiftTerm
import EverTermCore

/// Owns the child process (shell, ssh, et...) for one terminal.
/// Every byte from the host goes to the disk logger first, then to the screen,
/// so history survives even if the remote host or the app dies.
/// Callbacks arrive on LocalProcess's private serial queue, not the main thread.
final class TerminalSession: LocalProcessDelegate, @unchecked Sendable {
    /// Step 3: copy a full-screen app's last screen into scrollback when it
    /// leaves the alternate screen (or when the session dies while in it).
    static var captureAlternateScreen = true

    /// #14: drop "erase scrollback" (ESC[3J) so no program (Claude Code, `clear`)
    /// can delete the history. ESC[2J (clear the visible screen) still works.
    /// output.raw keeps the byte; only the screen ignores it.
    static var keepScrollbackOnErase = true

    /// #9: write capture-debug.log in each session folder (one line per screen look).
    /// Turn on with `EVERTERM_DEBUG_CAPTURE=1 swift run`. The log holds screen text; it stays local.
    static let debugCapture = ProcessInfo.processInfo.environment["EVERTERM_DEBUG_CAPTURE"] != nil

    /// Modes left on when a foreground program dies inside the tab but the shell
    /// lives on (e.g. `et` drops). Bracketed paste (2004) is left alone: the
    /// shell turns it on itself for its own prompt.
    static let foregroundModeReset = "\u{1b}[?1049l\u{1b}[?1000l\u{1b}[?1002l\u{1b}[?1003l\u{1b}[?1006l\u{1b}[?1007l\u{1b}[?25h"

    /// Modes a dropped remote app never got to switch off (the Tabby bug).
    static let modeReset = "\u{1b}[?1049l\u{1b}[?1000l\u{1b}[?1002l\u{1b}[?1003l\u{1b}[?1006l\u{1b}[?1007l\u{1b}[?2004l\u{1b}[?25h"

    let logger: SessionLogger
    private weak var view: TerminalView?
    private var process: LocalProcess!
    private var scanner = HostOutputScanner()    // split sequences, ESC[3J, frame boundaries
    private var rawOffset = 0                    // bytes received so far (position in output.raw)
    private let startTime = DispatchTime.now()
    private var altTracker = AltScreenTracker()  // what the full-screen app has shown (#9)
    private var trackGeneration = 0
    private var lastTrack = DispatchTime.now()
    private var foregroundJobRunning = false // a program other than the shell owns the tty
    /// Our own serial queue: process output and foreground checks run in order on it.
    private let queue = DispatchQueue(label: "everterm.session")
    var onExit: ((Int32?) -> Void)?
    /// Main-thread notifications for the sidebar. Set before start().
    var onOutput: (() -> Void)?            // at most every 0.5 s
    var onProgramDropped: (() -> Void)?    // a program died without leaving full-screen mode
    private var lastOutputNotify: UInt64 = 0

    init(view: TerminalView, command: String) {
        self.view = view
        self.logger = SessionLogger(command: command)
        self.process = LocalProcess(delegate: self, dispatchQueue: queue)
    }

    func start(executable: String, args: [String], execName: String?, directory: String?) {
        process.startProcess(
            executable: executable,
            args: args,
            environment: Terminal.getEnvironmentVariables(termName: "xterm-256color"),
            execName: execName,
            currentDirectory: directory
        )
    }

    func send(_ data: ArraySlice<UInt8>) { process.send(data: data) }

    /// #18: a dim marker line on the screen and in output.txt (output.raw stays host bytes only),
    /// then keys for the shell. The marker replaces the prompt line it lands on; the
    /// typed command echoes on the line below it.
    func mark(_ text: String, thenType keys: String? = nil) {
        queue.async {
            self.view?.feed(text: "\r\u{1b}[2K\u{1b}[0;2m\(text)\u{1b}[0m\r\n")
            self.logger.appendNote("\n\(text)\n")
            if let keys { self.process.send(data: Array(keys.utf8)[...]) }
        }
    }

    func resize(cols: Int, rows: Int) {
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = process.updateWindowSize(&size)
    }

    var isRunning: Bool { process.running }

    /// PID of the shell EverTerm started, or nil when it has ended.
    var shellPID: pid_t? {
        let pid = process.shellPid
        return pid > 0 ? pid : nil
    }

    /// Process group that owns the terminal right now (the shell, or ssh/et/claude...).
    func foregroundProcessGroup() -> pid_t? {
        let fd = process.childfd
        guard fd >= 0 else { return nil }
        let group = tcgetpgrp(fd)
        return group > 0 ? group : nil
    }

    func terminate() { process.terminate() }

    /// Called after the process ends (any thread; work runs on the session queue): save the alternate
    /// screen if the app was still in it, then reset stuck modes.
    func finishScreen(banner: String) {
        queue.async {
            guard let view = self.view else { return }
            let saved = self.captureAlternateScreen()
            view.feed(text: Self.modeReset)
            if let saved { self.inject(saved, into: view, reason: "session ended in full-screen mode") }
            view.feed(text: banner)
        }
    }

    // MARK: LocalProcessDelegate

    func dataReceived(slice: ArraySlice<UInt8>) {
        logger.append(slice)
        rawOffset += slice.count
        checkForegroundReturnedToShell()
        guard Self.captureAlternateScreen || Self.keepScrollbackOnErase else {
            view?.feed(byteArray: slice)
            return
        }
        scanner.keepScrollbackOnErase = Self.keepScrollbackOnErase
        let (bytes, events) = scanner.scan(slice)
        guard Self.captureAlternateScreen else {
            if !bytes.isEmpty { view?.feed(byteArray: bytes[...]) }
            notifyOutput()
            return
        }
        feedCapturingAltExit(bytes, events: events)
        notifyOutput()
    }

    /// Removes every ESC[3J; everything else passes through unchanged.
    static func removingEraseScrollback(_ bytes: [UInt8]) -> [UInt8] {
        TerminalBytes.removingEraseScrollback(bytes)
    }

    private func notifyOutput() {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now &- lastOutputNotify > 500_000_000 else { return }
        lastOutputNotify = now
        let handler = onOutput
        DispatchQueue.main.async { handler?() }
    }

    func getWindowSize() -> winsize {
        let d = view?.terminalDimensions ?? TerminalDimensions(cols: 80, rows: 24)
        return winsize(ws_row: UInt16(d.rows), ws_col: UInt16(d.cols), ws_xpixel: 0, ws_ypixel: 0)
    }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        let held = scanner.flush()
        if !held.isEmpty { view?.feed(byteArray: held[...]) }
        logger.finish(exitCode: exitCode)
        let handler = onExit
        DispatchQueue.main.async { handler?(exitCode) }
    }

    // MARK: foreground program ended (shell still alive)

    /// When a program run from the shell (ssh, et, claude...) ends and the
    /// shell takes the terminal back, the next output is the shell's prompt.
    /// If the program died without leaving full-screen mode, save that screen
    /// and reset modes now, before the prompt is drawn, so the prompt lands on
    /// the normal screen and scrollback works again.
    private func checkForegroundReturnedToShell() {
        let fd = process.childfd
        let shell = process.shellPid
        guard fd >= 0, shell > 0 else { return }
        let foreground = tcgetpgrp(fd)
        guard foreground > 0 else { return }
        if foreground != shell {
            foregroundJobRunning = true
            return
        }
        guard foregroundJobRunning else { return }
        foregroundJobRunning = false
        guard let view, let state = view.terminalInputStateSnapshot() else { return }
        guard state.isAlternateBuffer || state.mouseMode != .off else { return }
        let saved = captureAlternateScreen()
        let held = scanner.flush()
        if !held.isEmpty { view.feed(byteArray: held[...]) }
        view.feed(text: Self.foregroundModeReset)
        if let saved { inject(saved, into: view, reason: "program ended without leaving full-screen mode") }
        let dropped = onProgramDropped
        DispatchQueue.main.async { dropped?() }
    }

    /// Manual rescue from the menu: same as the automatic check, forced.
    func recoverScreen() {
        queue.async {
            guard let view = self.view else { return }
            let saved = self.captureAlternateScreen()
            view.feed(text: Self.foregroundModeReset)
            if let saved { self.inject(saved, into: view, reason: "Reset Terminal") }
        }
    }

    // MARK: alternate screen capture

    /// Feeds bytes. #9: the alt screen is looked at only when a frame is complete:
    /// at the end of each synchronized update (ESC[?2026l, Claude Code wraps every
    /// frame in one), or after output pauses when the app doesn't use them; never in
    /// the middle of an update, where a half-drawn screen looks like a wrong scroll.
    /// At each alt-exit sequence, the alt screen is copied first and replayed into the
    /// normal buffer right after the switch back.
    private func feedCapturingAltExit(_ bytes: [UInt8], events: [HostOutputScanner.Event]) {
        guard let view else { return }
        var start = 0
        for event in events {
            switch event.kind {
            case .syncBegin:
                continue
            case .syncEnd:
                view.feed(byteArray: bytes[start ..< event.end])
                start = event.end
                trackAltScroll(reason: "frame")
            case .altExit:
                if event.start > start { view.feed(byteArray: bytes[start ..< event.start]) }
                trackAltScroll(reason: "exit")
                let saved = captureAlternateScreen()
                view.feed(byteArray: bytes[event.start ..< event.end])
                if let saved { inject(saved, into: view, reason: "full-screen app exited") }
                start = event.end
            }
        }
        if start < bytes.count { view.feed(byteArray: bytes[start...]) }
        if !scanner.inSyncUpdate { scheduleAltTrack() }
    }

    /// Apps without synchronized updates: look once output pauses (30 ms), but at
    /// least every 300 ms during a stream. Skipped while a frame is being drawn.
    private func scheduleAltTrack() {
        trackGeneration &+= 1
        let generation = trackGeneration
        if DispatchTime.now().uptimeNanoseconds - lastTrack.uptimeNanoseconds > 300_000_000 {
            trackAltScroll(reason: "timer300")
            return
        }
        queue.asyncAfter(deadline: .now() + .milliseconds(30)) { [weak self] in
            guard let self, self.trackGeneration == generation, !self.scanner.inSyncUpdate else { return }
            self.trackAltScroll(reason: "pause")
        }
    }

    /// #16: what the full-screen app has shown so far, for the history panel.
    /// Built on the session queue (never blocks the UI); `done` runs on the main thread.
    func capturedSoFar(_ done: @escaping ([String]) -> Void) {
        queue.async {
            let lines = Self.captureAlternateScreen ? self.altTracker.peek() : []
            DispatchQueue.main.async { done(lines) }
        }
    }

    /// Raw text rows of the alt screen, or nil when the alt screen is not active.
    private func altRows() -> [String]? {
        guard let view,
              view.terminalInputStateSnapshot()?.isAlternateBuffer == true,
              let snapshot = view.terminalContentSnapshot(region: .all, buffer: .alt)
        else { return nil }
        return snapshot.rows.map { row -> String in
            var s = row.text.replacingOccurrences(of: "\u{0}", with: " ")
            while s.last?.isWhitespace == true { s.removeLast() }
            return s
        }
    }

    /// Called after each settled frame while a full-screen app runs; the
    /// tracker keeps the lines that scroll off the top (#9).
    private func trackAltScroll(reason: String) {
        lastTrack = DispatchTime.now()
        guard Self.captureAlternateScreen, let rows = altRows() else {
            altTracker.screenGone()
            return
        }
        let observation = altTracker.observe(rows)
        if Self.debugCapture {
            let ms = Int((DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000)
            logger.appendDebug(CaptureDebug.line(ms: ms, rawOffset: rawOffset, reason: reason,
                                                 inSync: reason == "frame" ? false : scanner.inSyncUpdate, observation))
        }
    }

    /// Everything the full-screen app showed: lines that scrolled off the top,
    /// then the final screen. Nil if there is nothing. Clears the archive.
    private func captureAlternateScreen() -> [String]? {
        guard Self.captureAlternateScreen else { return nil }
        trackAltScroll(reason: "capture")
        let lines = altTracker.capture(finalRows: altRows())
        if Self.debugCapture { logger.appendDebug("capture: \(lines?.count ?? 0) lines saved") }
        return lines
    }

    /// Plain text on purpose: SwiftTerm's ANSI export also rewrites the palette.
    private func inject(_ lines: [String], into view: TerminalView, reason: String) {
        let dim = "\u{1b}[0;2m", reset = "\u{1b}[0m"
        let body = lines.joined(separator: "\r\n")
        view.feed(text: "\r\(dim)── EverTerm saved screen (\(reason)) ──\(reset)\r\n\(body)\r\n\(dim)── end of saved screen ──\(reset)\r\n")
        logger.appendNote("\n── EverTerm saved screen (\(reason)) ──\n" + lines.joined(separator: "\n") + "\n── end of saved screen ──\n")
    }
}
