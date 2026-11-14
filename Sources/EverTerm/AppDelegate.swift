import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var main: MainWindowController?
    private var store: SessionStore? { main?.store }

    func applicationDidFinishLaunching(_ notification: Notification) {
        SandboxAccess.restore()                   // #23: no-op unless sandboxed
        NSApp.mainMenu = MainMenu.build(target: self)
        // `swift run` starts a bare executable, which has no .app bundle for macOS to
        // read the icon from, so set the Dock icon here. A real EverTerm.app (scripts/release.sh)
        // has AppIcon.icns in its Info.plist; Bundle.module is not touched there.
        if Bundle.main.bundleURL.pathExtension != "app",
           let url = Bundle.module.url(forResource: "AppIcon", withExtension: "png"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        let controller = MainWindowController()
        main = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: menu actions

    @objc func newSession(_ sender: Any?) { store?.newSession() }

    @objc func closeSession(_ sender: Any?) {
        if let store, let selected = store.selected { store.close(selected) }
    }

    @objc func renameSession(_ sender: Any?) { store?.beginRename() }

    @objc func nextSession(_ sender: Any?) { store?.selectNext(1) }

    @objc func previousSession(_ sender: Any?) { store?.selectNext(-1) }

    /// ⌘1–⌘9; the menu item's tag is the 0-based index.
    @objc func selectSession(_ sender: NSMenuItem) { store?.select(index: sender.tag) }

    @objc func resetTerminal(_ sender: Any?) { store?.selected?.resetTerminal() }

    @objc func reconnectSession(_ sender: Any?) {
        if let store, let selected = store.selected { store.reconnect(selected) }
    }

    @objc func typeResumeCommand(_ sender: Any?) {
        if let store, let selected = store.selected { store.typeResumeCommand(selected) }
    }

    @objc func showShellHistory(_ sender: Any?) { main?.showShellHistory() }

    @objc func grantFolderAccess(_ sender: Any?) { SandboxAccess.grant() }

    @objc func showSessionLogs(_ sender: Any?) {
        let root = SessionLogger.rootURL
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }
}
