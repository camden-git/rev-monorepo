import Foundation

/// the viewer's relationship to a profile they are looking at
public enum FollowState: String, Sendable, Equatable {
    case none
    case pending
    case accepted
}

/// `GET /api/rev/profile/{userId}`: the card for one player
public struct ProfileDTO: Decodable, Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let color: String
    public let homeH3: UInt64
    public let isPrivate: Bool
    public let isSelf: Bool
    public let tilesHeld: Int
    public let strength: Double
    public let score: Double
    public let rank: Int
    public let driveCount: Int
    public let followerCount: Int
    public let followingCount: Int
    public let followState: FollowState
    public let followsYou: Bool
    public let canViewDetails: Bool
    public let recentDrives: [DriveBriefDTO]

    enum CodingKeys: String, CodingKey {
        case id, color, strength, score, rank
        case displayName = "display_name"
        case homeH3 = "home_h3"
        case isPrivate = "is_private"
        case isSelf = "is_self"
        case tilesHeld = "tiles_held"
        case driveCount = "drive_count"
        case followerCount = "follower_count"
        case followingCount = "following_count"
        case followState = "follow_state"
        case followsYou = "follows_you"
        case canViewDetails = "can_view_details"
        case recentDrives = "recent_drives"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? ""
        homeH3 = UInt64(try c.decodeIfPresent(String.self, forKey: .homeH3) ?? "0") ?? 0
        isPrivate = try c.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false
        isSelf = try c.decodeIfPresent(Bool.self, forKey: .isSelf) ?? false
        tilesHeld = try c.decodeIfPresent(Int.self, forKey: .tilesHeld) ?? 0
        strength = try c.decodeIfPresent(Double.self, forKey: .strength) ?? 0
        score = try c.decodeIfPresent(Double.self, forKey: .score) ?? 0
        rank = try c.decodeIfPresent(Int.self, forKey: .rank) ?? 0
        driveCount = try c.decodeIfPresent(Int.self, forKey: .driveCount) ?? 0
        followerCount = try c.decodeIfPresent(Int.self, forKey: .followerCount) ?? 0
        followingCount = try c.decodeIfPresent(Int.self, forKey: .followingCount) ?? 0
        followState = FollowState(rawValue: try c.decodeIfPresent(String.self, forKey: .followState) ?? "none") ?? .none
        followsYou = try c.decodeIfPresent(Bool.self, forKey: .followsYou) ?? false
        canViewDetails = try c.decodeIfPresent(Bool.self, forKey: .canViewDetails) ?? false
        recentDrives = try c.decodeIfPresent([DriveBriefDTO].self, forKey: .recentDrives) ?? []
    }
}

/// a lightweight activity row used by profiles and the feed
public struct DriveBriefDTO: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let startedAt: Date
    public let durationSeconds: Double
    public let tiles: Int

    enum CodingKeys: String, CodingKey {
        case id
        case startedAt = "started_at"
        case durationSeconds = "duration_seconds"
        case tiles
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        startedAt = SocialDate.parse(try c.decodeIfPresent(String.self, forKey: .startedAt))
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? 0
        tiles = try c.decodeIfPresent(Int.self, forKey: .tiles) ?? 0
    }
}

/// one entry in the following feed (`GET /api/rev/feed`)
public struct FeedItemDTO: Decodable, Sendable, Equatable, Identifiable {
    public let driveID: String
    public let userID: String
    public let displayName: String
    public let color: String
    public let startedAt: Date
    public let durationSeconds: Double
    public let tiles: Int

    public var id: String { driveID }

    enum CodingKeys: String, CodingKey {
        case driveID = "drive_id"
        case userID = "user_id"
        case displayName = "display_name"
        case color
        case startedAt = "started_at"
        case durationSeconds = "duration_seconds"
        case tiles
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        driveID = try c.decode(String.self, forKey: .driveID)
        userID = try c.decodeIfPresent(String.self, forKey: .userID) ?? ""
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? ""
        startedAt = SocialDate.parse(try c.decodeIfPresent(String.self, forKey: .startedAt))
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? 0
        tiles = try c.decodeIfPresent(Int.self, forKey: .tiles) ?? 0
    }
}

struct FeedResponse: Decodable, Sendable {
    let items: [FeedItemDTO]
}

/// tolerant parse of a PocketBase datetime string
enum SocialDate {
    static func parse(_ raw: String?) -> Date {
        guard let raw, !raw.isEmpty else { return .distantPast }
        return PocketBaseCoding.dateFormatter.date(from: raw) ?? .distantPast
    }
}

/// one point in a player's empire-over-time series
public struct EmpireSnapshotDTO: Decodable, Sendable, Equatable, Identifiable {
    public let capturedAt: Date
    public let tilesHeld: Int
    public let strength: Double
    public let score: Double
    public let rank: Int

    public var id: Date { capturedAt }

    enum CodingKeys: String, CodingKey {
        case capturedAt = "captured_at"
        case tilesHeld = "tiles_held"
        case strength, score, rank
    }
}

struct StatsResponse: Decodable, Sendable {
    let items: [EmpireSnapshotDTO]
}

/// a raw `follows` record with the relation endpoints expanded to the players
public struct FollowRecordDTO: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let follower: String
    public let followee: String
    public let status: String
    public let expand: Expand?

    public struct Expand: Decodable, Sendable, Equatable {
        public let follower: PlayerDTO?
        public let followee: PlayerDTO?
    }
}
