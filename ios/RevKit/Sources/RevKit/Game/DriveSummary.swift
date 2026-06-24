import Foundation

/// how a tile ended up in the local player's hands this drive
public enum ClaimProvenance: Sendable {
    /// taken by driving across it (direct claim, `ClaimResolver`)
    case direct
    /// gained as enclosed interior (REF: docs/game-design.md §Trails & Enclosure)
    case enclosure
}

/// the net change to a single tile over one drive: who owned it when the drive first touched it
/// versus who owns it at finalize
public struct TileChange: Equatable, Sendable {
    public var cell: UInt64
    /// owner when the drive first touched this cell
    public var previousOwner: String?
    /// owner at finalize
    public var finalOwner: String
    public var provenance: ClaimProvenance

    public init(cell: UInt64, previousOwner: String?, finalOwner: String, provenance: ClaimProvenance) {
        self.cell = cell
        self.previousOwner = previousOwner
        self.finalOwner = finalOwner
        self.provenance = provenance
    }
}

/// a per-drive accounting of what changed
///
/// this is provisional and will eventually be server side
///
public struct DriveSummary: Codable, Equatable, Sendable {
    /// direct claims of previously-unowned tiles (`ClaimOutcome.created`)
    public var tilesClaimed: Int
    /// tiles taken from each opponent, keyed by their player id (`ClaimOutcome.captured`)
    public var capturedByOpponent: [String: Int]
    /// own tiles re-driven this drive (`ClaimOutcome.reinforced`, the re-drive floor)
    public var tilesReinforced: Int
    /// tiles gained as enclosed interior
    public var tilesEnclosed: Int
    public var distanceMeters: Double
    public var movingTime: TimeInterval
    /// distance-weighted average speed across scored tiles (mph)
    public var averageScore: Double
    /// fastest scored tile this drive (mph)
    public var peakScore: Double

    public init(
        tilesClaimed: Int = 0,
        capturedByOpponent: [String: Int] = [:],
        tilesReinforced: Int = 0,
        tilesEnclosed: Int = 0,
        distanceMeters: Double = 0,
        movingTime: TimeInterval = 0,
        averageScore: Double = 0,
        peakScore: Double = 0
    ) {
        self.tilesClaimed = tilesClaimed
        self.capturedByOpponent = capturedByOpponent
        self.tilesReinforced = tilesReinforced
        self.tilesEnclosed = tilesEnclosed
        self.distanceMeters = distanceMeters
        self.movingTime = movingTime
        self.averageScore = averageScore
        self.peakScore = peakScore
    }

    public var totalCaptured: Int { capturedByOpponent.values.reduce(0, +) }

    /// net new ground won this drive (newly claimed + captured from rivals + enclosed)
    public var totalGained: Int { tilesClaimed + totalCaptured + tilesEnclosed }

    public var tilesDriven: Int { totalGained + tilesReinforced }

    /// the movement metrics half of a summary
    ///
    /// kept separate so it can be computed straight from the GPS path + per-tile scores (see `TileScoring`) for `build`
    public struct Metrics: Equatable, Sendable {
        public var distanceMeters: Double
        public var movingTime: TimeInterval
        public var averageScore: Double
        public var peakScore: Double

        public init(distanceMeters: Double, movingTime: TimeInterval, averageScore: Double, peakScore: Double) {
            self.distanceMeters = distanceMeters
            self.movingTime = movingTime
            self.averageScore = averageScore
            self.peakScore = peakScore
        }

        /// derive the score half from a drive's final per-tile scores
        public init(distanceMeters: Double, movingTime: TimeInterval, perTileScores: [UInt64: Double]) {
            self.distanceMeters = distanceMeters
            self.movingTime = movingTime
            let values = perTileScores.values
            self.averageScore = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
            self.peakScore = values.max() ?? 0
        }
    }

    /// aggregate net per-tile changes into a player-facing tally
    ///
    /// only tiles the player actually holds at finalize count
    public static func build(
        changes: [TileChange],
        localPlayerId: String,
        metrics: Metrics
    ) -> DriveSummary {
        var summary = DriveSummary(
            distanceMeters: metrics.distanceMeters,
            movingTime: metrics.movingTime,
            averageScore: metrics.averageScore,
            peakScore: metrics.peakScore
        )

        for change in changes where change.finalOwner == localPlayerId {
            switch change.provenance {
            case .enclosure:
                summary.tilesEnclosed += 1
            case .direct:
                if change.previousOwner == nil {
                    summary.tilesClaimed += 1
                } else if change.previousOwner == localPlayerId {
                    summary.tilesReinforced += 1
                } else if let opponent = change.previousOwner {
                    summary.capturedByOpponent[opponent, default: 0] += 1
                }
            }
        }

        return summary
    }
}
