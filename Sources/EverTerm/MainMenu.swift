import AppKit

/// Menu bar. Session shortcuts follow the design in issue #11.
@MainActor
enum MainMenu {
    static func build(target: AppDelegate) -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit EverTerm", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: appMenu, title: "EverTerm")

        let shell = NSMenu(title: "Shell")
        shell.addItem(item("New Session", #selector(AppDelegate.newSession(_:)), "t", target: target))
        shell.addItem(item("New Session", #selector(AppDelegate.newSession(_:)), "n", target: target, alternate: true))
        shell.addItem(item("End / Remove Session", #selector(AppDelegate.closeSession(_:)), "w", target: target))
        shell.addItem(item("Rename Session…", #selector(AppDelegate.renameSession(_:)), "r", [.command, .shift], target: target))
        shell.addItem(.separator())
        shell.addItem(item("Reset Terminal", #selector(AppDelegate.resetTerminal(_:)), "r", [.command, .option], target: target))
        shell.addItem(item("Show Shell History", #selector(AppDelegate.showShellHistory(_:)), "h", [.command, .shift], target: target))
        shell.addItem(item("Show Session Logs in Finder", #selector(AppDelegate.showSessionLogs(_:)), "l", [.command, .shift], target: target))
        main.addItem(submenu: shell, title: "Shell")

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu: edit, title: "Edit")

        let view = NSMenu(title: "View")
        view.addItem(item("Toggle Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control], target: nil))
        main.addItem(submenu: view, title: "View")

        let sessions = NSMenu(title: "Session")
        sessions.addItem(item("Next Session", #selector(AppDelegate.nextSession(_:)), "}", target: target))
        sessions.addItem(item("Previous Session", #selector(AppDelegate.previousSession(_:)), "{", target: target))
        sessions.addItem(.separator())
        for index in 0 ..< 9 {
            let entry = item("Session \(index + 1)", #selector(AppDelegate.selectSession(_:)), "\(index + 1)", target: target)
            entry.tag = index
            sessions.addItem(entry)
        }
        main.addItem(submenu: sessions, title: "Session")

        return main
    }

    private static func item(_ title: String, _ action: Selector, _ key: String,
                             _ modifiers: NSEvent.ModifierFlags = [.command],
                             target: AnyObject?, alternate: Bool = false) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.keyEquivalentModifierMask = modifiers
        entry.target = target
        if alternate { entry.isHidden = true; entry.allowsKeyEquivalentWhenHidden = true }
        return entry
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = submenu
        addItem(holder)
    }
}
