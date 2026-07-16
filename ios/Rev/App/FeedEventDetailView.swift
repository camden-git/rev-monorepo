import Charts
import MapKit
import RevKit
import SwiftUI

/// per-type detail for one feed moment, pushed from the activity feed
struct FeedEventDetailView: View {
    let store: TerritoryStore
    let social: SocialService
    let event: FeedEventDTO

    @State private var drive: DriveDetailDTO?
    @State private var profile: ProfileDTO?
    @State private var statPoints: [EmpireSnapshotDTO] = []
    @State private var prPoints: [PRPointDTO] = []
    @State private var isLoading = true

    var body: some View {
        List {
            heroSection

            switch event.type {
            case .drive:
                driveSections
            case .capture:
                clashSection
                driveSections
            case .pr:
                prSections
                driveSections
            case .rankUp:
                rankSections
            case .streak:
                streakSections
            case .achievement:
                achievementSections
            case .unknown:
                EmptyView()
            }

            playersSection
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: event.id) { await load() }
    }

    private var title: String {
        switch event.type {
        case .drive: return "Drive"
        case .capture: return "Capture"
        case .pr: return "Personal Record"
        case .rankUp: return "Rank Up"
        case .streak: return "Streak"
        case .achievement: return "Achievement"
        case .unknown: return "Activity"
        }
    }

    // MARK: hero

    private var heroSection: some View {
        let p = FeedEventPresentation(event)
        return Section {
            VStack(spacing: 12) {
                Image(systemName: p.glyph)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 76, height: 76)
                    .background(p.tint.gradient, in: Circle())
                VStack(spacing: 4) {
                    Text(p.message)
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                    Text(event.occurredAt, format: .dateTime.weekday().month().day().hour().minute())
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    // MARK: drive

    @ViewBuilder
    private var driveSections: some View {
        if let drive {
            if drive.path.count > 1 || !drive.tileScores.isEmpty {
                Section {
                    DriveRouteMap(path: drive.path, tiles: drive.tileScores, colorHex: event.color)
                        .listRowInsets(EdgeInsets())
                } footer: {
                    if !drive.tileScores.isEmpty {
                        Text("Hexes shade from cool to hot by driven speed.")
                    }
                }
            }
            Section("Drive Stats") {
                statGrid(for: drive)
            }
            if let fastest = drive.tileScores.max(by: { $0.mph < $1.mph }), fastest.mph > 0 {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "flame.fill")
                            .font(.title3)
                            .foregroundStyle(.orange)
                            .frame(width: 38)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Fastest hex")
                                .font(.subheadline.weight(.medium))
                            Text("Top speed scored on a single tile this drive")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Text("\(Int(fastest.mph)) mph")
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(.orange)
                    }
                }
            }
        } else if hasDrive, isLoading {
            Section {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .padding(.vertical, 12)
            }
        }
    }

    private func statGrid(for drive: DriveDetailDTO) -> some View {
        let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
        let avgMph = drive.durationSeconds > 0 ? drive.distanceMeters / drive.durationSeconds * 2.2369 : 0
        return LazyVGrid(columns: columns, spacing: 16) {
            statCell("\(drive.tiles)", "Hexes driven", "hexagon.fill", .blue)
            statCell("\(drive.tilesGained)", "Gained", "flag.fill", .teal)
            statCell("\(drive.tilesCaptured)", "Captured", "bolt.fill", .red)
            statCell(String(format: "%.1f mi", drive.distanceMeters / 1609.344), "Distance", "map.fill", .green)
            statCell(SocialFormat.duration(drive.durationSeconds), "Duration", "clock.fill", .orange)
            statCell(avgMph > 0 ? "\(Int(avgMph)) mph" : "—", "Avg speed", "gauge.with.needle", .purple)
        }
        .padding(.vertical, 8)
    }

    private func statCell(_ value: String, _ label: String, _ symbol: String, _ tint: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(tint)
            Text(value)
                .font(.subheadline.weight(.bold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: capture

    private var clashSection: some View {
        Section {
            HStack(spacing: 16) {
                clashPlayer(name: event.displayName, colorHex: event.color, label: "Attacker")
                VStack(spacing: 2) {
                    Image(systemName: "bolt.fill")
                        .font(.title3)
                        .foregroundStyle(.orange)
                    Text("\(Int(event.value))")
                        .font(.title2.weight(.bold).monospacedDigit())
                    Text(Int(event.value) == 1 ? "hex taken" : "hexes taken")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                clashPlayer(
                    name: event.subjectName.isEmpty ? "Rival" : event.subjectName,
                    colorHex: subjectColorHex,
                    label: "Defender"
                )
            }
            .padding(.vertical, 8)
        }
    }

    private func clashPlayer(name: String, colorHex: String, label: String) -> some View {
        VStack(spacing: 6) {
            PlayerAvatar(colorHex: colorHex, name: name, size: 52)
            Text(name)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    /// the defender's real color when they're in the local roster
    private var subjectColorHex: String {
        store.players.first { $0.id == event.subjectID }?.colorHex ?? "#888888"
    }

    // MARK: pr

    @ViewBuilder
    private var prSections: some View {
        if let kind = DrivePRKind(rawValue: event.subtype) {
            Section("Record") {
                HStack(spacing: 12) {
                    Image(systemName: kind.systemImage)
                        .font(.title3)
                        .foregroundStyle(.yellow)
                        .frame(width: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(kind.title)
                            .font(.subheadline.weight(.medium))
                        Text(previousBestCaption(kind))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text(prValueText(kind, event.value))
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.yellow)
                }
            }

            if prPoints.count >= 2 {
                Section {
                    Chart {
                        ForEach(prPoints) { point in
                            LineMark(
                                x: .value("Date", point.occurredAt),
                                y: .value("Record", prChartValue(kind, point.value))
                            )
                            .foregroundStyle(.yellow)
                            .interpolationMethod(.stepEnd)
                            PointMark(
                                x: .value("Date", point.occurredAt),
                                y: .value("Record", prChartValue(kind, point.value))
                            )
                            .foregroundStyle(.yellow)
                        }
                    }
                    .chartYAxis { AxisMarks(position: .leading) }
                    .frame(height: 150)
                    .padding(.vertical, 6)
                } header: {
                    Label("Record Progression (\(prChartUnit(kind)))", systemImage: "chart.line.uptrend.xyaxis")
                        .foregroundStyle(.yellow)
                } footer: {
                    Text("Every time \(event.displayName.isEmpty ? "this player" : event.displayName) has raised this record.")
                }
            }
        }
    }

    /// the record this one beat
    private func previousBestCaption(_ kind: DrivePRKind) -> String {
        let prior = prPoints.filter { $0.occurredAt < event.occurredAt }.last
        guard let prior, prior.value > 0 else { return "First record in this category" }
        let improvement = (event.value - prior.value) / prior.value * 100
        let delta = improvement >= 1 ? String(format: " (+%.0f%%)", improvement) : ""
        return "Beat their previous best of \(prValueText(kind, prior.value))\(delta)"
    }

    private func prValueText(_ kind: DrivePRKind, _ value: Double) -> String {
        switch kind {
        case .distance: return String(format: "%.1f mi", value / 1609.344)
        case .duration: return SocialFormat.duration(value)
        case .tilesDriven, .tilesGained, .tilesCaptured: return "\(Int(value)) hexes"
        }
    }

    private func prChartValue(_ kind: DrivePRKind, _ value: Double) -> Double {
        switch kind {
        case .distance: return value / 1609.344
        case .duration: return value / 60
        case .tilesDriven, .tilesGained, .tilesCaptured: return value
        }
    }

    private func prChartUnit(_ kind: DrivePRKind) -> String {
        switch kind {
        case .distance: return "miles"
        case .duration: return "minutes"
        case .tilesDriven, .tilesGained, .tilesCaptured: return "hexes"
        }
    }

    // MARK: rank

    @ViewBuilder
    private var rankSections: some View {
        Section {
            HStack(spacing: 20) {
                rankBadge(Int(event.prevValue), label: "Was", tint: .secondary)
                Image(systemName: "arrow.right")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.green)
                rankBadge(Int(event.value), label: "Now", tint: .green)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }

        leaderboardNeighborhood

        let rankedPoints = statPoints.filter { $0.rank > 0 }
        if rankedPoints.count >= 2 {
            Section {
                Chart {
                    ForEach(Array(rankedPoints.enumerated()), id: \.offset) { _, point in
                        LineMark(
                            x: .value("Date", point.capturedAt),
                            y: .value("Rank", point.rank)
                        )
                        .foregroundStyle(.green)
                        .interpolationMethod(.monotone)
                        PointMark(
                            x: .value("Date", point.capturedAt),
                            y: .value("Rank", point.rank)
                        )
                        .foregroundStyle(.green)
                    }
                }
                .chartYScale(domain: [(rankedPoints.map(\.rank).max() ?? 1) + 1, 1])
                .chartYAxis { AxisMarks(position: .leading) }
                .frame(height: 150)
                .padding(.vertical, 6)
            } header: {
                Label("Rank Over Time", systemImage: "trophy.fill")
                    .foregroundStyle(.green)
            } footer: {
                Text("Lower is better. Rank 1 is the top of the leaderboard.")
            }
        }
    }

    /// the slice of the leaderboard around the climber. centered on their local
    /// board position (which can drift from the event's server rank) so they
    /// always appear in the window
    @ViewBuilder
    private var leaderboardNeighborhood: some View {
        let board = store.leaderboard()
        if let climberIndex = board.firstIndex(where: { $0.playerId == event.userID }) {
            let lower = max(0, climberIndex - 1)
            let upper = min(board.count - 1, climberIndex + 1)
            Section("The Board Today") {
                ForEach(lower...upper, id: \.self) { index in
                    leaderboardRow(rank: index + 1, entry: board[index])
                }
            }
        }
    }

    private func leaderboardRow(rank: Int, entry: TerritoryStore.LeaderboardEntry) -> some View {
        let isClimber = entry.playerId == event.userID
        return HStack(spacing: 12) {
            Text("#\(rank)")
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(isClimber ? .green : .secondary)
                .frame(width: 34, alignment: .leading)
            PlayerAvatar(colorHex: entry.colorHex, name: entry.displayName, size: 32)
            Text(entry.displayName)
                .font(.subheadline.weight(isClimber ? .semibold : .regular))
                .lineLimit(1)
            if isClimber {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.green)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(String(format: "%.0f", entry.empireStrength))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                Text("strength")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .listRowBackground(isClimber ? Color.green.opacity(0.08) : nil)
    }

    private func rankBadge(_ rank: Int, label: String, tint: Color) -> some View {
        VStack(spacing: 4) {
            Text(rank > 0 ? ordinal(rank) : "—")
                .font(.title.weight(.bold).monospacedDigit())
                .foregroundStyle(tint)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: streak

    @ViewBuilder
    private var streakSections: some View {
        Section {
            drivingCalendar
        } header: {
            Label("Last 4 Weeks", systemImage: "calendar")
                .foregroundStyle(.red)
        } footer: {
            Text("Days \(event.displayName.isEmpty ? "this player" : event.displayName) drove, from their recent drives.")
        }

        if let next = DriveStreakMilestones.next(after: Int(event.value)) {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("\(Int(event.value)) days")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.red)
                        Spacer()
                        Text("next: \(next)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: Double(Int(event.value)), total: Double(next))
                        .tint(.red)
                }
                .padding(.vertical, 6)
            } header: {
                Label("Next Milestone", systemImage: "flame.fill")
                    .foregroundStyle(.red)
            }
        }
    }

    /// 4-week dot grid of driving days from the player's recent drives. the profile
    /// only carries the last 20, so days before the oldest known drive show as
    /// unknown rather than falsely empty
    private var drivingCalendar: some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let drives = profile?.recentDrives ?? []
        let drivenDays = Set(drives.map { calendar.startOfDay(for: $0.startedAt) })
        // when the 20-drive cap is hit, anything before the oldest fetched drive
        // is unknowable, not rest
        let knownSince = drives.count >= 20 ? drivenDays.min() : nil
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)
        return LazyVGrid(columns: columns, spacing: 6) {
            ForEach(0..<28, id: \.self) { offset in
                let day = calendar.date(byAdding: .day, value: offset - 27, to: today) ?? today
                let drove = drivenDays.contains(day)
                let unknown = !drove && knownSince.map { day < $0 } == true
                VStack(spacing: 3) {
                    Circle()
                        .fill(drove ? Color.red : Color(.quaternarySystemFill))
                        .frame(width: 22, height: 22)
                        .opacity(unknown ? 0.25 : 1)
                        .overlay {
                            if drove {
                                Image(systemName: "car.fill")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                    Text(day, format: .dateTime.day())
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: achievement

    @ViewBuilder
    private var achievementSections: some View {
        if event.subtype == "tiles_held" {
            empireMilestoneSections
        } else {
            driveSections
        }
    }

    @ViewBuilder
    private var empireMilestoneSections: some View {
        if let profile {
            Section("Empire Today") {
                HStack(spacing: 0) {
                    tintedStat("\(profile.tilesHeld)", "Hexes", .blue)
                    statDivider
                    tintedStat(String(format: "%.0f", profile.strength), "Strength", .orange)
                    statDivider
                    tintedStat(profile.rank > 0 ? ordinal(profile.rank) : "—", "Rank", .green)
                }
                .padding(.vertical, 6)
            }

            if let next = EmpireMilestones.next(after: Int(event.value)) {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("\(profile.tilesHeld) hexes held")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.purple)
                            Spacer()
                            Text("next: \(next)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: Double(min(profile.tilesHeld, next)), total: Double(next))
                            .tint(.purple)
                    }
                    .padding(.vertical, 6)
                } header: {
                    Label("Next Milestone", systemImage: "trophy.fill")
                        .foregroundStyle(.purple)
                }
            }
        }
        Section {
            NavigationLink {
                EmpireStatsView(social: social, userId: event.userID, title: event.displayName, embedded: true)
            } label: {
                Label("Empire Over Time", systemImage: "chart.xyaxis.line")
            }
        }
    }

    private func tintedStat(_ value: String, _ label: String, _ tint: Color) -> some View {
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

    private var statDivider: some View {
        Rectangle().fill(.quaternary).frame(width: 1, height: 28)
    }

    // MARK: players

    private var playersSection: some View {
        Section {
            NavigationLink {
                PlayerProfileView(
                    store: store,
                    social: social,
                    userId: event.userID,
                    fallbackName: event.displayName,
                    fallbackColor: event.color
                )
            } label: {
                playerRow(name: event.displayName, colorHex: event.color)
            }
            if event.type == .capture, !event.subjectID.isEmpty {
                NavigationLink {
                    PlayerProfileView(
                        store: store,
                        social: social,
                        userId: event.subjectID,
                        fallbackName: event.subjectName,
                        fallbackColor: subjectColorHex
                    )
                } label: {
                    playerRow(name: event.subjectName.isEmpty ? "Rival" : event.subjectName, colorHex: subjectColorHex)
                }
            }
        }
    }

    private func playerRow(name: String, colorHex: String) -> some View {
        HStack(spacing: 12) {
            PlayerAvatar(colorHex: colorHex, name: name.isEmpty ? "?" : name, size: 38)
            Text(name.isEmpty ? "Player" : name)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
        }
    }

    // MARK: data

    private var hasDrive: Bool { !event.driveID.isEmpty }

    private func load() async {
        isLoading = true
        if hasDrive {
            drive = await social.driveDetail(event.driveID)
        }
        switch event.type {
        case .rankUp:
            statPoints = await social.stats(event.userID)
        case .pr:
            prPoints = await social.prHistory(event.userID, kind: event.subtype)
        case .streak:
            profile = await social.profile(event.userID)
        case .achievement where event.subtype == "tiles_held":
            profile = await social.profile(event.userID)
        default:
            break
        }
        isLoading = false
    }
}

/// streak milestone ladder, mirrored from the server's feed emitter
enum DriveStreakMilestones {
    static let ladder = [3, 7, 14, 30, 60, 100, 200, 365]

    static func next(after days: Int) -> Int? {
        ladder.first { $0 > days }
    }
}

/// tiles-held milestone ladder, mirrored from the server's snapshot writer
enum EmpireMilestones {
    static let ladder = [10, 25, 50, 100, 250, 500, 1000, 2500]

    static func next(after tiles: Int) -> Int? {
        ladder.first { $0 > tiles }
    }
}

/// a non-interactive preview of a drive
private struct DriveRouteMap: View {
    let path: [DriveDetailDTO.PathPoint]
    let tiles: [DriveDetailDTO.TileScore]
    let colorHex: String

    /// most hexes a single map preview will draw
    private static let maxHexOverlays = 250

    var body: some View {
        let coords = path.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng) }
        let sampled: [DriveDetailDTO.TileScore] = {
            guard tiles.count > Self.maxHexOverlays else { return tiles }
            let stride = Double(tiles.count) / Double(Self.maxHexOverlays)
            return (0..<Self.maxHexOverlays).map { tiles[Int(Double($0) * stride)] }
        }()
        let hexes = sampled.compactMap { tile -> (score: DriveDetailDTO.TileScore, loop: [CLLocationCoordinate2D])? in
            let loop = H3Grid.boundary(of: tile.h3)
            return loop.isEmpty ? nil : (tile, loop)
        }
        let framing = coords + hexes.flatMap(\.loop)
        if let region = H3Grid.region(coveringCoordinates: framing, paddingFraction: 0.4) {
            let maxMph = max(tiles.map(\.mph).max() ?? 0, 1)
            Map(initialPosition: .region(region), interactionModes: []) {
                ForEach(hexes, id: \.score.id) { hex in
                    MapPolygon(coordinates: hex.loop)
                        .foregroundStyle(Color(hex: colorHex).opacity(0.15 + 0.45 * (hex.score.mph / maxMph)))
                        .stroke(Color(hex: colorHex).opacity(0.6), lineWidth: 1)
                }
                if coords.count > 1 {
                    MapPolyline(coordinates: coords)
                        .stroke(
                            Color(hex: colorHex),
                            style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
                        )
                }
                if let start = coords.first {
                    Annotation("", coordinate: start) {
                        Circle()
                            .fill(.white)
                            .stroke(Color(hex: colorHex), lineWidth: 3)
                            .frame(width: 12, height: 12)
                    }
                }
                if let end = coords.last, coords.count > 1 {
                    Annotation("", coordinate: end) {
                        Image(systemName: "flag.checkered.circle.fill")
                            .font(.title3)
                            .foregroundStyle(Color(hex: colorHex), .white)
                    }
                }
            }
            .frame(height: 240)
            .allowsHitTesting(false)
        }
    }
}
