import Foundation
import Testing
@testable import RevKit

struct DriveSummaryGainedCellsTests {
    private let me = "me"
    private let metrics = DriveSummary.Metrics(distanceMeters: 0, movingTime: 0, averageScore: 0, peakScore: 0)

    private func summary(_ changes: [TileChange]) -> DriveSummary {
        DriveSummary.build(changes: changes, localPlayerId: me, metrics: metrics)
    }

    /// build collects claimed + captured + enclosed cells, excludes reinforced and tiles not held,
    /// and sorts ascending for determinism
    @Test func buildCollectsGainsAndExcludesReinforced() {
        let s = summary([
            TileChange(cell: 30, previousOwner: nil, finalOwner: me, provenance: .direct),       // claimed
            TileChange(cell: 10, previousOwner: "rival", finalOwner: me, provenance: .direct),   // captured
            TileChange(cell: 20, previousOwner: nil, finalOwner: me, provenance: .enclosure),    // enclosed
            TileChange(cell: 40, previousOwner: me, finalOwner: me, provenance: .direct),        // reinforced -> excluded
            TileChange(cell: 50, previousOwner: nil, finalOwner: "rival", provenance: .direct),  // not held -> excluded
        ])
        #expect(s.gainedCells == [10, 20, 30])
    }

    /// decoding a JSON object that predates gainedCells yields []
    @Test func decodingLegacyJSONDefaultsToEmpty() throws {
        let json = """
        {
          "tilesClaimed": 3,
          "capturedByOpponent": {"rival": 1},
          "tilesReinforced": 0,
          "tilesEnclosed": 2,
          "distanceMeters": 1200,
          "movingTime": 300,
          "averageScore": 24,
          "peakScore": 41
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(DriveSummary.self, from: json)
        #expect(decoded.gainedCells == [])
        #expect(decoded.tilesClaimed == 3)
        #expect(decoded.tilesEnclosed == 2)
    }

    /// a round-trip encode/decode preserves the gained cells
    @Test func gainedCellsRoundTrip() throws {
        let original = summary([
            TileChange(cell: 100, previousOwner: nil, finalOwner: me, provenance: .direct),
            TileChange(cell: 200, previousOwner: "rival", finalOwner: me, provenance: .enclosure),
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DriveSummary.self, from: data)
        #expect(decoded == original)
        #expect(decoded.gainedCells == [100, 200])
    }
}
