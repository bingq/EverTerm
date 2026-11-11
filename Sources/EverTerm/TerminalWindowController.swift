import AppKit
import SwiftTerm

/// One window = one terminal session.
/// The window stays open and scrollable after the shell or remote host ends,
/// and the full output is already on disk (see SessionLogger).
final class TerminalWindowController: NSWindowController, NSWindowDelegate, TerminalViewDelegate {
    /// Lines kept in memory per window. Costs ~8 bytes/line up front for slots;
    /// line content is allocated only as output arrives. Disk log has no limit.
    static let scrollbackLines = 1_000_000

    let terminalView: TerminalView
    private var session: TerminalSession!
    var onClose: ((TerminalWindowController) -> Void)?

    init() {
        let frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        terminalView = TerminalView(frame: frame)

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "EverTerm"
        window.contentView = terminalView
        window.center()
        super.init(window: window)
        window.delegate = self

        terminalView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        terminalView.changeScrollback(Self.scrollbackLines)
        terminalView.terminalDelegate = self

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let execName = "-" + (shell as NSString).lastPathComponent   // leading "-" = login shell
        session = TerminalSession(view: terminalView, command: shell)
        session.onExit = { [weak self] code in self?.sessionEnded(exitCode: code) }
        session.start(executable: shell, args: [], execName: execName, directory: NSHomeDirectory())
        window.makeFirstResponder(terminalView)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var sessionDirectory: URL { session.logger.directory }

    private func sessionEnded(exitCode: Int32?) {
        let code = exitCode.map(String.init) ?? "signal"
        session.finishScreen(banner: "\r\n\u{1b}[2m[session ended, exit \(code); history kept in memory and on disk]\u{1b}[0m\r\n")
        window?.title = (window?.title ?? "EverTerm") + " (ended)"
    }

    // MARK: TerminalViewDelegate

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        session?.resize(cols: newCols, rows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        window?.title = title.isEmpty ? "EverTerm" : title
        session?.logger.update(title: title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        session?.logger.update(directory: directory)
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        session?.send(data)   // keystrokes are not logged, only host output
    }

    func scrolled(source: TerminalView, position: Double) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    func bell(source: TerminalView) { NSSound.beep() }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        if session.isRunning { session.terminate() }
        onClose?(self)
    }
}
