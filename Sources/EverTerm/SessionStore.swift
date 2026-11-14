import AppKit
import Combine

/// All sessions shown in the sidebar, and which one is selected.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [SessionModel] = []
    @Published var selectedID: UUID? {
        didSet { for model in sessions { model.isSelected = (model.id == selectedID) } }
    }
    /// Session whose name is being edited in the sidebar (Rename).
    @Published var editingID: UUID?

    private var forwarders: [UUID: AnyCancellable] = [:]
    private var timer: Timer?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    var live: [SessionModel] { sessions.filter { $0.status == .running } }
    var ended: [SessionModel] { sessions.filter { $0.status != .running } }
    /// Sidebar order: live first, then ended (used by ⌘1–9 and next/previous).
    var ordered: [SessionModel] { live + ended }
    var selected: SessionModel? { sessions.first { $0.id == selectedID } }

    func newSession() {
        add(SessionModel(directory: selected?.directory ?? NSHomeDirectory()))
    }

    private func add(_ model: SessionModel) {
        // Re-publish the model's changes so the sidebar sections regroup.
        forwarders[model.id] = model.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        sessions.append(model)
        selectedID = model.id
    }

    /// Live session: end it (it moves to Ended). Ended session: remove it from the list.
    func close(_ model: SessionModel) {
        if model.status == .running {
            model.terminate()
            return
        }
        let order = ordered
        let index = order.firstIndex { $0 === model } ?? 0
        sessions.removeAll { $0 === model }
        forwarders[model.id] = nil
        if selectedID == model.id {
            let rest = ordered
            selectedID = rest.isEmpty ? nil : rest[min(index, rest.count - 1)].id
        }
        if sessions.isEmpty { newSession() }
    }

    func select(index: Int) {
        let order = ordered
        guard order.indices.contains(index) else { return }
        selectedID = order[index].id
    }

    func selectNext(_ step: Int) {
        let order = ordered
        guard !order.isEmpty else { return }
        let current = order.firstIndex { $0.id == selectedID } ?? 0
        selectedID = order[(current + step + order.count) % order.count].id
    }

    // MARK: reconnect (#18)

    /// ⌘R. Dropped connection, shell at its prompt: run the saved command again here.
    /// Ended session: new session in the same directory running it, same custom name.
    /// The command is shown once before it first runs (it can hold a secret).
    func reconnect(_ model: SessionModel) {
        switch model.reconnectPlan {
        case .rerun(let command):
            guard confirm(command, for: model) else { return }
            model.rerun(command)
        case .newSession(_, let command):
            if let command, !confirm(command, for: model) { return }
            var carry = model.carry()
            carry.confirmed = true
            add(SessionModel(directory: carry.directory ?? NSHomeDirectory(), carry: carry))
        case .busy, .nothingSaved:
            NSSound.beep()
        }
    }

    func typeResumeCommand(_ model: SessionModel) {
        if !model.typeResumeCommand() { NSSound.beep() }
    }

    private func confirm(_ command: String, for model: SessionModel) -> Bool {
        if model.reconnectConfirmed { return true }
        let alert = NSAlert()
        alert.messageText = "Reconnect “\(model.displayName)”?"
        alert.informativeText = "EverTerm will run:\n\n\(command)\n\nThis command line is saved only on this Mac, in the session's meta.json. "
            + "Use Forget Reconnect Command in the sidebar menu to clear it."
        alert.addButton(withTitle: "Reconnect")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func beginRename() {
        editingID = selectedID
    }

    func endAll() {
        for model in sessions { model.terminate() }
    }

    private func refresh() {
        for model in sessions { model.refreshProcessInfo() }
    }
}
