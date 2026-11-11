import AppKit
import SwiftTerm

/// One window = one terminal session running the user's login shell.
/// Step 1: the window stays open (and scrollable) after the shell/remote exits.
final class TerminalWindowController: NSWindowController, NSWindowDelegate, LocalProcessTerminalViewDelegate {
    let terminalView: LocalProcessTerminalView
    var onClose: ((TerminalWindowController) -> Void)?

    init() {
        let frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        terminalView = LocalProcessTerminalView(frame: frame)

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
        terminalView.changeScrollback(100_000)   // step 2 makes this unlimited + disk-backed
        terminalView.processDelegate = self

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let execName = "-" + (shell as NSString).lastPathComponent   // leading "-" = login shell
        terminalView.startProcess(
            executable: shell,
            args: [],
            environment: Terminal.getEnvironmentVariables(termName: "xterm-256color"),
            execName: execName,
            currentDirectory: NSHomeDirectory()
        )
        window.makeFirstResponder(terminalView)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        window?.title = title.isEmpty ? "EverTerm" : title
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Leave alternate screen, turn off mouse/scroll tracking and bracketed paste,
            // show cursor: the cleanup a dropped remote app never sent (the Tabby bug).
            self.terminalView.feed(text: "\u{1b}[?1049l\u{1b}[?1000l\u{1b}[?1002l\u{1b}[?1003l\u{1b}[?1006l\u{1b}[?1007l\u{1b}[?2004l\u{1b}[?25h")
            let code = exitCode.map(String.init) ?? "signal"
            self.terminalView.feed(text: "\r\n\u{1b}[2m[session ended, exit \(code); history kept]\u{1b}[0m\r\n")
            self.window?.title = (self.window?.title ?? "EverTerm") + " (ended)"
        }
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        onClose?(self)
    }
}
