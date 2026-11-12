import Foundation

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
                let url = self.directory.appendingPathComponent("capture-debug.log")
                FileManager.default.createFile(atPath: url.path, contents: nil)
                self.debug = try? FileHandle(forWritingTo: url)
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

/// Streaming escape-code stripper: keeps printable text, newlines and tabs.
/// State carries across chunks, so a sequence split between two reads is handled.
struct AnsiStripper {
    private enum State { case ground, esc, csi, string, stringEsc }
    private var state: State = .ground

    mutating func strip(_ input: Data) -> Data {
        var out = Data()
        out.reserveCapacity(input.count)
        for b in input {
            switch state {
            case .ground:
                switch b {
                case 0x1B: state = .esc
                case 0x0A, 0x09: out.append(b)
                case 0x00...0x1F, 0x7F: break          // other controls (CR, BS, BEL...)
                default: out.append(b)                 // printable ASCII and UTF-8 bytes
                }
            case .esc:
                switch b {
                case UInt8(ascii: "["): state = .csi
                case UInt8(ascii: "]"), UInt8(ascii: "P"), UInt8(ascii: "X"),
                     UInt8(ascii: "^"), UInt8(ascii: "_"): state = .string   // OSC / DCS / SOS / PM / APC
                case 0x20...0x2F: break                // intermediate, wait for final byte
                default: state = .ground               // two-byte escape (ESC 7, ESC =, ...)
                }
            case .csi:
                if (0x40...0x7E).contains(b) { state = .ground }
            case .string:
                if b == 0x07 { state = .ground }        // BEL terminator
                else if b == 0x1B { state = .stringEsc }
            case .stringEsc:
                state = (b == UInt8(ascii: "\\")) ? .ground : .string
            }
        }
        return out
    }
}
