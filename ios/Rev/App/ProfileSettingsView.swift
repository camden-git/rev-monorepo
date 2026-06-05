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
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    preview
                    nameSection
                    colorSection
                    if let saveError {
                        Text(saveError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(20)
            }
            .scrollContentBackground(.hidden)
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
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Display name")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("Name", text: $name)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Map color")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(MapColorPalette.swatches, id: \.self) { hex in
                    swatch(hex)
                }
            }
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
