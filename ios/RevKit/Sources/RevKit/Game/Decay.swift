import Foundation

/// time decay of a tile's stored claim score (REF: docs/game-design.md §Time Decay)
public enum Decay {
    /// decay time constant, τ (tau)
    public static let tau: TimeInterval = 3 * 7 * 24 * 60 * 60 // = aprox. 3 weeks

    /// `claim_score * exp(-Δt/τ)`
    public static func effectiveScore(claimScore: Double, lastDrivenAt: Date, now: Date) -> Double {
        let delta = max(0, now.timeIntervalSince(lastDrivenAt))
        return claimScore * exp(-delta / tau)
    }
}
