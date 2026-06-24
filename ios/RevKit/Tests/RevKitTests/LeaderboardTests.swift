import Foundation
import SwiftData
import Testing
@testable import RevKit

/// one shared in-memory container bootstraps the local player once,
/// so this single test asserts the zero-tile case first, then
/// the post-claim ordering
@MainActor
@Suite(.serialized)
struct LeaderboardTests {
    static let container: ModelContainer = {
        try! ModelContainer(
            for: Player.self, TileRecord.self, DriveRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }()

    @Test func rankByEmpireStrength() {
        let store = TerritoryStore(context: Self.container.mainContext)

        // first launch starts with only the local player, and no claimed tiles
        let before = store.leaderboard()
        #expect(before.first { $0.isLocal }?.tilesHeld == 0)
        #expect(before.filter(\.isLocal).count == 1)
        #expect(before.allSatisfy { $0.tilesHeld == 0 })
        #expect(before.allSatisfy { $0.empireStrength == 0 })
        #expect(before.allSatisfy { $0.empireScore == 0 })

        // give the local player some claimed tiles so it sorts to the top
        let me = store.localPlayer.id
        store.claim(0xA001, score: 30, by: me)
        store.claim(0xA002, score: 30, by: me)
        store.claim(0xA003, score: 30, by: me)

        let board = store.leaderboard()

        // descending by speed-weighted empire strength
        let strengths = board.map(\.empireStrength)
        #expect(strengths == strengths.sorted(by: >))

        // local player on top: 3 plain tiles, strength = sum of claim scores, score = tile count
        #expect(board.first?.isLocal == true)
        #expect(board.first?.tilesHeld == 3)
        #expect(board.first?.empireStrength == 90)
        #expect(board.first?.empireScore == 3)

        // every player appears exactly once
        #expect(Set(board.map(\.playerId)).count == board.count)
    }
}
