import AppKit
import EverTermCore
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
    private var historyOpening = false   // #16: waiting for the session to build the panel text

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
        // Return only a Bool from the main-actor block: NSEvent is not Sendable.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                self?.openHistoryOnShiftScroll(event) ?? false
            }
            return handled ? nil : event
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
    /// #16: also shows what the app has shown so far. Opens once the session has built
    /// that list (a moment later, off the main thread).
    func showShellHistory() {
        guard historyPanel == nil, !historyOpening, let model = store.selected else { return }
        let terminal = model.terminalView
        let shell = ShellHistoryPanel.lines(of: terminal)
        historyOpening = true
        model.session.capturedSoFar { [weak self] app in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.historyOpening = false
                guard self.historyPanel == nil, self.store.selected === model else { return }
                let lines = HistoryPanelContent.lines(shell: shell, app: app, appName: model.displayName)
                guard !lines.isEmpty else { NSSound.beep(); return }
                let panel = ShellHistoryPanel(lines: lines, hasApp: !app.isEmpty, terminal: terminal,
                                              frame: self.container.view.bounds)
                panel.onClose = { [weak self] in self?.historyPanel = nil }
                self.historyPanel = panel
                self.container.view.addSubview(panel, positioned: .above, relativeTo: terminal)
                panel.present()
            }
        }
    }

    /// True when the event was used to open the panel (and should not reach the terminal).
    private func openHistoryOnShiftScroll(_ event: NSEvent) -> Bool {
        guard event.window === window, let terminal = store.selected?.terminalView else { return false }
        let opens = HistoryPanelRules.opensOnScroll(
            panelOpen: historyPanel != nil || historyOpening,
            shift: event.modifierFlags.contains(.shift),
            alternateScreen: terminal.terminalInputStateSnapshot()?.isAlternateBuffer == true,
            overTerminal: terminal.bounds.contains(terminal.convert(event.locationInWindow, from: nil)),
            deltaY: Double(event.scrollingDeltaY), deltaX: Double(event.scrollingDeltaX),
            precise: event.hasPreciseScrollingDeltas, momentum: !event.momentumPhase.isEmpty)
        guard opens else { return false }
        showShellHistory()
        return historyOpening || historyPanel != nil
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
