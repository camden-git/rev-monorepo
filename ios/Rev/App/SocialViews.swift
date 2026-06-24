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
            VStack(spacing: 0) {
                Picker("Section", selection: $pane) {
                    ForEach(Pane.allCases) { option in
                        Text(label(for: option)).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 10)

                Divider()

                switch pane {
                case .feed:
                    ActivityFeedView(store: store, social: social, embedded: true)
                case .friends:
                    FollowListView(store: store, social: social, embedded: true)
                case .discover:
                    FindPeopleView(store: store, social: social, sync: sync, embedded: true)
                }
            }
            .navigationTitle("Social")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
        }
        .onAppear { pane = initialPane }
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
                        PlayerProfileView(
                            store: store,
                            social: social,
                            userId: item.userID,
                            fallbackName: item.displayName,
                            fallbackColor: item.color
                        )
                    } label: {
                        ActivityRow(
                            colorHex: item.color,
                            name: item.displayName,
                            startedAt: item.startedAt,
                            durationSeconds: item.durationSeconds,
                            tiles: item.tiles,
                            showName: true
                        )
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
            Text("Follow other drivers to see their drives roll in here.")
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
