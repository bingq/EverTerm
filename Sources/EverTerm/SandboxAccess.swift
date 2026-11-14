import AppKit

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

    /// Shell > Grant Folder Access…: pick a folder (your home folder, ~/.ssh, a tool folder).
    /// Kept across launches. New sessions get it; already open ones may not (step 1 checks).
    static func grant() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.showsHiddenFiles = true
        panel.prompt = "Grant Access"
        panel.message = "Choose a folder that EverTerm's sessions may use (for example your home folder)."
        panel.directoryURL = URL(fileURLWithPath: realHome)
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? url.bookmarkData(options: [.withSecurityScope],
                                               includingResourceValuesForKeys: nil, relativeTo: nil)
        else { return }
        var saved = UserDefaults.standard.array(forKey: key) as? [Data] ?? []
        saved.append(data)
        UserDefaults.standard.set(saved, forKey: key)
        if url.startAccessingSecurityScopedResource() { granted.append(url) }
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
