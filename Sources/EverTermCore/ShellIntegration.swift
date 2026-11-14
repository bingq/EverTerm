import Foundation

/// #23: shell integration. A small zsh hook that EverTerm adds (see Resources/shell-integration)
/// reports each command line and its exit status as invisible OSC sequences, so EverTerm does
/// not have to read other processes (the App Sandbox refuses that):
///
///   ESC ] 6973 ; C ; <base64 command line> BEL     command started
///   ESC ] 6973 ; D ; <exit status> BEL             command finished, shell back at its prompt
///
/// ST (ESC \) is accepted in place of BEL.
public enum ShellEvent: Equatable, Sendable {
    case commandStarted(String)
    case commandFinished(exitStatus: Int32?)
}

/// Finds shell-integration sequences in host output. Feed it every chunk in order; a sequence
/// split across chunks is still found. Bytes are not changed (the terminal ignores unknown OSC).
public struct ShellIntegrationScanner: Sendable {
    public static let code = "6973"
    private static let prefix = Array("\u{1b}]\(code);".utf8)
    private static let maxPayload = 64 * 1024

    private var matched = 0            // bytes of `prefix` matched so far
    private var payload: [UInt8] = []
    private var inPayload = false
    private var sawEsc = false         // inside payload: previous byte was ESC (maybe ST)

    public init() {}

    public mutating func feed(_ bytes: some Sequence<UInt8>) -> [ShellEvent] {
        var events: [ShellEvent] = []
        for byte in bytes {
            if inPayload {
                if sawEsc {
                    sawEsc = false
                    if byte == 0x5c { finish(into: &events); continue }   // ESC \
                    reset()                                               // broken sequence
                    if byte == 0x1b { matched = 1 }
                    continue
                }
                switch byte {
                case 0x07: finish(into: &events)
                case 0x1b: sawEsc = true
                default:
                    payload.append(byte)
                    if payload.count > Self.maxPayload { reset() }
                }
                continue
            }
            if byte == Self.prefix[matched] {
                matched += 1
                if matched == Self.prefix.count { inPayload = true; matched = 0 }
            } else {
                matched = byte == Self.prefix[0] ? 1 : 0
            }
        }
        return events
    }

    private mutating func finish(into events: inout [ShellEvent]) {
        if let event = Self.parse(payload) { events.append(event) }
        reset()
    }

    private mutating func reset() {
        payload.removeAll(keepingCapacity: true)
        inPayload = false
        sawEsc = false
        matched = 0
    }

    static func parse(_ payload: [UInt8]) -> ShellEvent? {
        guard let text = String(bytes: payload, encoding: .utf8) else { return nil }
        let parts = text.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "C":
            guard let data = Data(base64Encoded: String(parts[1])),
                  let line = String(data: data, encoding: .utf8) else { return nil }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : .commandStarted(trimmed)
        case "D":
            return .commandFinished(exitStatus: Int32(parts[1]))
        default:
            return nil
        }
    }
}

/// #23: which typed command lines are worth saving for ⌘R, without reading processes.
public enum ConnectDetection {
    /// The command starts with a connect program (`ssh host`, `env X=1 et host`, `/usr/bin/ssh -p 22 h`).
    public static func startsWithConnectProgram(_ line: String) -> Bool {
        var words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        while let first = words.first, first == "env" || first == "command" || first == "exec"
                || (first.contains("=") && !first.hasPrefix("-") && !first.hasPrefix("=")) {
            words.removeFirst()
        }
        guard words.count >= 2 else { return false }
        return ReconnectRules.connectPrograms.contains(ReconnectRules.baseName(words[0]))
    }

    /// The terminal title names another machine: `me@otherhost:~` or `me@otherhost: ~/x`.
    /// Shells on a remote host set that, so whatever command is running reached another
    /// machine (ssh, et, a launcher, kubectl exec...). `localHost` is this Mac's name.
    public static func titleIsRemote(_ title: String, localHost: String) -> Bool {
        guard let at = title.firstIndex(of: "@") else { return false }
        let afterAt = title[title.index(after: at)...]
        let host = afterAt.prefix { $0 != ":" && $0 != " " && $0 != "/" }
        guard !host.isEmpty, title[..<at].allSatisfy({ !$0.isWhitespace }) else { return false }
        return shortName(String(host)) != shortName(localHost)
    }

    static func shortName(_ host: String) -> String {
        (host.split(separator: ".").first.map(String.init) ?? host).lowercased()
    }
}
