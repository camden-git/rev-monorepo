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

/// the kind of activity moment in the following feed
public enum FeedEventType: String, Decodable, Sendable, Equatable {
    /// a completed drive: `value` = tiles driven, `prevValue` = duration seconds
    case drive
    /// territory taken from a rival: `value` = tiles taken, `subject*` = the displaced owner
    case capture
    /// a personal record: `subtype` = the record kind (see `DrivePRKind`), `value` = the record value
    case pr
    /// climbed the leaderboard: `value` = new rank, `prevValue` = old rank
    case rankUp = "rank_up"
    /// a consecutive-day streak milestone: `value` = streak length in days
    case streak
    /// an achievement unlock: `subtype` = the achievement id, `value` = its magnitude
    case achievement
    /// a type this build does not understand yet
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = FeedEventType(rawValue: raw) ?? .unknown
    }
}

/// one entry in the following feed (`GET /api/rev/feed`)
public struct FeedEventDTO: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let type: FeedEventType
    public let userID: String
    public let displayName: String
    public let color: String
    public let occurredAt: Date
    public let subtype: String
    public let value: Double
    public let prevValue: Double
    public let driveID: String
    public let subjectID: String
    public let subjectName: String

    enum CodingKeys: String, CodingKey {
        case id, type, color, subtype, value
        case userID = "user_id"
        case displayName = "display_name"
        case occurredAt = "occurred_at"
        case prevValue = "prev_value"
        case driveID = "drive_id"
        case subjectID = "subject_id"
        case subjectName = "subject_name"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = try c.decodeIfPresent(FeedEventType.self, forKey: .type) ?? .unknown
        userID = try c.decodeIfPresent(String.self, forKey: .userID) ?? ""
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? ""
        occurredAt = SocialDate.parse(try c.decodeIfPresent(String.self, forKey: .occurredAt))
        subtype = try c.decodeIfPresent(String.self, forKey: .subtype) ?? ""
        value = try c.decodeIfPresent(Double.self, forKey: .value) ?? 0
        prevValue = try c.decodeIfPresent(Double.self, forKey: .prevValue) ?? 0
        driveID = try c.decodeIfPresent(String.self, forKey: .driveID) ?? ""
        subjectID = try c.decodeIfPresent(String.self, forKey: .subjectID) ?? ""
        subjectName = try c.decodeIfPresent(String.self, forKey: .subjectName) ?? ""
    }

    public init(
        id: String,
        type: FeedEventType,
        userID: String,
        displayName: String,
        color: String,
        occurredAt: Date,
        subtype: String = "",
        value: Double = 0,
        prevValue: Double = 0,
        driveID: String = "",
        subjectID: String = "",
        subjectName: String = ""
    ) {
        self.id = id
        self.type = type
        self.userID = userID
        self.displayName = displayName
        self.color = color
        self.occurredAt = occurredAt
        self.subtype = subtype
        self.value = value
        self.prevValue = prevValue
        self.driveID = driveID
        self.subjectID = subjectID
        self.subjectName = subjectName
    }
}

struct FeedResponse: Decodable, Sendable {
    let items: [FeedEventDTO]
}

/// one drive expanded for a feed detail view (`GET /api/rev/drives/{driveId}`)
public struct DriveDetailDTO: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let userID: String
    public let displayName: String
    public let color: String
    public let startedAt: Date
    public let endedAt: Date
    public let durationSeconds: Double
    public let tiles: Int
    public let tilesGained: Int
    public let tilesCaptured: Int
    public let distanceMeters: Double
    /// the cleaned, downsampled route as (lat, lng) pairs
    public let path: [PathPoint]
    /// the server-derived per-hex speeds, for the detail map overlay
    public let tileScores: [TileScore]

    public struct PathPoint: Sendable, Equatable {
        public let lat: Double
        public let lng: Double

        public init(lat: Double, lng: Double) {
            self.lat = lat
            self.lng = lng
        }
    }

    public struct TileScore: Decodable, Sendable, Equatable, Identifiable {
        public let h3: UInt64
        public let mph: Double

        public var id: UInt64 { h3 }

        enum CodingKeys: String, CodingKey {
            case h3, mph
        }

        public init(h3: UInt64, mph: Double) {
            self.h3 = h3
            self.mph = mph
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // h3 crosses the wire as a decimal string for exactness (2^53 JSON limit)
            h3 = UInt64(try c.decodeIfPresent(String.self, forKey: .h3) ?? "0") ?? 0
            mph = try c.decodeIfPresent(Double.self, forKey: .mph) ?? 0
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, color, tiles, path
        case userID = "user_id"
        case displayName = "display_name"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case durationSeconds = "duration_seconds"
        case tilesGained = "tiles_gained"
        case tilesCaptured = "tiles_captured"
        case distanceMeters = "distance_meters"
        case tileScores = "tile_scores"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        userID = try c.decodeIfPresent(String.self, forKey: .userID) ?? ""
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? ""
        startedAt = SocialDate.parse(try c.decodeIfPresent(String.self, forKey: .startedAt))
        endedAt = SocialDate.parse(try c.decodeIfPresent(String.self, forKey: .endedAt))
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? 0
        tiles = try c.decodeIfPresent(Int.self, forKey: .tiles) ?? 0
        tilesGained = try c.decodeIfPresent(Int.self, forKey: .tilesGained) ?? 0
        tilesCaptured = try c.decodeIfPresent(Int.self, forKey: .tilesCaptured) ?? 0
        distanceMeters = try c.decodeIfPresent(Double.self, forKey: .distanceMeters) ?? 0
        let pairs = try c.decodeIfPresent([[Double]].self, forKey: .path) ?? []
        path = pairs.compactMap { $0.count == 2 ? PathPoint(lat: $0[0], lng: $0[1]) : nil }
        tileScores = (try c.decodeIfPresent([TileScore].self, forKey: .tileScores) ?? []).filter { $0.h3 != 0 }
    }

    public init(
        id: String,
        userID: String,
        displayName: String,
        color: String,
        startedAt: Date,
        endedAt: Date,
        durationSeconds: Double,
        tiles: Int,
        tilesGained: Int,
        tilesCaptured: Int,
        distanceMeters: Double,
        path: [PathPoint],
        tileScores: [TileScore] = []
    ) {
        self.id = id
        self.userID = userID
        self.displayName = displayName
        self.color = color
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.tiles = tiles
        self.tilesGained = tilesGained
        self.tilesCaptured = tilesCaptured
        self.distanceMeters = distanceMeters
        self.path = path
        self.tileScores = tileScores
    }
}

/// one moment a personal record was set
/// (`GET /api/rev/profile/{userId}/prs/{kind}`)
public struct PRPointDTO: Decodable, Sendable, Equatable, Identifiable {
    public let occurredAt: Date
    public let value: Double

    public var id: Date { occurredAt }

    enum CodingKeys: String, CodingKey {
        case occurredAt = "occurred_at"
        case value
    }

    public init(occurredAt: Date, value: Double) {
        self.occurredAt = occurredAt
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        occurredAt = SocialDate.parse(try c.decodeIfPresent(String.self, forKey: .occurredAt))
        value = try c.decodeIfPresent(Double.self, forKey: .value) ?? 0
    }
}

struct PRHistoryResponse: Decodable, Sendable {
    let items: [PRPointDTO]
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
