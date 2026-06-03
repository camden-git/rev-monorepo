import Observation

/// in-memory, single-player territory state for the local-only slice. maps each owned H3 cell to
/// its claim score (mph)
///
/// SwiftData will go here soon REF: docs/tech-stack.md §Local Storage
@MainActor
@Observable
public final class TerritoryStore {
    /// owned cells -> claim score (mph) current assumption is single player so every key is ours
    public private(set) var tiles: [UInt64: Double] = [:]

    public var claimedCells: Set<UInt64> { Set(tiles.keys) }

    public init() {}

    /// claim a cell for the local player
    ///
    /// changes will be neeeded here to enforce game rules
    /// REF: docs/game-design.md §Claiming Territory
    public func claim(_ cellIndex: UInt64, score: Double = 0) {
        tiles[cellIndex] = max(tiles[cellIndex] ?? 0, score)
    }

    public func isClaimed(_ cellIndex: UInt64) -> Bool {
        tiles[cellIndex] != nil
    }
}
