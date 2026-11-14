import XCTest
@testable import EverTermCore

/// #18: reconnect rules, command-line reading and the Claude resume hint.
final class ReconnectTests: XCTestCase {
    typealias R = ReconnectRules

    // MARK: what ⌘R does

    func testPlan() {
        // Orange dot (or any drop): shell back at its prompt, connect command saved -> run it again here.
        XCTAssertEqual(R.plan(running: true, atShellPrompt: true, command: "et host", directory: "/w"),
                       .rerun(command: "et host"))
        // Connection still up: ⌘R does nothing.
        XCTAssertEqual(R.plan(running: true, atShellPrompt: false, command: "et host", directory: "/w"), .busy)
        // Local shell, never connected anywhere.
        XCTAssertEqual(R.plan(running: true, atShellPrompt: true, command: nil, directory: "/w"), .nothingSaved)
        // Ended (grey/red): new session in the same directory, same command if there was one.
        XCTAssertEqual(R.plan(running: false, atShellPrompt: false, command: "ssh h", directory: "/w"),
                       .newSession(directory: "/w", command: "ssh h"))
        XCTAssertEqual(R.plan(running: false, atShellPrompt: false, command: nil, directory: "/w"),
                       .newSession(directory: "/w", command: nil))
    }

    func testKeystrokesClearHalfTypedInputFirst() {
        XCTAssertEqual(R.keystrokes(command: "et host", pressEnter: true), "\u{15}et host\r")
        // Resume hint: typed but not run, so you can check it first.
        XCTAssertEqual(R.keystrokes(command: "claude --resume x", pressEnter: false), "\u{15}claude --resume x")
    }

    // MARK: which commands are saved

    func testConnectProgramsAreSaved() {
        XCTAssertEqual(R.savedCommand(argv: ["et", "host:8080"]), ["et", "host:8080"])
        XCTAssertEqual(R.savedCommand(argv: ["/usr/bin/ssh", "-p", "2222", "me@host"]), ["ssh", "-p", "2222", "me@host"])
        XCTAssertEqual(R.savedCommand(argv: ["autossh", "-M", "0", "host"]), ["autossh", "-M", "0", "host"])
        // mosh is a Perl script: unwrap the interpreter.
        XCTAssertEqual(R.savedCommand(argv: ["/usr/bin/perl", "/opt/homebrew/bin/mosh", "host"]), ["mosh", "host"])
    }

    func testOtherProgramsAreNotSaved() {
        XCTAssertNil(R.savedCommand(argv: ["vim", "notes.txt"]))
        XCTAssertNil(R.savedCommand(argv: ["claude"]))
        XCTAssertNil(R.savedCommand(argv: ["mosh-client", "-#", "host", "1.2.3.4", "60001"]))  // mosh's helper
        XCTAssertNil(R.savedCommand(argv: ["/usr/bin/perl", "script.pl"]))
        XCTAssertNil(R.savedCommand(argv: ["ssh"]))      // usage message, nowhere to go
        XCTAssertNil(R.savedCommand(argv: []))
    }

    // MARK: launchers and the job's other processes (Mac run 1 of #18)

    /// A launcher you type, with et kept in a private folder (not on PATH) underneath it.
    let privateET = ["/Users/me/.devbox/tools/et", "devbox.ssh.et"]

    func testLauncherIsSavedAsTyped() {
        XCTAssertEqual(R.savedCommand(job: ["devbox", "connect"], others: [privateET]), ["devbox", "connect"])
        // Launcher script: the kernel shows `bash /usr/local/bin/devbox connect`.
        XCTAssertEqual(R.savedCommand(job: ["/bin/bash", "/usr/local/bin/devbox", "connect"], others: [privateET]),
                       ["/usr/local/bin/devbox", "connect"])
        // Interactive ssh underneath, with options.
        XCTAssertEqual(R.savedCommand(job: ["jump"], others: [["ssh", "-p", "2222", "-i", "/k", "me@host"]]), ["jump"])
        XCTAssertEqual(R.savedCommand(job: ["jump"], others: [["ssh", "-t", "host", "tmux", "attach"]]), ["jump"])
    }

    func testDirectConnectStillWinsOverItsChildren() {
        XCTAssertEqual(R.savedCommand(job: ["ssh", "host"], others: [["ssh", "-W", "x:22", "jump"]]), ["ssh", "host"])
        XCTAssertNil(R.savedCommand(job: ["vim", "notes"], others: []))
        XCTAssertNil(R.savedCommand(job: [], others: [privateET]))
    }

    func testOneShotSSHUnderAToolIsNotSaved() {
        XCTAssertNil(R.savedCommand(job: ["git", "push"],
                                    others: [["ssh", "-o", "SendEnv=GIT_PROTOCOL", "git@github.com", "git-receive-pack 'me/r.git'"]]))
        XCTAssertNil(R.savedCommand(job: ["rsync", "-a", "x", "host:y"], others: [["ssh", "-l", "me", "host", "rsync", "--server", "."]]))
        XCTAssertNil(R.savedCommand(job: ["scp", "f", "host:"], others: [["/usr/bin/ssh", "-x", "-oForwardAgent=no", "host", "scp", "-t", "."]]))
        XCTAssertNil(R.savedCommand(job: ["make"], others: [["cc", "-c", "a.c"]]))
    }

    func testSSHRemoteCommandParsing() {
        XCTAssertFalse(SSHArguments.runsRemoteCommand(["host"], autossh: false))
        XCTAssertFalse(SSHArguments.runsRemoteCommand(["-p", "2222", "host"], autossh: false))
        XCTAssertFalse(SSHArguments.runsRemoteCommand(["-p2222", "-A", "host"], autossh: false))
        XCTAssertTrue(SSHArguments.runsRemoteCommand(["-p2222", "host", "uptime"], autossh: false))
        XCTAssertTrue(SSHArguments.runsRemoteCommand(["-o", "X=1", "host", "ls"], autossh: false))
        XCTAssertFalse(SSHArguments.runsRemoteCommand(["-tt", "host", "htop"], autossh: false))
        XCTAssertFalse(SSHArguments.runsRemoteCommand(["-M", "0", "host"], autossh: true))
        XCTAssertTrue(SSHArguments.runsRemoteCommand(["-M", "host", "ls"], autossh: false))  // ssh -M takes no value
        XCTAssertTrue(SSHArguments.runsRemoteCommand(["--", "host", "ls"], autossh: false))
    }

    func testPrivateFolderProgramKeepsItsPath() {
        // et started by a launcher that exec'd it: not on PATH, so keep the full path.
        XCTAssertEqual(R.savedCommand(argv: privateET, typedName: { $0 }), privateET)
        XCTAssertEqual(R.savedCommand(argv: ["/usr/bin/ssh", "host"], typedName: R.baseName), ["ssh", "host"])
        XCTAssertEqual(R.savedCommand(argv: ["et", "host"], typedName: { _ in "wrong" }), ["et", "host"])  // typed bare: as is
    }

    func testShellQuoting() {
        XCTAssertEqual(ShellCommand.join(["ssh", "-p", "2222", "me@host"]), "ssh -p 2222 me@host")
        XCTAssertEqual(ShellCommand.join(["ssh", "host", "ls ~/x"]), "ssh host 'ls ~/x'")
        XCTAssertEqual(ShellCommand.join(["et", "it's"]), "et 'it'\\''s'")
        XCTAssertEqual(ShellCommand.join(["ssh", ""]), "ssh ''")
        XCTAssertEqual(ShellCommand.join(["ssh", "~host"]), "ssh '~host'")   // a bare ~ would be expanded
    }

    // MARK: KERN_PROCARGS2

    private func procargs(_ args: [String], exec: String = "/usr/bin/ssh", padding: Int = 3,
                          env: [String] = ["HOME=/Users/me"]) -> [UInt8] {
        var argc = Int32(args.count)
        var bytes = withUnsafeBytes(of: &argc) { Array($0) }
        bytes += Array(exec.utf8) + [0] + Array(repeating: 0, count: padding)
        for word in args + env { bytes += Array(word.utf8) + [0] }
        return bytes
    }

    func testParseProcArgs() {
        XCTAssertEqual(ProcessArguments.parse(procargs(["ssh", "-p", "2222", "host"])), ["ssh", "-p", "2222", "host"])
        XCTAssertEqual(ProcessArguments.parse(procargs(["et", "host"], padding: 0)), ["et", "host"])
        XCTAssertEqual(ProcessArguments.parse(procargs(["ssh", "héllo"])), ["ssh", "héllo"])
    }

    func testParseProcArgsRejectsBadBuffers() {
        XCTAssertNil(ProcessArguments.parse([]))
        XCTAssertNil(ProcessArguments.parse([1, 0, 0]))
        let full = procargs(["ssh", "host"], env: [])
        XCTAssertNil(ProcessArguments.parse(Array(full.dropLast(2))))   // cut inside the last argument
        var zero = procargs([], env: [])
        zero[0] = 0
        XCTAssertNil(ProcessArguments.parse(zero))
    }

    // MARK: Claude Code resume hint

    /// The bytes Claude Code writes when it exits, as in a real Mac session log (id replaced).
    private let claudeExit = Array(("\u{1b}[?1000l\u{1b}[?25h\u{1b}7\u{1b}[r\u{1b}8\u{1b}]7501;state=clear\u{07}\u{1b}]0;\u{07}"
        + "\u{1b}[2m\u{1b}[22m\r\n\u{1b}[2mResume this session with:\u{1b}[22m\r\n"
        + "\u{1b}[2mclaude --resume 0E5B1C2A-1111-4222-8333-444455556666\u{1b}[22m\r\n"
        + "\u{1b}[2m\u{1b}[22m\u{1b}[?25h\u{1b}[1m\u{1b}[7m%\u{1b}[27m").utf8)

    private func scan(_ raw: [UInt8], chunk: Int) -> String? {
        var stripper = AnsiStripper()
        var scanner = ResumeHintScanner()
        var found: String?
        var index = 0
        while index < raw.count {
            let end = min(index + chunk, raw.count)
            let plain = stripper.strip(Data(raw[index ..< end]))
            if let hint = scanner.feed(plain) { found = hint }
            index = end
        }
        return found
    }

    func testResumeHintFromRealExitBytes() {
        // Same path as the app: strip escape codes, then scan, at any read size.
        for chunk in [1, 2, 7, 64, claudeExit.count] {
            XCTAssertEqual(scan(claudeExit, chunk: chunk), "claude --resume 0e5b1c2a-1111-4222-8333-444455556666",
                           "chunk \(chunk)")
        }
    }

    func testTipLineIsNotAHint() {
        let tip = Array("  ⎿  Tip: Run claude --continue or claude --resume to resume a conversation\n".utf8)
        XCTAssertNil(scan(tip, chunk: 16))
        XCTAssertNil(ResumeHintScanner.hint(in: Array("claude --resume notanid".utf8)))
        XCTAssertNil(ResumeHintScanner.hint(in: Array("% claude --resume 0e5b1c2a-1111-4222-8333-444455556666".utf8)))
    }

    func testShortFlagAndNewestHintWins() {
        var scanner = ResumeHintScanner()
        XCTAssertEqual(scanner.feed(Array("claude -r 0e5b1c2a-1111-4222-8333-444455556666\n".utf8)),
                       "claude --resume 0e5b1c2a-1111-4222-8333-444455556666")
        let two = "claude --resume 0e5b1c2a-1111-4222-8333-444455556666\nclaude --resume 11111111-2222-4333-8444-555555555555\n"
        XCTAssertEqual(scanner.feed(Array(two.utf8)), "claude --resume 11111111-2222-4333-8444-555555555555")
        XCTAssertNil(scanner.feed(Array("claude --resume 0e5b1c2a-1111-4222-8333-444455556666".utf8)))  // no newline yet
        XCTAssertEqual(scanner.feed([0x0A]), "claude --resume 0e5b1c2a-1111-4222-8333-444455556666")
    }
}
