import AppKit
import Combine
import SwiftUI

/// The single main window: sidebar on the left, selected session's terminal on the right.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let store: SessionStore
    private let container: TerminalContainerViewController
    private var selection: AnyCancellable?

    init() {
        let store = SessionStore()
        let container = TerminalContainerViewController()
        self.store = store
        self.container = container

        let split = NSSplitViewController()
        let sidebar = NSSplitViewItem(sidebarWithViewController: NSHostingController(rootView: SidebarView(store: store)))
        sidebar.minimumThickness = 200
        sidebar.maximumThickness = 420
        sidebar.canCollapse = true
        split.addSplitViewItem(sidebar)
        split.addSplitViewItem(NSSplitViewItem(viewController: container))

        let window = NSWindow(contentViewController: split)
        window.title = "EverTerm"
        window.setContentSize(NSSize(width: 1200, height: 760))
        window.styleMask.insert([.resizable, .miniaturizable, .closable, .titled])
        super.init(window: window)
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("EverTermMain")

        // $selectedID publishes the new value before it is stored, so use it directly.
        selection = store.$selectedID.sink { [weak self] id in
            self?.show(id)
        }
        store.newSession()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func show(_ id: UUID?) {
        guard let model = store.sessions.first(where: { $0.id == id }) else { return }
        container.show(model.terminalView)
        window?.makeFirstResponder(model.terminalView)
    }

    func windowWillClose(_ notification: Notification) {
        store.endAll()
    }
}

/// Right side: shows exactly one session's terminal view at a time.
final class TerminalContainerViewController: NSViewController {
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
    }

    func show(_ terminal: NSView) {
        guard terminal.superview !== view else { return }
        view.subviews.forEach { $0.removeFromSuperview() }
        terminal.frame = view.bounds
        terminal.autoresizingMask = [.width, .height]
        view.addSubview(terminal)
    }
}
