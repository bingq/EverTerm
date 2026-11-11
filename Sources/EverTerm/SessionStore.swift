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
        let directory = selected?.directory ?? NSHomeDirectory()
        let model = SessionModel(directory: directory)
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
