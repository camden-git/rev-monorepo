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
    /// Score Metric v2 claim strength at claim time
    public var claimScore: Double
    /// EWMA raw mph reference speed for this tile
    public var refSpeed: Double
    /// number of raw speed observations folded into `refSpeed`
    public var obsCount: Int
    /// lifetime ownership changes, used for tile value
    public var captures: Int
    public var lastDrivenAt: Date
    public var isHome: Bool

    public init(
        h3: UInt64,
        ownerId: String,
        claimScore: Double,
        refSpeed: Double = Strength.referenceSpeedPrior,
        obsCount: Int = 0,
        captures: Int = 0,
        lastDrivenAt: Date,
        isHome: Bool
    ) {
        self.h3 = Int64(h3: h3)
        self.ownerId = ownerId
        self.claimScore = claimScore
        self.refSpeed = refSpeed
        self.obsCount = obsCount
        self.captures = captures
        self.lastDrivenAt = lastDrivenAt
        self.isHome = isHome
    }

    public var cellId: UInt64 { h3.h3Cell }
}
