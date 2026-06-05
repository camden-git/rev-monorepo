import RevKit
import SwiftUI

/// territory leaderboard
///
/// lifetime drive stats only exist for the local player, so ranking uses current
/// territory size
struct LeaderboardView: View {
    let store: TerritoryStore
    var onDone: () -> Void = {}

    private var entries: [TerritoryStore.LeaderboardEntry] { store.leaderboard() }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        row(rank: index + 1, entry: entry)
                    }
                }
                .padding(20)
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Leaderboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
        }
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
                Text("\(entry.tilesHeld)")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.blue)
                Text("tiles")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .liquidGlassPanel(cornerRadius: 14, tint: entry.isLocal ? .blue : nil, interactive: true)
        .overlay {
            if entry.isLocal {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.blue.opacity(0.5), lineWidth: 1)
            }
        }
    }
}

private extension View {
    @ViewBuilder
    func liquidGlassPanel(cornerRadius: CGFloat, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(iOS 26, *) {
            let base: Glass = tint.map { Glass.regular.tint($0.opacity(0.18)) } ?? .regular
            let glass = interactive ? base.interactive() : base
            glassEffect(glass, in: .rect(cornerRadius: cornerRadius))
        } else {
            background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}
