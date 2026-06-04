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

    private var stats: EmpireStats { store.empireStats() }
    private var drives: [DriveRecord] { store.driveHistory() }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    overview
                    driveList
                }
                .padding(20)
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

    // MARK: empire overview

    private var overview: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                statCard(value: "\(stats.tilesHeld)", label: "tiles held", tint: .blue)
                statCard(
                    value: "\(stats.tilesAtRisk)",
                    label: "at risk",
                    tint: stats.tilesAtRisk > 0 ? .orange : .secondary
                )
                statCard(
                    value: String(format: "%.0f", stats.strongholdScore),
                    label: "stronghold mph",
                    tint: .blue
                )
            }

            HStack {
                lifetimeStat(value: "\(stats.totalDrives)", label: "drives")
                Divider().frame(height: 32)
                lifetimeStat(value: lifetimeDistanceText, label: "lifetime")
                Divider().frame(height: 32)
                lifetimeStat(value: "+\(stats.lifetimeTilesGained)", label: "tiles gained")
            }
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func statCard(value: String, label: String, tint: Color) -> some View {
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
        .padding(.vertical, 16)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
    }

    private func lifetimeStat(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline.monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: past drives

    @ViewBuilder
    private var driveList: some View {
        if drives.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "road.lanes")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("No drives yet")
                    .font(.headline)
                Text("Start a drive to begin claiming territory.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("Past drives")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(drives) { record in
                    Button { selectedDrive = record } label: { driveRow(record) }
                        .buttonStyle(.plain)
                }
            }
        }
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
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
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

    private var lifetimeDistanceText: String {
        let miles = stats.lifetimeDistanceMeters / 1609.344
        return String(format: "%.1f mi", miles)
    }
}
