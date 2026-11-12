import XCTest
@testable import EverTermCore

/// #16: the panel shows the shell history, then what the app has shown so far.
final class HistoryPanelContentTests: XCTestCase {
    func testShellThenApp() {
        let out = HistoryPanelContent.lines(shell: ["$ seq 1 2", "1", "2"], app: ["❯ hi", "● hello"], appName: "claude")
        XCTAssertEqual(out, ["$ seq 1 2", "1", "2", "", "── claude (live, captured so far) ──", "❯ hi", "● hello"])
    }

    func testOnlyShellIsUnchangedFrom14() {
        XCTAssertEqual(HistoryPanelContent.lines(shell: ["a", "b"], app: [], appName: "x"), ["a", "b"])
    }

    func testOnlyApp() {
        XCTAssertEqual(HistoryPanelContent.lines(shell: [], app: ["x"], appName: "vim"),
                       ["── vim (live, captured so far) ──", "x"])
    }

    func testLimitKeepsNewest() {
        let out = HistoryPanelContent.lines(shell: ["1", "2", "3"], app: ["4", "5"], appName: "a", limit: 3)
        XCTAssertEqual(out, ["── a (live, captured so far) ──", "4", "5"])
    }

    func testHeaderMentionsCopy() {
        XCTAssertTrue(HistoryPanelContent.header(hasApp: true).contains("⌘C"))
        XCTAssertTrue(HistoryPanelContent.header(hasApp: false).hasPrefix("Shell history before this program"))
    }
}
