import AppKit
import EverTermCore

/// #27: asks for the folders the shell needs, in plain words (sandboxed build only).
/// macOS lets an app use a folder only after the user picks it in Apple's own folder picker,
/// so EverTerm opens one picker per folder, already at that folder: the user just clicks Grant Access.
@MainActor
enum AccessPrompt {
    private static let skipAtLaunchKey = "accessPromptSkipAtLaunch"
    private static var showing = false

    /// At launch: one dialog listing what's missing and why, then one picker per folder.
    static func atLaunch(store: SessionStore) {
        guard SandboxAccess.isSandboxed, !UserDefaults.standard.bool(forKey: skipAtLaunchKey) else { return }
        let needs = SandboxAccess.needs()
        guard !needs.isEmpty, !showing else { return }
        showing = true
        defer { showing = false }
        let alert = NSAlert()
        alert.messageText = "EverTerm needs access to these folders so your shell works as usual"
        alert.informativeText = describe(needs)
            + "\n\nmacOS asks once for each folder. EverTerm opens each one for you; just click Grant Access."
        alert.addButton(withTitle: "Allow…")
        alert.addButton(withTitle: "Not Now")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask when EverTerm starts"
        let answer = alert.runModal()
        if alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: skipAtLaunchKey) }
        guard answer == .alertFirstButtonReturn, grantOneByOne(needs) else { return }
        store.restartShellsAtPrompt(marker: "shell restarted to use the new folder access")
    }

    /// One picker per folder. After the home folder is granted its startup files can be read,
    /// which may name more folders: those are asked next. Cancel stops. Returns whether any was granted.
    static func grantOneByOne(_ first: [AccessPlanner.Need]) -> Bool {
        var asked = Set<String>()
        var queue = first
        var grantedAny = false
        while !queue.isEmpty {
            let need = queue.removeFirst()
            guard asked.insert(need.folder).inserted else { continue }
            let message = "Click Grant Access to let EverTerm's sessions use \(ProcessInspector.abbreviate(need.folder)) "
                + "(\(need.reasons.joined(separator: "; ")))."
            guard SandboxAccess.grant(startingAt: need.folder, message: message) else { break }
            grantedAny = true
            if queue.isEmpty { queue = SandboxAccess.needs().filter { !asked.contains($0.folder) } }
        }
        return grantedAny
    }

    /// A program in `model` was refused `paths`: offer the folder once (per session), then a restart.
    static func offer(paths: [String], in model: SessionModel, store: SessionStore) {
        guard SandboxAccess.isSandboxed, !showing else { return }
        let home = SandboxAccess.realHome
        let granted = SandboxAccess.grantedPaths
        let candidates = paths.compactMap { path -> (folder: String, path: String)? in
            guard let root = AccessPlanner.grantRoot(for: path, home: home) else { return nil }
            return (root, path)
        }
        guard let hit = candidates.first(where: { candidate in
            !model.declinedFolders.contains(candidate.folder)
                && AccessPlanner.plan(sources: [], home: candidate.folder, granted: granted,
                                      readable: SandboxAccess.canRead).contains { $0.folder == candidate.folder }
        }) else { return }
        showing = true
        defer { showing = false }
        let folder = ProcessInspector.abbreviate(hit.folder)
        let alert = NSAlert()
        alert.messageText = "\(folder) isn't accessible to EverTerm"
        alert.informativeText = "A program in “\(model.displayName)” was refused \(ProcessInspector.abbreviate(hit.path)). "
            + "Allow EverTerm's sessions to use \(folder)?"
        alert.addButton(withTitle: "Allow…")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else {
            model.declinedFolders.insert(hit.folder)
            return
        }
        guard SandboxAccess.grant(startingAt: hit.folder,
                                  message: "Click Grant Access to let EverTerm's sessions use \(folder).") else { return }
        let restart = NSAlert()
        restart.messageText = "Restart the shell in “\(model.displayName)” to use \(folder)?"
        restart.informativeText = model.isAtPrompt
            ? "The history above stays. A shell only gets folder access granted after it started."
            : "Something is still running in it; restarting ends it. The history above stays."
        restart.addButton(withTitle: "Restart Shell")
        restart.addButton(withTitle: "Later")
        if restart.runModal() == .alertFirstButtonReturn {
            model.respawn(marker: "shell restarted to use \(folder)")
        }
    }

    static func describe(_ needs: [AccessPlanner.Need]) -> String {
        needs.map { "• \(ProcessInspector.abbreviate($0.folder)): \($0.reasons.joined(separator: "; "))" }
            .joined(separator: "\n")
    }
}
