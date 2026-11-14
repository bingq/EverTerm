import Foundation

/// #27: which folders the sandboxed build should ask for, and in what words.
/// Plain rules on strings; the app reads the files, asks the sandbox what it can read, and shows the dialog.
public enum AccessPlanner {
    /// One folder to ask for, with why ("~/.zprofile", "your shell settings, ssh keys, projects").
    public struct Need: Equatable, Sendable {
        public var folder: String
        public var reasons: [String]
        public init(folder: String, reasons: [String]) { self.folder = folder; self.reasons = reasons }
    }

    /// Startup files zsh reads, relative to the home (or ZDOTDIR) folder.
    public static let startupFiles = [".zshenv", ".zprofile", ".zshrc", ".zlogin"]
    /// Tool folders worth asking for when they exist on this Mac.
    public static let wellKnownFolders = ["/opt/homebrew", "/usr/local"]
    public static let homeReason = "your shell settings, ssh keys, projects"

    /// Absolute paths named in a shell startup file: `/opt/x/bin/tool`, `~/bin`, `$HOME/y`, `${HOME}/z`.
    /// Comment lines are skipped.
    public static func paths(inStartupFile text: String, home: String) -> [String] {
        var found: [String] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { continue }
            let expanded = line
                .replacingOccurrences(of: "${HOME}", with: home)
                .replacingOccurrences(of: "$HOME", with: home)
                .replacingOccurrences(of: "~/", with: home + "/")
            found += absolutePaths(in: expanded)
        }
        return found
    }

    /// The folder to grant so `path` works, or nil when the sandbox can reach it anyway
    /// (system folders, apps) or it is not a real location.
    public static func grantRoot(for path: String, home: String) -> String? {
        let path = normalized(path)
        if path == home || path.hasPrefix(home + "/") { return home }
        if path.hasPrefix("/usr/local/") || path == "/usr/local" { return "/usr/local" }
        let parts = path.split(separator: "/").map(String.init)
        guard let top = parts.first else { return nil }
        if systemTops.contains(top) { return nil }
        if top == "Users" {
            // Someone else's home, or /Users/Shared.
            return parts.count >= 2 ? "/Users/" + parts[1] : nil
        }
        if top == "opt" || top == "Volumes" {
            return parts.count >= 2 ? "/\(top)/\(parts[1])" : nil
        }
        return "/" + top
    }

    /// The folders to ask for, home first, then in the order they were found.
    /// `sources` maps each path to where it was seen (a startup file name, "Homebrew"...).
    /// Folders inside a granted one, or that `readable` says the sandbox can already read, are left out.
    public static func plan(sources: [(path: String, reason: String)], home: String,
                            granted: [String], readable: (String) -> Bool) -> [Need] {
        var needs: [Need] = []
        let granted = granted.map(normalized)
        func covered(_ folder: String) -> Bool {
            granted.contains { $0 == "/" || folder == $0 || folder.hasPrefix($0 + "/") }
        }
        func note(_ folder: String, _ reason: String) {
            if let index = needs.firstIndex(where: { $0.folder == folder }) {
                if !needs[index].reasons.contains(reason) { needs[index].reasons.append(reason) }
            } else if !covered(folder), !readable(folder) {
                needs.append(Need(folder: folder, reasons: [reason]))
            }
        }
        note(home, homeReason)
        for source in sources {
            guard let root = grantRoot(for: source.path, home: home) else { continue }
            note(root, source.reason)
        }
        return needs
    }

    /// Paths in an output line that reports a sandbox refusal ("operation not permitted"),
    /// e.g. `zsh: operation not permitted: /opt/homebrew/bin/brew` or `ls: /x: Operation not permitted`.
    public static func refusedPaths(inLine line: String) -> [String] {
        guard line.range(of: "operation not permitted", options: .caseInsensitive) != nil else { return [] }
        return absolutePaths(in: line)
    }

    // MARK: private

    private static let systemTops: Set<String> = [
        "System", "bin", "sbin", "usr", "Applications", "Library", "private", "etc", "var", "tmp", "dev", "cores",
    ]

    private static func normalized(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// `/a/b-c.d` style words; stops at quotes, spaces, colons, `$`, `)` and similar.
    static func absolutePaths(in text: String) -> [String] {
        var paths: [String] = []
        var current = ""
        var inPath = false
        var previous: Character = " "
        func flush() {
            if inPath {
                let trimmed = current.trimmingCharacters(in: CharacterSet(charactersIn: ".,;"))
                if trimmed.count > 1, trimmed.hasPrefix("/"), !trimmed.hasPrefix("//") { paths.append(trimmed) }
            }
            current = ""
            inPath = false
        }
        for char in text {
            if inPath {
                if char.isLetter || char.isNumber || "._-+@%/".contains(char) { current.append(char) } else { flush() }
            } else if char == "/", !(previous.isLetter || previous.isNumber || "._-~$}".contains(previous)) {
                inPath = true
                current = "/"
            }
            previous = char
        }
        flush()
        return paths
    }
}
