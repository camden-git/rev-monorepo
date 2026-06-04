import Foundation

/// an empire overview aggregated of the local player's currently-held tiles and the
/// summaries of their persisted drives (REF: docs/game-design.md §Defense & Decay)
///
/// TODO FOR SERVER SIDE: lost-tile deltas / turnover ("tiles lost since last session") need the
/// backend's `tile_history` audit log (docs/tech-stack.md §Schema). so there is currently some bullshit instead that will be replaced
public struct EmpireStats: Equatable, Sendable {
    /// tiles currently owned by the local player (home hex included)
    public var tilesHeld: Int
    /// held tiles whose decayed score has fallen below `atRiskFraction` of their peak
    public var tilesAtRisk: Int
    /// highest stored claim score among held tiles (mph)
    public var strongholdScore: Double
    /// number of persisted drives folded into the lifetime totals
    public var totalDrives: Int
    /// sum of `distanceMeters` across drive summaries
    public var lifetimeDistanceMeters: Double
    /// sum of `totalGained` across drive summaries
    public var lifetimeTilesGained: Int
    /// the at-risk threshold used, echoed for the view
    public var atRiskFraction: Double

    public init(
        tilesHeld: Int = 0,
        tilesAtRisk: Int = 0,
        strongholdScore: Double = 0,
        totalDrives: Int = 0,
        lifetimeDistanceMeters: Double = 0,
        lifetimeTilesGained: Int = 0,
        atRiskFraction: Double = 0.5
    ) {
        self.tilesHeld = tilesHeld
        self.tilesAtRisk = tilesAtRisk
        self.strongholdScore = strongholdScore
        self.totalDrives = totalDrives
        self.lifetimeDistanceMeters = lifetimeDistanceMeters
        self.lifetimeTilesGained = lifetimeTilesGained
        self.atRiskFraction = atRiskFraction
    }

    /// fold the local player's held tiles + persisted drive summaries into an overview
    public static func compute(
        tiles: [ClaimResolver.TileState],
        ownedBy localPlayerId: String,
        driveSummaries: [DriveSummary],
        now: Date = .now,
        atRiskFraction: Double = 0.5 // not driven in aprox 4.8 days
    ) -> EmpireStats {
        var stats = EmpireStats(atRiskFraction: atRiskFraction)

        for tile in tiles where tile.ownerId == localPlayerId {
            stats.tilesHeld += 1
            stats.strongholdScore = max(stats.strongholdScore, tile.claimScore)

            guard !tile.isHome, tile.claimScore > 0 else { continue }
            let effective = Decay.effectiveScore(
                claimScore: tile.claimScore,
                lastDrivenAt: tile.lastDrivenAt,
                now: now
            )
            if effective / tile.claimScore < atRiskFraction {
                stats.tilesAtRisk += 1
            }
        }

        stats.totalDrives = driveSummaries.count
        for summary in driveSummaries {
            stats.lifetimeDistanceMeters += summary.distanceMeters
            stats.lifetimeTilesGained += summary.totalGained
        }

        return stats
    }
}
