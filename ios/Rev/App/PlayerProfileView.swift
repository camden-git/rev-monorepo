import Charts
import RevKit
import SwiftUI

/// another player's profile: identity, empire standing, follow controls,
/// and their recent activity
struct PlayerProfileView: View {
    let store: TerritoryStore
    let social: SocialService
    let userId: String
    /// shown immediately while the full profile loads
    var fallbackName: String = ""
    var fallbackColor: String = "#888888"

    @State private var profile: ProfileDTO?
    @State private var followState: FollowState = .none
    @State private var isLoading = true
    @State private var isMutating = false
    @State private var confirmUnfollow = false

    var body: some View {
        List {
            Section { header }
                .listRowSeparator(.hidden)

            if let profile {
                Section { statStrip(profile).padding(.vertical, 4) }

                if profile.canViewDetails {
                    Section {
                        NavigationLink {
                            EmpireStatsView(social: social, userId: userId, title: profile.displayName, embedded: true)
                        } label: {
                            Label("Empire Over Time", systemImage: "chart.xyaxis.line")
                        }
                    }
                    activitySection(profile)
                } else {
                    Section {
                        privateNotice
                    }
                }
            } else if !isLoading {
                Section {
                    Text("Couldn't load this profile.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(profile?.displayName ?? (fallbackName.isEmpty ? "Profile" : fallbackName))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: userId) { await load() }
        .refreshable { await load() }
        .confirmationDialog("Unfollow \(displayName)?", isPresented: $confirmUnfollow, titleVisibility: .visible) {
            Button("Unfollow", role: .destructive) { Task { await unfollow() } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var displayName: String {
        profile?.displayName ?? fallbackName
    }

    private var header: some View {
        VStack(spacing: 14) {
            PlayerAvatar(colorHex: profile?.color ?? fallbackColor, name: displayName.isEmpty ? "?" : displayName, size: 84)

            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Text(displayName.isEmpty ? "Player" : displayName)
                        .font(.title2.weight(.bold))
                    if profile?.isPrivate == true {
                        Image(systemName: "lock.fill")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                if let profile, profile.rank > 0 {
                    Text(rankText(profile.rank))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if profile?.followsYou == true {
                    Text("Follows you")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                }
            }

            if let profile, !profile.isSelf {
                followButton
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var followButton: some View {
        let label = HStack(spacing: 6) {
            if isMutating {
                ProgressView()
            } else {
                Image(systemName: followSymbol)
            }
            Text(followLabel)
        }
        .font(.subheadline.weight(.semibold))
        .frame(maxWidth: .infinity)
        .frame(height: 34)

        Group {
            if followState == .none {
                Button { Task { await toggleFollow() } } label: { label }
                    .buttonStyle(.borderedProminent)
            } else {
                Button { Task { await toggleFollow() } } label: { label }
                    .buttonStyle(.bordered)
            }
        }
        .controlSize(.large)
        .buttonBorderShape(.capsule)
        .tint(.blue)
        .disabled(isMutating)
        .padding(.horizontal, 24)
    }

    private var followLabel: String {
        switch followState {
        case .none: return "Follow"
        case .pending: return "Requested"
        case .accepted: return "Following"
        }
    }

    private var followSymbol: String {
        switch followState {
        case .none: return "person.badge.plus"
        case .pending: return "clock"
        case .accepted: return "checkmark"
        }
    }

    private func statStrip(_ profile: ProfileDTO) -> some View {
        HStack(spacing: 0) {
            profileStat("\(profile.tilesHeld)", "Hexes")
            divider
            profileStat(String(format: "%.0f", profile.strength), "Strength")
            divider
            profileStat("\(profile.driveCount)", "Drives")
            divider
            profileStat("\(profile.followerCount)", "Followers")
        }
    }

    private func profileStat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var divider: some View {
        Rectangle()
            .fill(.quaternary)
            .frame(width: 1, height: 28)
    }

    @ViewBuilder
    private func activitySection(_ profile: ProfileDTO) -> some View {
        if profile.recentDrives.isEmpty {
            Section("Recent Activity") {
                Text("No drives yet.")
                    .foregroundStyle(.secondary)
            }
        } else {
            Section("Recent Activity") {
                ForEach(profile.recentDrives) { drive in
                    ActivityRow(
                        colorHex: profile.color,
                        name: profile.displayName,
                        startedAt: drive.startedAt,
                        durationSeconds: drive.durationSeconds,
                        tiles: drive.tiles
                    )
                }
            }
        }
    }

    private var privateNotice: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("This account is private")
                    .font(.subheadline.weight(.semibold))
                Text("Follow \(displayName) to see their drives and stats.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func rankText(_ rank: Int) -> String {
        "Global rank \(ordinal(rank))"
    }

    private func load() async {
        isLoading = true
        let fetched = await social.profile(userId)
        if let fetched {
            profile = fetched
            followState = fetched.followState
        }
        isLoading = false
    }

    private func toggleFollow() async {
        switch followState {
        case .accepted:
            confirmUnfollow = true
        case .pending:
            await unfollow()
        case .none:
            await follow()
        }
    }

    private func follow() async {
        isMutating = true
        if let result = await social.follow(userId) {
            followState = result
        }
        await load()
        isMutating = false
    }

    private func unfollow() async {
        isMutating = true
        await social.unfollow(userId)
        followState = .none
        await load()
        isMutating = false
    }
}

/// a single drive row shared by profiles and the activity feed
struct ActivityRow: View {
    let colorHex: String
    let name: String
    let startedAt: Date
    let durationSeconds: Double
    let tiles: Int
    var showName = false

    var body: some View {
        HStack(spacing: 12) {
            if showName {
                PlayerAvatar(colorHex: colorHex, name: name, size: 38)
            } else {
                Image(systemName: "flag.checkered")
                    .font(.title3)
                    .foregroundStyle(Color(hex: colorHex))
                    .frame(width: 38)
            }
            VStack(alignment: .leading, spacing: 2) {
                if showName {
                    Text(name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
                Text(startedAt, format: .dateTime.weekday().month().day().hour().minute())
                    .font(showName ? .caption : .subheadline.weight(.medium))
                    .foregroundStyle(showName ? .secondary : .primary)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(tiles)")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.blue)
                Text("hexes")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var subtitle: String {
        SocialFormat.duration(durationSeconds)
    }
}

enum SocialFormat {
    static func duration(_ seconds: Double) -> String {
        guard seconds > 0 else { return "in progress" }
        let total = Int(seconds)
        let minutes = total / 60
        if minutes < 60 {
            return "\(max(1, minutes)) min"
        }
        return String(format: "%dh %dm", minutes / 60, minutes % 60)
    }
}

func ordinal(_ n: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .ordinal
    return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
}
