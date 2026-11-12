/// Splits host output into what the screen should get and the points where
/// EverTerm must act: the start and end of a synchronized update (DEC mode 2026,
/// used by Claude Code for every frame) and leaving the alternate screen.
/// A sequence split across two reads is held back and joined with the next read.
public struct HostOutputScanner: Sendable {
    public enum Kind: Equatable, Sendable {
        case syncBegin   // ESC[?2026h: the app starts drawing a frame
        case syncEnd     // ESC[?2026l: the frame is complete
        case altExit     // ESC[?1049l / ?1047l / ?47l: the app leaves full-screen mode
    }

    /// `start ..< end` is the sequence's position in the `bytes` returned with it.
    public struct Event: Equatable, Sendable {
        public let kind: Kind
        public let start: Int
        public let end: Int
    }

    public static let syncBegin: [UInt8] = Array("\u{1b}[?2026h".utf8)
    public static let syncEnd: [UInt8] = Array("\u{1b}[?2026l".utf8)
    public static let altExits: [[UInt8]] = ["\u{1b}[?1049l", "\u{1b}[?1047l", "\u{1b}[?47l"].map { Array($0.utf8) }

    private static let watched: [[UInt8]] = altExits + [syncBegin, syncEnd, TerminalBytes.eraseScrollback]

    /// #14: drop ESC[3J so no program can erase scrollback.
    public var keepScrollbackOnErase: Bool
    /// True between ESC[?2026h and ESC[?2026l: the screen is half drawn.
    public private(set) var inSyncUpdate = false
    private var carry: [UInt8] = []

    public init(keepScrollbackOnErase: Bool = true) {
        self.keepScrollbackOnErase = keepScrollbackOnErase
    }

    /// The bytes to feed (carry from the last read included, a possible partial
    /// sequence at the end held back) and the events found in them, in order.
    public mutating func scan(_ input: ArraySlice<UInt8>) -> (bytes: [UInt8], events: [Event]) {
        var bytes = carry
        bytes.append(contentsOf: input)
        carry = []
        if let esc = bytes.lastIndex(of: 0x1B), bytes.count - esc < 8 {
            let tail = Array(bytes[esc...])
            if Self.watched.contains(where: { $0.count > tail.count && $0.starts(with: tail) }) {
                carry = tail
                bytes.removeLast(tail.count)
            }
        }
        if keepScrollbackOnErase { bytes = TerminalBytes.removingEraseScrollback(bytes) }
        var events: [Event] = []
        var i = 0
        while i < bytes.count {
            guard bytes[i] == 0x1B else { i += 1; continue }
            if let kind = Self.match(bytes, at: i) {
                let length = kind.length
                events.append(Event(kind: kind.kind, start: i, end: i + length))
                switch kind.kind {
                case .syncBegin: inSyncUpdate = true
                case .syncEnd, .altExit: inSyncUpdate = false
                }
                i += length
            } else {
                i += 1
            }
        }
        return (bytes, events)
    }

    /// Whatever was held back (call when the process ends).
    public mutating func flush() -> [UInt8] {
        defer { carry = [] }
        return carry
    }

    private static func match(_ bytes: [UInt8], at i: Int) -> (kind: Kind, length: Int)? {
        func has(_ seq: [UInt8]) -> Bool {
            bytes.count - i >= seq.count && bytes[i ..< i + seq.count].elementsEqual(seq)
        }
        if has(syncEnd) { return (.syncEnd, syncEnd.count) }
        if has(syncBegin) { return (.syncBegin, syncBegin.count) }
        for seq in altExits where has(seq) { return (.altExit, seq.count) }
        return nil
    }
}
