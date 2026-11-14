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
        env.append("EVERTERM_SANDBOX=1")
        if let probe = Bundle.main.url(forResource: "sandbox-probe", withExtension: "sh") {
            env.append("EVERTERM_PROBE=" + probe.path)
        }
        return env
    }
}
