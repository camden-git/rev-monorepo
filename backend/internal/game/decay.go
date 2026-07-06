package game

import (
	"math"
	"time"
)

// Tau is the decay time constant (REF: docs/game-design.md §Time Decay)
// port of RevKit Decay.tau
const Tau = 3 * 7 * 24 * 60 * 60 // seconds

// ExpiryThreshold is the effective score below which ownership lapses
const ExpiryThreshold = 0.5

// Expired reports whether a tile's ownership has decayed away entirely
// port of RevKit Decay.expired
func Expired(claimScore float64, lastDrivenAt, now time.Time) bool {
	return EffectiveScore(claimScore, lastDrivenAt, now) < ExpiryThreshold
}

// EffectiveScore returns claimScore * exp(-Δt/τ)
// port of RevKit's Decay.effectiveScore
func EffectiveScore(claimScore float64, lastDrivenAt, now time.Time) float64 {
	delta := now.Sub(lastDrivenAt).Seconds()
	if delta < 0 {
		delta = 0
	}
	return claimScore * math.Exp(-delta/Tau)
}
