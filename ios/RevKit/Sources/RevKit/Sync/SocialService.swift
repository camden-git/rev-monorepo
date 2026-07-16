import Foundation
import Observation

/// a follow edge flattened for display: the other player plus the edge's state
public struct FollowEdge: Identifiable, Sendable, Equatable {
    /// the `follows` record id
    public let id: String
    public let otherId: String
    public let displayName: String
    public let colorHex: String
    public let homeH3: UInt64
    public let status: String
}

/// the social graph and following feed for the signed-in player
@MainActor
@Observable
public final class SocialService {
    private let client: PocketBaseClient

    public private(set) var viewerId: String?
    public private(set) var following: [FollowEdge] = []
    public private(set) var followers: [FollowEdge] = []
    public private(set) var incomingRequests: [FollowEdge] = []
    public private(set) var outgoingRequests: [FollowEdge] = []
    public private(set) var feed: [FeedEventDTO] = []
    public private(set) var lastError: String?

    public init(client: PocketBaseClient) {
        self.client = client
    }

    public var incomingRequestCount: Int { incomingRequests.count }
    public var followingCount: Int { following.count }
    public var followerCount: Int { followers.count }

    /// pull the graph and feed for the given signed-in user
    public func refresh(viewerId: String) async {
        self.viewerId = viewerId
        await loadFollows()
        await loadFeed()
    }

    public func clear() {
        viewerId = nil
        following = []
        followers = []
        incomingRequests = []
        outgoingRequests = []
        feed = []
        lastError = nil
    }

    public func loadFollows() async {
        guard let viewerId else { return }
        do {
            let edges = try await client.listFollows()
            var following: [FollowEdge] = []
            var followers: [FollowEdge] = []
            var incoming: [FollowEdge] = []
            var outgoing: [FollowEdge] = []
            for record in edges {
                let iAmFollower = record.follower == viewerId
                let other = iAmFollower ? record.expand?.followee : record.expand?.follower
                let edge = FollowEdge(
                    id: record.id,
                    otherId: iAmFollower ? record.followee : record.follower,
                    displayName: other?.displayName.isEmpty == false ? other!.displayName : "Player",
                    colorHex: other?.color.isEmpty == false ? other!.color : "#888888",
                    homeH3: other?.homeH3 ?? 0,
                    status: record.status
                )
                switch (iAmFollower, record.status) {
                case (true, "accepted"): following.append(edge)
                case (true, _): outgoing.append(edge)
                case (false, "accepted"): followers.append(edge)
                default: incoming.append(edge)
                }
            }
            self.following = following.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            self.followers = followers.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            self.incomingRequests = incoming
            self.outgoingRequests = outgoing
            lastError = nil
        } catch {
            lastError = Self.message(for: error)
        }
    }

    public func loadFeed() async {
        do {
            feed = try await client.fetchFeed()
            lastError = nil
        } catch {
            lastError = Self.message(for: error)
        }
    }

    public func profile(_ userId: String) async -> ProfileDTO? {
        do {
            return try await client.fetchProfile(userId: userId)
        } catch {
            lastError = Self.message(for: error)
            return nil
        }
    }

    public func stats(_ userId: String) async -> [EmpireSnapshotDTO] {
        do {
            return try await client.fetchStats(userId: userId)
        } catch {
            lastError = Self.message(for: error)
            return []
        }
    }

    public func driveDetail(_ driveId: String) async -> DriveDetailDTO? {
        do {
            return try await client.fetchDrive(driveId: driveId)
        } catch {
            lastError = Self.message(for: error)
            return nil
        }
    }

    public func prHistory(_ userId: String, kind: String) async -> [PRPointDTO] {
        do {
            return try await client.fetchPRHistory(userId: userId, kind: kind)
        } catch {
            lastError = Self.message(for: error)
            return []
        }
    }

    /// returns the resulting state so the calling view can update its button
    /// without a full round trip
    @discardableResult
    public func follow(_ targetId: String) async -> FollowState? {
        guard let viewerId else { return nil }
        do {
            let record = try await client.createFollow(followerId: viewerId, followeeId: targetId)
            await loadFollows()
            return FollowState(rawValue: record.status) ?? .pending
        } catch {
            lastError = Self.message(for: error)
            return nil
        }
    }

    public func unfollow(_ targetId: String) async {
        guard let edgeId = edgeId(toward: targetId) else { return }
        await drop(edgeId)
    }

    public func accept(_ requestId: String) async {
        do {
            try await client.acceptFollow(edgeId: requestId)
            await loadFollows()
            await loadFeed()
            lastError = nil
        } catch {
            lastError = Self.message(for: error)
        }
    }

    public func decline(_ requestId: String) async {
        await drop(requestId)
    }

    public func removeFollower(_ edgeId: String) async {
        await drop(edgeId)
    }

    /// the edge id for an outbound follow toward `targetId`, if one exists
    public func edgeId(toward targetId: String) -> String? {
        (following + outgoingRequests).first { $0.otherId == targetId }?.id
    }

    private func drop(_ edgeId: String) async {
        do {
            try await client.removeFollow(edgeId: edgeId)
            await loadFollows()
            lastError = nil
        } catch {
            lastError = Self.message(for: error)
        }
    }

    private static func message(for error: Error) -> String {
        if let pbError = error as? PocketBaseError, case let .http(_, body) = pbError,
           let data = body.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = object["message"] as? String, !message.isEmpty {
            return message
        }
        return "Something went wrong. Try again."
    }
}
