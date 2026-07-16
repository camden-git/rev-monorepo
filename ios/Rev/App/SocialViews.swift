import RevKit
import SwiftUI

struct SocialHubView: View {
    let store: TerritoryStore
    let social: SocialService
    let sync: SyncService
    var initialPane: Pane = .feed
    var onDone: () -> Void = {}

    enum Pane: String, CaseIterable, Identifiable {
        case feed = "Feed"
        case friends = "Friends"
        case discover = "Discover"
        var id: String { rawValue }
    }

    @State private var pane: Pane = .feed

    var body: some View {
        NavigationStack {
            content
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Picker("Section", selection: $pane) {
                            ForEach(Pane.allCases) { option in
                                Text(label(for: option)).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(minWidth: 240)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: onDone)
                    }
                }
        }
        .onAppear { pane = initialPane }
    }

    @ViewBuilder
    private var content: some View {
        switch pane {
        case .feed:
            ActivityFeedView(store: store, social: social, embedded: true)
        case .friends:
            FollowListView(store: store, social: social, embedded: true)
        case .discover:
            FindPeopleView(store: store, social: social, sync: sync, embedded: true)
        }
    }

    private func label(for pane: Pane) -> String {
        if pane == .friends, social.incomingRequestCount > 0 {
            return "Friends (\(social.incomingRequestCount))"
        }
        return pane.rawValue
    }
}

/// the following feed: recent drives from people the player follows
struct ActivityFeedView: View {
    let store: TerritoryStore
    let social: SocialService
    var embedded = false
    var onDone: () -> Void = {}

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
            if social.feed.isEmpty {
                Section {
                    emptyState
                }
            } else {
                ForEach(social.feed) { item in
                    NavigationLink {
                        FeedEventDetailView(store: store, social: social, event: item)
                    } label: {
                        FeedEventRow(event: item)
                    }
                }
            }
        }
        .navigationTitle("Activity")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await social.loadFeed() }
        .task { await social.loadFeed() }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "figure.wave")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No activity yet")
                .font(.headline)
            Text("Follow other drivers to see their drives, captures, records, and milestones roll in here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

/// followers, following, and incoming follow requests
struct FollowListView: View {
    let store: TerritoryStore
    let social: SocialService
    var initialTab: Tab = .following
    var embedded = false
    var onDone: () -> Void = {}

    enum Tab: String, CaseIterable, Identifiable {
        case following = "Following"
        case followers = "Followers"
        case requests = "Requests"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .following

    var body: some View {
        Group {
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
        .onAppear { tab = initialTab }
    }

    private var list: some View {
        List {
            Section {
                Picker("List", selection: $tab) {
                    ForEach(Tab.allCases) { option in
                        Text(label(for: option)).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
                .listRowBackground(Color.clear)
            }

            switch tab {
            case .following: edgeRows(social.following, empty: "You are not following anyone yet.")
            case .followers: edgeRows(social.followers, empty: "No followers yet.")
            case .requests: requestRows
            }
        }
        .navigationTitle("Friends")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await social.loadFollows() }
        .task { await social.loadFollows() }
    }

    private func label(for tab: Tab) -> String {
        if tab == .requests, social.incomingRequestCount > 0 {
            return "Requests (\(social.incomingRequestCount))"
        }
        return tab.rawValue
    }

    @ViewBuilder
    private func edgeRows(_ edges: [FollowEdge], empty: String) -> some View {
        if edges.isEmpty {
            Section { Text(empty).foregroundStyle(.secondary) }
        } else {
            Section {
                ForEach(edges) { edge in
                    NavigationLink {
                        PlayerProfileView(
                            store: store,
                            social: social,
                            userId: edge.otherId,
                            fallbackName: edge.displayName,
                            fallbackColor: edge.colorHex
                        )
                    } label: {
                        playerRow(edge)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var requestRows: some View {
        if social.incomingRequests.isEmpty {
            Section { Text("No pending requests.").foregroundStyle(.secondary) }
        } else {
            Section {
                ForEach(social.incomingRequests) { edge in
                    HStack(spacing: 12) {
                        playerRow(edge)
                        Spacer(minLength: 4)
                        Button {
                            Task { await social.accept(edge.id) }
                        } label: {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.blue)
                        }
                        .buttonStyle(.plain)
                        Button {
                            Task { await social.decline(edge.id) }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func playerRow(_ edge: FollowEdge) -> some View {
        HStack(spacing: 12) {
            PlayerAvatar(colorHex: edge.colorHex, name: edge.displayName, size: 38)
            Text(edge.displayName)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
        }
    }
}

/// search the synced roster to find players to follow
struct FindPeopleView: View {
    let store: TerritoryStore
    let social: SocialService
    let sync: SyncService
    var embedded = false
    var onDone: () -> Void = {}

    @State private var query = ""

    var body: some View {
        Group {
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
    }

    private var list: some View {
        List {
            if matches.isEmpty {
                Section {
                    Text(query.isEmpty ? "Search for other drivers by name." : "No players match \"\(query)\".")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(matches, id: \.id) { player in
                    NavigationLink {
                        PlayerProfileView(
                            store: store,
                            social: social,
                            userId: player.id,
                            fallbackName: player.displayName,
                            fallbackColor: player.colorHex
                        )
                    } label: {
                        HStack(spacing: 12) {
                            PlayerAvatar(colorHex: player.colorHex, name: player.displayName, size: 38)
                            Text(player.displayName)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .navigationTitle("Find People")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Name")
        .task { await sync.syncRoster() }
    }

    private var matches: [Player] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let roster = store.players.filter { !$0.isLocal && $0.id != store.localPlayer.id }
        let pool = trimmed.isEmpty
            ? roster
            : roster.filter { $0.displayName.localizedCaseInsensitiveContains(trimmed) }
        return pool.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
}

/// one heterogeneous moment in the following feed
struct FeedEventRow: View {
    let event: FeedEventDTO

    var body: some View {
        let p = FeedEventPresentation(event)
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                PlayerAvatar(colorHex: event.color, name: event.displayName, size: 38)
                Image(systemName: p.glyph)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(p.tint, in: Circle())
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 1.5))
                    .offset(x: 4, y: 4)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(event.displayName.isEmpty ? "Player" : event.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(p.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(event.occurredAt, format: .dateTime.weekday().month().day().hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            if let metric = p.metric {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(metric.value)
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(p.tint)
                    if !metric.unit.isEmpty {
                        Text(metric.unit)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// shared glyph/tint/copy for one feed moment, used by the row and its detail view
struct FeedEventPresentation {
    let glyph: String
    let tint: Color
    let message: String
    let metric: (value: String, unit: String)?

    init(_ e: FeedEventDTO) {
        switch e.type {
        case .drive:
            glyph = "flag.checkered"
            tint = Color(hex: e.color)
            let tiles = Int(e.value)
            message = e.prevValue > 0 ? "Drove for \(SocialFormat.duration(e.prevValue))" : "Completed a drive"
            metric = (String(tiles), Self.hexes(tiles))
        case .capture:
            glyph = "bolt.fill"
            tint = .orange
            let n = Int(e.value)
            let who = e.subjectName.isEmpty ? "a rival" : e.subjectName
            message = "Captured \(n) \(Self.hexes(n)) from \(who)"
            metric = (String(n), "taken")
        case .pr:
            glyph = DrivePRKind(rawValue: e.subtype)?.systemImage ?? "rosette"
            tint = .yellow
            message = "New record · \(DrivePRKind(rawValue: e.subtype)?.title ?? "Personal best")"
            metric = Self.prMetric(e)
        case .rankUp:
            glyph = "chart.line.uptrend.xyaxis"
            tint = .green
            let rank = Int(e.value)
            message = e.prevValue > 0 ? "Climbed to #\(rank) (from #\(Int(e.prevValue)))" : "Climbed to #\(rank)"
            metric = ("#\(rank)", "rank")
        case .streak:
            glyph = "flame.fill"
            tint = .red
            let days = Int(e.value)
            message = "\(days)-day driving streak!"
            metric = (String(days), "days")
        case .achievement:
            glyph = "trophy.fill"
            tint = .purple
            message = Self.achievementMessage(e)
            metric = nil
        case .unknown:
            glyph = "sparkles"
            tint = .secondary
            message = "New activity"
            metric = nil
        }
    }

    private static func hexes(_ n: Int) -> String { n == 1 ? "hex" : "hexes" }

    private static func prMetric(_ e: FeedEventDTO) -> (value: String, unit: String)? {
        switch DrivePRKind(rawValue: e.subtype) {
        case .distance:
            return (String(format: "%.1f", e.value / 1609.344), "mi")
        case .duration:
            return (SocialFormat.duration(e.value), "")
        case .tilesDriven, .tilesGained, .tilesCaptured:
            return (String(Int(e.value)), "hexes")
        case .none:
            return nil
        }
    }

    private static func achievementMessage(_ e: FeedEventDTO) -> String {
        switch e.subtype {
        case "first_drive": return "Unlocked: First drive"
        case "first_capture": return "Unlocked: First capture"
        case "tiles_held": return "Empire reached \(Int(e.value)) tiles"
        default: return "Achievement unlocked"
        }
    }
}
