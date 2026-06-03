import Foundation

/// represents one recorded movement session
///
/// in-memory atm but when SwiftData is added should?? become a `@Model` with an `uploaded: Bool`
/// flag and the raw path stored as an array of `GPSSample` REF: docs/tech-stack.md §Local Storage
public struct Drive: Identifiable, Sendable {
    public let id: UUID
    public let startedAt: Date
    public var endedAt: Date?
    public var rawPath: [GPSSample]
    /// distance-weighted average speed (mph) per H3 cell, computed at end-of-drive
    /// keyed by raw H3 index; serialize via `PerTileScores` for the future upload payload
    public var perTileScores: [UInt64: Double]

    public init(
        id: UUID = UUID(),
        startedAt: Date,
        endedAt: Date? = nil,
        rawPath: [GPSSample] = [],
        perTileScores: [UInt64: Double] = [:]
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.rawPath = rawPath
        self.perTileScores = perTileScores
    }
}
