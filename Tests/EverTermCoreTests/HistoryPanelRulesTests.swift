import XCTest
@testable import EverTermCore

/// #14 behaviours verified on the Mac 2026-11-12. These must keep passing
/// when the panel grows (#16, #17).
final class HistoryPanelRulesTests: XCTestCase {
    typealias R = HistoryPanelRules

    func testKeys() {
        XCTAssertEqual(R.action(for: .escape), .close)               // Esc closes
        XCTAssertEqual(R.action(for: .other), .closeAndForward)      // a letter closes and goes to Claude
        XCTAssertEqual(R.action(for: .command), .keepInPanel)        // ⌘C / ⌘A copy in the panel
        XCTAssertEqual(R.action(for: .navigation), .keepInPanel)     // paging stays in the panel
    }

    private func opens(panelOpen: Bool = false, shift: Bool = true, alt: Bool = true, over: Bool = true,
                       dy: Double = 3, dx: Double = 0, precise: Bool = true, momentum: Bool = false) -> Bool {
        R.opensOnScroll(panelOpen: panelOpen, shift: shift, alternateScreen: alt, overTerminal: over,
                        deltaY: dy, deltaX: dx, precise: precise, momentum: momentum)
    }

    func testShiftScrollUpInFullScreenAppOpens() {
        XCTAssertTrue(opens())                                        // trackpad
        XCTAssertTrue(opens(dy: 0, dx: 1, precise: false))           // mouse wheel: Shift turns it horizontal
    }

    func testOtherScrollsDoNotOpen() {
        XCTAssertFalse(opens(shift: false))                           // plain scroll goes to Claude
        XCTAssertFalse(opens(alt: false))                             // normal screen: ordinary scrollback
        XCTAssertFalse(opens(dy: -3))                                 // scrolling down
        XCTAssertFalse(opens(momentum: true))                         // momentum from an earlier flick
        XCTAssertFalse(opens(panelOpen: true))                        // already open
        XCTAssertFalse(opens(over: false))                            // pointer over the sidebar
    }

    func testScrollPastEndCloses() {
        XCTAssertTrue(R.closesOnScroll(wasAtEnd: true, deltaY: -3, momentum: false))
        XCTAssertFalse(R.closesOnScroll(wasAtEnd: false, deltaY: -3, momentum: false))  // still scrolling down
        XCTAssertFalse(R.closesOnScroll(wasAtEnd: true, deltaY: 3, momentum: false))    // scrolling up
        XCTAssertFalse(R.closesOnScroll(wasAtEnd: true, deltaY: -3, momentum: true))    // momentum
    }
}
