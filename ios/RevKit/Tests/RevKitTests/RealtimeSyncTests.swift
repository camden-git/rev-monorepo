import Foundation
import SwiftData
import Testing
@testable import RevKit

/// realtime tile-stream lifecycle + apply
@MainActor
@Suite(.serialized)
struct RealtimeSyncTests {
    static let container: ModelContainer = {
        try! ModelContainer(
            for: Player.self, TileRecord.self, DriveRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }()

    private func makeStore() -> TerritoryStore {
        TerritoryStore(context: Self.container.mainContext)
    }

    private func makeSync(
        store: TerritoryStore,
        client: PocketBaseClient,
        realtime: TileRealtimeClient
    ) -> SyncService {
        SyncService(
            store: store,
            context: Self.container.mainContext,
            client: client,
            tokenStore: InMemoryTokenStore(),
            cursor: InMemorySyncCursor(),
            realtime: realtime
        )
    }

    @Test func flushLiveClaimsPostsBatchWhenSignedIn() async throws {
        let client = MockPocketBaseClient()
        let sync = makeSync(store: makeStore(), client: client, realtime: MockTileRealtimeClient())
        sync.adoptSession(AuthResponse(token: "t", record: AuthUserDTO(id: "me", email: nil, displayName: nil)))

        await sync.flushLiveClaims([SyncFixtures.cell: 33.0])

        #expect(client.claimBatches.count == 1)
        #expect(client.claimBatches.first?[SyncFixtures.cell] == 33.0)
    }

    @Test func flushLiveClaimsSkippedWhenSignedOutOrEmpty() async throws {
        let client = MockPocketBaseClient()
        let sync = makeSync(store: makeStore(), client: client, realtime: MockTileRealtimeClient())

        await sync.flushLiveClaims([SyncFixtures.cell: 33.0]) // signed out -> skip
        sync.adoptSession(AuthResponse(token: "t", record: AuthUserDTO(id: "me", email: nil, displayName: nil)))
        await sync.flushLiveClaims([:]) // empty -> skip

        #expect(client.claimBatches.isEmpty)
    }

    @Test func signedOutStartRealtimeIsNoOp() async throws {
        let realtime = MockTileRealtimeClient()
        let sync = makeSync(store: makeStore(), client: MockPocketBaseClient(), realtime: realtime)

        sync.startRealtime()

        #expect(realtime.startCount == 0)
        #expect(!realtime.isRunning)
    }

    @Test func startedStreamAppliesPushedTileIntoStore() async throws {
        let store = makeStore()
        let realtime = MockTileRealtimeClient()
        let sync = makeSync(store: store, client: MockPocketBaseClient(), realtime: realtime)
        sync.adoptSession(AuthResponse(token: "t", record: AuthUserDTO(id: "me", email: nil, displayName: nil)))

        sync.startRealtime()
        #expect(realtime.startCount == 1)
        #expect(realtime.isRunning)

        let cell = SyncFixtures.cell &+ 9001
        let updated = Date(timeIntervalSince1970: 1_700_500_000)
        realtime.emit(makeTileDTO(cell, owner: "rival-server-id", score: 42, updated: updated))

        let state = try #require(store.tiles[cell])
        #expect(state.ownerId == "rival-server-id")
        #expect(state.claimScore == 42)
    }

    @Test func startRealtimeIsIdempotentWhileRunning() async throws {
        let realtime = MockTileRealtimeClient()
        let sync = makeSync(store: makeStore(), client: MockPocketBaseClient(), realtime: realtime)
        sync.adoptSession(AuthResponse(token: "t", record: AuthUserDTO(id: "me", email: nil, displayName: nil)))

        sync.startRealtime()
        sync.startRealtime()

        #expect(realtime.startCount == 1)
    }

    @Test func reconnectRunsDeltaPollBackfill() async throws {
        let store = makeStore()
        let client = MockPocketBaseClient()
        let realtime = MockTileRealtimeClient()
        let sync = makeSync(store: store, client: client, realtime: realtime)
        sync.adoptSession(AuthResponse(token: "t", record: AuthUserDTO(id: "me", email: nil, displayName: nil)))
        sync.startRealtime()

        realtime.simulateConnect() // fires the onConnect backfill

        // the backfill is dispatched on a detached task, spin briefly until it lands
        try await waitUntil { client.listSinceArgs.isEmpty == false }
        #expect(client.listSinceArgs.isEmpty == false)
    }

    @Test func signOutStopsRealtimeStream() async throws {
        let realtime = MockTileRealtimeClient()
        let sync = makeSync(store: makeStore(), client: MockPocketBaseClient(), realtime: realtime)
        sync.adoptSession(AuthResponse(token: "t", record: AuthUserDTO(id: "me", email: nil, displayName: nil)))
        sync.startRealtime()
        #expect(realtime.isRunning)

        sync.signOut()

        #expect(realtime.stopCount == 1)
        #expect(!realtime.isRunning)
    }

    @Test func authFailureDuringSyncTearsDownRealtime() async throws {
        let store = makeStore()
        let client = MockPocketBaseClient()
        client.onListTiles = { _ in
            throw PocketBaseError.http(status: 401, body: #"{"message":"expired"}"#)
        }
        let realtime = MockTileRealtimeClient()
        let sync = makeSync(store: store, client: client, realtime: realtime)
        sync.adoptSession(AuthResponse(token: "bad", record: AuthUserDTO(id: "me", email: nil, displayName: nil)))
        sync.startRealtime()
        #expect(realtime.isRunning)

        await sync.pollTiles() // auth failure clears the session

        #expect(sync.currentUserId == nil)
        #expect(realtime.stopCount == 1)
        #expect(!realtime.isRunning)
    }

    /// poll a condition for up to ~1s so detached backfill tasks can settle
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
