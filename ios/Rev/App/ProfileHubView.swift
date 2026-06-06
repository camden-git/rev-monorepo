import RevKit
import SwiftUI

/// the account hub
///
/// built as a `NavigationStack` so it scales
struct ProfileHubView: View {
    let store: TerritoryStore
    let sync: SyncService
    var onDone: () -> Void = {}

    var body: some View {
        NavigationStack {
            List {
                Section { header }

                Section {
                    NavigationLink {
                        DriveHistoryView(store: store, embedded: true)
                    } label: {
                        Label("Empire & Drive History", systemImage: "chart.bar.xaxis")
                    }
                }

                Section {
                    NavigationLink {
                        ProfileSettingsView(store: store, sync: sync, embedded: true)
                    } label: {
                        Label("Edit Profile", systemImage: "pencil")
                    }
                }

                #if DEBUG
                Section("Developer") {
                    Button {
                        Task {
                            await sync.devSignIn()
                            await sync.uploadPending()
                        }
                    } label: {
                        Label(
                            sync.isSignedIn ? "Signed in · sync now" : "Dev sign in & sync",
                            systemImage: sync.isSignedIn ? "icloud.fill" : "icloud.slash"
                        )
                    }
                }
                #endif
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            PlayerAvatar(
                colorHex: store.localPlayer.colorHex,
                name: store.localPlayer.displayName,
                size: 56
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(store.localPlayer.displayName)
                    .font(.title3.weight(.semibold))
                if let standing {
                    Text(standing)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }

    /// "Rank #2 · 39 tiles", drawn from the same leaderboard the trophy button shows
    private var standing: String? {
        let board = store.leaderboard()
        guard let index = board.firstIndex(where: { $0.isLocal }) else { return nil }
        return "Rank #\(index + 1) · \(board[index].tilesHeld) tiles"
    }
}
