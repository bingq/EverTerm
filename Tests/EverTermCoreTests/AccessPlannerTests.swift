import XCTest
@testable import EverTermCore

/// #27: which folders to ask for in the sandboxed build.
final class AccessPlannerTests: XCTestCase {
    typealias P = AccessPlanner
    let home = "/Users/me"

    func testPathsInStartupFiles() {
        let zprofile = """
        # Homebrew
        eval "$(/opt/homebrew/bin/brew shellenv)"
        export PATH="$HOME/.local/bin:${HOME}/.bun/bin:$PATH"
        source ~/work/env.sh
        # source /ignored/in/comment
        if [ -f '/opt/homebrew/share/google-cloud-sdk/path.zsh.inc' ]; then . '/opt/homebrew/share/google-cloud-sdk/path.zsh.inc'; fi
        """
        XCTAssertEqual(P.paths(inStartupFile: zprofile, home: home), [
            "/opt/homebrew/bin/brew",
            "/Users/me/.local/bin", "/Users/me/.bun/bin",
            "/Users/me/work/env.sh",
            "/opt/homebrew/share/google-cloud-sdk/path.zsh.inc", "/opt/homebrew/share/google-cloud-sdk/path.zsh.inc",
        ])
    }

    func testURLsAndRelativeWordsAreNotPaths() {
        XCTAssertEqual(P.paths(inStartupFile: "curl https://example.com/x | sh; cd src/app; a=b/c", home: home), [])
    }

    func testGrantRoot() {
        XCTAssertEqual(P.grantRoot(for: "/Users/me/.zshrc", home: home), home)
        XCTAssertEqual(P.grantRoot(for: "/Users/me", home: home), home)
        XCTAssertEqual(P.grantRoot(for: "/opt/homebrew/share/x/path.zsh.inc", home: home), "/opt/homebrew")
        XCTAssertEqual(P.grantRoot(for: "/opt/homebrew/", home: home), "/opt/homebrew")
        XCTAssertEqual(P.grantRoot(for: "/usr/local/bin/tool", home: home), "/usr/local")
        XCTAssertEqual(P.grantRoot(for: "/Volumes/Work/repo", home: home), "/Volumes/Work")
        XCTAssertEqual(P.grantRoot(for: "/nix/store/abc/bin/x", home: home), "/nix")
        XCTAssertEqual(P.grantRoot(for: "/Users/Shared/tools", home: home), "/Users/Shared")
        XCTAssertNil(P.grantRoot(for: "/usr/bin/git", home: home))
        XCTAssertNil(P.grantRoot(for: "/bin/bash", home: home))
        XCTAssertNil(P.grantRoot(for: "/Applications/Xcode.app/Contents/Developer/usr/bin", home: home))
        XCTAssertNil(P.grantRoot(for: "/System/Cryptexes/App/usr/bin", home: home))
        XCTAssertNil(P.grantRoot(for: "/opt", home: home))
        XCTAssertNil(P.grantRoot(for: "/", home: home))
    }

    func testPlanHomeFirstMergedReasonsAndSkips() {
        let sources: [(path: String, reason: String)] = [
            ("/opt/homebrew/bin/brew", "~/.zprofile"),
            ("/opt/homebrew/share/sdk/path.zsh.inc", "~/.zshrc"),
            ("/opt/homebrew/bin/brew", "~/.zprofile"),          // same reason once
            ("/usr/bin/git", "~/.zshrc"),                       // system: never asked
            ("/usr/local/bin/tool", "~/.zshrc"),                // readable: skipped
            ("/Users/me/.bun/bin", "~/.zprofile"),              // inside home: merged into home
        ]
        let needs = P.plan(sources: sources, home: home, granted: [], readable: { $0 == "/usr/local" })
        XCTAssertEqual(needs, [
            P.Need(folder: home, reasons: [P.homeReason, "~/.zprofile"]),
            P.Need(folder: "/opt/homebrew", reasons: ["~/.zprofile", "~/.zshrc"]),
        ])
    }

    func testPlanLeavesOutGrantedFolders() {
        let sources: [(path: String, reason: String)] = [("/opt/homebrew/bin/brew", "~/.zprofile")]
        XCTAssertEqual(P.plan(sources: sources, home: home, granted: [home], readable: { _ in false }),
                       [P.Need(folder: "/opt/homebrew", reasons: ["~/.zprofile"])])
        XCTAssertEqual(P.plan(sources: sources, home: home, granted: [home, "/opt/homebrew/"], readable: { _ in false }), [])
        XCTAssertEqual(P.plan(sources: sources, home: home, granted: ["/"], readable: { _ in false }), [])   // whole disk
        XCTAssertEqual(P.plan(sources: [], home: home, granted: [], readable: { $0 == "/Users/me" }), [])
    }

    func testRefusedPathsInOutput() {
        XCTAssertEqual(P.refusedPaths(inLine: "/Users/me/.zprofile:2: operation not permitted: /opt/homebrew/bin/brew"),
                       ["/Users/me/.zprofile", "/opt/homebrew/bin/brew"])
        XCTAssertEqual(P.refusedPaths(inLine: "ls: /Volumes/Work: Operation not permitted"), ["/Volumes/Work"])
        XCTAssertEqual(P.refusedPaths(inLine: "probe.sh: /opt/homebrew/bin/brew: /bin/bash: bad interpreter: Operation not permitted"),
                       ["/opt/homebrew/bin/brew", "/bin/bash"])
        XCTAssertEqual(P.refusedPaths(inLine: "zsh: permission denied: /opt/x"), [])
        XCTAssertEqual(P.refusedPaths(inLine: "nothing to see /opt/x"), [])
    }
}
