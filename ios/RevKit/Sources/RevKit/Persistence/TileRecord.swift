import Foundation
import SwiftData

/// a claimed tile (mirrors the server `tiles` collection: REF: docs/tech-stack.md
/// §Local Storage Model)
/// this is what will eventually be server side
@Model
public final class TileRecord {
    /// H3 cell id stored as Int64 bit-pattern
    @Attribute(.unique) public var h3: Int64
    public var ownerId: String
    /// distance-weighted average speed (mph) at claim time
    public var claimScore: Double
    public var lastDrivenAt: Date
    public var isHome: Bool

    public init(
        h3: UInt64,
        ownerId: String,
        claimScore: Double,
        lastDrivenAt: Date,
        isHome: Bool
    ) {
        self.h3 = Int64(h3: h3)
        self.ownerId = ownerId
        self.claimScore = claimScore
        self.lastDrivenAt = lastDrivenAt
        self.isHome = isHome
    }

    public var cellId: UInt64 { h3.h3Cell }
}
