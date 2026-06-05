import Foundation
import SwiftData
import Testing
@testable import RevKit

/// one shared in-memory container the seeder runs once,
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

    @Test func rankByTilesHeld() {
        let store = TerritoryStore(context: Self.container.mainContext)

        // seeded opponents (Ada, Owen) hold tiles and the local player starts with none
        let before = store.leaderboard()
        #expect(before.first { $0.isLocal }?.tilesHeld == 0)
        #expect(before.contains { $0.displayName == "Ada" })
        #expect(before.contains { $0.displayName == "Owen" })

        // give the local player the most territory so it sorts to the top
        let me = store.localPlayer.id
        store.claim(0xA001, score: 30, by: me)
        store.claim(0xA002, score: 30, by: me)
        store.claim(0xA003, score: 30, by: me)

        let board = store.leaderboard()

        // descending by tilesHeld
        let counts = board.map(\.tilesHeld)
        #expect(counts == counts.sorted(by: >))

        // local player on top with 3 tiles and flagged
        #expect(board.first?.isLocal == true)
        #expect(board.first?.tilesHeld == 3)

        // every player appears exactly once
        #expect(Set(board.map(\.playerId)).count == board.count)
    }
}
