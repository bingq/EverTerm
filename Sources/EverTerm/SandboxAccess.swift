import AppKit
import EverTermCore

/// #23 step 1: folder access for the sandboxed test build (`EVERTERM_SANDBOX=1 scripts/release.sh`).
/// In the normal (unsandboxed) app none of this runs and its menu item is not added.
@MainActor
enum SandboxAccess {
    nonisolated static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    private static let key = "grantedFolderBookmarks"
    private(set) static var granted: [URL] = []

    /// At launch: open the folders granted in earlier runs again.
    static func restore() {
        guard isSandboxed else { return }
        for data in UserDefaults.standard.array(forKey: key) as? [Data] ?? [] {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                                     relativeTo: nil, bookmarkDataIsStale: &stale),
                  url.startAccessingSecurityScopedResource() else { continue }
            granted.append(url)
        }
    }

    /// Folder picker (Apple's Powerbox: the user picks, the app can't grant itself), opened at
    /// `folder` so the user only clicks Grant Access. Kept across launches. Only shells started
    /// after this get it, so callers offer to restart the shell. Returns whether a folder was granted.
    @discardableResult
    static func grant(startingAt folder: String? = nil, message: String? = nil) -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.showsHiddenFiles = true
        panel.prompt = "Grant Access"
        panel.message = message ?? "Choose a folder that EverTerm's sessions may use (for example your home folder)."
        panel.directoryURL = URL(fileURLWithPath: folder ?? realHome)
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? url.bookmarkData(options: [.withSecurityScope],
                                               includingResourceValuesForKeys: nil, relativeTo: nil)
        else { return false }
        var saved = UserDefaults.standard.array(forKey: key) as? [Data] ?? []
        saved.append(data)
        UserDefaults.standard.set(saved, forKey: key)
        if url.startAccessingSecurityScopedResource() { granted.append(url) }
        return true
    }

    /// Shell > Grant Whole Disk Access…: one picker at the disk. Kept out of the first-run
    /// dialog on purpose (#27): ask only for what the shell needs.
    @discardableResult
    static func grantWholeDisk() -> Bool {
        grant(startingAt: "/", message: "To let EverTerm's sessions use every folder your account can open, click Grant Access with the disk (/) selected.")
    }

    static var grantedPaths: [String] { granted.map(\.path) }

    /// Can the sandbox list this folder right now?
    nonisolated static func canRead(_ folder: String) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: folder)) != nil
    }

    /// #27: the folders still missing for the shell, with reasons: home first, then folders named in
    /// the startup files (readable once home is granted), where symlinks there point, and tool folders.
    static func needs() -> [AccessPlanner.Need] {
        let home = realHome
        let files = FileManager.default
        let zdot = ProcessInfo.processInfo.environment["ZDOTDIR"] ?? home
        var sources: [(path: String, reason: String)] = []
        for name in AccessPlanner.startupFiles {
            let file = zdot + "/" + name
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            let label = zdot == home ? "~/" + name : file
            for path in AccessPlanner.paths(inStartupFile: text, home: home) {
                sources.append((path, "used by " + label))
                if let target = try? files.destinationOfSymbolicLink(atPath: path) {
                    let absolute = target.hasPrefix("/") ? target
                        : ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(target)
                    sources.append((absolute, "used by " + label))
                }
            }
        }
        for folder in AccessPlanner.wellKnownFolders where files.fileExists(atPath: folder) {
            sources.append((folder, "tools installed there"))
        }
        return AccessPlanner.plan(sources: sources, home: home, granted: grantedPaths, readable: canRead)
    }

    /// The user's real home folder. In the sandbox NSHomeDirectory() is the app's container.
    nonisolated static var realHome: String {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir { return String(cString: dir) }
        return NSHomeDirectory()
    }

    /// The shell's environment in the sandbox: the real HOME (not the container), the ssh-agent
    /// socket, and the path of the step 1 probe. Unsandboxed: unchanged.
    nonisolated static func shellEnvironment(_ base: [String]) -> [String] {
        guard isSandboxed else { return base }
        var env = base.filter { !$0.hasPrefix("HOME=") }
        env.append("HOME=" + realHome)
        let process = ProcessInfo.processInfo.environment
        if let sock = process["SSH_AUTH_SOCK"], !env.contains(where: { $0.hasPrefix("SSH_AUTH_SOCK=") }) {
            env.append("SSH_AUTH_SOCK=" + sock)
        }
        env = env.filter { !$0.hasPrefix("PATH=") }
        env.append("PATH=" + sandboxPath().joined(separator: ":"))
        env.append("EVERTERM_SANDBOX=1")
        // Shell integration: zsh reads its startup files from our folder, which loads yours
        // and adds the command hooks (the sandbox does not let EverTerm read child processes).
        if let zdot = Bundle.main.resourceURL?.appendingPathComponent("shell-integration/zsh").path,
           FileManager.default.fileExists(atPath: zdot + "/.zshrc") {
            let user = process["ZDOTDIR"] ?? realHome
            env = env.filter { !$0.hasPrefix("ZDOTDIR=") && !$0.hasPrefix("EVERTERM_USER_ZDOTDIR=") }
            env.append("EVERTERM_USER_ZDOTDIR=" + user)
            env.append("ZDOTDIR=" + zdot)
        }
        if let probe = Bundle.main.url(forResource: "sandbox-probe", withExtension: "sh") {
            env.append("EVERTERM_PROBE=" + probe.path)
        }
        return env
    }

    /// The PATH macOS normally sets up (/etc/paths, /etc/paths.d) plus Homebrew, with the real
    /// developer tools first: /usr/bin/git and friends are xcrun stubs, and xcrun refuses to run
    /// inside an App Sandbox. Your own shell files (~/.zprofile) can still change it afterwards.
    nonisolated static func sandboxPath() -> [String] {
        let files = FileManager.default
        var dirs: [String] = []
        func add(_ dir: String) {
            let dir = dir.trimmingCharacters(in: .whitespaces)
            if !dir.isEmpty, !dirs.contains(dir), files.fileExists(atPath: dir) { dirs.append(dir) }
        }
        // #26: wrappers for system tools that can't work sandboxed (launchctl start ssh-agent).
        if let bin = Bundle.main.resourceURL?.appendingPathComponent("bin").path { add(bin) }
        if let developer = try? files.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link") {
            add(developer + "/usr/bin")                      // e.g. /Applications/Xcode.app/Contents/Developer
        }
        add("/Library/Developer/CommandLineTools/usr/bin")
        add("/opt/homebrew/bin")
        add("/opt/homebrew/sbin")
        var lists = ["/etc/paths"]
        if let extra = try? files.contentsOfDirectory(atPath: "/etc/paths.d") {
            lists += extra.sorted().map { "/etc/paths.d/" + $0 }
        }
        for list in lists {
            guard let text = try? String(contentsOfFile: list, encoding: .utf8) else { continue }
            text.split(whereSeparator: \.isNewline).forEach { add(String($0)) }
        }
        for fallback in ["/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"] { add(fallback) }
        return dirs
    }
}
