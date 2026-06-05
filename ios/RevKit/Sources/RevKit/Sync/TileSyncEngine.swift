import Foundation

/// persisted "last successful sync" watermark for the delta-poll
public protocol SyncCursor: AnyObject, Sendable {
    var lastSync: Date? { get set }
}

/// in-memory cursor for tests
public final class InMemorySyncCursor: SyncCursor, @unchecked Sendable {
    public var lastSync: Date?
    public init(lastSync: Date? = nil) { self.lastSync = lastSync }
}

/// `UserDefaults` backed cursor
public final class UserDefaultsSyncCursor: SyncCursor, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "rev.tileSync.lastSync") {
        self.defaults = defaults
        self.key = key
    }

    public var lastSync: Date? {
        get { defaults.object(forKey: key) as? Date }
        set {
            if let newValue { defaults.set(newValue, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
    }
}

/// foreground delta-poll, fetches tiles changed since the last sync and merges
/// the server's authoritative state into the `TerritoryStore`
@MainActor
public final class TileSyncEngine {
    private let client: PocketBaseClient
    private let store: TerritoryStore
    private let cursor: SyncCursor

    public init(client: PocketBaseClient, store: TerritoryStore, cursor: SyncCursor) {
        self.client = client
        self.store = store
        self.cursor = cursor
    }

    /// pull the delta and apply it
    @discardableResult
    public func sync() async throws -> Int {
        let tiles = try await client.listTiles(updatedSince: cursor.lastSync)
        store.applyRemoteTiles(tiles)
        if let newest = tiles.map(\.updated).max() {
            cursor.lastSync = newest
        }
        return tiles.count
    }

    @discardableResult
    public func sync(h3Cells: Set<UInt64>) async throws -> Int {
        let tiles = try await client.listTiles(h3Cells: h3Cells)
        store.applyRemoteTiles(tiles)
        return tiles.count
    }
}
