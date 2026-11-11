import Foundation
import SwiftTerm

/// Owns the child process (shell, ssh, et...) for one terminal.
/// Every byte from the host goes to the disk logger first, then to the screen,
/// so history survives even if the remote host or the app dies.
/// Callbacks arrive on LocalProcess's private serial queue, not the main thread.
final class TerminalSession: LocalProcessDelegate, @unchecked Sendable {
    /// Step 3: copy a full-screen app's last screen into scrollback when it
    /// leaves the alternate screen (or when the session dies while in it).
    static var captureAlternateScreen = true

    /// Sequences that leave the alternate screen.
    private static let altExitSequences: [[UInt8]] =
        ["\u{1b}[?1049l", "\u{1b}[?1047l", "\u{1b}[?47l"].map { Array($0.utf8) }

    /// Modes left on when a foreground program dies inside the tab but the shell
    /// lives on (e.g. `et` drops). Bracketed paste (2004) is left alone: the
    /// shell turns it on itself for its own prompt.
    static let foregroundModeReset = "\u{1b}[?1049l\u{1b}[?1000l\u{1b}[?1002l\u{1b}[?1003l\u{1b}[?1006l\u{1b}[?1007l\u{1b}[?25h"

    /// Modes a dropped remote app never got to switch off (the Tabby bug).
    static let modeReset = "\u{1b}[?1049l\u{1b}[?1000l\u{1b}[?1002l\u{1b}[?1003l\u{1b}[?1006l\u{1b}[?1007l\u{1b}[?2004l\u{1b}[?25h"

    let logger: SessionLogger
    private weak var view: TerminalView?
    private var process: LocalProcess!
    private var carry: [UInt8] = []          // partial alt-exit sequence split across reads
    private var foregroundJobRunning = false // a program other than the shell owns the tty
    /// Our own serial queue: process output and foreground checks run in order on it.
    private let queue = DispatchQueue(label: "everterm.session")
    var onExit: ((Int32?) -> Void)?

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

    func resize(cols: Int, rows: Int) {
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = process.updateWindowSize(&size)
    }

    var isRunning: Bool { process.running }

    func terminate() { process.terminate() }

    /// Called on the main thread after the process ends: save the alternate
    /// screen if the app was still in it, then reset stuck modes.
    func finishScreen(banner: String) {
        guard let view else { return }
        let saved = captureAlternateScreen()
        view.feed(text: Self.modeReset)
        if let saved { inject(saved, into: view, reason: "session ended in full-screen mode") }
        view.feed(text: banner)
    }

    // MARK: LocalProcessDelegate

    func dataReceived(slice: ArraySlice<UInt8>) {
        logger.append(slice)
        checkForegroundReturnedToShell()
        guard Self.captureAlternateScreen else {
            view?.feed(byteArray: slice)
            return
        }
        var bytes = carry
        bytes.append(contentsOf: slice)
        carry = []
        // Hold back a tail that could be the start of an alt-exit sequence.
        if let esc = bytes.lastIndex(of: 0x1B), bytes.count - esc >= 3, bytes.count - esc < 8 {
            let tail = Array(bytes[esc...])
            if Self.altExitSequences.contains(where: { $0.count > tail.count && $0.starts(with: tail) }) {
                carry = tail
                bytes.removeLast(tail.count)
            }
        }
        feedCapturingAltExit(bytes)
    }

    func getWindowSize() -> winsize {
        let d = view?.terminalDimensions ?? TerminalDimensions(cols: 80, rows: 24)
        return winsize(ws_row: UInt16(d.rows), ws_col: UInt16(d.cols), ws_xpixel: 0, ws_ypixel: 0)
    }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        if !carry.isEmpty { view?.feed(byteArray: carry[...]); carry = [] }
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
        if !carry.isEmpty { view.feed(byteArray: carry[...]); carry = [] }
        view.feed(text: Self.foregroundModeReset)
        if let saved { inject(saved, into: view, reason: "program ended without leaving full-screen mode") }
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

    /// Feeds bytes; at each alt-exit sequence, copies the alt screen first and
    /// replays it into the normal buffer right after the switch back.
    private func feedCapturingAltExit(_ bytes: [UInt8]) {
        guard let view else { return }
        var start = 0
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x1B,
               let seq = Self.altExitSequences.first(where: {
                   bytes.count - i >= $0.count && bytes[i ..< i + $0.count].elementsEqual($0)
               }) {
                if i > start { view.feed(byteArray: bytes[start ..< i]) }
                let saved = captureAlternateScreen()
                view.feed(byteArray: bytes[i ..< i + seq.count])
                if let saved { inject(saved, into: view, reason: "full-screen app exited") }
                i += seq.count
                start = i
                continue
            }
            i += 1
        }
        if start < bytes.count { view.feed(byteArray: bytes[start...]) }
    }

    /// Text rows of the alternate screen, or nil if it is not active or blank.
    private func captureAlternateScreen() -> [String]? {
        guard Self.captureAlternateScreen,
              let view,
              view.terminalInputStateSnapshot()?.isAlternateBuffer == true,
              let snapshot = view.terminalContentSnapshot(region: .all, buffer: .alt)
        else { return nil }
        var lines = snapshot.rows.map { row -> String in
            var s = row.text.replacingOccurrences(of: "\u{0}", with: " ")
            while s.last?.isWhitespace == true { s.removeLast() }
            return s
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        return lines.isEmpty ? nil : lines
    }

    /// Plain text on purpose: SwiftTerm's ANSI export also rewrites the palette.
    private func inject(_ lines: [String], into view: TerminalView, reason: String) {
        let dim = "\u{1b}[0;2m", reset = "\u{1b}[0m"
        let body = lines.joined(separator: "\r\n")
        view.feed(text: "\r\(dim)── EverTerm saved screen (\(reason)) ──\(reset)\r\n\(body)\r\n\(dim)── end of saved screen ──\(reset)\r\n")
        logger.appendNote("\n── EverTerm saved screen (\(reason)) ──\n" + lines.joined(separator: "\n") + "\n── end of saved screen ──\n")
    }
}
