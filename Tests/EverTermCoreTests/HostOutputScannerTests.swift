import XCTest
@testable import EverTermCore

/// #9: frame boundaries and alt-exit detection; #14: ESC[3J removal.
final class HostOutputScannerTests: XCTestCase {
    private func b(_ s: String) -> ArraySlice<UInt8> { ArraySlice(Array(s.utf8)) }
    private func text(_ bytes: [UInt8]) -> String { String(decoding: bytes, as: UTF8.self) }

    func testFrameBoundaries() {
        var s = HostOutputScanner()
        let (bytes, events) = s.scan(b("a\u{1b}[?2026hframe\u{1b}[?2026lb"))
        XCTAssertEqual(text(bytes), "a\u{1b}[?2026hframe\u{1b}[?2026lb")
        XCTAssertEqual(events.map(\.kind), [.syncBegin, .syncEnd])
        XCTAssertEqual(events[1].end, 1 + 8 + 5 + 8)
        XCTAssertFalse(s.inSyncUpdate)
    }

    func testInsideAnUpdateAcrossReads() {
        var s = HostOutputScanner()
        _ = s.scan(b("\u{1b}[?2026hhalf a fra"))
        XCTAssertTrue(s.inSyncUpdate)            // must not look at the screen now
        let (_, events) = s.scan(b("me\u{1b}[?2026l"))
        XCTAssertEqual(events.map(\.kind), [.syncEnd])
        XCTAssertFalse(s.inSyncUpdate)
    }

    func testSequenceSplitAcrossReadsIsHeldBack() {
        var s = HostOutputScanner()
        let first = s.scan(b("abc\u{1b}[?20"))
        XCTAssertEqual(text(first.bytes), "abc")
        XCTAssertTrue(first.events.isEmpty)
        let second = s.scan(b("26l"))
        XCTAssertEqual(text(second.bytes), "\u{1b}[?2026l")
        XCTAssertEqual(second.events.map(\.kind), [.syncEnd])
    }

    func testAltExit() {
        for seq in ["\u{1b}[?1049l", "\u{1b}[?1047l", "\u{1b}[?47l"] {
            var s = HostOutputScanner()
            _ = s.scan(b("\u{1b}[?2026h"))
            let (_, events) = s.scan(b("x" + seq + "y"))
            XCTAssertEqual(events.map(\.kind), [.altExit], seq)
            XCTAssertEqual(events.first?.start, 1)
            XCTAssertFalse(s.inSyncUpdate)
        }
    }

    func testEraseScrollbackRemovedEvenWhenSplit() {
        var s = HostOutputScanner()
        let a = s.scan(b("x\u{1b}[3"))
        let c = s.scan(b("Jy"))
        XCTAssertEqual(text(a.bytes) + text(c.bytes), "xy")
        var keep = HostOutputScanner(keepScrollbackOnErase: false)
        XCTAssertEqual(text(keep.scan(b("x\u{1b}[3Jy")).bytes), "x\u{1b}[3Jy")
    }

    func testOtherEscapesPassAndFlush() {
        var s = HostOutputScanner()
        let (bytes, events) = s.scan(b("\u{1b}[31mred\u{1b}[0m\u{1b}"))
        XCTAssertEqual(text(bytes), "\u{1b}[31mred\u{1b}[0m")
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(text(s.flush()), "\u{1b}")
        XCTAssertEqual(s.flush(), [])
    }

    func testDebugLine() {
        var o = AltScreenTracker.Observation()
        o.rows = 53; o.up = 3; o.appended = 3; o.firstAppended = "  1 line"; o.lastAppended = "  3 \"q\""
        let line = CaptureDebug.line(ms: 12, rawOffset: 345, reason: "frame", inSync: false, o)
        XCTAssertTrue(line.hasPrefix("t=12ms raw=345 why=frame sync=0 rows=53 pin=0 up=3 down=- add=3"))
        XCTAssertTrue(line.hasSuffix("first=\"  1 line\" last=\"  3 'q'\""))
    }
}
