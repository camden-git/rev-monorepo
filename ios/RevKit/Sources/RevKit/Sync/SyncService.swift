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

    public init(
        store: TerritoryStore,
        context: ModelContext,
        config: PocketBaseConfig,
        tokenStore: TokenStore = InMemoryTokenStore(),
        cursor: SyncCursor = InMemorySyncCursor()
    ) {
        self.store = store
        self.context = context
        self.tokenStore = tokenStore
        self.cursor = cursor
        self.client = URLSessionPocketBaseClient(config: config, tokenStore: tokenStore)
    }

    public var isSignedIn: Bool { currentUserId != nil }

    /// adopt a session from an external auth flow (e.g. Sign in with Apple)
    public func adoptSession(_ response: AuthResponse) {
        tokenStore.save(response.token)
        currentUserId = response.record.id
    }

    public func restoreSessionIfPossible() async {
        guard !attemptedSessionRestore, currentUserId == nil, tokenStore.load() != nil else { return }
        attemptedSessionRestore = true
        do {
            let response = try await client.authRefresh()
            adoptSession(response)
            lastError = nil
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
        }
    }

    #if DEBUG
    /// local dev sign-in against the seeded `dev@test.driverev.app` user
    public func devSignIn(identity: String = "dev@test.driverev.app", password: String = "driverev") async {
        do {
            let response = try await client.authWithPassword(identity: identity, password: password)
            adoptSession(response)
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }
    #endif
}
