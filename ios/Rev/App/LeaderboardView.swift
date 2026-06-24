import RevKit
import SwiftUI

/// territory leaderboard
///
/// ranking uses Score Metric v2's speed-weighted empire strength (sum of claim strength)
struct LeaderboardView: View {
    let store: TerritoryStore
    let social: SocialService
    /// when pushed inside a hub/drawer, drop the wrapping stack + Done button
    var embedded = false
    var onDone: () -> Void = {}

    private var entries: [TerritoryStore.LeaderboardEntry] { store.leaderboard() }

    var body: some View {
        if embedded {
            list
        } else {
            NavigationStack {
                list
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done", action: onDone)
                        }
                    }
            }
        }
    }

    private var list: some View {
        List {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                NavigationLink {
                    PlayerProfileView(
                        store: store,
                        social: social,
                        userId: entry.playerId,
                        fallbackName: entry.displayName,
                        fallbackColor: entry.colorHex
                    )
                } label: {
                    row(rank: index + 1, entry: entry)
                }
                .listRowBackground(entry.isLocal ? Color.blue.opacity(0.12) : nil)
            }
        }
        .navigationTitle("Leaderboard")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(rank: Int, entry: TerritoryStore.LeaderboardEntry) -> some View {
        HStack(spacing: 14) {
            Text("\(rank)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .center)

            Circle()
                .fill(Color(hex: entry.colorHex))
                .frame(width: 22, height: 22)
                .overlay(Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1))

            Text(entry.isLocal ? "\(entry.displayName) (you)" : entry.displayName)
                .font(.subheadline.weight(entry.isLocal ? .semibold : .medium))
                .lineLimit(1)

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 1) {
                Text(String(format: "%.1f", entry.empireStrength))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.blue)
                Text("\(entry.tilesHeld) tiles")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
