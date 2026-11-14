import AppKit
import EverTermCore

/// #27: asks for the folders the shell needs (sandboxed build only).
/// One dialog lists exactly the folders needed and why. macOS lets an app use a folder only after
/// the user picks it in Apple's own folder picker, so after Allow that picker appears once per folder,
/// already opened at it ("1 of 2"): the user only clicks Grant Access. Access is exactly those folders.
@MainActor
enum AccessPrompt {
    private static let declinedKey = "accessDeclinedFolders"
    private static var busy = false
    /// Refusal offers stay quiet until then (during the launch flow and right after a restart,
    /// the shell's own startup errors would otherwise pop another picker).
    private static var quietUntil = Date.distantPast

    /// At launch: the dialog, then one picker per folder, then shells at their prompt restart.
    static func atLaunch(store: SessionStore) {
        guard SandboxAccess.isSandboxed, !busy else { return }
        let needs = SandboxAccess.needs().filter { !declined.contains($0.folder) }
        guard !needs.isEmpty else { return }
        busy = true
        quietUntil = .distantFuture
        defer {
            busy = false
            quietUntil = Date().addingTimeInterval(3)
        }
        let alert = NSAlert()
        alert.messageText = "Allow EverTerm to use these folders?"
        alert.informativeText = list(needs)
            + "\n\nYour shell needs them to work as usual. macOS then shows its folder picker once for each, "
            + "already at the folder: just click Grant Access."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else {
            declined.formUnion(needs.map(\.folder))
            return
        }
        if grantInTurn(needs) { store.restartShellsAtPrompt(marker: "shell restarted to use the new folder access") }
    }

    /// Apple's picker once per folder, already at it. Once home is granted its startup files can be
    /// read and may name more folders: those are added to the end. Cancel stops. Returns whether any was granted.
    static func grantInTurn(_ first: [AccessPlanner.Need]) -> Bool {
        var queue = first
        var asked = Set(first.map(\.folder))
        var index = 0
        var grantedAny = false
        while index < queue.count {
            let need = queue[index]
            let step = queue.count > 1 ? "\(index + 1) of \(queue.count): " : ""
            let message = step + "click Grant Access to let EverTerm use \(ProcessInspector.abbreviate(need.folder)) "
                + "(\(need.reasons.joined(separator: "; ")))."
            guard SandboxAccess.grant(startingAt: need.folder, message: message) else { break }
            grantedAny = true
            index += 1
            for more in SandboxAccess.needs() where !declined.contains(more.folder) {
                if asked.insert(more.folder).inserted { queue.append(more) }
            }
        }
        return grantedAny
    }

    /// A program in `model` was refused `paths`: the picker for that folder, once per session.
    /// Then the shell restarts in place if it is at its prompt; otherwise a note says how to use it.
    static func offer(paths: [String], in model: SessionModel, store: SessionStore) {
        guard SandboxAccess.isSandboxed, !busy, Date() >= quietUntil else { return }
        let home = SandboxAccess.realHome
        let granted = SandboxAccess.grantedPaths
        guard let hit = paths.lazy.compactMap({ path -> (folder: String, path: String)? in
            guard let root = AccessPlanner.grantRoot(for: path, home: home) else { return nil }
            return (root, path)
        }).first(where: { candidate in
            !model.declinedFolders.contains(candidate.folder)
                && AccessPlanner.plan(sources: [], home: candidate.folder, granted: granted,
                                      readable: SandboxAccess.canRead).contains { $0.folder == candidate.folder }
        }) else { return }
        busy = true
        defer { busy = false }
        let need = AccessPlanner.Need(folder: hit.folder,
                                      reasons: ["a program in “\(model.displayName)” was refused \(ProcessInspector.abbreviate(hit.path))"])
        let message = "Click Grant Access to let EverTerm use \(ProcessInspector.abbreviate(need.folder)) "
            + "(\(need.reasons.joined(separator: "; ")))."
        guard SandboxAccess.grant(startingAt: hit.folder, message: message) else {
            model.declinedFolders.insert(hit.folder)
            return
        }
        quietUntil = Date().addingTimeInterval(3)
        let folder = ProcessInspector.abbreviate(hit.folder)
        if model.isAtPrompt {
            model.respawn(marker: "shell restarted to use \(folder)")
        } else {
            model.note("\(folder) granted: it works in new sessions, or here after the running program ends and the shell restarts (Shell > Grant Folder Access… restarts shells at their prompt)")
        }
    }

    private static func list(_ needs: [AccessPlanner.Need]) -> String {
        needs.map { "• \(ProcessInspector.abbreviate($0.folder)): \($0.reasons.joined(separator: "; "))" }
            .joined(separator: "\n")
    }

    private static var declined: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: declinedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: declinedKey) }
    }
}
