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

    @Test func fullResyncPrunesLocalTilesAbsentFromServer() async throws {
        let store = makeStore()
        let stale = SyncFixtures.cell &+ 8001
        let live = SyncFixtures.cell &+ 8002
        store.claim(stale, score: 15)
        store.claim(live, score: 15)

        let client = MockPocketBaseClient()
        let updated = Date(timeIntervalSince1970: 1_700_002_000)
        client.onListTiles = { _ in [makeTileDTO(live, owner: "srv", score: 99, updated: updated)] }

        let cursor = InMemorySyncCursor()
        let count = try await TileSyncEngine(client: client, store: store, cursor: cursor).fullResync()

        #expect(count == 1)
        #expect(store.tiles[stale] == nil)                // pruned: the backend no longer has it
        #expect(store.tiles[live]?.ownerId == "srv")      // reconciled onto the server's view
        #expect(client.listSinceArgs.last == .some(nil))  // full pull
        #expect(cursor.lastSync == updated)               // cursor re-armed for later deltas
    }

    @Test func sessionRestorePrunesStaleLocalTilesAfterBackendReset() async throws {
        let store = makeStore()
        let stale = SyncFixtures.cell &+ 8003 // cached from before the backend was reset
        store.claim(stale, score: 20)
        #expect(store.tiles[stale] != nil)

        let client = MockPocketBaseClient()
        client.onAuthRefresh = {
            AuthResponse(token: "t", record: AuthUserDTO(id: "me", email: nil, displayName: "Cam"))
        }
        client.onListTiles = { _ in [] } // backend tiles collection was wiped

        let sync = SyncService(
            store: store,
            context: Self.container.mainContext,
            client: client,
            tokenStore: InMemoryTokenStore(token: "stored"),
            cursor: InMemorySyncCursor()
        )
        await sync.restoreSessionIfPossible()

        #expect(sync.currentUserId == "me")
        #expect(store.tiles[stale] == nil) // backend-authoritative, stale cache pruned on relaunch
    }

    @Test func reconcileTilesKeepsCacheWhenFetchFails() async throws {
        let store = makeStore()
        let cell = SyncFixtures.cell &+ 8004
        store.claim(cell, score: 20)

        let client = MockPocketBaseClient()
        client.onListTiles = { _ in throw URLError(.notConnectedToInternet) }

        let sync = SyncService(
            store: store,
            context: Self.container.mainContext,
            client: client,
            tokenStore: InMemoryTokenStore(),
            cursor: InMemorySyncCursor()
        )
        sync.adoptSession(AuthResponse(token: "tok", record: AuthUserDTO(id: "me", email: nil, displayName: nil)))

        await sync.reconcileTiles()

        #expect(store.tiles[cell] != nil) // offline reconcile must not prune the cache
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

    @Test func visibleCellSyncFetchesOnlyRequestedCellsWithoutAdvancingCursor() async throws {
        let store = makeStore()
        let client = MockPocketBaseClient()
        let cell = SyncFixtures.cell &+ 7100
        let updated = Date(timeIntervalSince1970: 1_700_001_000)
        client.onListTilesForCells = { cells in
            cells.contains(cell) ? [makeTileDTO(cell, owner: "visible-rival", score: 12, updated: updated)] : []
        }

        let cursor = InMemorySyncCursor(lastSync: Date(timeIntervalSince1970: 1_700_000_000))
        let engine = TileSyncEngine(client: client, store: store, cursor: cursor)
        let count = try await engine.sync(h3Cells: [cell])

        #expect(count == 1)
        #expect(client.listCellArgs.last == [cell])
        #expect(cursor.lastSync == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(store.tiles[cell]?.ownerId == "visible-rival")
    }

    // MARK: identity reconciliation

    @Test func reconcileLocalIdentityRepointsLocalTiles() async throws {
        let store = makeStore()
        let oldId = store.localPlayer.id
        let cell = SyncFixtures.cell &+ 7001
        store.claim(cell, score: 30) // owned by the local player under its pre-sign-in id
        #expect(store.tiles[cell]?.ownerId == oldId)

        let serverId = "srv-\(UUID().uuidString)"
        store.reconcileLocalIdentity(to: serverId)

        #expect(store.localPlayer.id == serverId)
        #expect(store.tiles[cell]?.ownerId == serverId)        // tile follows the new identity
        #expect(store.owner(of: cell)?.id == serverId)         // resolves to the local player
        #expect(store.cells(ownedBy: oldId).isEmpty)           // nothing left under the stale id
    }

    @Test func reconcileLocalIdentityIsNoOpWhenAlreadyServerId() async throws {
        let store = makeStore()
        let current = store.localPlayer.id
        store.reconcileLocalIdentity(to: current)
        #expect(store.localPlayer.id == current)
    }

    // MARK: roster

    @Test func applyRemotePlayersInsertsAndResolvesOpponent() async throws {
        let store = makeStore()
        let rivalId = "rival-\(UUID().uuidString)"
        store.applyRemotePlayers([makePlayerDTO(rivalId, name: "Zoe", color: "#123456")])

        let cell = SyncFixtures.cell &+ 7002
        store.claim(cell, score: 10, by: rivalId) // tile owned by the remote player

        let owner = try #require(store.owner(of: cell))
        #expect(owner.id == rivalId)
        #expect(owner.displayName == "Zoe")     // name now resolvable for tap-inspect
        #expect(owner.colorHex == "#123456")    // colour now resolvable for the overlay
    }

    @Test func applyRemotePlayersUpdatesExistingInPlace() async throws {
        let store = makeStore()
        let id = "rival2-\(UUID().uuidString)"
        store.applyRemotePlayers([makePlayerDTO(id, name: "Old", color: "#000000")])
        store.applyRemotePlayers([makePlayerDTO(id, name: "New", color: "#FFFFFF", homeH3: SyncFixtures.cell)])

        let p = try #require(store.player(id: id))
        #expect(p.displayName == "New")
        #expect(p.colorHex == "#FFFFFF")
        #expect(p.homeCell == SyncFixtures.cell)
        #expect(store.players.filter { $0.id == id }.count == 1) // updated, not duplicated
    }

    @Test func applyRemotePlayersDoesNotClearExistingHomeWithRemoteZero() async throws {
        let store = makeStore()
        let id = "rival3-\(UUID().uuidString)"
        let home = SyncFixtures.cell &+ 7004
        store.applyRemotePlayers([makePlayerDTO(id, name: "Old", color: "#000000", homeH3: home)])
        store.applyRemotePlayers([makePlayerDTO(id, name: "New", color: "#FFFFFF", homeH3: 0)])

        let p = try #require(store.player(id: id))
        #expect(p.displayName == "New")
        #expect(p.colorHex == "#FFFFFF")
        #expect(p.homeCell == home)
    }

    // MARK: sign-in lifecycle (mock client)

    @Test func signInReconcilesIdentitySyncsRosterAndPushesProfile() async throws {
        let store = makeStore()
        let cell = SyncFixtures.cell &+ 7003
        store.claim(cell, score: 25) // local tile under the pre-sign-in id

        let serverId = "me-\(UUID().uuidString)"
        let rivalId = "rin-\(UUID().uuidString)"
        let client = MockPocketBaseClient()
        client.onInviteAuth = { _, _, _ in
            AuthResponse(token: "t", record: AuthUserDTO(id: serverId, email: nil, displayName: "Cam"))
        }
        client.onListUsers = { [makePlayerDTO(rivalId, name: "Rin", color: "#ABCDEF")] }

        let sync = SyncService(
            store: store,
            context: Self.container.mainContext,
            client: client,
            tokenStore: InMemoryTokenStore(),
            cursor: InMemorySyncCursor()
        )
        await sync.signInWithInvite(displayName: "Cam", email: "c@e.com", code: "x")

        #expect(sync.currentUserId == serverId)
        #expect(store.localPlayer.id == serverId)                 // reconciled onto the PB id
        #expect(store.localPlayer.displayName == "Cam")           // name adopted from the session
        #expect(store.tiles[cell]?.ownerId == serverId)           // offline-claimed tile re-pointed
        #expect(store.player(id: rivalId)?.colorHex == "#ABCDEF") // roster synced
        #expect(client.profileUpdates.last?.userId == serverId)   // own profile pushed back
    }

    @Test func signInPushesLocalHomeBeforeRosterCanApplyRemoteZero() async throws {
        let store = makeStore()
        let home = SyncFixtures.cell &+ 7005
        store.establishHome(at: home)

        let serverId = "home-\(UUID().uuidString)"
        let client = MockPocketBaseClient()
        client.onInviteAuth = { _, _, _ in
            AuthResponse(token: "t", record: AuthUserDTO(id: serverId, email: nil, displayName: "Cam"))
        }
        client.onListUsers = { [makePlayerDTO(serverId, name: "Cam", color: "#3B82F6", homeH3: 0)] }

        let sync = SyncService(
            store: store,
            context: Self.container.mainContext,
            client: client,
            tokenStore: InMemoryTokenStore(),
            cursor: InMemorySyncCursor()
        )
        await sync.signInWithInvite(displayName: "Cam", email: "c@e.com", code: "x")

        #expect(store.localPlayer.homeCell == home)
        #expect(client.profileUpdates.first?.homeH3 == home)
    }

    @Test func signedOutPollSkipsRosterSync() async throws {
        let store = makeStore()
        let client = MockPocketBaseClient()

        let sync = SyncService(
            store: store,
            context: Self.container.mainContext,
            client: client,
            tokenStore: InMemoryTokenStore(),
            cursor: InMemorySyncCursor()
        )
        await sync.pollTiles()

        #expect(client.listUsersCallCount == 0)
        #expect(sync.lastError == nil)
    }

    @Test func rosterFailureAfterTilePollIsDebugOnly() async throws {
        let store = makeStore()
        let client = MockPocketBaseClient()
        client.onListTiles = { _ in [] }
        client.onListUsers = {
            throw PocketBaseError.decoding("missing display_name")
        }
        let sync = SyncService(
            store: store,
            context: Self.container.mainContext,
            client: client,
            tokenStore: InMemoryTokenStore(),
            cursor: InMemorySyncCursor()
        )
        sync.adoptSession(AuthResponse(token: "tok", record: AuthUserDTO(id: "u-debug", email: nil, displayName: nil)))

        await sync.pollTiles()

        #expect(sync.lastError == nil)
        #expect(sync.lastErrorKind == nil)
        #expect(sync.lastDebugMessage?.contains("operation=syncRoster") == true)
    }

    @Test func visibleTileFailureIsDebugOnlyUnlessAuthFails() async throws {
        let store = makeStore()
        let client = MockPocketBaseClient()
        client.onListTilesForCells = { _ in
            throw PocketBaseError.http(status: 500, body: "window failed")
        }
        let sync = SyncService(
            store: store,
            context: Self.container.mainContext,
            client: client,
            tokenStore: InMemoryTokenStore(),
            cursor: InMemorySyncCursor()
        )
        sync.adoptSession(AuthResponse(token: "tok", record: AuthUserDTO(id: "u-debug", email: nil, displayName: nil)))

        await sync.pollVisibleTiles(h3Cells: [SyncFixtures.cell])

        #expect(sync.lastError == nil)
        #expect(sync.lastErrorKind == nil)
        #expect(sync.lastDebugMessage?.contains("operation=pollVisibleTiles") == true)
    }

    @Test func invalidStoredSessionClearsTokenAndRequiresSignIn() async throws {
        let store = makeStore()
        let client = MockPocketBaseClient()
        client.onAuthRefresh = {
            throw PocketBaseError.http(status: 401, body: #"{"message":"The request requires valid record authorization token."}"#)
        }
        let tokenStore = InMemoryTokenStore(token: "stale-token")
        let sync = SyncService(
            store: store,
            context: Self.container.mainContext,
            client: client,
            tokenStore: tokenStore,
            cursor: InMemorySyncCursor()
        )

        await sync.restoreSessionIfPossible()

        #expect(sync.currentUserId == nil)
        #expect(tokenStore.load() == nil)
        #expect(sync.requiresSignIn)
        #expect(sync.lastError == "Your session expired. Sign in again to keep syncing.")
    }

    @Test func unavailableServerDuringSessionRestoreDoesNotRequireSignIn() async throws {
        let store = makeStore()
        let client = MockPocketBaseClient()
        client.onAuthRefresh = {
            throw URLError(.cannotConnectToHost)
        }
        let tokenStore = InMemoryTokenStore(token: "stored-token")
        let sync = SyncService(
            store: store,
            context: Self.container.mainContext,
            client: client,
            tokenStore: tokenStore,
            cursor: InMemorySyncCursor()
        )

        await sync.restoreSessionIfPossible()

        #expect(sync.currentUserId == nil)
        #expect(tokenStore.load() == "stored-token")
        #expect(!sync.requiresSignIn)
        #expect(sync.canRetrySessionRestore)
        #expect(sync.lastErrorKind == .unavailable)
        #expect(sync.lastError == "Server unreachable. Your local progress is saved.")
    }

    @Test func retrySessionRestoreAfterUnavailableServerCanRecover() async throws {
        let store = makeStore()
        let client = MockPocketBaseClient()
        let counter = Counter()
        client.onAuthRefresh = {
            if counter.next() == 0 {
                throw URLError(.cannotConnectToHost)
            }
            return AuthResponse(token: "fresh-token", record: AuthUserDTO(id: "u-restored", email: nil, displayName: "Cam"))
        }
        let tokenStore = InMemoryTokenStore(token: "stored-token")
        let sync = SyncService(
            store: store,
            context: Self.container.mainContext,
            client: client,
            tokenStore: tokenStore,
            cursor: InMemorySyncCursor()
        )

        await sync.restoreSessionIfPossible()
        await sync.retrySessionRestore()

        #expect(sync.currentUserId == "u-restored")
        #expect(tokenStore.load() == "fresh-token")
        #expect(!sync.requiresSignIn)
        #expect(!sync.canRetrySessionRestore)
        #expect(sync.lastError == nil)
        #expect(sync.lastErrorKind == nil)
    }

    @Test func authFailureDuringSyncInvalidatesCurrentSession() async throws {
        let store = makeStore()
        let client = MockPocketBaseClient()
        client.onListTiles = { _ in
            throw PocketBaseError.http(status: 403, body: #"{"message":"The request requires valid record authorization token."}"#)
        }
        let tokenStore = InMemoryTokenStore()
        let sync = SyncService(
            store: store,
            context: Self.container.mainContext,
            client: client,
            tokenStore: tokenStore,
            cursor: InMemorySyncCursor()
        )
        sync.adoptSession(AuthResponse(token: "bad-token", record: AuthUserDTO(id: "u-expired", email: nil, displayName: nil)))

        await sync.pollTiles()

        #expect(sync.currentUserId == nil)
        #expect(tokenStore.load() == nil)
        #expect(sync.requiresSignIn)
        #expect(client.listUsersCallCount == 0)
    }
}
