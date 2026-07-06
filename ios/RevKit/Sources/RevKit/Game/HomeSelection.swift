import Foundation

/// home-hex selection rules (REF: docs/game-design.md §Home Hex)
public enum HomeSelection {
    /// a chosen home cell is eligible only if it isn't already another player's home hex
    public static func isEligible(_ cell: UInt64, existingHomes: Set<UInt64>) -> Bool {
        !existingHomes.contains(cell)
    }

    /// a home must sit inside the Chicago play area: the server's home-tile sync
    /// silently skips out-of-bounds cells, leaving a local-only phantom home hex
    public static func isWithinPlayArea(_ cell: UInt64) -> Bool {
        Geofence.containsCell(cell)
    }
}
