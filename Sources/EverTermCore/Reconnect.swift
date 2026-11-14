import Foundation

/// #18: reconnect a dropped or ended session from what EverTerm saved about it.
/// Everything here is plain logic; the app reads the process and the screen and calls in.
public enum ReconnectRules {
    /// Programs whose command line is worth saving: they connect somewhere, so running
    /// them again gets you back. Anything else (vim, claude, make...) is not saved.
    public static let connectPrograms: Set<String> = ["ssh", "et", "mosh", "autossh", "telnet"]

    /// What ⌘R does for one session.
    public enum Plan: Equatable, Sendable {
        /// Shell alive and at its prompt: type the saved command again in this session.
        case rerun(command: String)
        /// Session ended: open a new session in this directory, running the command (if any).
        case newSession(directory: String?, command: String?)
        /// A program still owns the terminal (the connection is up): nothing to do.
        case busy
        /// Shell at its prompt but no connect command was seen in this session.
        case nothingSaved
    }

    public static func plan(running: Bool, atShellPrompt: Bool,
                            command: String?, directory: String?) -> Plan {
        guard running else { return .newSession(directory: directory, command: command) }
        guard atShellPrompt else { return .busy }
        guard let command else { return .nothingSaved }
        return .rerun(command: command)
    }

    /// The command line to save for a foreground program, or nil if it isn't a connect program.
    /// Script launchers are unwrapped: mosh is a Perl script, so the process shows up as
    /// `perl /path/to/mosh host`. Its helper mosh-client is not a command you type: nil.
    ///
    /// `onPath` says whether a short name finds a program on PATH: then `/usr/bin/ssh` is
    /// saved as `ssh`, like you typed it; if not (a tool kept in a private folder and started
    /// by a launcher), the full path is kept. Default: everything is on PATH.
    public static func savedCommand(argv: [String],
                                    onPath: (String) -> Bool = { _ in true }) -> [String]? {
        var args = argv
        if args.count >= 2, interpreters.contains(baseName(args[0])),
           connectPrograms.contains(baseName(args[1])) {
            args.removeFirst()
        }
        guard let first = args.first, connectPrograms.contains(baseName(first)) else { return nil }
        guard args.count >= 2 else { return nil }   // bare `ssh` prints usage; nothing to reconnect to
        args[0] = shortName(first, onPath: onPath)
        return args
    }

    /// The command line to save for a whole job: the program you typed (`job`) and the
    /// processes it started (`others`). A launcher you type (`devbox connect`) that runs a
    /// connect program underneath is saved as typed, so ⌘R runs the launcher again.
    /// ssh run by another tool to do one thing (git push, rsync, scp: a command after the
    /// host, no -t) does not count, so `git push` is never saved.
    public static func savedCommand(job: [String], others: [[String]],
                                    onPath: (String) -> Bool = { _ in true }) -> [String]? {
        if let direct = savedCommand(argv: job, onPath: onPath) { return direct }
        guard !job.isEmpty, others.contains(where: isInteractiveConnect) else { return nil }
        // A launcher script runs as `<runner> <script file> <args>`: a shebang script
        // (`bash /usr/local/bin/devbox connect`) or a runner that keeps its scripts in a
        // cache folder (`runner /cache/devbox.runner connect`). If the script's name without
        // its extension is a command on PATH, that is what you typed: `devbox connect`.
        if job.count >= 2, job[1].hasPrefix("/") {
            let stem = scriptStem(job[1])
            if !stem.isEmpty, onPath(stem) { return [stem] + job.dropFirst(2) }
        }
        var args = job
        if args.count >= 2, interpreters.contains(baseName(args[0])), !args[1].hasPrefix("-") {
            args.removeFirst()
        }
        args[0] = shortName(args[0], onPath: onPath)
        return args
    }

    static func shortName(_ program: String, onPath: (String) -> Bool) -> String {
        guard program.contains("/") else { return program }
        let name = baseName(program)
        return onPath(name) ? name : program
    }

    /// "/cache/devbox.runner" -> "devbox"; "/usr/local/bin/devbox" -> "devbox".
    static func scriptStem(_ path: String) -> String {
        let name = baseName(path)
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
        return String(name[..<dot])
    }

    /// A connect program that gives you a remote shell (not one remote command).
    static func isInteractiveConnect(_ argv: [String]) -> Bool {
        guard let args = savedCommand(argv: argv) else { return false }
        switch args[0] {
        case "ssh": return !SSHArguments.runsRemoteCommand(Array(args.dropFirst()), autossh: false)
        case "autossh": return !SSHArguments.runsRemoteCommand(Array(args.dropFirst()), autossh: true)
        default: return true
        }
    }

    /// Keys sent to the shell to run a command: Ctrl-U clears anything half-typed first.
    public static func keystrokes(command: String, pressEnter: Bool) -> String {
        "\u{15}" + command + (pressEnter ? "\r" : "")
    }

    private static let interpreters: Set<String> = ["perl", "perl5", "python", "python3", "sh", "bash", "zsh"]

    public static func baseName(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}

/// Reads an ssh argument list: does it run one remote command instead of a login shell?
enum SSHArguments {
    /// ssh options that take a value (`-p 2222` or `-p2222`). autossh adds `-M port`.
    private static let withValue = Set("BbcDEeFIiJLlmOoPpQRSWw")

    static func runsRemoteCommand(_ args: [String], autossh: Bool) -> Bool {
        var positional: [String] = []
        var forcedTTY = false
        var index = 0
        while index < args.count {
            let arg = args[index]
            index += 1
            if !positional.isEmpty || !arg.hasPrefix("-") || arg == "-" {
                positional.append(arg)
                continue
            }
            if arg == "--" {
                positional.append(contentsOf: args[index...])
                break
            }
            for (offset, flag) in arg.dropFirst().enumerated() {
                if flag == "t" { forcedTTY = true }
                if withValue.contains(flag) || (autossh && flag == "M") {
                    if offset == arg.count - 2 { index += 1 }   // value is the next word
                    break                                     // value is the rest of this word
                }
            }
        }
        // positional[0] is the host; anything after it is a remote command.
        // -t asks for a terminal: an interactive command such as `tmux attach`.
        return positional.count > 1 && !forcedTTY
    }
}

/// Turns an argument list back into one line you could type into a shell.
public enum ShellCommand {
    public static func join(_ argv: [String]) -> String {
        argv.map(quote).joined(separator: " ")
    }

    /// Single quotes unless the word is made only of characters every shell leaves alone.
    public static func quote(_ word: String) -> String {
        if !word.isEmpty, word.unicodeScalars.allSatisfy({ safe.contains($0) }) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static let safe = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./_-")
}

/// macOS `sysctl(KERN_PROCARGS2)` buffer: Int32 argc, the executable path, NUL padding,
/// then argc NUL-terminated arguments, then the environment (ignored).
public enum ProcessArguments {
    public static func parse(_ buffer: [UInt8]) -> [String]? {
        let intSize = MemoryLayout<Int32>.size
        guard buffer.count > intSize else { return nil }
        let argc = buffer.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        guard argc > 0, argc < 4096 else { return nil }
        var index = intSize
        while index < buffer.count, buffer[index] != 0 { index += 1 }   // executable path
        while index < buffer.count, buffer[index] == 0 { index += 1 }   // padding
        var args: [String] = []
        while args.count < argc, index < buffer.count {
            let start = index
            while index < buffer.count, buffer[index] != 0 { index += 1 }
            guard index < buffer.count else { return nil }               // truncated
            args.append(String(decoding: buffer[start ..< index], as: UTF8.self))
            index += 1
        }
        return args.count == argc ? args : nil
    }
}

/// Watches plain session text (escape codes already stripped) for the line Claude Code
/// prints when it exits:
///     Resume this session with:
///     claude --resume 250df699-6466-474b-85a7-470e714578c9
/// The line must be exactly that command (so the "Tip: Run claude --resume to resume"
/// hint, which has no session id, does not count). Lines can arrive split across reads.
public struct ResumeHintScanner: Sendable {
    private var line: [UInt8] = []
    private static let maxLine = 4096

    public init() {}

    /// Feed the next plain-text bytes; returns the newest resume command completed in them.
    public mutating func feed<S: Sequence>(_ bytes: S) -> String? where S.Element == UInt8 {
        var found: String?
        for byte in bytes {
            if byte == 0x0A {
                if let hint = Self.hint(in: line) { found = hint }
                line.removeAll(keepingCapacity: true)
            } else if line.count < Self.maxLine {
                line.append(byte)
            }
        }
        return found
    }

    /// "claude --resume <uuid>" (or `-r`) on a line of its own, normalised.
    public static func hint(in line: [UInt8]) -> String? {
        let words = String(decoding: line, as: UTF8.self)
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\u{a0}" })
        guard words.count == 3, words[0] == "claude",
              words[1] == "--resume" || words[1] == "-r",
              let id = UUID(uuidString: String(words[2])) else { return nil }
        return "claude --resume " + id.uuidString.lowercased()
    }
}
