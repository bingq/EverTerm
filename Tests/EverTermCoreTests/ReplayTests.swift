import Foundation
import XCTest
@testable import EverTermCore

/// Optional: replays frames recorded from a real session. Session logs are
/// private, so no frames are in the repo; set EVERTERM_REPLAY_DIR to a folder
/// with run1-frames.json / run2-frames.json (JSON array of frames, each an
/// array of row strings) to run it. Skipped otherwise.
final class ReplayTests: XCTestCase {
    private func frames(_ name: String) throws -> [[String]] {
        guard let dir = ProcessInfo.processInfo.environment["EVERTERM_REPLAY_DIR"] else {
            throw XCTSkip("EVERTERM_REPLAY_DIR not set")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-frames.json"))
        return try JSONDecoder().decode([[String]].self, from: data)
    }

    private func replay(_ frames: [[String]]) -> [String] {
        var t = AltScreenTracker()
        frames.forEach { t.observe($0) }
        return t.capture(finalRows: frames.last) ?? []
    }

    private func numbers(_ lines: [String], _ prefix: String) -> [Int] {
        lines.compactMap { line in
            let s = line.trimmingCharacters(in: .whitespaces)
            return s.hasPrefix(prefix) ? Int(s.dropFirst(prefix.count)) : nil
        }
    }

    /// Mac run 2: no scrolling inside Claude. Every line once, in order.
    func testRun2() throws {
        let out = replay(try frames("run2"))
        XCTAssertEqual(numbers(out, "Line "), Array(1 ... 300))
    }

    /// Mac run 1: scrolled inside Claude while it printed. Every line once, prompt once.
    func testRun1() throws {
        let out = replay(try frames("run1"))
        XCTAssertEqual(numbers(out, "").filter { (1 ... 300).contains($0) }, Array(1 ... 300))
        XCTAssertEqual(out.filter { $0.contains("print 300 numbered") }.count, 1)
    }

    /// Mac run 3: the same numbers printed in several batches, the last one in
    /// slow chunks with shell commands in between. Each prompt once; the slow
    /// batch (51-300) almost complete. A few lines at chunk joins may be lost or
    /// doubled where Claude collapses its tool output.
    func testRun3() throws {
        let out = replay(try frames("run3"))
        for prompt in ["just keep but at slower pace", "another time please"] {
            XCTAssertEqual(out.filter { $0.contains(prompt) }.count, 1, prompt)
        }
        guard let start = out.firstIndex(where: { $0.contains("Continuing from 51") }) else {
            return XCTFail("slow batch not found")
        }
        let slow = Set(numbers(Array(out[start...]).map { $0.replacingOccurrences(of: "⏺ ", with: "") }, "")
            .filter { (51 ... 300).contains($0) })
        XCTAssertGreaterThanOrEqual(slow.count, 245, "slow batch kept \(slow.count) of 250")
        print("run3: slow batch kept \(slow.count) of 250 lines")
    }
}
