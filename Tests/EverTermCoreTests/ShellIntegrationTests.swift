import XCTest
@testable import EverTermCore

/// #23: shell-integration sequences and connect detection without reading processes.
final class ShellIntegrationTests: XCTestCase {
    private func started(_ line: String, st: Bool = false) -> [UInt8] {
        let b64 = Data(line.utf8).base64EncodedString()
        return Array("\u{1b}]6973;C;\(b64)\(st ? "\u{1b}\\" : "\u{07}")".utf8)
    }
    private func finished(_ code: String) -> [UInt8] { Array("\u{1b}]6973;D;\(code)\u{07}".utf8) }

    func testStartAndFinish() {
        var scanner = ShellIntegrationScanner()
        let bytes = Array("prompt% ".utf8) + started("devbox connect") + Array("output\r\n".utf8) + finished("0")
        XCTAssertEqual(scanner.feed(bytes), [.commandStarted("devbox connect"), .commandFinished(exitStatus: 0)])
    }

    func testEveryReadSizeGivesTheSameEvents() {
        let bytes = Array("x\u{1b}]0;title\u{07}".utf8) + started("ssh -p 2222 me@host") + Array("\u{1b}[31mred".utf8)
            + finished("130") + started("ls", st: true)
        let expected: [ShellEvent] = [.commandStarted("ssh -p 2222 me@host"), .commandFinished(exitStatus: 130),
                                      .commandStarted("ls")]
        for size in 1...bytes.count {
            var scanner = ShellIntegrationScanner()
            var events: [ShellEvent] = []
            var index = 0
            while index < bytes.count {
                events += scanner.feed(bytes[index..<min(index + size, bytes.count)])
                index += size
            }
            XCTAssertEqual(events, expected, "read size \(size)")
        }
    }

    func testOtherOSCAndBrokenSequencesAreIgnored() {
        var scanner = ShellIntegrationScanner()
        XCTAssertEqual(scanner.feed(Array("\u{1b}]7;file://h/p\u{07}\u{1b}]697;C;x\u{07}".utf8)), [])
        XCTAssertEqual(scanner.feed(Array("\u{1b}]6973;C;!!notbase64\u{07}".utf8)), [])
        XCTAssertEqual(scanner.feed(Array("\u{1b}]6973;Z;1\u{07}".utf8)), [])
        // ESC inside the payload that is not ST: dropped, and the next sequence still parses.
        XCTAssertEqual(scanner.feed(Array("\u{1b}]6973;D;1\u{1b}[0m".utf8) + finished("2")), [.commandFinished(exitStatus: 2)])
        XCTAssertEqual(scanner.feed(Array("\u{1b}]6973;C;\u{07}".utf8)), [])        // empty command
        XCTAssertEqual(scanner.feed(finished("")), [.commandFinished(exitStatus: nil)])
    }

    func testMultilineAndUnicodeCommand() {
        var scanner = ShellIntegrationScanner()
        XCTAssertEqual(scanner.feed(started("echo 'héllo'\nls\n")), [.commandStarted("echo 'héllo'\nls")])
    }

    func testConnectProgramAtStart() {
        typealias D = ConnectDetection
        XCTAssertTrue(D.startsWithConnectProgram("ssh host"))
        XCTAssertTrue(D.startsWithConnectProgram("/usr/bin/ssh -p 22 me@host"))
        XCTAssertTrue(D.startsWithConnectProgram("env TERM=xterm et host:8080"))
        XCTAssertTrue(D.startsWithConnectProgram("LANG=C mosh host"))
        XCTAssertFalse(D.startsWithConnectProgram("ssh"))
        XCTAssertFalse(D.startsWithConnectProgram("git push"))
        XCTAssertFalse(D.startsWithConnectProgram("devbox connect"))   // a launcher: found by the title instead
        XCTAssertFalse(D.startsWithConnectProgram("vim ssh.txt"))
    }

    func testRemoteTitle() {
        typealias D = ConnectDetection
        XCTAssertTrue(D.titleIsRemote("me@ip-10-0-0-1:~", localHost: "MyMac"))
        XCTAssertTrue(D.titleIsRemote("me@build.example.com: ~/src", localHost: "MyMac.local"))
        XCTAssertFalse(D.titleIsRemote("me@MyMac:~", localHost: "MyMac.local"))
        XCTAssertFalse(D.titleIsRemote("me@mymac.local:~/x", localHost: "MyMac"))
        XCTAssertFalse(D.titleIsRemote("vim notes@home.txt", localHost: "MyMac"))   // not user@host
        XCTAssertFalse(D.titleIsRemote("Cross-screen text generation", localHost: "MyMac"))
        XCTAssertFalse(D.titleIsRemote("me@:~", localHost: "MyMac"))
    }
}
