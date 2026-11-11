import Foundation
import SwiftTerm

/// Owns the child process (shell, ssh, et...) for one terminal.
/// Every byte from the host goes to the disk logger first, then to the screen,
/// so history survives even if the remote host or the app dies.
/// Callbacks arrive on LocalProcess's private serial queue, not the main thread.
final class TerminalSession: LocalProcessDelegate, @unchecked Sendable {
    let logger: SessionLogger
    private weak var view: TerminalView?
    private var process: LocalProcess!
    var onExit: ((Int32?) -> Void)?

    init(view: TerminalView, command: String) {
        self.view = view
        self.logger = SessionLogger(command: command)
        self.process = LocalProcess(delegate: self)
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

    // MARK: LocalProcessDelegate

    func dataReceived(slice: ArraySlice<UInt8>) {
        logger.append(slice)
        view?.feed(byteArray: slice)
    }

    func getWindowSize() -> winsize {
        let d = view?.terminalDimensions ?? TerminalDimensions(cols: 80, rows: 24)
        return winsize(ws_row: UInt16(d.rows), ws_col: UInt16(d.cols), ws_xpixel: 0, ws_ypixel: 0)
    }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        logger.finish(exitCode: exitCode)
        let handler = onExit
        DispatchQueue.main.async { handler?(exitCode) }
    }
}
