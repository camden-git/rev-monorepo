import Foundation
import Testing
@testable import RevKit

struct EmpireStatsTests {
    private let me = "me"
    private let now = Date(timeIntervalSince1970: 1_000_000_000)

    /// a held tile last driven `daysAgo` days before `now`
    private func tile(
        owner: String,
        score: Double,
        daysAgo: Double,
        isHome: Bool = false,
        captures: Int = 0
    ) -> ClaimResolver.TileState {
        ClaimResolver.TileState(
            ownerId: owner,
            claimScore: score,
            captures: captures,
            lastDrivenAt: now.addingTimeInterval(-daysAgo * 24 * 60 * 60),
            isHome: isHome
        )
    }

    private func summary(distance: Double, gained: Int) -> DriveSummary {
        DriveSummary(tilesClaimed: gained, distanceMeters: distance)
    }

    private func compute(
        _ tiles: [ClaimResolver.TileState],
        drives: [DriveSummary] = [],
        atRiskFraction: Double = 0.5
    ) -> EmpireStats {
        EmpireStats.compute(
            tiles: tiles,
            ownedBy: me,
            driveSummaries: drives,
            now: now,
            atRiskFraction: atRiskFraction
        )
    }

    /// an empty world aggregates to all zeros
    @Test func emptyWorldIsZeroed() {
        let s = compute([])
        #expect(s.tilesHeld == 0)
        #expect(s.empireScore == 0)
        #expect(s.tilesAtRisk == 0)
        #expect(s.strongholdScore == 0)
        #expect(s.totalDrives == 0)
        #expect(s.lifetimeDistanceMeters == 0)
        #expect(s.lifetimeTilesGained == 0)
    }

    /// only the local player's tiles count toward tilesHeld
    @Test func tilesHeldCountsOnlyLocalPlayer() {
        let s = compute([
            tile(owner: me, score: 30, daysAgo: 0),
            tile(owner: me, score: 30, daysAgo: 0),
            tile(owner: "rival", score: 50, daysAgo: 0),
        ])
        #expect(s.tilesHeld == 2)
    }

    /// empire score weights non-home tiles by their contestedness value
    @Test func empireScoreWeightsCapturedTiles() {
        let s = compute([
            tile(owner: me, score: 0, daysAgo: 0, isHome: true),
            tile(owner: me, score: 1.5, daysAgo: 0, captures: 3),
            tile(owner: me, score: 1.0, daysAgo: 0),
        ])
        let expected = 1 + Strength.tileValue(captures: 3) + 1
        #expect(abs(s.empireScore - expected) < 1e-9)
    }

    /// a tile driven recently is not at-risk but one untouched for 2 weeks is
    @Test func staleTileIsAtRiskFreshIsNot() {
        let s = compute([
            tile(owner: me, score: 30, daysAgo: 0),   // fresh
            tile(owner: me, score: 30, daysAgo: 14),  // stale
        ])
        #expect(s.tilesHeld == 2)
        #expect(s.tilesAtRisk == 1)
    }

    /// the at-risk threshold is respected on each side of the half-life
    @Test func atRiskThresholdRespectsEitherSide() {
        let halfLifeDays = Decay.tau * log(2) / (24 * 60 * 60) // ratio crosses 0.5 here
        let justFresh = compute(
            [tile(owner: me, score: 30, daysAgo: halfLifeDays - 0.5)], // ratio > 0.5
            atRiskFraction: 0.5
        )
        let justStale = compute(
            [tile(owner: me, score: 30, daysAgo: halfLifeDays + 0.5)], // ratio < 0.5
            atRiskFraction: 0.5
        )
        #expect(justFresh.tilesAtRisk == 0)
        #expect(justStale.tilesAtRisk == 1)
    }

    /// the home hex is inviolable and never counts as at-risk however stale
    @Test func homeHexNeverAtRisk() {
        let s = compute([
            tile(owner: me, score: 0, daysAgo: 999, isHome: true),
            tile(owner: me, score: 30, daysAgo: 999), // ordinary stale tile
        ])
        #expect(s.tilesHeld == 2)
        #expect(s.tilesAtRisk == 1) // only the ordinary tile
    }

    /// stronghold score is the max claim strength among held tiles
    @Test func strongholdScoreIsMaxHeld() {
        let s = compute([
            tile(owner: me, score: 22, daysAgo: 0),
            tile(owner: me, score: 47, daysAgo: 0),
            tile(owner: "rival", score: 88, daysAgo: 0), // not ours, ignored
        ])
        #expect(s.strongholdScore == 47)
    }

    /// lifetime totals fold distance + gained across every drive summary
    @Test func lifetimeTotalsFoldSummaries() {
        let s = compute(
            [tile(owner: me, score: 30, daysAgo: 0)],
            drives: [
                summary(distance: 1000, gained: 3),
                summary(distance: 2500, gained: 5),
            ]
        )
        #expect(s.totalDrives == 2)
        #expect(s.lifetimeDistanceMeters == 3500)
        #expect(s.lifetimeTilesGained == 8)
        #expect(s.lifetimeTilesDriven == 8) // no reinforcement here
    }

    @Test func reDrivesCountAsTilesDrivenNotGained() {
        let s = compute(
            [tile(owner: me, score: 30, daysAgo: 0)],
            drives: [
                DriveSummary(tilesClaimed: 0, tilesReinforced: 12, distanceMeters: 1600),
            ]
        )
        #expect(s.lifetimeTilesGained == 0)
        #expect(s.lifetimeTilesDriven == 12)
    }
}
