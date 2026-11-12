import AppKit
import Combine
import SwiftTerm

/// One session in the sidebar: its terminal view, process, name and status.
/// The terminal keeps running when another session is selected.
@MainActor
final class SessionModel: ObservableObject, Identifiable, TerminalViewDelegate {
    enum Status: Equatable {
        case running
        case ended(exitCode: Int32?)   // nil = killed by a signal
    }

    /// Lines kept in memory per session. Costs ~8 bytes/line up front for slots;
    /// line content is allocated only as output arrives. Disk log has no limit.
    static let scrollbackLines = 1_000_000

    let id = UUID()
    let terminalView: TerminalView
    let startedAt = Date()
    private(set) var session: TerminalSession!

    /// The foreground program's title (e.g. "Cross-screen text generation"); the program
    /// name (e.g. "ssh") only when it sets no title; "local zsh" at the shell prompt.
    @Published private(set) var autoName: String
    /// Set by Rename. nil = use the automatic name.
    @Published var customName: String? = nil {
        didSet { session.logger.update(customName: customName ?? "") }
    }
    @Published private(set) var directory: String? = nil
    @Published private(set) var status: Status = .running
    @Published private(set) var endedAt: Date? = nil
    @Published private(set) var hasUnseenOutput = false
    /// A program (ssh, et...) died without leaving full-screen mode; cleared
    /// when the next program starts.
    @Published private(set) var programDropped = false

    private var title = ""
    private let shellName: String

    var isSelected = false {
        didSet { if isSelected, hasUnseenOutput { hasUnseenOutput = false } }
    }

    var displayName: String {
        if let customName, !customName.isEmpty { return customName }
        return autoName
    }

    var logDirectory: URL { session.logger.directory }

    init(directory: String = NSHomeDirectory()) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        shellName = (shell as NSString).lastPathComponent
        autoName = "local " + shellName
        self.directory = directory
        terminalView = TerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        terminalView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        terminalView.changeScrollback(Self.scrollbackLines)
        // #12: always-visible scroll bar. SwiftTerm narrows the columns by its width
        // and disables it on the alternate screen. Overlay style becomes a setting in step 5.
        terminalView.scrollerStyle = .legacy
        terminalView.autoresizingMask = [.width, .height]
        terminalView.terminalDelegate = self

        session = TerminalSession(view: terminalView, command: shell)
        session.onExit = { [weak self] code in self?.processEnded(exitCode: code) }
        session.onOutput = { [weak self] in self?.noteOutput() }
        session.onProgramDropped = { [weak self] in self?.programDropped = true }
        session.start(executable: shell, args: [], execName: "-" + shellName, directory: directory)
    }

    // MARK: actions

    func terminate() {
        if session.isRunning { session.terminate() }
    }

    func resetTerminal() {
        session.recoverScreen()
    }

    /// Called about once a second by the store: refresh the automatic name and directory.
    func refreshProcessInfo() {
        guard status == .running, let shell = session.shellPID else { return }
        if let cwd = ProcessInspector.currentDirectory(of: shell), cwd != directory {
            directory = cwd
            session.logger.update(directory: cwd)
        }
        let foreground = session.foregroundProcessGroup() ?? shell
        var name = "local " + shellName
        if foreground != shell, let program = ProcessInspector.name(of: foreground) {
            if programDropped { programDropped = false }
            name = title.isEmpty ? program : title   // title alone, no "program · " prefix (#13)
        }
        if name != autoName { autoName = name }
    }

    // MARK: sidebar text

    var subtitle: String {
        let dir = directory.map(ProcessInspector.abbreviate) ?? ""
        switch status {
        case .running:
            if programDropped { return "connection dropped · \(dir)" }
            return [dir, "since " + Self.clock.string(from: startedAt)]
                .filter { !$0.isEmpty }.joined(separator: " · ")
        case .ended(let code):
            let how = code.map { "exit \($0)" } ?? "killed"
            let when = endedAt.map { Self.clock.string(from: $0) } ?? ""
            return "\(how) · ended \(when)"
        }
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    // MARK: private

    private func noteOutput() {
        if !isSelected, status == .running, !hasUnseenOutput { hasUnseenOutput = true }
    }

    private func processEnded(exitCode: Int32?) {
        let code = exitCode.map(String.init) ?? "signal"
        session.finishScreen(banner: "\r\n\u{1b}[2m[session ended, exit \(code); history kept in memory and on disk]\u{1b}[0m\r\n")
        status = .ended(exitCode: exitCode)
        endedAt = Date()
        programDropped = false
    }

    // MARK: TerminalViewDelegate

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        session?.resize(cols: newCols, rows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        self.title = title
        session?.logger.update(title: title)
        refreshProcessInfo()
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

    /// #16: an app asked to put text on the clipboard (OSC 52). Claude Code does this
    /// when you select text in its own view. Write only: clipboardRead stays unimplemented
    /// (SwiftTerm's default returns nil), so a program can't read what you copied elsewhere.
    func clipboardCopy(source: TerminalView, content: Data) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(String(decoding: content, as: UTF8.self), forType: .string)
    }
}
