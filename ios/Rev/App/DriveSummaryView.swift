import RevKit
import SwiftUI

/// post-drive recap sheet (REF: docs/game-design.md §Claiming, §Trails & Enclosure)
///
/// reads the provisional `DriveSummary` built locally at finalize
///
/// future: once the drive uploads, the backend returns the authoritative tally and this recap
/// would be reconciled against it (docs/tech-stack.md §Sync Model)
struct DriveSummaryView: View {
    let summary: DriveSummary
    let store: TerritoryStore
    var onDone: () -> Void = {}

    var body: some View {
        NavigationStack {
            List {
                Section {
                    header
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }

                Section("This Drive") {
                    if summary.tilesClaimed > 0 {
                        tallyRow(icon: "flag.fill", tint: .blue,
                                 label: "New tiles claimed", value: summary.tilesClaimed)
                    }
                    ForEach(capturedRows) { row in
                        tallyRow(icon: "bolt.fill", tint: row.color,
                                 label: "Captured from \(row.name)", value: row.count)
                    }
                    if summary.tilesEnclosed > 0 {
                        tallyRow(icon: "lasso", tint: .orange,
                                 label: "Enclosed", value: summary.tilesEnclosed)
                            .listRowBackground(Color.orange.opacity(0.12))
                    }
                    if summary.tilesReinforced > 0 {
                        tallyRow(icon: "arrow.clockwise", tint: .secondary,
                                 label: "Tiles reinforced", value: summary.tilesReinforced)
                    }
                    if summary.totalGained == 0 && summary.tilesReinforced == 0 {
                        Text("No tiles changed hands this drive.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section { metricsRow }
            }
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                Button(action: onDone) {
                    Text("Done")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .glassProminentButton()
                .padding()
            }
        }
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text("Drive complete")
                .font(.title3.weight(.semibold))
            Text("+\(summary.totalGained) tiles")
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(.blue)
                .contentTransition(.numericText())
        }
        .padding(.vertical, 8)
    }

    private func tallyRow(icon: String, tint: Color, label: String, value: Int) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 24)
            Text(label)
            Spacer()
            Text("\(value)")
                .font(.headline.monospacedDigit())
        }
    }

    private var metricsRow: some View {
        HStack {
            metric(value: distanceText, label: "distance")
            Divider().frame(height: 32)
            metric(value: durationText, label: "moving")
            Divider().frame(height: 32)
            metric(value: String(format: "%.0f", summary.averageScore), label: "avg mph")
            Divider().frame(height: 32)
            metric(value: String(format: "%.0f", summary.peakScore), label: "peak mph")
        }
        .frame(maxWidth: .infinity)
    }

    private func metric(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline.monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: derived

    private struct CapturedRow: Identifiable {
        let id: String
        let name: String
        let color: Color
        let count: Int
    }

    private var capturedRows: [CapturedRow] {
        summary.capturedByOpponent
            .sorted { $0.value > $1.value }
            .map { ownerId, count in
                let player = store.player(id: ownerId)
                return CapturedRow(
                    id: ownerId,
                    name: player?.displayName ?? "rival",
                    color: player.map { Color(hex: $0.colorHex) } ?? .red,
                    count: count
                )
            }
    }

    private var distanceText: String {
        let miles = summary.distanceMeters / 1609.344
        return String(format: "%.1f mi", miles)
    }

    private var durationText: String {
        let total = Int(summary.movingTime.rounded())
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

private extension View {
    @ViewBuilder
    func glassProminentButton() -> some View {
        if #available(iOS 26, *) {
            buttonStyle(.glassProminent).tint(.blue)
        } else {
            buttonStyle(.borderedProminent).tint(.blue)
        }
    }
}
