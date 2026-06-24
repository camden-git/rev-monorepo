import RevKit
import SwiftUI
import UIKit

/// edit the local player's display name + map color and push to server
struct ProfileSettingsView: View {
    let store: TerritoryStore
    let sync: SyncService
    let social: SocialService
    /// when pushed inside the profile hub, drop the wrapping stack + Cancel button
    /// (the hub's navigation bar back button serves as cancel)
    var embedded = false
    var onDone: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var colorHex: String
    @State private var isPrivate = false
    @State private var privacyLoaded = false
    @State private var isSaving = false
    @State private var saveError: String?

    init(
        store: TerritoryStore,
        sync: SyncService,
        social: SocialService,
        embedded: Bool = false,
        onDone: @escaping () -> Void = {}
    ) {
        self.store = store
        self.sync = sync
        self.social = social
        self.embedded = embedded
        self.onDone = onDone
        _name = State(initialValue: store.localPlayer.displayName)
        _colorHex = State(initialValue: store.localPlayer.colorHex)
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 14), count: 4)

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        if embedded {
            form
                .navigationTitle("Edit Profile")
                .navigationBarTitleDisplayMode(.inline)
                .task { await loadPrivacy() }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { saveButton }
                }
        } else {
            NavigationStack {
                form
                    .navigationTitle("Profile")
                    .navigationBarTitleDisplayMode(.inline)
                    .task { await loadPrivacy() }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel", action: onDone)
                                .disabled(isSaving)
                        }
                        ToolbarItem(placement: .confirmationAction) { saveButton }
                    }
            }
        }
    }

    private func loadPrivacy() async {
        guard sync.isSignedIn, !privacyLoaded, let id = sync.currentUserId else { return }
        if let profile = await social.profile(id) {
            isPrivate = profile.isPrivate
        }
        privacyLoaded = true
    }

    private var form: some View {
        Form {
            Section { preview }

            Section("Display Name") {
                ResponsiveTextField(
                    "Name",
                    text: $name,
                    textContentType: .name,
                    autocapitalizationType: .words,
                    autocorrectionType: .no
                )
            }

            Section("Map Color") {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(MapColorPalette.swatches, id: \.self) { hex in
                        swatch(hex)
                    }
                }
                .padding(.vertical, 8)
            }

            if sync.isSignedIn {
                Section {
                    Toggle(isOn: $isPrivate) {
                        Label("Private Account", systemImage: "lock.fill")
                    }
                } footer: {
                    Text("When your account is private, new followers need your approval and only accepted followers can see your drives and stats. Your territory always stays visible on the map.")
                }
            }

            if let saveError {
                Section {
                    Text(saveError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var saveButton: some View {
        Button {
            Task { await save() }
        } label: {
            if isSaving {
                ProgressView()
            } else {
                Text("Save")
            }
        }
        .disabled(trimmedName.isEmpty || isSaving)
    }

    private var preview: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color(hex: colorHex))
                .frame(width: 34, height: 34)
                .overlay(Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1))
            VStack(alignment: .leading, spacing: 2) {
                Text(trimmedName.isEmpty ? "Your name" : trimmedName)
                    .font(.headline)
                    .foregroundStyle(trimmedName.isEmpty ? .secondary : .primary)
                Text("how you appear on the map")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func swatch(_ hex: String) -> some View {
        let isSelected = hex.caseInsensitiveCompare(colorHex) == .orderedSame
        return Circle()
            .fill(Color(hex: hex))
            .frame(height: 48)
            .overlay {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                }
            }
            .overlay {
                Circle().strokeBorder(.white.opacity(isSelected ? 0.9 : 0.3), lineWidth: isSelected ? 3 : 1)
            }
            .contentShape(Circle())
            .onTapGesture { colorHex = hex }
            .accessibilityLabel("Color \(hex)")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func save() async {
        saveError = nil
        store.updateLocalProfile(displayName: trimmedName, colorHex: colorHex)
        guard sync.isSignedIn else {
            finish()
            return
        }

        isSaving = true
        let didSave = await sync.pushProfile()
        if didSave {
            await sync.pushPrivacy(isPrivate)
        }
        isSaving = false

        if didSave {
            finish()
        } else {
            saveError = sync.lastError ?? "Couldn't sync your profile. Try again."
        }
    }

    /// pop when pushed in the hub, otherwise hand back to the presenting sheet
    private func finish() {
        if embedded {
            dismiss()
        } else {
            onDone()
        }
    }
}

/// UIKit keeps editing responsive even when the surrounding SwiftUI view is doing
/// extra work for previews, toolbar state, or form layout on each character
struct ResponsiveTextField: UIViewRepresentable {
    let placeholder: String
    @Binding var text: String
    var textContentType: UITextContentType?
    var keyboardType: UIKeyboardType = .default
    var autocapitalizationType: UITextAutocapitalizationType = .sentences
    var autocorrectionType: UITextAutocorrectionType = .default
    var returnKeyType: UIReturnKeyType = .default
    var borderStyle: UITextField.BorderStyle = .none
    var onSubmit: (() -> Void)?

    init(
        _ placeholder: String,
        text: Binding<String>,
        textContentType: UITextContentType? = nil,
        keyboardType: UIKeyboardType = .default,
        autocapitalizationType: UITextAutocapitalizationType = .sentences,
        autocorrectionType: UITextAutocorrectionType = .default,
        returnKeyType: UIReturnKeyType = .default,
        borderStyle: UITextField.BorderStyle = .none,
        onSubmit: (() -> Void)? = nil
    ) {
        self.placeholder = placeholder
        _text = text
        self.textContentType = textContentType
        self.keyboardType = keyboardType
        self.autocapitalizationType = autocapitalizationType
        self.autocorrectionType = autocorrectionType
        self.returnKeyType = returnKeyType
        self.borderStyle = borderStyle
        self.onSubmit = onSubmit
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UITextField {
        let textField = UITextField()
        textField.delegate = context.coordinator
        textField.addTarget(
            context.coordinator,
            action: #selector(Coordinator.editingChanged(_:)),
            for: .editingChanged
        )
        textField.font = .preferredFont(forTextStyle: .body)
        textField.adjustsFontForContentSizeCategory = true
        textField.clearButtonMode = .whileEditing
        configure(textField)
        textField.text = text
        return textField
    }

    func updateUIView(_ textField: UITextField, context: Context) {
        context.coordinator.parent = self
        configure(textField)
        if !textField.isFirstResponder, textField.text != text {
            textField.text = text
        }
    }

    private func configure(_ textField: UITextField) {
        textField.placeholder = placeholder
        textField.textContentType = textContentType
        textField.keyboardType = keyboardType
        textField.autocapitalizationType = autocapitalizationType
        textField.autocorrectionType = autocorrectionType
        textField.returnKeyType = returnKeyType
        textField.borderStyle = borderStyle
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: ResponsiveTextField

        init(_ parent: ResponsiveTextField) {
            self.parent = parent
        }

        @objc func editingChanged(_ textField: UITextField) {
            let value = textField.text ?? ""
            if parent.text != value {
                parent.text = value
            }
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onSubmit?()
            if parent.onSubmit != nil {
                textField.resignFirstResponder()
            }
            return true
        }
    }
}
