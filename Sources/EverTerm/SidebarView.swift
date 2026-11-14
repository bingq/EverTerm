import AppKit
import SwiftUI

/// Left panel: filter box, Live and Ended sections, New Session button.
struct SidebarView: View {
    @ObservedObject var store: SessionStore
    @State private var filter = ""

    var body: some View {
        VStack(spacing: 0) {
            TextField("Filter sessions", text: $filter)
                .textFieldStyle(.roundedBorder)
                .padding(8)

            List(selection: $store.selectedID) {
                section("Live", store.live)
                section("Ended", store.ended)
            }
            .listStyle(.sidebar)
            // Right-click menu, and double-click (primaryAction) to rename.
            .contextMenu(forSelectionType: UUID.self) { ids in
                if let id = ids.first, let model = store.sessions.first(where: { $0.id == id }) {
                    menu(for: model)
                }
            } primaryAction: { ids in
                store.editingID = ids.first
            }

            Divider()
            Button {
                store.newSession()
            } label: {
                Label("New Session", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .padding(8)
            .help("New Session (⌘T)")
        }
        .frame(minWidth: 200)
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [SessionModel]) -> some View {
        let shown = items.filter(matches)
        if !shown.isEmpty {
            Section(title) {
                ForEach(shown) { model in
                    SessionRow(model: model, store: store).tag(model.id)
                }
            }
        }
    }

    private func matches(_ model: SessionModel) -> Bool {
        let query = filter.trimmingCharacters(in: .whitespaces)
        if query.isEmpty { return true }
        return model.displayName.localizedCaseInsensitiveContains(query)
            || (model.directory ?? "").localizedCaseInsensitiveContains(query)
    }

    @ViewBuilder
    private func menu(for model: SessionModel) -> some View {
        Button("Rename…") { store.editingID = model.id }
        if model.customName != nil {
            Button("Use Automatic Name") { model.customName = nil }
        }
        Divider()
        Button("Reconnect") { store.reconnect(model) }
            .disabled(model.status == .running && model.reconnectCommand == nil)
        if model.resumeHint != nil {
            Button("Type Claude Resume Command") { store.typeResumeCommand(model) }
                .disabled(model.status != .running)
        }
        if model.reconnectCommand != nil || model.resumeHint != nil {
            Button("Forget Reconnect Command") { model.forgetReconnect() }
        }
        Divider()
        Button("Show Logs in Finder") { NSWorkspace.shared.open(model.logDirectory) }
        Divider()
        Button(model.status == .running ? "End Session" : "Remove from List") { store.close(model) }
    }
}

/// One row: status dot, name (or rename field), subtitle, unseen-output dot.
struct SessionRow: View {
    @ObservedObject var model: SessionModel
    @ObservedObject var store: SessionStore
    @State private var draft = ""
    @FocusState private var nameFieldFocused: Bool

    private var isEditing: Bool { store.editingID == model.id }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
                .help(statusHelp)

            VStack(alignment: .leading, spacing: 2) {
                if isEditing {
                    TextField("Session name", text: $draft)
                        .textFieldStyle(.plain)
                        .focused($nameFieldFocused)
                        .onSubmit(commitRename)
                        .onExitCommand { store.editingID = nil }
                        .onAppear {
                            draft = model.displayName
                            nameFieldFocused = true
                        }
                        .onChange(of: nameFieldFocused) { focused in
                            if !focused, isEditing { commitRename() }
                        }
                } else {
                    Text(model.displayName)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Text(model.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            if model.hasUnseenOutput {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
                    .padding(.top, 6)
                    .help("New output")
            }
        }
        .padding(.vertical, 2)
    }

    /// Empty name, or the automatic name itself, means "use the automatic name".
    private func commitRename() {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        model.customName = (name.isEmpty || name == model.autoName) ? nil : name
        store.editingID = nil
    }

    private var statusColor: Color {
        switch model.status {
        case .running: return model.programDropped ? .orange : .green
        case .ended(let code): return code == 0 ? .gray : .red
        }
    }

    private var statusHelp: String {
        switch model.status {
        case .running: return model.programDropped ? "Running · connection ended; ⌘R reconnects" : "Running"
        case .ended(let code): return code.map { "Ended, exit \($0)" } ?? "Ended by a signal"
        }
    }
}
