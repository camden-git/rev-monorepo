import Foundation
import SwiftData

/// entry point to backend
@MainActor
@Observable
public final class SyncService {
    private let store: TerritoryStore
    private let context: ModelContext
    private let client: PocketBaseClient
    private let tokenStore: TokenStore
    private let cursor: SyncCursor

    /// authenticated PocketBase user id, or nil when signed out
    public private(set) var currentUserId: String?
    public private(set) var lastError: String?
    private var attemptedSessionRestore = false

    public convenience init(
        store: TerritoryStore,
        context: ModelContext,
        config: PocketBaseConfig,
        tokenStore: TokenStore = InMemoryTokenStore(),
        cursor: SyncCursor = InMemorySyncCursor()
    ) {
        self.init(
            store: store,
            context: context,
            client: URLSessionPocketBaseClient(config: config, tokenStore: tokenStore),
            tokenStore: tokenStore,
            cursor: cursor
        )
    }

    /// designated init taking an explicit client (enables mock-client tests)
    init(
        store: TerritoryStore,
        context: ModelContext,
        client: PocketBaseClient,
        tokenStore: TokenStore = InMemoryTokenStore(),
        cursor: SyncCursor = InMemorySyncCursor()
    ) {
        self.store = store
        self.context = context
        self.tokenStore = tokenStore
        self.cursor = cursor
        self.client = client
    }

    public var isSignedIn: Bool { currentUserId != nil }

    /// adopt a session from an external auth flow (e.g. Sign in with Apple)
    /// reconciles the local player's seeded id onto the authenticated PocketBase
    /// user id so offline-claimed tiles dedupe with the server's view of "me".
    public func adoptSession(_ response: AuthResponse) {
        tokenStore.save(response.token)
        currentUserId = response.record.id
        store.reconcileLocalIdentity(to: response.record.id)
        if let name = response.record.displayName { store.setLocalDisplayName(name) }
    }

    /// roster + profile refresh to run after any successful sign-in:
    public func refreshAfterSignIn() async {
        await pushProfile()
        await syncRoster()
    }

    public func restoreSessionIfPossible() async {
        guard !attemptedSessionRestore, currentUserId == nil, tokenStore.load() != nil else { return }
        attemptedSessionRestore = true
        do {
            let response = try await client.authRefresh()
            adoptSession(response)
            lastError = nil
            await refreshAfterSignIn()
        } catch {
            tokenStore.clear()
            lastError = String(describing: error)
        }
    }

    public func signInWithInvite(displayName: String, email: String, code: String) async {
        do {
            let response = try await client.authWithInvite(displayName: displayName, email: email, code: code)
            adoptSession(response)
            lastError = nil
            await refreshAfterSignIn()
        } catch {
            lastError = String(describing: error)
        }
    }

    /// upload every locally-recorded drive that hasn't synced yet, then refresh
    /// tiles so the provisional local state is reconciled with the server
    public func uploadPending() async {
        guard let userId = currentUserId else { return }
        let source = SwiftDataDriveSource(context: context, userID: userId)
        let queue = DriveUploadQueue(client: client, source: source)
        let result = await queue.drain()
        if result.uploaded > 0 { await pollTiles() }
    }

    /// foreground delta-poll
    public func pollTiles() async {
        do {
            _ = try await TileSyncEngine(client: client, store: store, cursor: cursor).sync()
            lastError = nil
        } catch {
            lastError = String(describing: error)
            return
        }
        await syncRoster()
    }

    /// pull the player roster into the local `Player` table
    public func syncRoster() async {
        guard currentUserId != nil else { return }
        do {
            let players = try await client.listUsers()
            store.applyRemotePlayers(players)
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    /// push the local player's profile (home hex, color, name) to their server
    /// user record so the roster reflects it
    @discardableResult
    public func pushProfile() async -> Bool {
        guard let userId = currentUserId else { return true }
        let local = store.localPlayer
        do {
            try await client.updateProfile(
                userId: userId,
                homeH3: local.homeCell,
                color: local.colorHex,
                displayName: local.displayName
            )
            lastError = nil
            return true
        } catch {
            lastError = String(describing: error)
            return false
        }
    }

    #if DEBUG
    /// local dev sign-in against the seeded `dev@test.driverev.app` user
    public func devSignIn(identity: String = "dev@test.driverev.app", password: String = "driverev") async {
        do {
            let response = try await client.authWithPassword(identity: identity, password: password)
            adoptSession(response)
            lastError = nil
            await refreshAfterSignIn()
        } catch {
            lastError = String(describing: error)
        }
    }
    #endif
}
