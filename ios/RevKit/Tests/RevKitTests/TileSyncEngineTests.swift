import Foundation
import SwiftData
import Testing
@testable import RevKit

/// serialized + one shared in-memory container
/// each test asserts on its own distinct cells, which its own sync writes
@MainActor
@Suite(.serialized)
struct TileSyncEngineTests {
    static let container: ModelContainer = {
        try! ModelContainer(
            for: Player.self, TileRecord.self, DriveRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }()

    private func makeStore() -> TerritoryStore {
        TerritoryStore(context: Self.container.mainContext)
    }

    @Test func syncAppliesRemoteTilesIntoStore() async throws {
        let store = makeStore()
        let client = MockPocketBaseClient()
        let cell = SyncFixtures.cell
        let updated = Date(timeIntervalSince1970: 1_700_000_500)
        client.onListTiles = { _ in [makeTileDTO(cell, owner: "rival-server-id", score: 47, updated: updated)] }

        let engine = TileSyncEngine(client: client, store: store, cursor: InMemorySyncCursor())
        let count = try await engine.sync()

        #expect(count == 1)
        let state = try #require(store.tiles[cell])
        #expect(state.ownerId == "rival-server-id")
        #expect(state.claimScore == 47)
    }

    @Test func syncAdvancesCursorToNewestUpdated() async throws {
        let store = makeStore()
        let client = MockPocketBaseClient()
        let older = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = Date(timeIntervalSince1970: 1_700_009_999)
        client.onListTiles = { _ in [
            makeTileDTO(SyncFixtures.cell, owner: "a", score: 10, updated: older),
            makeTileDTO(SyncFixtures.cell &+ 1, owner: "b", score: 20, updated: newer),
        ] }

        let cursor = InMemorySyncCursor()
        let engine = TileSyncEngine(client: client, store: store, cursor: cursor)
        _ = try await engine.sync()
        #expect(cursor.lastSync == newer)

        // a second sync passes the advanced cursor as the `updatedSince` arg
        _ = try await engine.sync()
        #expect(client.listSinceArgs.last == newer)
    }

    @Test func emptyDeltaLeavesCursorUnchanged() async throws {
        let store = makeStore()
        let client = MockPocketBaseClient() // default returns []
        let cursor = InMemorySyncCursor(lastSync: Date(timeIntervalSince1970: 1_700_000_000))

        let engine = TileSyncEngine(client: client, store: store, cursor: cursor)
        let count = try await engine.sync()

        #expect(count == 0)
        #expect(cursor.lastSync == Date(timeIntervalSince1970: 1_700_000_000))
    }
}
