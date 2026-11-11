import AppKit
import Combine
import SwiftUI

/// The single main window: sidebar on the left, selected session's terminal on the right.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let store: SessionStore
    private let container: TerminalContainerViewController
    private var selection: AnyCancellable?
    private var scrollMonitor: Any?
    private var historyPanel: ShellHistoryPanel?

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

        // #14: Shift + scroll up over a full-screen app opens the shell history.
        // SwiftTerm's scrollWheel is public but not open, so watch events instead of subclassing.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.openHistoryOnShiftScroll(event) else { return event }
                return nil
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func show(_ id: UUID?) {
        guard let model = store.sessions.first(where: { $0.id == id }) else { return }
        historyPanel?.close()
        container.show(model.terminalView)
        window?.makeFirstResponder(model.terminalView)
    }

    // MARK: shell history panel (#14)

    /// Shell → Show Shell History (⇧⌘H). Works on any screen; most useful in a full-screen app.
    func showShellHistory() {
        guard historyPanel == nil, let terminal = store.selected?.terminalView else { return }
        guard let lines = ShellHistoryPanel.lines(of: terminal) else { NSSound.beep(); return }
        let panel = ShellHistoryPanel(lines: lines, terminal: terminal, frame: container.view.bounds)
        panel.onClose = { [weak self] in self?.historyPanel = nil }
        historyPanel = panel
        container.view.addSubview(panel, positioned: .above, relativeTo: terminal)
        panel.present()
    }

    /// True when the event was used to open the panel (and should not reach the terminal).
    private func openHistoryOnShiftScroll(_ event: NSEvent) -> Bool {
        guard historyPanel == nil, event.window === window,
              event.modifierFlags.contains(.shift),
              let terminal = store.selected?.terminalView,
              terminal.terminalInputStateSnapshot()?.isAlternateBuffer == true,
              terminal.bounds.contains(terminal.convert(event.locationInWindow, from: nil))
        else { return false }
        // A mouse wheel with Shift held reports a horizontal scroll; a trackpad keeps it vertical.
        let delta = event.scrollingDeltaY != 0 || event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY : event.scrollingDeltaX
        guard delta > 0, event.momentumPhase.isEmpty else { return false }   // up, finger on the pad
        showShellHistory()
        return historyPanel != nil
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
