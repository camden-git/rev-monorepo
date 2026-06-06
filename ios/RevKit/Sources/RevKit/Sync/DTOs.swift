import Foundation

/// types for the PocketBase REST API (REF: docs/tech-stack.md §Sync
/// Model, §Schema)


/// POST body for `POST /api/collections/drives/records`
public struct DriveUploadPayload: Encodable, Sendable {
    public let startedAt: Date
    public let endedAt: Date?
    public let rawPath: [GPSSample]
    public let perTileScores: PerTileScores

    public init(startedAt: Date, endedAt: Date?, rawPath: [GPSSample], perTileScores: [UInt64: Double]) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.rawPath = rawPath
        self.perTileScores = PerTileScores(perTileScores)
    }

    enum CodingKeys: String, CodingKey {
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case rawPath = "raw_path"
        case perTileScores = "per_tile_scores"
    }
}

/// the created `drives` record echoed back by PocketBase
public struct DriveRecordDTO: Decodable, Sendable, Equatable {
    public let id: String
    public let created: Date?
}

/// a `tiles` record as returned by the list endpoint
public struct TileDTO: Decodable, Sendable, Equatable {
    public let id: String
    public let h3: UInt64
    public let owner: String
    public let claimScore: Double
    public let lastDrivenAt: Date
    public let isHome: Bool
    public let updated: Date

    public init(id: String, h3: UInt64, owner: String, claimScore: Double, lastDrivenAt: Date, isHome: Bool, updated: Date) {
        self.id = id
        self.h3 = h3
        self.owner = owner
        self.claimScore = claimScore
        self.lastDrivenAt = lastDrivenAt
        self.isHome = isHome
        self.updated = updated
    }

    enum CodingKeys: String, CodingKey {
        case id, owner, updated
        case h3
        case claimScore = "claim_score"
        case lastDrivenAt = "last_driven_at"
        case isHome = "is_home"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        owner = try c.decode(String.self, forKey: .owner)
        updated = try c.decode(Date.self, forKey: .updated)
        // h3 crosses the wire as a decimal string for exactness
        let h3String = try c.decode(String.self, forKey: .h3)
        guard let parsed = UInt64(h3String) else {
            throw DecodingError.dataCorruptedError(forKey: .h3, in: c, debugDescription: "h3 not a uint64 string: \(h3String)")
        }
        h3 = parsed
        claimScore = try c.decodeIfPresent(Double.self, forKey: .claimScore) ?? 0
        lastDrivenAt = try c.decodeIfPresent(Date.self, forKey: .lastDrivenAt) ?? .distantPast
        isHome = try c.decodeIfPresent(Bool.self, forKey: .isHome) ?? false
    }
}

/// POST body for the live in-drive claim endpoint `POST /api/rev/tiles/claim`
public struct TileClaimRequest: Encodable, Sendable {
    public let perTileScores: PerTileScores

    public init(perTileScores: [UInt64: Double]) {
        self.perTileScores = PerTileScores(perTileScores)
    }

    enum CodingKeys: String, CodingKey {
        case perTileScores = "per_tile_scores"
    }
}

/// `{ "ok": true }` ack from the claim endpoint
public struct TileClaimResponse: Decodable, Sendable {
    public let ok: Bool
}

/// POST body for the compact map-window tile endpoint
public struct TileWindowRequest: Encodable, Sendable {
    public let parentResolution: Int
    public let parents: [String]

    public init(parentResolution: Int, parents: [UInt64]) {
        self.parentResolution = parentResolution
        self.parents = parents.map(String.init)
    }

    enum CodingKeys: String, CodingKey {
        case parentResolution = "parent_resolution"
        case parents
    }
}

/// response from `POST /api/rev/tiles/window`
public struct TileWindowResponse: Decodable, Sendable {
    public let items: [TileDTO]
}

/// a `users` record as returned by the roster list endpoint
public struct PlayerDTO: Decodable, Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let color: String
    /// home hex H3 id, `0` means the player hasn't onboarded a home yet
    public let homeH3: UInt64

    public init(id: String, displayName: String, color: String, homeH3: UInt64) {
        self.id = id
        self.displayName = displayName
        self.color = color
        self.homeH3 = homeH3
    }

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case color
        case homeH3 = "home_h3"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? ""
        // home_h3 crosses the wire as a decimal string for exactness (same as TileDTO.h3)
        let homeString = try c.decodeIfPresent(String.self, forKey: .homeH3) ?? "0"
        homeH3 = UInt64(homeString) ?? 0
    }
}

/// PocketBase's paginated list envelope
public struct ListResponse<Item: Decodable & Sendable>: Decodable, Sendable {
    public let items: [Item]
    public let page: Int
    public let perPage: Int
    public let totalItems: Int
    public let totalPages: Int

    enum CodingKeys: String, CodingKey {
        case items, page
        case perPage = "perPage"
        case totalItems = "totalItems"
        case totalPages = "totalPages"
    }
}

/// response of `auth-with-oauth2`
public struct AuthResponse: Decodable, Sendable, Equatable {
    public let token: String
    public let record: AuthUserDTO
}

/// the authenticated user record
public struct AuthUserDTO: Decodable, Sendable, Equatable {
    public let id: String
    public let email: String?
    public let displayName: String?

    enum CodingKeys: String, CodingKey {
        case id, email
        case displayName = "display_name"
    }
}
