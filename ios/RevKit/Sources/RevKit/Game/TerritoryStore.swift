import Observation

/// an n-memory, single-player territory state for the local-only slice
/// holds the set of claimed H3 cell indices
/// at some point this should be using SwiftData but ill deal w/ that later
@MainActor
@Observable
public final class TerritoryStore {
    public private(set) var claimedCells: Set<UInt64> = []

    public init() {}

    public func claim(_ cellIndex: UInt64) {
        claimedCells.insert(cellIndex)
    }

    public func isClaimed(_ cellIndex: UInt64) -> Bool {
        claimedCells.contains(cellIndex)
    }
}
