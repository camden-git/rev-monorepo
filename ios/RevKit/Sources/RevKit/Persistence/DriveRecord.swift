import Foundation
import SwiftData

/// a persisted recorded drive (REF: docs/tech-stack.md §Local Storage Model)
@Model
public final class DriveRecord {
    @Attribute(.unique) public var id: UUID
    public var startedAt: Date
    public var endedAt: Date?
    /// raw GPS fixes: stored inline as Codable values
    public var rawPath: [GPSSample]
    /// per-tile scores encoded via `PerTileScores`, nil until the drive finalizes
    public var perTileScoresData: Data?
    /// the provisional per-drive `DriveSummary`, json.
    ///
    /// future server side: superseded by the backend's authoritative delta response on upload
    public var summaryData: Data?
    public var uploaded: Bool

    public init(
        id: UUID,
        startedAt: Date,
        endedAt: Date?,
        rawPath: [GPSSample],
        perTileScores: [UInt64: Double],
        summary: DriveSummary? = nil,
        uploaded: Bool = false
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.rawPath = rawPath
        self.perTileScoresData = try? JSONEncoder().encode(PerTileScores(perTileScores))
        self.summaryData = summary.flatMap { try? JSONEncoder().encode($0) }
        self.uploaded = uploaded
    }

    /// convenience initializer from a finished in-flight `Drive`
    public convenience init(drive: Drive, summary: DriveSummary? = nil) {
        self.init(
            id: drive.id,
            startedAt: drive.startedAt,
            endedAt: drive.endedAt,
            rawPath: drive.rawPath,
            perTileScores: drive.perTileScores,
            summary: summary
        )
    }

    public var perTileScores: [UInt64: Double] {
        guard let perTileScoresData,
              let decoded = try? JSONDecoder().decode(PerTileScores.self, from: perTileScoresData)
        else { return [:] }
        return decoded.scores
    }

    public var summary: DriveSummary? {
        guard let summaryData else { return nil }
        return try? JSONDecoder().decode(DriveSummary.self, from: summaryData)
    }
}
