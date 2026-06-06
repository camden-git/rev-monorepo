import Foundation
#if canImport(os)
import os
#endif
import SwiftData

public enum SyncErrorKind: Equatable, Sendable {
    case authenticationRequired
    case missingSession
    case unavailable
    case server
    case response
    case unknown
}

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
    public private(set) var lastErrorKind: SyncErrorKind?
    public private(set) var lastDebugMessage: String?
    public private(set) var isRestoringSession = false
    private var attemptedSessionRestore = false
    private var currentVisibleTileCells: Set<UInt64> = []
    private var currentVisibleTileParents: Set<UInt64> = []

    #if canImport(os)
    private let logger = Logger(subsystem: "app.driverev.RevKit", category: "SyncService")
    #endif

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
    public var requiresSignIn: Bool {
        lastErrorKind == .authenticationRequired || lastErrorKind == .missingSession
    }
    public var canRetrySessionRestore: Bool {
        currentUserId == nil && tokenStore.load() != nil && !isRestoringSession && !requiresSignIn
    }

    /// adopt a session from an external auth flow (e.g. Sign in with Apple)
    /// reconciles the local player's local id onto the authenticated PocketBase
    /// user id so offline-claimed tiles dedupe with the server's view of "me"
    public func adoptSession(_ response: AuthResponse) {
        tokenStore.save(response.token)
        currentUserId = response.record.id
        attemptedSessionRestore = true
        lastErrorKind = nil
        store.reconcileLocalIdentity(to: response.record.id)
        if let name = response.record.displayName { store.setLocalDisplayName(name) }
    }

    /// roster + profile refresh to run after any successful sign-in:
    public func refreshAfterSignIn() async {
        guard await pushProfile() else { return }
        await syncRoster()
    }

    public func restoreSessionIfPossible() async {
        guard !attemptedSessionRestore, currentUserId == nil, tokenStore.load() != nil else { return }
        await restoreStoredSession()
    }

    public func retrySessionRestore() async {
        guard canRetrySessionRestore else { return }
        await restoreStoredSession()
    }

    private func restoreStoredSession() async {
        attemptedSessionRestore = true
        isRestoringSession = true
        defer { isRestoringSession = false }
        do {
            let response = try await client.authRefresh()
            adoptSession(response)
            lastError = nil
            lastErrorKind = nil
            lastDebugMessage = nil
            await refreshAfterSignIn()
        } catch {
            recordSyncFailure(error, operation: "restoreSession")
        }
    }

    public func signInWithInvite(displayName: String, email: String, code: String) async {
        do {
            let response = try await client.authWithInvite(displayName: displayName, email: email, code: code)
            adoptSession(response)
            lastError = nil
            lastErrorKind = nil
            lastDebugMessage = nil
            await refreshAfterSignIn()
        } catch {
            recordSyncFailure(error, operation: "signInWithInvite")
        }
    }

    /// upload every locally-recorded drive that hasn't synced yet, then refresh
    /// tiles so the provisional local state is reconciled with the server
    public func uploadPending() async {
        guard currentUserId != nil else { return }
        let source = SwiftDataDriveSource(context: context)
        let queue = DriveUploadQueue(client: client, source: source)
        let result = await queue.drain()
        if let error = result.error {
            recordSyncFailure(error, operation: "uploadPending")
            return
        }
        if result.uploaded > 0, !currentVisibleTileCells.isEmpty {
            await pollVisibleTiles(h3Cells: currentVisibleTileCells, force: true)
        }
    }

    /// foreground delta-poll
    public func pollTiles() async {
        do {
            _ = try await TileSyncEngine(client: client, store: store, cursor: cursor).sync()
            lastError = nil
            lastErrorKind = nil
            lastDebugMessage = nil
        } catch {
            recordSyncFailure(error, operation: "pollTiles", visible: false)
            return
        }
        await syncRoster()
    }

    /// map-window tile refresh, driven by the visible H3 cells plus padding
    public func pollVisibleTiles(h3Cells: Set<UInt64>, force: Bool = false) async {
        guard !h3Cells.isEmpty else { return }
        let parents = H3Grid.tileWindowParentIds(for: h3Cells)
        guard !parents.isEmpty else { return }
        if !force, parents == currentVisibleTileParents {
            currentVisibleTileCells = h3Cells
            return
        }
        currentVisibleTileCells = h3Cells
        currentVisibleTileParents = parents
        do {
            _ = try await TileSyncEngine(client: client, store: store, cursor: cursor).sync(h3Cells: h3Cells)
            lastError = nil
            lastErrorKind = nil
            lastDebugMessage = nil
        } catch {
            recordSyncFailure(error, operation: "pollVisibleTiles", visible: false)
        }
    }

    /// pull the player roster into the local `Player` table
    public func syncRoster() async {
        guard currentUserId != nil else { return }
        do {
            let players = try await client.listUsers()
            store.applyRemotePlayers(players)
            lastError = nil
            lastErrorKind = nil
            lastDebugMessage = nil
        } catch {
            recordSyncFailure(error, operation: "syncRoster", visible: false)
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
            lastErrorKind = nil
            lastDebugMessage = nil
            return true
        } catch {
            recordSyncFailure(error, operation: "pushProfile")
            return false
        }
    }

    public func signOut() {
        clearSession()
        lastError = nil
        lastErrorKind = nil
        lastDebugMessage = nil
    }

    #if DEBUG
    /// local dev sign-in against the seeded `dev@test.driverev.app` user
    public func devSignIn(identity: String = "dev@test.driverev.app", password: String = "driverev") async {
        do {
            let response = try await client.authWithPassword(identity: identity, password: password)
            adoptSession(response)
            lastError = nil
            lastErrorKind = nil
            lastDebugMessage = nil
            await refreshAfterSignIn()
        } catch {
            recordSyncFailure(error, operation: "devSignIn")
        }
    }
    #endif

    private func recordSyncFailure(_ error: Error, operation: String, visible: Bool = true) {
        let authFailure = isAuthenticationFailure(error)
        if authFailure {
            clearSession()
        }
        let kind = errorKind(for: error)
        let debugMessage = debugMessage(for: error, operation: operation, kind: kind)
        lastDebugMessage = debugMessage
        logSyncFailure(debugMessage)

        guard visible || authFailure else { return }
        lastErrorKind = kind
        lastError = userFacingMessage(for: error)
    }

    private func clearSession() {
        tokenStore.clear()
        currentUserId = nil
    }

    private func isAuthenticationFailure(_ error: Error) -> Bool {
        guard let pocketBaseError = error as? PocketBaseError else { return false }
        switch pocketBaseError {
        case .notAuthenticated:
            return true
        case .http(let status, _):
            return status == 401 || status == 403
        case .decoding, .invalidResponse:
            return false
        }
    }

    private func userFacingMessage(for error: Error) -> String {
        if let pocketBaseError = error as? PocketBaseError, pocketBaseError == .notAuthenticated {
            return "Sign in to keep syncing."
        }
        if isAuthenticationFailure(error) {
            return "Your session expired. Sign in again to keep syncing."
        }
        if let pocketBaseError = error as? PocketBaseError {
            switch pocketBaseError {
            case .http(let status, _):
                return "Server error \(status). Your local progress is saved."
            case .decoding:
                return "Sync failed because the server response was unexpected."
            case .invalidResponse:
                return "Sync failed because the server response was invalid."
            case .notAuthenticated:
                return "Sign in to keep syncing."
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .timedOut:
                return "Server unreachable. Your local progress is saved."
            default:
                break
            }
        }
        return "Sync failed. Try again in a moment."
    }

    private func errorKind(for error: Error) -> SyncErrorKind {
        if let pocketBaseError = error as? PocketBaseError {
            switch pocketBaseError {
            case .notAuthenticated:
                return .missingSession
            case .http:
                if isAuthenticationFailure(error) {
                    return .authenticationRequired
                }
                return .server
            case .decoding, .invalidResponse:
                return .response
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .timedOut, .cannotFindHost, .dnsLookupFailed:
                return .unavailable
            default:
                return .unknown
            }
        }
        return .unknown
    }

    private func debugMessage(for error: Error, operation: String, kind: SyncErrorKind) -> String {
        "operation=\(operation) kind=\(kind) error=\(debugDescription(for: error))"
    }

    private func debugDescription(for error: Error) -> String {
        if let pocketBaseError = error as? PocketBaseError {
            switch pocketBaseError {
            case .http(let status, let body):
                return "PocketBase HTTP \(status) body=\(body)"
            case .notAuthenticated:
                return "PocketBase request missing auth token"
            case .decoding(let message):
                return "PocketBase decode failure \(message)"
            case .invalidResponse:
                return "PocketBase invalid HTTP response"
            }
        }
        if let urlError = error as? URLError {
            return "URLError \(urlError.code.rawValue) \(urlError.localizedDescription)"
        }
        return String(describing: error)
    }

    private func logSyncFailure(_ message: String) {
        #if canImport(os)
        logger.error("\(message, privacy: .public)")
        #else
        print("SyncService failure: \(message)")
        #endif
    }
}
