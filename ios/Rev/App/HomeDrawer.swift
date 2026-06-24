import RevKit
import SwiftUI

/// the home surface
struct HomeDrawer: View {
    let store: TerritoryStore
    let tracker: DriveTracker
    let signIn: AppleSignInCoordinator
    let sync: SyncService
    let social: SocialService

    @Binding var selectedTile: HexTileDetail?
    @Binding var showSummary: Bool

    @State private var showProfile = false
    @State private var showSessionRecovery = false
    @State private var selectedDrive: DriveRecord?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    primaryRow

                    if !tracker.isRecording {
                        leaderboardSection
                        pastDrivesSection
                    }
                }
                .padding(.horizontal)
                .padding(.top, 20)
                .padding(.bottom, 32)
            }
            .scrollBounceBehavior(.basedOnSize)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $selectedTile) { tile in
                TileDetailView(detail: tile) { selectedTile = nil }
                    .presentationDetents([.height(340), .medium])
                    .presentationBackgroundInteraction(.enabled(upThrough: .height(340)))
                    .presentationDragIndicator(.visible)
            }
        }
    }

    // MARK: primary row

    @ViewBuilder
    private var primaryRow: some View {
        VStack(spacing: 12) {
            if tracker.isRecording {
                recordingHUD
            }

            if sync.requiresSignIn {
                sessionRecoveryButton
            }

            HStack(spacing: 12) {
                Button {
                    if tracker.isRecording { tracker.endDrive() } else { tracker.startDrive() }
                } label: {
                    Label(
                        tracker.isRecording ? "Stop Drive" : "Start Drive",
                        systemImage: tracker.isRecording ? "stop.fill" : "play.fill"
                    )
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 36)
                }
                .driveButtonStyle(recording: tracker.isRecording)

                Button { showProfile = true } label: {
                    PlayerAvatar(
                        colorHex: store.localPlayer.colorHex,
                        name: store.localPlayer.displayName,
                        size: 52
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Your profile")
            }
        }
        .sheet(isPresented: $showProfile) {
            ProfileHubView(store: store, sync: sync, social: social, signIn: signIn) { showProfile = false }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showSessionRecovery) {
            SessionRecoveryView(signIn: signIn, sync: sync) {
                showSessionRecovery = false
            }
            .presentationDetents([.height(420), .medium])
            .presentationDragIndicator(.visible)
            .interactiveDismissDisabled(sync.requiresSignIn)
        }
        .onAppear {
            if sync.requiresSignIn {
                showSessionRecovery = true
            }
        }
        .onChange(of: sync.requiresSignIn) { _, needsSignIn in
            if needsSignIn {
                showSessionRecovery = true
            } else {
                showSessionRecovery = false
            }
        }
        .sheet(isPresented: $showSummary) {
            if let summary = tracker.lastDriveSummary {
                DriveSummaryView(summary: summary, store: store) { showSummary = false }
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    private var sessionRecoveryButton: some View {
        Button {
            showSessionRecovery = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(sessionRecoveryTitle)
                        .font(.subheadline.weight(.semibold))
                    Text(sync.lastError ?? "Rev cannot sync until your session is refreshed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var sessionRecoveryTitle: String {
        sync.lastErrorKind == .authenticationRequired ? "Sign in again" : "Sign in to sync"
    }

    private var recordingHUD: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 8) {
                HStack(spacing: 14) {
                    Label("\(tracker.claimsThisDrive)", systemImage: "flag.fill")
                        .foregroundStyle(.blue)
                    Text(contestedText)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Label(distanceText, systemImage: "ruler")
                    Label(elapsedText(asOf: context.date), systemImage: "clock")
                        .foregroundStyle(.secondary)
                }
                .font(.caption.weight(.medium).monospacedDigit())

                HStack(spacing: 10) {
                    Image(systemName: "record.circle.fill")
                        .foregroundStyle(.red)
                    Text(String(format: "%.0f mph", tracker.currentSpeedMph))
                        .monospacedDigit()
                    Text("\(tracker.claimedTileCount) tiles")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .font(.subheadline.weight(.medium))
            }
            .lineLimit(1)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: Capsule())
        }
    }

    // MARK: leaderboard carousel

    private var leaderboardSection: some View {
        let board = store.leaderboard()
        let rank = board.firstIndex { $0.isLocal }.map { $0 + 1 }
        let stats = empireStats()

        return VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Leaderboard") {
                LeaderboardView(store: store, social: social, embedded: true)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    rankCard(rank: rank, tiles: stats.tilesHeld, drivers: board.count)
                    statCard(String(format: "%.1f", stats.empireScore), "Empire score", .blue, "square.grid.3x3.fill")
                    statCard(
                        "\(stats.tilesAtRisk)",
                        "At risk",
                        stats.tilesAtRisk > 0 ? .orange : .secondary,
                        "exclamationmark.triangle.fill"
                    )
                    statCard(
                        String(format: "%.1f", stats.strongholdScore),
                        "Stronghold",
                        .blue,
                        "bolt.fill"
                    )
                    statCard(
                        "+\(stats.lifetimeTilesGained)",
                        "Lifetime gained",
                        .green,
                        "chart.line.uptrend.xyaxis"
                    )
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func rankCard(rank: Int?, tiles: Int, drivers: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(rank.map(ordinal) ?? "—")
                .font(.system(size: 38, weight: .bold, design: .rounded))
                .foregroundStyle(.blue)
            Spacer(minLength: 0)
            Text("\(tiles) tiles")
                .font(.subheadline.weight(.semibold).monospacedDigit())
            Text("of \(drivers) drivers")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(width: 132, height: 116, alignment: .leading)
        .padding(14)
        .modifier(CardBackground())
    }

    private func statCard(_ value: String, _ label: String, _ tint: Color, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint)
            Spacer(minLength: 0)
            Text(value)
                .font(.title2.weight(.bold).monospacedDigit())
                .foregroundStyle(tint)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(width: 116, height: 116, alignment: .leading)
        .padding(14)
        .modifier(CardBackground())
    }

    // MARK: past drives carousel

    private var pastDrivesSection: some View {
        let drives = store.driveHistory()

        return VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Past Drives") {
                DriveHistoryView(store: store, embedded: true)
            }
            if drives.isEmpty {
                emptyDrives
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(drives.prefix(10)) { record in
                            Button { selectedDrive = record } label: { driveCard(record) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
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
    }

    private func driveCard(_ record: DriveRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "flag.checkered")
                    .foregroundStyle(.blue)
                Spacer()
                if let summary = record.summary {
                    Text("\(summary.tilesDriven)")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.blue)
                }
            }
            Spacer(minLength: 0)
            Text(record.startedAt, format: .dateTime.month().day().hour().minute())
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Text(driveSubtitle(record))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 156, height: 116, alignment: .leading)
        .padding(14)
        .modifier(CardBackground())
    }

    private var emptyDrives: some View {
        HStack(spacing: 10) {
            Image(systemName: "road.lanes")
                .foregroundStyle(.secondary)
            Text("No drives yet, start one to claim territory.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 10)
    }

    // MARK: header

    private func sectionHeader<Destination: View>(
        _ title: String,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink { destination() } label: {
            HStack(spacing: 4) {
                Text(title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: derived data

    private func empireStats() -> EmpireStats {
        let drives = store.driveHistory()
        return EmpireStats.compute(
            tiles: Array(store.tiles.values),
            ownedBy: store.localPlayer.id,
            driveSummaries: drives.compactMap(\.summary)
        )
    }

    private var contestedText: String {
        guard let owner = tracker.contestedOwnerName else { return "—" }
        if owner == "Unclaimed" { return "open tile" }
        if let score = tracker.contestedScore {
            return String(format: "vs %@ %.1f", owner, score)
        }
        return "vs \(owner)"
    }

    private var distanceText: String {
        String(format: "%.1f mi", tracker.driveDistanceMeters / 1609.344)
    }

    private func elapsedText(asOf now: Date) -> String {
        guard let start = tracker.currentDrive?.startedAt else { return "0:00" }
        let total = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func driveSubtitle(_ record: DriveRecord) -> String {
        guard let summary = record.summary else { return "—" }
        var parts: [String] = []
        let miles = summary.distanceMeters / 1609.344
        if miles > 0 { parts.append(String(format: "%.1f mi", miles)) }
        if summary.totalCaptured > 0 { parts.append("\(summary.totalCaptured) captured") }
        if summary.tilesEnclosed > 0 { parts.append("\(summary.tilesEnclosed) enclosed") }
        if parts.isEmpty { parts.append("no tiles changed hands") }
        return parts.joined(separator: " · ")
    }

    private func ordinal(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}

/// soft card surface for the carousel tiles, readable over the sheet's material
private struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content.background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }
}
