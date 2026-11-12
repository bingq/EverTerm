import XCTest
@testable import EverTermCore

/// #14: programs can't erase scrollback any more.
final class TerminalBytesTests: XCTestCase {
    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    func testRemovesEraseScrollback() {
        XCTAssertEqual(TerminalBytes.removingEraseScrollback(bytes("a\u{1b}[3Jb\u{1b}[3J")), bytes("ab"))
    }

    func testKeepsClearScreenAndOtherSequences() {
        let s = bytes("\u{1b}[2J\u{1b}[H\u{1b}[?1049h\u{1b}[31mred")
        XCTAssertEqual(TerminalBytes.removingEraseScrollback(s), s)
    }

    func testPlainAndShortInputUnchanged() {
        XCTAssertEqual(TerminalBytes.removingEraseScrollback([]), [])
        XCTAssertEqual(TerminalBytes.removingEraseScrollback(bytes("\u{1b}[3")), bytes("\u{1b}[3"))
        XCTAssertEqual(TerminalBytes.removingEraseScrollback(bytes("hello")), bytes("hello"))
    }
}
