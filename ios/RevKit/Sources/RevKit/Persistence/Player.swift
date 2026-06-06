import Foundation
import SwiftData

/// a local player (mirrors the server `users` collection - REF: docs/tech-stack.md
/// §Local Storage Model). the local player is created on first launch, opponents
/// arrive from roster sync
@Model
public final class Player {
    @Attribute(.unique) public var id: String
    public var displayName: String
    /// home hex (H3 id) stored as Int64 bit-pattern; see `h3Cell`.
    public var homeH3: Int64
    /// hex color string (e.g. "#3B82F6") for the map overlay fill.
    public var colorHex: String
    public var isLocal: Bool

    public init(
        id: String = UUID().uuidString,
        displayName: String,
        homeH3: UInt64,
        colorHex: String,
        isLocal: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.homeH3 = Int64(h3: homeH3)
        self.colorHex = colorHex
        self.isLocal = isLocal
    }

    public var homeCell: UInt64 { homeH3.h3Cell }
}
