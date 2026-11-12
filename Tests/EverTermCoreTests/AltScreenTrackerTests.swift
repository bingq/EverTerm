import XCTest
@testable import EverTermCore

/// Made-up full-screen app: a growing transcript shown in a viewport, with an
/// optional pinned header row and fixed footer rows (Claude Code's input box).
private struct FakeApp {
    var rows: Int
    var header: String?          // pinned at the top while scrolled (Claude pins your prompt)
    var footer: [String]
    var transcript: [String] = []
    var scrolledBack = 0         // lines the user scrolled up inside the app

    var bodyHeight: Int { rows - footer.count - (header == nil ? 0 : 1) }

    func screen() -> [String] {
        let end = max(0, transcript.count - scrolledBack)
        let start = max(0, end - bodyHeight)
        var body = Array(transcript[start ..< end])
        body += Array(repeating: "", count: bodyHeight - body.count)
        return (header.map { [$0] } ?? []) + body + footer
    }
}

private func numbers(_ lines: [String], prefix: String = "  ") -> [Int] {
    lines.compactMap { $0.hasPrefix(prefix) ? Int($0.dropFirst(prefix.count)) : nil }
}

final class AltScreenTrackerTests: XCTestCase {
    private let footer = ["────", "❯", "────", "  ? for shortcuts"]

    /// Streams `count` numbered lines, `perFrame` at a time, observing each frame.
    private func stream(_ app: inout FakeApp, _ tracker: inout AltScreenTracker, count: Int, perFrame: Int) {
        var n = numbers(app.transcript).last ?? 0
        while n < count {
            for _ in 0 ..< perFrame where n < count {
                n += 1
                app.transcript.append(String(format: "  %03d", n))
            }
            tracker.observe(app.screen())
        }
    }

    private func assertAll300(_ out: [String], file: StaticString = #filePath, line: UInt = #line) {
        let nums = numbers(out)
        XCTAssertEqual(nums, Array(1 ... 300), "numbers missing, repeated or out of order", file: file, line: line)
    }

    // MARK: behaviour verified before #9 (must keep passing)

    func testNoScrollCapturesFinalScreen() {
        var t = AltScreenTracker()
        let screen = ["hello", "world", "", "", ""]
        t.observe(screen)
        t.observe(screen)
        XCTAssertEqual(t.capture(finalRows: screen), ["hello", "world"])
    }

    func testNothingShownCapturesNil() {
        var t = AltScreenTracker()
        XCTAssertNil(t.capture(finalRows: ["", "", ""]))
        XCTAssertNil(t.capture(finalRows: nil))
    }

    func testCaptureStartsOver() {
        var t = AltScreenTracker()
        var app = FakeApp(rows: 20, header: nil, footer: footer, transcript: ["❯ hi"])
        t.observe(app.screen())
        stream(&app, &t, count: 50, perFrame: 3)
        _ = t.capture(finalRows: app.screen())
        XCTAssertEqual(t.archive, [])
        XCTAssertEqual(t.capture(finalRows: ["next app"]), ["next app"])
    }

    func testVimPagingKeepsViewedPages() {
        // 23 text rows + a fixed status line; Ctrl-F moves 21 lines (2 lines of overlap).
        let file = (1 ... 200).map { "line \($0)" }
        func page(_ top: Int) -> [String] { Array(file[top ..< top + 23]) + ["\"words\" 200L"] }
        var t = AltScreenTracker()
        for top in stride(from: 0, through: 84, by: 21) { t.observe(page(top)) }
        let out = t.capture(finalRows: page(84)) ?? []
        let seen = out.compactMap { $0.hasPrefix("line ") ? Int($0.dropFirst(5)) : nil }
        XCTAssertEqual(seen, Array(1 ... 107))
    }

    func testArchiveLimit() {
        var t = AltScreenTracker(limit: 30)
        var app = FakeApp(rows: 20, header: nil, footer: footer, transcript: [])
        stream(&app, &t, count: 200, perFrame: 2)
        XCTAssertLessThanOrEqual(t.archive.count, 30)
    }

    // MARK: #9

    /// Run 2 on the Mac: Claude streams 300 lines, no scrolling inside Claude.
    func testStreamingWithFooterKeepsEveryLineOnce() {
        for perFrame in [1, 3, 7, 15] {
            var t = AltScreenTracker()
            var app = FakeApp(rows: 52, header: nil, footer: footer, transcript: ["❯ print 300 lines", "", "● Here they are:"])
            t.observe(app.screen())
            stream(&app, &t, count: 300, perFrame: perFrame)
            let out = t.capture(finalRows: app.screen()) ?? []
            assertAll300(out)
            XCTAssertEqual(out.filter { $0 == "❯ print 300 lines" }.count, 1, "perFrame \(perFrame)")
        }
    }

    /// Run 1 on the Mac: Claude pins the prompt to the top row while the answer scrolls under it.
    func testPinnedHeaderIsKeptOnce() {
        var t = AltScreenTracker()
        var app = FakeApp(rows: 52, header: "❯ print 300 numbered lines", footer: footer, transcript: ["● Print the numbers"])
        t.observe(app.screen())
        stream(&app, &t, count: 300, perFrame: 4)
        let out = t.capture(finalRows: app.screen()) ?? []
        assertAll300(out)
        XCTAssertLessThanOrEqual(out.filter { $0.hasPrefix("❯ print 300") }.count, 1)
    }

    /// Run 1: the user scrolls up inside Claude and back down, with the prompt pinned.
    func testScrollingBackInsideAppAddsNothing() {
        var t = AltScreenTracker()
        var app = FakeApp(rows: 52, header: "❯ print 300 numbered lines", footer: footer, transcript: ["● Print the numbers"])
        t.observe(app.screen())
        stream(&app, &t, count: 300, perFrame: 4)
        for back in stride(from: 3, through: 150, by: 3) { app.scrolledBack = back; t.observe(app.screen()) }
        for back in stride(from: 150, through: 0, by: -3) { app.scrolledBack = back; t.observe(app.screen()) }
        let out = t.capture(finalRows: app.screen()) ?? []
        assertAll300(out)
        XCTAssertLessThanOrEqual(out.filter { $0.hasPrefix("❯ print 300") }.count, 1)
    }

    /// The archive and the final screen overlap; the overlap must appear once.
    func testJoinWithFinalScreenHasNoRepeat() {
        var t = AltScreenTracker()
        var app = FakeApp(rows: 30, header: nil, footer: footer, transcript: ["❯ go"])
        t.observe(app.screen())
        stream(&app, &t, count: 300, perFrame: 5)
        // The app redraws its last frame once more before exiting (as Claude does).
        t.observe(app.screen())
        let out = t.capture(finalRows: app.screen()) ?? []
        assertAll300(out)
    }

    /// Mac run 3: the same numbers printed three times. Every batch is kept
    /// (repeated output is not mistaken for scrolling back).
    func testRepeatedOutputIsKept() {
        var t = AltScreenTracker()
        var app = FakeApp(rows: 52, header: nil, footer: footer, transcript: [])
        for round in 1 ... 3 {
            app.transcript += ["❯ print 300 lines, round \(round)", ""]
            for n in 1 ... 300 {
                app.transcript.append(String(format: "  %03d", n))
                if n % 4 == 0 { t.observe(app.screen()) }
            }
            app.transcript.append("")
            t.observe(app.screen())
        }
        let out = t.capture(finalRows: app.screen()) ?? []
        XCTAssertEqual(numbers(out), Array(1 ... 300) + Array(1 ... 300) + Array(1 ... 300))
        for round in 1 ... 3 {
            XCTAssertEqual(out.filter { $0 == "❯ print 300 lines, round \(round)" }.count, 1)
        }
    }

    /// Scrolling up inside the app and back down, without a pinned header.
    func testScrollingBackWithoutHeaderAddsNothing() {
        var t = AltScreenTracker()
        var app = FakeApp(rows: 40, header: nil, footer: footer, transcript: ["❯ go"])
        t.observe(app.screen())
        stream(&app, &t, count: 300, perFrame: 5)
        for back in stride(from: 5, through: 200, by: 5) { app.scrolledBack = back; t.observe(app.screen()) }
        for back in stride(from: 200, through: 0, by: -5) { app.scrolledBack = back; t.observe(app.screen()) }
        let out = t.capture(finalRows: app.screen()) ?? []
        assertAll300(out)
    }

    /// The debug log's totals (archive size, rewind count) must be current.
    func testObservationReportsTotals() {
        var t = AltScreenTracker()
        var app = FakeApp(rows: 20, header: nil, footer: footer, transcript: [])
        stream(&app, &t, count: 40, perFrame: 2)
        app.transcript += ["  041", "  042"]
        let o = t.observe(app.screen())
        XCTAssertEqual(o.up, 2)
        XCTAssertEqual(o.appended, 2)
        XCTAssertEqual(o.archiveCount, t.archive.count)
        XCTAssertGreaterThan(o.archiveCount, 0)
        app.scrolledBack = 3
        let back = t.observe(app.screen())
        XCTAssertEqual(back.down, 3)
        XCTAssertEqual(back.rewound, 3)
    }

    /// #16: peek shows everything so far and changes nothing, so the save on exit is unchanged.
    func testPeekMatchesCaptureAndChangesNothing() {
        var t = AltScreenTracker()
        var app = FakeApp(rows: 30, header: "❯ print 300 numbered lines", footer: footer, transcript: ["● ok"])
        t.observe(app.screen())
        stream(&app, &t, count: 300, perFrame: 4)
        let archiveBefore = t.archive
        let peeked = t.peek()
        XCTAssertEqual(t.archive, archiveBefore)
        XCTAssertEqual(numbers(peeked), Array(1 ... 300))
        XCTAssertEqual(peeked, t.peek())                        // peeking twice is the same
        XCTAssertEqual(t.capture(finalRows: app.screen()), peeked)
    }

    /// #16: halfway through a stream, peek has every line so far.
    func testPeekMidStream() {
        var t = AltScreenTracker()
        var app = FakeApp(rows: 30, header: nil, footer: footer, transcript: ["❯ go"])
        t.observe(app.screen())
        stream(&app, &t, count: 120, perFrame: 3)
        XCTAssertEqual(numbers(t.peek()), Array(1 ... 120))
        stream(&app, &t, count: 300, perFrame: 3)
        XCTAssertEqual(numbers(t.capture(finalRows: app.screen()) ?? []), Array(1 ... 300))
    }

    /// Quitting (or peeking) while scrolled back inside the app must not append the
    /// older lines on screen below the newest ones.
    func testScrolledBackAtExitKeepsOrder() {
        var t = AltScreenTracker()
        var app = FakeApp(rows: 30, header: nil, footer: footer, transcript: ["❯ go"])
        t.observe(app.screen())
        stream(&app, &t, count: 300, perFrame: 5)
        for back in stride(from: 5, through: 120, by: 5) { app.scrolledBack = back; t.observe(app.screen()) }
        assertAll300(t.peek())
        assertAll300(t.capture(finalRows: app.screen()) ?? [])
    }

    /// Mac run 5: after the app finishes, you scroll up (the app pins your prompt to the
    /// top row) and back down; the app keeps the prompt pinned, covering the line that was
    /// at the top of the last screen. That line was never saved and must not be lost.
    func testLineHiddenUnderPinnedRowAfterScrollingBackIsKept() {
        var t = AltScreenTracker()
        var app = FakeApp(rows: 30, header: nil, footer: footer, transcript: ["❯ go"])
        t.observe(app.screen())
        stream(&app, &t, count: 300, perFrame: 5)
        app.header = "❯ go"                       // scrolling up pins the prompt
        for back in stride(from: 3, through: 60, by: 3) { app.scrolledBack = back; t.observe(app.screen()) }
        for back in stride(from: 60, through: 0, by: -3) { app.scrolledBack = back; t.observe(app.screen()) }
        assertAll300(t.peek())                    // the panel
        XCTAssertLessThanOrEqual(t.peek().filter { $0 == "❯ go" }.count, 1)
        app.header = nil                          // the app unpins before exiting
        t.observe(app.screen())
        assertAll300(t.capture(finalRows: app.screen()) ?? [])
    }
}
