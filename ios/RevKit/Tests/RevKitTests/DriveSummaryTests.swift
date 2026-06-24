import Foundation
import Testing
@testable import RevKit

struct DriveSummaryTests {
    /// da
    private let me = "me"
    private let metrics = DriveSummary.Metrics(distanceMeters: 0, movingTime: 0, averageScore: 0, peakScore: 0)

    private func summary(_ changes: [TileChange]) -> DriveSummary {
        DriveSummary.build(changes: changes, localPlayerId: me, metrics: metrics)
    }

    /// a previously-unowned tile driven across counts as a fresh claim
    @Test func unownedDirectIsClaimed() {
        let s = summary([TileChange(cell: 1, previousOwner: nil, finalOwner: me, provenance: .direct)])
        #expect(s.tilesClaimed == 1)
        #expect(s.totalGained == 1)
        #expect(s.totalCaptured == 0)
        #expect(s.tilesEnclosed == 0)
        #expect(s.tilesReinforced == 0)
    }

    /// taking a tile from an opponent is tallied against that opponent
    @Test func opponentDirectIsCaptured() {
        let s = summary([TileChange(cell: 1, previousOwner: "rival", finalOwner: me, provenance: .direct)])
        #expect(s.capturedByOpponent["rival"] == 1)
        #expect(s.totalCaptured == 1)
        #expect(s.tilesClaimed == 0)
    }

    /// re-driving your own tile is reinforcement, not a gain of new ground
    @Test func ownTileIsReinforced() {
        let s = summary([TileChange(cell: 1, previousOwner: me, finalOwner: me, provenance: .direct)])
        #expect(s.tilesReinforced == 1)
        #expect(s.tilesClaimed == 0)
        #expect(s.totalGained == 0)
        #expect(s.tilesDriven == 1)
    }

    /// enclosure provenance wins regardless of who (if anyone) held the tile before
    @Test func enclosureProvenanceCountsAsEnclosed() {
        let s = summary([
            TileChange(cell: 1, previousOwner: nil, finalOwner: me, provenance: .enclosure),
            TileChange(cell: 2, previousOwner: "rival", finalOwner: me, provenance: .enclosure),
        ])
        #expect(s.tilesEnclosed == 2)
        #expect(s.tilesClaimed == 0)
        #expect(s.totalCaptured == 0)
        #expect(s.totalGained == 2)
    }

    /// a tile touched but not held at finalize (cut trail / lost to a fresher owner) is ignored
    @Test func tilesNotHeldAtFinalizeAreIgnored() {
        let s = summary([
            TileChange(cell: 1, previousOwner: nil, finalOwner: "rival", provenance: .direct),
            TileChange(cell: 2, previousOwner: me, finalOwner: "rival", provenance: .direct),
        ])
        #expect(s.totalGained == 0)
        #expect(s.tilesClaimed == 0)
        #expect(s.tilesReinforced == 0)
    }

    /// a realistic mix tallies into the right buckets and total
    @Test func mixedDriveTotals() {
        let s = summary([
            TileChange(cell: 1, previousOwner: nil, finalOwner: me, provenance: .direct),       // claimed
            TileChange(cell: 2, previousOwner: nil, finalOwner: me, provenance: .direct),       // claimed
            TileChange(cell: 3, previousOwner: "a", finalOwner: me, provenance: .direct),       // captured a
            TileChange(cell: 4, previousOwner: "b", finalOwner: me, provenance: .direct),       // captured b
            TileChange(cell: 5, previousOwner: "a", finalOwner: me, provenance: .direct),       // captured a
            TileChange(cell: 6, previousOwner: me, finalOwner: me, provenance: .direct),        // reinforced
            TileChange(cell: 7, previousOwner: nil, finalOwner: me, provenance: .enclosure),    // enclosed
            TileChange(cell: 8, previousOwner: "a", finalOwner: "a", provenance: .direct),      // never taken
        ])
        #expect(s.tilesClaimed == 2)
        #expect(s.capturedByOpponent["a"] == 2)
        #expect(s.capturedByOpponent["b"] == 1)
        #expect(s.totalCaptured == 3)
        #expect(s.tilesReinforced == 1)
        #expect(s.tilesEnclosed == 1)
        #expect(s.totalGained == 6) // 2 claimed + 3 captured + 1 enclosed
        #expect(s.tilesDriven == 7) // + 1 reinforced
    }

    /// the movement metrics are carried through verbatim
    @Test func metricsArePassedThrough() {
        let m = DriveSummary.Metrics(distanceMeters: 1200, movingTime: 300, averageScore: 24, peakScore: 41)
        let s = DriveSummary.build(changes: [], localPlayerId: me, metrics: m)
        #expect(s.distanceMeters == 1200)
        #expect(s.movingTime == 300)
        #expect(s.averageScore == 24)
        #expect(s.peakScore == 41)
    }

    /// the per-tile-scores metrics convenience derives mean + max correctly
    @Test func metricsFromPerTileScoresDerivesAverageAndPeak() {
        let m = DriveSummary.Metrics(distanceMeters: 0, movingTime: 0, perTileScores: [1: 10, 2: 20, 3: 30])
        #expect(abs(m.averageScore - 20) < 0.001)
        #expect(m.peakScore == 30)
    }

    /// a summary survives a JSON round-trip (it's persisted on DriveRecord)
    @Test func codableRoundTrips() throws {
        let original = summary([
            TileChange(cell: 1, previousOwner: nil, finalOwner: me, provenance: .direct),
            TileChange(cell: 2, previousOwner: "rival", finalOwner: me, provenance: .enclosure),
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DriveSummary.self, from: data)
        #expect(decoded == original)
    }
}
