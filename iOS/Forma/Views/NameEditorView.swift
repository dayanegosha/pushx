import SwiftUI

struct NameEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var auth: AuthService
    @State private var name: String
    @State private var saving = false
    @State private var error: String?
    @FocusState private var focused: Bool

    init(name: String) {
        _name = State(initialValue: name)
    }

    private var normalized: String? { ProfileName.normalized(name) }

    var body: some View {
        NavigationStack {
            ScrollView {
                AdaptiveContent(maxWidth: 640) {
                    VStack(alignment: .leading, spacing: 24) {
                        PageTitle(title: L.text("name_editor_title"))
                        VStack(alignment: .leading, spacing: 12) {
                            TextField(L.text("name_placeholder"), text: $name)
                                .font(AppFont.text(25, weight: .medium)).textContentType(.name)
                                .textInputAutocapitalization(.words).autocorrectionDisabled()
                                .submitLabel(.done).focused($focused).disabled(saving)
                                .accessibilityIdentifier("profile_name_input")
                                .onSubmit { save() }
                                .onChange(of: name) { _, _ in error = nil }
                            Text(L.text("name_range")).font(AppFont.text(12)).foregroundStyle(.secondary)
                        }.padding(22).background(Color.panel, in: RoundedRectangle(cornerRadius: 22))
                        Text(L.text("name_hint")).font(AppFont.text(14)).foregroundStyle(.secondary)
                        if !name.isEmpty && normalized == nil { StatusNote(text: L.text("name_invalid")) }
                        if let error { StatusNote(text: error) }
                        Button(action: save) {
                            if saving { ProgressView().tint(Color.canvas) }
                            else { Text(L.text("save")) }
                        }.buttonStyle(FilledButton()).disabled(normalized == nil || saving || auth.session == nil)
                            .accessibilityIdentifier("save_profile_name")
                    }
                }
            }.background(Color.canvas)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L.text("cancel")) { dismiss() }.disabled(saving)
                    }
                }
                .interactiveDismissDisabled(saving)
        }
    }

    private func save() {
        guard let normalized, !saving, auth.session != nil else { return }
        saving = true
        focused = false
        error = nil
        Task {
            do {
                try await auth.updateDisplayName(normalized)
                dismiss()
            } catch {
                self.error = L.text("name_save_error")
            }
            saving = false
        }
    }
}
