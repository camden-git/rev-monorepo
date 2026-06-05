import RevKit
import SwiftUI

/// drive history + empire overview sheet (REF: docs/game-design.md §Defense & Decay)
///
/// future: once drives upload, the backend's authoritative state replaces these provisional
/// local tallies (docs/tech-stack.md §Sync Model)
struct DriveHistoryView: View {
    let store: TerritoryStore
    var onDone: () -> Void = {}

    /// the drive whose full recap is being shown
    @State private var selectedDrive: DriveRecord?

    var body: some View {
        let drives = store.driveHistory()
        let stats = EmpireStats.compute(
            tiles: Array(store.tiles.values),
            ownedBy: store.localPlayer.id,
            driveSummaries: drives.compactMap(\.summary)
        )

        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        statCell("\(stats.tilesHeld)", "Tiles held", .blue)
                        statCell(
                            "\(stats.tilesAtRisk)",
                            "At risk",
                            stats.tilesAtRisk > 0 ? .orange : .secondary
                        )
                        statCell(
                            String(format: "%.0f", stats.strongholdScore),
                            "Stronghold mph",
                            .blue
                        )
                    }
                    .padding(.vertical, 4)
                }

                Section("Lifetime") {
                    LabeledContent("Drives") {
                        Text("\(stats.totalDrives)").monospacedDigit()
                    }
                    LabeledContent("Distance") {
                        Text(lifetimeDistanceText(for: stats)).monospacedDigit()
                    }
                    LabeledContent("Tiles gained") {
                        Text("+\(stats.lifetimeTilesGained)")
                            .monospacedDigit()
                            .foregroundStyle(.green)
                    }
                }

                if drives.isEmpty {
                    Section { emptyState }
                } else {
                    Section("Past Drives") {
                        ForEach(drives) { record in
                            Button { selectedDrive = record } label: { driveRow(record) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Your Empire")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
            .sheet(item: $selectedDrive) { record in
                if let summary = record.summary {
                    DriveSummaryView(summary: summary, store: store) { selectedDrive = nil }
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                }
            }
        }
    }

    // MARK: rows

    private func statCell(_ value: String, _ label: String, _ tint: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title2.weight(.bold).monospacedDigit())
                .foregroundStyle(tint)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "road.lanes")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No drives yet")
                .font(.headline)
            Text("Start a drive to begin claiming territory.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private func driveRow(_ record: DriveRecord) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "flag.checkered")
                .foregroundStyle(.blue)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.startedAt, format: .dateTime.month().day().hour().minute())
                    .font(.subheadline.weight(.medium))
                Text(rowSubtitle(record))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let summary = record.summary {
                Text("+\(summary.totalGained)")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.blue)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: derived text

    private func rowSubtitle(_ record: DriveRecord) -> String {
        guard let summary = record.summary else { return "—" }
        var parts: [String] = []
        let miles = summary.distanceMeters / 1609.344
        if miles > 0 { parts.append(String(format: "%.1f mi", miles)) }
        if summary.totalCaptured > 0 { parts.append("\(summary.totalCaptured) captured") }
        if summary.tilesEnclosed > 0 { parts.append("\(summary.tilesEnclosed) enclosed") }
        if parts.isEmpty { parts.append("no tiles changed hands") }
        return parts.joined(separator: " · ")
    }

    private func lifetimeDistanceText(for stats: EmpireStats) -> String {
        let miles = stats.lifetimeDistanceMeters / 1609.344
        return String(format: "%.1f mi", miles)
    }
}
