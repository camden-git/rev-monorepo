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
        realtime: TileRealtimeClient,
        tokenStore: TokenStore = InMemoryTokenStore()
    ) -> SyncService {
        SyncService(
            store: store,
            context: Self.container.mainContext,
            client: client,
            tokenStore: tokenStore,
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

    // MARK: account deletion

    @Test func deleteAccountWipesLocalDataAndSignsOut() async throws {
        let store = makeStore()
        let client = MockPocketBaseClient()
        let sync = makeSync(store: store, client: client, realtime: MockTileRealtimeClient())
        sync.adoptSession(AuthResponse(token: "t", record: AuthUserDTO(id: "me", email: nil, displayName: nil)))
        store.applyRemoteTiles([makeTileDTO(SyncFixtures.cell, owner: "me", score: 10, updated: Date(timeIntervalSince1970: 1_700_000_000))])
        #expect(!store.tiles.isEmpty)

        let deleted = await sync.deleteAccount()

        #expect(deleted)
        #expect(client.deleteAccountCount == 1)
        #expect(sync.currentUserId == nil)
        #expect(!sync.isSignedIn)
        #expect(store.tiles.isEmpty)
        #expect(store.needsOnboarding)
    }

    @Test func deleteAccountKeepsEverythingOnFailure() async throws {
        let store = makeStore()
        let client = MockPocketBaseClient()
        client.onDeleteAccount = { throw PocketBaseError.http(status: 500, body: "boom") }
        let sync = makeSync(store: store, client: client, realtime: MockTileRealtimeClient())
        sync.adoptSession(AuthResponse(token: "t", record: AuthUserDTO(id: "me", email: nil, displayName: nil)))
        store.applyRemoteTiles([makeTileDTO(SyncFixtures.cell, owner: "me", score: 10, updated: Date(timeIntervalSince1970: 1_700_000_000))])

        let deleted = await sync.deleteAccount()

        // a failed delete must not sign the user out or drop local data
        #expect(!deleted)
        #expect(sync.currentUserId == "me")
        #expect(!store.tiles.isEmpty)
        #expect(sync.lastError != nil)
    }

    @Test func deleteAccountSkippedWhenSignedOut() async throws {
        let client = MockPocketBaseClient()
        let sync = makeSync(store: makeStore(), client: client, realtime: MockTileRealtimeClient())

        let deleted = await sync.deleteAccount()

        #expect(!deleted)
        #expect(client.deleteAccountCount == 0)
    }

    // MARK: invite sign-in error surfacing

    @Test func inviteRejectionSurfacesServerMessage() async throws {
        let client = MockPocketBaseClient()
        client.onInviteAuth = { _, _, _ in
            throw PocketBaseError.http(status: 400, body: #"{"message":"Invite code has expired.","data":{}}"#)
        }
        let sync = makeSync(store: makeStore(), client: client, realtime: MockTileRealtimeClient())

        await sync.signInWithInvite(displayName: "Sam", email: "s@example.com", code: "OLD")

        // the user sees the actual reason, not a generic "Server error 400"
        #expect(sync.lastError == "Invite code has expired.")
        #expect(!sync.isSignedIn)
    }

    @Test func serverErrorWithoutBodyFallsBackToGenericMessage() async throws {
        let client = MockPocketBaseClient()
        client.onInviteAuth = { _, _, _ in
            throw PocketBaseError.http(status: 500, body: "")
        }
        let sync = makeSync(store: makeStore(), client: client, realtime: MockTileRealtimeClient())

        await sync.signInWithInvite(displayName: "Sam", email: "s@example.com", code: "X")

        #expect(sync.lastError == "Server error 500. Your local progress is saved.")
    }

    // MARK: visible-tile polling

    @Test func visibleTilePollRetriesAfterAFailedFetch() async throws {
        let client = MockPocketBaseClient()
        let counter = Counter()
        client.onListTilesForCells = { _ in
            if counter.next() == 0 { throw URLError(.timedOut) }
            return []
        }
        let sync = makeSync(store: makeStore(), client: client, realtime: MockTileRealtimeClient())
        let cells: Set<UInt64> = [SyncFixtures.cell]

        await sync.pollVisibleTiles(h3Cells: cells) // fails, must not cache the viewport
        await sync.pollVisibleTiles(h3Cells: cells) // same view, must retry rather than dedupe

        #expect(client.listCellArgs.count == 2)
    }

    @Test func visibleTilePollDedupesAfterSuccess() async throws {
        let client = MockPocketBaseClient() // default returns []
        let sync = makeSync(store: makeStore(), client: client, realtime: MockTileRealtimeClient())
        let cells: Set<UInt64> = [SyncFixtures.cell]

        await sync.pollVisibleTiles(h3Cells: cells) // success caches the viewport
        await sync.pollVisibleTiles(h3Cells: cells) // identical view is skipped

        #expect(client.listCellArgs.count == 1)
    }

    // MARK: session liveness

    @Test func verifySessionClearsSessionWhenServerRevokedToken() async throws {
        let client = MockPocketBaseClient()
        client.onAuthRefresh = { throw PocketBaseError.http(status: 401, body: #"{"message":"expired"}"#) }
        let tokenStore = InMemoryTokenStore()
        let sync = makeSync(store: makeStore(), client: client, realtime: MockTileRealtimeClient(), tokenStore: tokenStore)
        sync.adoptSession(AuthResponse(token: "dead", record: AuthUserDTO(id: "me", email: nil, displayName: nil)))

        await sync.verifySession()

        #expect(sync.currentUserId == nil)
        #expect(sync.requiresSignIn)
        #expect(tokenStore.load() == nil)
    }

    @Test func verifySessionKeepsSessionWhenOffline() async throws {
        let client = MockPocketBaseClient()
        client.onAuthRefresh = { throw URLError(.notConnectedToInternet) }
        let tokenStore = InMemoryTokenStore()
        let sync = makeSync(store: makeStore(), client: client, realtime: MockTileRealtimeClient(), tokenStore: tokenStore)
        sync.adoptSession(AuthResponse(token: "good", record: AuthUserDTO(id: "me", email: nil, displayName: nil)))

        await sync.verifySession()

        // a network blip must not sign the user out
        #expect(sync.currentUserId == "me")
        #expect(!sync.requiresSignIn)
        #expect(tokenStore.load() == "good")
    }

    @Test func verifySessionRotatesTokenOnSuccess() async throws {
        let client = MockPocketBaseClient()
        client.onAuthRefresh = {
            AuthResponse(token: "rotated", record: AuthUserDTO(id: "me", email: nil, displayName: nil))
        }
        let tokenStore = InMemoryTokenStore()
        let sync = makeSync(store: makeStore(), client: client, realtime: MockTileRealtimeClient(), tokenStore: tokenStore)
        sync.adoptSession(AuthResponse(token: "old", record: AuthUserDTO(id: "me", email: nil, displayName: nil)))

        await sync.verifySession()

        #expect(sync.currentUserId == "me")
        #expect(tokenStore.load() == "rotated")
    }

    @Test func verifySessionSkippedWhenSignedOut() async throws {
        let client = MockPocketBaseClient()
        let sync = makeSync(store: makeStore(), client: client, realtime: MockTileRealtimeClient())

        await sync.verifySession()

        #expect(client.authRefreshCount == 0)
    }

    @Test func heartbeatVerifiesImmediatelyThenStops() async throws {
        let client = MockPocketBaseClient()
        let sync = makeSync(store: makeStore(), client: client, realtime: MockTileRealtimeClient())
        sync.adoptSession(AuthResponse(token: "good", record: AuthUserDTO(id: "me", email: nil, displayName: nil)))

        sync.startHeartbeat(interval: .seconds(30))
        // the first verify fires immediately, before any interval elapses
        try await waitUntil { client.authRefreshCount >= 1 }
        sync.stopHeartbeat()

        #expect(client.authRefreshCount >= 1)
    }

    @Test func heartbeatIsIdempotentWhileRunning() async throws {
        let client = MockPocketBaseClient()
        let sync = makeSync(store: makeStore(), client: client, realtime: MockTileRealtimeClient())
        sync.adoptSession(AuthResponse(token: "good", record: AuthUserDTO(id: "me", email: nil, displayName: nil)))

        sync.startHeartbeat(interval: .seconds(30))
        sync.startHeartbeat(interval: .seconds(30))
        try await waitUntil { client.authRefreshCount >= 1 }
        sync.stopHeartbeat()

        // two starts, one running task: only the immediate verify ran
        #expect(client.authRefreshCount == 1)
    }

    /// poll a condition for up to ~1s so detached backfill tasks can settle
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
