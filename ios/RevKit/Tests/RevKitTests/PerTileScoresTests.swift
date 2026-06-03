import Foundation
import Testing
@testable import RevKit

struct PerTileScoresTests {
    /// test if encode and decode work round trip
    @Test func roundTripsThroughJSON() throws {
        let original: [UInt64: Double] = [
            0x8a2a1072b59ffff: 27.4,
            0x8a2a1072b597fff: 0.0,
            0x8a2a1072b5b7fff: 13.125,
        ]

        let data = try JSONEncoder().encode(PerTileScores(original))
        let decoded = try JSONDecoder().decode(PerTileScores.self, from: data)

        #expect(decoded.scores == original)
    }

    @Test func encodesKeysAsDecimalStrings() throws {
        let h3: UInt64 = 0x8a2a1072b59ffff
        let data = try JSONEncoder().encode(PerTileScores([h3: 42.0]))

        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let json = try #require(object)
        #expect(json.keys.first == String(h3)) // expect decimal string
        #expect(json[String(h3)] as? Double == 42.0)
    }
}
