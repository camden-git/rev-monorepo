import RevKit
import SwiftUI

/// edit the local player's display name + map color and push to server
struct ProfileSettingsView: View {
    let store: TerritoryStore
    let sync: SyncService
    var onDone: () -> Void = {}

    @State private var name: String
    @State private var colorHex: String
    @State private var isSaving = false
    @State private var saveError: String?

    init(store: TerritoryStore, sync: SyncService, onDone: @escaping () -> Void = {}) {
        self.store = store
        self.sync = sync
        self.onDone = onDone
        _name = State(initialValue: store.localPlayer.displayName)
        _colorHex = State(initialValue: store.localPlayer.colorHex)
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 14), count: 4)

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section { preview }

                Section("Display Name") {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                }

                Section("Map Color") {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(MapColorPalette.swatches, id: \.self) { hex in
                            swatch(hex)
                        }
                    }
                    .padding(.vertical, 8)
                }

                if let saveError {
                    Section {
                        Text(saveError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onDone)
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
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
            }
        }
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
            onDone()
            return
        }

        isSaving = true
        let didSave = await sync.pushProfile()
        isSaving = false

        if didSave {
            onDone()
        } else {
            saveError = sync.lastError ?? "Couldn't sync your profile. Try again."
        }
    }
}
