import Charts
import RevKit
import SwiftUI

/// empire history charts
struct EmpireStatsView: View {
    let social: SocialService
    let userId: String
    var title: String = "Empire"
    var embedded = false

    @State private var points: [EmpireSnapshotDTO] = []
    @State private var isLoading = true

    var body: some View {
        Group {
            if embedded {
                content
            } else {
                NavigationStack { content }
            }
        }
    }

    private var content: some View {
        List {
            if points.count < 2 {
                Section {
                    emptyState
                }
            } else {
                latest
                chartSection(
                    "Hexes Held",
                    tint: .blue,
                    symbol: "hexagon.fill",
                    values: points.map { ($0.capturedAt, Double($0.tilesHeld)) }
                )
                chartSection(
                    "Empire Strength",
                    tint: .orange,
                    symbol: "bolt.fill",
                    values: points.map { ($0.capturedAt, $0.strength) }
                )
                rankChartSection
            }
        }
        .navigationTitle("\(title) Stats")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: userId) { await load() }
        .refreshable { await load() }
    }

    @ViewBuilder
    private var latest: some View {
        if let last = points.last {
            Section {
                HStack(spacing: 0) {
                    summary("\(last.tilesHeld)", "Hexes", .blue)
                    summaryDivider
                    summary(String(format: "%.0f", last.strength), "Strength", .orange)
                    summaryDivider
                    summary(ordinal(last.rank), "Rank", .green)
                }
            }
            .listRowInsets(EdgeInsets(top: 10, leading: 8, bottom: 10, trailing: 8))
        }
    }

    private func summary(_ value: String, _ label: String, _ tint: Color) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(tint)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var summaryDivider: some View {
        Rectangle().fill(.quaternary).frame(width: 1, height: 28)
    }

    private func chartSection(_ name: String, tint: Color, symbol: String, values: [(Date, Double)]) -> some View {
        Section {
            Chart {
                ForEach(Array(values.enumerated()), id: \.offset) { _, point in
                    AreaMark(
                        x: .value("Date", point.0),
                        y: .value(name, point.1)
                    )
                    .foregroundStyle(tint.opacity(0.15).gradient)
                    LineMark(
                        x: .value("Date", point.0),
                        y: .value(name, point.1)
                    )
                    .foregroundStyle(tint)
                    .interpolationMethod(.monotone)
                }
            }
            .chartYAxis { AxisMarks(position: .leading) }
            .frame(height: 170)
            .padding(.vertical, 6)
        } header: {
            Label(name, systemImage: symbol)
                .foregroundStyle(tint)
        }
    }

    private var rankChartSection: some View {
        let values = points.map { ($0.capturedAt, $0.rank) }
        let worst = (values.map(\.1).max() ?? 1) + 1
        return Section {
            Chart {
                ForEach(Array(values.enumerated()), id: \.offset) { _, point in
                    LineMark(
                        x: .value("Date", point.0),
                        y: .value("Rank", point.1)
                    )
                    .foregroundStyle(.green)
                    .interpolationMethod(.monotone)
                    PointMark(
                        x: .value("Date", point.0),
                        y: .value("Rank", point.1)
                    )
                    .foregroundStyle(.green)
                }
            }
            .chartYScale(domain: [worst, 1])
            .chartYAxis { AxisMarks(position: .leading) }
            .frame(height: 170)
            .padding(.vertical, 6)
        } header: {
            Label("Global Rank", systemImage: "trophy.fill")
                .foregroundStyle(.green)
        } footer: {
            Text("Lower is better. Rank 1 is the top of the leaderboard.")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(isLoading ? "Loading stats..." : "Not enough history yet")
                .font(.headline)
            Text("Your empire is snapshotted as you drive. Check back after a few more drives to see your trends.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private func load() async {
        isLoading = true
        points = await social.stats(userId)
        isLoading = false
    }
}
