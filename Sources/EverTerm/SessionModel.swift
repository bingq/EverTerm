import AppKit
import Combine
import EverTermCore
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
    private(set) var startedAt = Date()
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
    /// A connect program (ssh, et...) ended with the shell still alive, or any program
    /// died without leaving full-screen mode; cleared when the next program starts.
    @Published private(set) var programDropped = false

    /// #18: last connect command run in this session (ssh, et, mosh...) and where from,
    /// plus the Claude Code resume command seen in the output. Saved in meta.json only.
    @Published private(set) var reconnectCommand: [String]? = nil
    /// #23: the same, as the typed command line, when shell integration reported it (sandbox build).
    @Published private(set) var reconnectLine: String? = nil
    private var runningLine: String?          // command running now, from shell integration
    private var runningIsConnect = false      // it reached another machine
    private(set) var reconnectDirectory: String? = nil
    @Published private(set) var resumeHint: String? = nil
    /// The saved command was shown once (it can hold a secret); later ⌘R runs it straight away.
    var reconnectConfirmed = false
    private var lastForegroundPID: pid_t?
    private var foregroundChecks = 0
    private var foregroundIsConnect = false   // the current job holds a connect program
    private var pendingInput: String?      // typed into the shell when it first prints

    /// What a reconnect carries from an ended session into the new one.
    struct Carry {
        var command: [String]?
        var directory: String?
        var resumeHint: String?
        var customName: String?
        var confirmed: Bool
        var fromName: String?        // nil: restarted in place, so no "from ended session" note
        var line: String? = nil      // #23: typed command line (shell integration)
        var marker: String? = nil    // #27: own marker text instead of "reconnected"
        var runCommand = true        // #27: false = keep the saved command but don't run it
    }

    private var title = ""
    private let shellName: String
    private let shellPath: String

    var isSelected = false {
        didSet { if isSelected, hasUnseenOutput { hasUnseenOutput = false } }
    }

    var displayName: String {
        if let customName, !customName.isEmpty { return customName }
        return autoName
    }

    var logDirectory: URL { session.logger.directory }

    init(directory: String = NSHomeDirectory(), carry: Carry? = nil) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        shellPath = shell
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
        startShell(directory: directory, carry: carry)
    }

    /// A new shell in this session's terminal. With a carry (reconnect): the saved name and
    /// command come along, a dim marker line goes first, and the command runs at the first prompt.
    private func startShell(directory: String, carry: Carry?) {
        let shell = shellPath
        session = TerminalSession(view: terminalView, command: shell)
        session.onExit = { [weak self] code in self?.processEnded(exitCode: code) }
        session.onOutput = { [weak self] in self?.noteOutput() }
        session.onProgramDropped = { [weak self] in self?.programDropped = true }
        session.logger.onResumeHint = { [weak self] hint in self?.resumeHint = hint }
        session.logger.onShellEvent = { [weak self] event in self?.shellEvent(event) }
        session.logger.onRefusedPaths = { [weak self] paths in
            guard let self else { return }
            self.onAccessRefused?(self, paths)
        }
        runningLine = nil
        runningIsConnect = false
        if let carry {
            reconnectCommand = carry.command
            reconnectLine = carry.line
            reconnectDirectory = carry.directory
            resumeHint = carry.resumeHint
            reconnectConfirmed = carry.confirmed
            customName = carry.customName          // didSet does not run in init
            if let name = carry.customName { session.logger.update(customName: name) }
            session.logger.updateReconnect(command: carry.command, directory: carry.directory,
                                           resumeHint: carry.resumeHint, line: carry.line)
            if carry.runCommand {
                pendingInput = (carry.line ?? carry.command.map(ShellCommand.join))
                    .map { ReconnectRules.keystrokes(command: $0, pressEnter: true) }
            }
            session.mark(carry.marker.map { "── \($0) ──" } ?? reconnectMarker(from: carry.fromName))
        }
        session.start(executable: shell, args: [], execName: "-" + shellName, directory: directory)
    }

    /// #18: ⌘R on an ended session: a new shell in this same session, so it keeps its place
    /// in the sidebar and the old history stays above. Same directory, same name, and the
    /// saved command (if any) runs at the first prompt. New log folder, like any new shell.
    func restart(marker: String? = nil, runCommand: Bool = true) {
        var carry = carry()
        carry.confirmed = true
        carry.fromName = nil
        carry.marker = marker
        carry.runCommand = runCommand
        status = .running
        endedAt = nil
        startedAt = Date()
        programDropped = false
        lastForegroundPID = nil
        foregroundIsConnect = false
        // The new shell gets the view's size at start (TerminalSession.getWindowSize).
        startShell(directory: carry.directory ?? NSHomeDirectory(), carry: carry)
    }

    // MARK: folder access (#27, sandboxed build)

    /// Set by the store: a program in this session was refused these paths.
    var onAccessRefused: ((SessionModel, [String]) -> Void)?
    /// Folders the user said "Not Now" to in this session: not offered again.
    var declinedFolders: Set<String> = []
    private var respawnMarker: String?

    /// The shell is at its prompt (nothing else owns the terminal).
    var isAtPrompt: Bool {
        guard status == .running, let shell = session.shellPID else { return false }
        return (session.foregroundProcessGroup() ?? shell) == shell
    }

    /// A dim note line in this session (screen and output.txt).
    func note(_ text: String) {
        session.mark("── \(text) ──")
    }

    /// End this shell and start a new one in the same session, history above kept, so it gets
    /// folder access granted after it started. The saved connect command is kept, not run.
    func respawn(marker: String) {
        guard status == .running, session.isRunning else { return }
        respawnMarker = marker
        session.hangUp()
    }

    // MARK: actions

    func terminate() {
        if session.isRunning { session.terminate() }
    }

    func resetTerminal() {
        session.recoverScreen()
    }

    // MARK: reconnect (#18)

    var reconnectCommandLine: String? { reconnectLine ?? reconnectCommand.map(ShellCommand.join) }

    var reconnectPlan: ReconnectRules.Plan {
        let shell = status == .running ? session.shellPID : nil
        let atPrompt = shell != nil && (session.foregroundProcessGroup() ?? shell) == shell
        return ReconnectRules.plan(running: status == .running, atShellPrompt: atPrompt,
                                   command: reconnectCommandLine, directory: reconnectDirectory ?? directory)
    }

    /// Same session: marker line, then the saved command typed and run at the prompt.
    func rerun(_ command: String) {
        reconnectConfirmed = true
        session.mark(reconnectMarker(from: nil),
                     thenType: ReconnectRules.keystrokes(command: command, pressEnter: true))
    }

    /// Types the saved Claude Code resume command at the prompt without pressing Enter.
    func typeResumeCommand() -> Bool {
        guard status == .running, let resumeHint else { return false }
        session.send(Array(ReconnectRules.keystrokes(command: resumeHint, pressEnter: false).utf8)[...])
        return true
    }

    func forgetReconnect() {
        reconnectCommand = nil
        reconnectLine = nil
        reconnectDirectory = nil
        resumeHint = nil
        reconnectConfirmed = false
        session.logger.updateReconnect(command: nil, directory: nil, resumeHint: nil)
    }

    func carry() -> Carry {
        Carry(command: reconnectCommand, directory: reconnectDirectory ?? directory, resumeHint: resumeHint,
              customName: customName, confirmed: reconnectConfirmed, fromName: displayName, line: reconnectLine)
    }

    private func reconnectMarker(from name: String?) -> String {
        var text = "── reconnected " + Self.clock.string(from: Date())
        if let name { text += " (from ended session “\(name)”)" }
        text += " ──"
        if resumeHint != nil { text += "  Claude session saved: ⌃⌘R types its resume command" }
        return text
    }

    /// #18: save the command line of a connect program when it takes the terminal.
    /// A launcher (`devbox connect`) can take a while (sign-in) before it starts its connect
    /// program, so the job is looked at once a second for up to a minute until one shows up.
    private func noteForeground(_ pid: pid_t) {
        if pid != lastForegroundPID {
            lastForegroundPID = pid
            foregroundChecks = 0
            foregroundIsConnect = false
        }
        guard !foregroundIsConnect, foregroundChecks < 60 else { return }
        foregroundChecks += 1
        guard let argv = ProcessInspector.arguments(of: pid) else { return }
        let direct = ReconnectRules.savedCommand(argv: argv, onPath: ProcessInspector.isOnPath)
        let others = direct == nil ? ProcessInspector.otherArguments(inJob: pid) : []
        guard let command = direct
                ?? ReconnectRules.savedCommand(job: argv, others: others, onPath: ProcessInspector.isOnPath)
        else { return }
        foregroundIsConnect = true
        reconnectCommand = command
        reconnectDirectory = directory
        session.logger.updateReconnect(command: command, directory: directory, resumeHint: resumeHint)
    }

    /// Called about once a second by the store: refresh the automatic name and directory.
    func refreshProcessInfo() {
        guard status == .running, let shell = session.shellPID else { return }
        if let cwd = ProcessInspector.currentDirectory(of: shell), cwd != directory {
            directory = cwd
            session.logger.update(directory: cwd)
        }
        let foreground = session.foregroundProcessGroup() ?? shell
        if foreground != shell {
            noteForeground(foreground)
        } else {
            // A connect job ended and the shell has the terminal back: the connection is gone
            // (dropped or closed), so ⌘R has something to do. Orange until the next program starts.
            if lastForegroundPID != nil, foregroundIsConnect { programDropped = true }
            lastForegroundPID = nil
            foregroundIsConnect = false
        }
        var name = "local " + shellName
        // Connection ended: name the session after what ⌘R will run ("et host"), not "local zsh".
        if programDropped, let command = reconnectCommandLine { name = command }
        if foreground != shell, let program = ProcessInspector.name(of: foreground) {
            if programDropped { programDropped = false }
            name = title.isEmpty ? program : title   // title alone, no "program · " prefix (#13)
        }
        if name != autoName { autoName = name }
    }

    // MARK: shell integration (#23)

    /// Commands reported by the zsh hook (sandbox build): no process reading needed.
    private func shellEvent(_ event: ShellEvent) {
        switch event {
        case .commandStarted(let line):
            runningLine = line
            runningIsConnect = false
            if programDropped { programDropped = false }
            if ConnectDetection.startsWithConnectProgram(line) { markConnect() }
        case .commandFinished:
            // The connection's command ended and the prompt is back: orange, ⌘R runs it again.
            if runningLine != nil, runningIsConnect { programDropped = true }
            runningLine = nil
            runningIsConnect = false
            refreshProcessInfo()
        }
    }

    private func markConnect() {
        guard let line = runningLine, !runningIsConnect else { return }
        runningIsConnect = true
        reconnectLine = line
        reconnectCommand = nil
        reconnectDirectory = directory
        session.logger.updateReconnect(command: nil, directory: directory, resumeHint: resumeHint, line: line)
    }

    /// This Mac's name, to tell a remote title (`me@otherhost:~`) from a local one.
    private static let localHost: String = {
        var buffer = [CChar](repeating: 0, count: 256)
        return gethostname(&buffer, buffer.count) == 0 ? String(cString: buffer) : ProcessInfo.processInfo.hostName
    }()

    // MARK: sidebar text

    var subtitle: String {
        let dir = directory.map(ProcessInspector.abbreviate) ?? ""
        switch status {
        case .running:
            if programDropped { return "connection ended · \(dir)" }
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
        if let keys = pendingInput {
            pendingInput = nil
            session.send(Array(keys.utf8)[...])
        }
        if !isSelected, status == .running, !hasUnseenOutput { hasUnseenOutput = true }
    }

    private func processEnded(exitCode: Int32?) {
        if let marker = respawnMarker {
            respawnMarker = nil
            restart(marker: marker, runCommand: false)
            return
        }
        let code = exitCode.map(String.init) ?? "signal"
        session.finishScreen(banner: "\r\n\u{1b}[2m[session ended, exit \(code); history kept in memory and on disk; ⌘R reconnects]\u{1b}[0m\r\n")
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
        // #23: a title naming another machine while a command runs: that command is a connection.
        if runningLine != nil, ConnectDetection.titleIsRemote(title, localHost: Self.localHost) { markConnect() }
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
