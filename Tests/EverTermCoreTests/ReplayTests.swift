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

    /// Mac run 1: scrolled inside Claude while it printed. No repeated prompt;
    /// at most a couple of lines lost or repeated (the redraws are ambiguous).
    func testRun1() throws {
        let out = replay(try frames("run1"))
        let nums = numbers(out, "").filter { (1 ... 300).contains($0) }
        let missing = Set(1 ... 300).subtracting(nums).count
        XCTAssertLessThanOrEqual(missing, 3)
        XCTAssertLessThanOrEqual(nums.count - Set(nums).count, 2)
        XCTAssertLessThanOrEqual(out.filter { $0.contains("print 300 numbered") }.count, 3)
        print("run1: \(nums.count) numbers, \(missing) missing, \(nums.count - Set(nums).count) repeated")
    }
}
