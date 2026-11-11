import AppKit

/// Minimal menu bar so Cmd-Q / Cmd-N / Cmd-C / Cmd-V / Cmd-W work.
enum MainMenu {
    static func build(target: AppDelegate) -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit EverTerm", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let shellItem = NSMenuItem()
        let shellMenu = NSMenu(title: "Shell")
        let newItem = NSMenuItem(title: "New Window", action: #selector(AppDelegate.newWindow(_:)), keyEquivalent: "n")
        newItem.target = target
        shellMenu.addItem(newItem)
        shellMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        shellMenu.addItem(.separator())
        let resetItem = NSMenuItem(title: "Reset Terminal", action: #selector(TerminalWindowController.resetTerminal(_:)), keyEquivalent: "r")
        resetItem.keyEquivalentModifierMask = [.command, .option]
        shellMenu.addItem(resetItem)   // nil target: goes to the key window's controller
        let logsItem = NSMenuItem(title: "Show Session Logs in Finder", action: #selector(AppDelegate.showSessionLogs(_:)), keyEquivalent: "l")
        logsItem.keyEquivalentModifierMask = [.command, .shift]
        logsItem.target = target
        shellMenu.addItem(logsItem)
        shellItem.submenu = shellMenu
        main.addItem(shellItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        return main
    }
}
