import Foundation
import EverTermCore

/// Metadata for one session, stored as meta.json next to the logs.
struct SessionRecord: Codable {
    var id: String
    var command: String
    var title: String
    var directory: String?
    var startedAt: Date
    var endedAt: Date?
    var exitCode: Int32?
    var customName: String?      // set when the user renames the session
    // #18 reconnect. Local only; a command line can hold a secret, so it is shown
    // before the first reconnect and can be cleared (Forget Reconnect Command).
    var reconnectCommand: [String]? = nil   // last connect command run here (ssh, et, mosh...)
    var reconnectDirectory: String? = nil   // local directory it was started from
    var resumeHint: String? = nil           // e.g. "claude --resume <id>", seen in the output
}

/// Writes one session to disk as it happens:
///   ~/Library/Application Support/EverTerm/sessions/<id>/
///     output.raw   every byte from the host, unmodified (replayable, colours intact)
///     output.txt   the same output with escape codes stripped (grep-able)
///     meta.json    SessionRecord
/// All file work runs on a private serial queue; callers never block on disk.
final class SessionLogger: @unchecked Sendable {
    static let rootURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("EverTerm/sessions", isDirectory: true)
    }()

    let directory: URL
    private let queue = DispatchQueue(label: "everterm.sessionlog")
    private var record: SessionRecord
    private var raw: FileHandle?
    private var text: FileHandle?
    private var debug: FileHandle?   // capture-debug.log, opened on first use
    private var stripper = AnsiStripper()
    private var hints = ResumeHintScanner()
    /// #18: called on the main thread when a new resume command shows up in the output. Set before output starts.
    var onResumeHint: ((String) -> Void)?

    init(command: String) {
        let stamp = ISO8601DateFormatter.fileSafe.string(from: Date())
        let id = "\(stamp)-\(UUID().uuidString.prefix(8))"
        directory = Self.rootURL.appendingPathComponent(id, isDirectory: true)
        record = SessionRecord(id: id, command: command, title: command, directory: nil,
                               startedAt: Date(), endedAt: nil, exitCode: nil)
        queue.async { self.open() }
    }

    func append(_ bytes: ArraySlice<UInt8>) {
        let copy = Data(bytes)
        queue.async {
            self.raw?.write(copy)
            let plain = self.stripper.strip(copy)
            if !plain.isEmpty { self.text?.write(plain) }
            if let hint = self.hints.feed(plain), hint != self.record.resumeHint {
                self.record.resumeHint = hint
                self.writeMeta()
                let handler = self.onResumeHint
                DispatchQueue.main.async { handler?(hint) }
            }
        }
    }

    /// Clean text that goes to output.txt only (raw log stays byte-exact).
    func appendNote(_ note: String) {
        let data = Data(note.utf8)
        queue.async { self.text?.write(data) }
    }

    /// One line to capture-debug.log (only written when EVERTERM_DEBUG_CAPTURE is set).
    func appendDebug(_ line: String) {
        let data = Data((line + "\n").utf8)
        queue.async {
            if self.debug == nil {
                // Append, never recreate: lines can arrive after finish() (the final
                // capture), and recreating the file used to wipe the whole log.
                let url = self.directory.appendingPathComponent("capture-debug.log")
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                self.debug = try? FileHandle(forWritingTo: url)
                _ = try? self.debug?.seekToEnd()
            }
            self.debug?.write(data)
        }
    }

    /// customName: pass "" to clear it (back to the automatic name).
    func update(title: String? = nil, directory: String? = nil, customName: String? = nil) {
        queue.async {
            if let title, !title.isEmpty { self.record.title = title }
            if let directory { self.record.directory = directory }
            if let customName { self.record.customName = customName.isEmpty ? nil : customName }
            self.writeMeta()
        }
    }

    /// #18. nil clears.
    func updateReconnect(command: [String]?, directory: String?, resumeHint: String?) {
        queue.async {
            self.record.reconnectCommand = command
            self.record.reconnectDirectory = directory
            self.record.resumeHint = resumeHint
            self.writeMeta()
        }
    }

    func finish(exitCode: Int32?) {
        queue.async {
            self.record.endedAt = Date()
            self.record.exitCode = exitCode
            self.writeMeta()
            try? self.raw?.synchronize()
            try? self.text?.synchronize()
            try? self.raw?.close()
            try? self.text?.close()
            try? self.debug?.close()
            self.debug = nil
            self.raw = nil
            self.text = nil
        }
    }

    // MARK: private (queue only)

    private func open() {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let rawURL = directory.appendingPathComponent("output.raw")
            let txtURL = directory.appendingPathComponent("output.txt")
            fm.createFile(atPath: rawURL.path, contents: nil)
            fm.createFile(atPath: txtURL.path, contents: nil)
            raw = try FileHandle(forWritingTo: rawURL)
            text = try FileHandle(forWritingTo: txtURL)
            writeMeta()
        } catch {
            NSLog("EverTerm: cannot open session log at \(directory.path): \(error)")
        }
    }

    private func writeMeta() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(record) {
            try? data.write(to: directory.appendingPathComponent("meta.json"), options: .atomic)
        }
    }
}

extension ISO8601DateFormatter {
    /// 20261111T123456Z style, safe in file names.
    static let fileSafe: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withTimeZone]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
}
