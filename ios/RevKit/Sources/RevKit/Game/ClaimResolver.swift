import Foundation

/// direct-claim resolution (REF: docs/game-design.md §Direct Claims, §Re-Drive Floor,
/// §Home Hex)
public enum ClaimResolver {
    /// snapshot of a tile's current state
    public struct TileState: Equatable, Sendable {
        public var ownerId: String
        public var claimScore: Double
        public var lastDrivenAt: Date
        public var isHome: Bool

        public init(ownerId: String, claimScore: Double, lastDrivenAt: Date, isHome: Bool) {
            self.ownerId = ownerId
            self.claimScore = claimScore
            self.lastDrivenAt = lastDrivenAt
            self.isHome = isHome
        }
    }

    /// outcome of resolving an incoming claim. `score` is the new stored claim score
    public enum ClaimOutcome: Equatable, Sendable {
        case noChange
        case created(score: Double)
        case reinforced(score: Double)
        case captured(score: Double)
    }

    /// resolve a single tile claim
    ///
    /// - unowned tile -> `.created` (first traversal claims it at the driver's score)
    /// - home hex -> `.noChange` (inviolable by direct drive)
    /// - your own tile -> `.reinforced(max(current, new))` (re-drive floor)
    /// - someone else's tile -> compare against its decayed score; `>=` flips it
    ///   (`.captured`), ties last-write-wins otherwise `.noChange`
    public static func resolve(
        current: TileState?,
        claimantId: String,
        incomingScore: Double,
        now: Date
    ) -> ClaimOutcome {
        guard let current else {
            return .created(score: incomingScore)
        }
        if current.isHome {
            return .noChange
        }
        if current.ownerId == claimantId {
            return .reinforced(score: max(current.claimScore, incomingScore))
        }
        let effective = Decay.effectiveScore(
            claimScore: current.claimScore,
            lastDrivenAt: current.lastDrivenAt,
            now: now
        )
        if incomingScore >= effective {
            return .captured(score: incomingScore)
        }
        return .noChange
    }
}
