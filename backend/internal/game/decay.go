package game

import (
	"math"
	"time"
)

// Tau is the decay time constant (REF: docs/game-design.md §Time Decay)
// port of RevKit Decay.tau
const Tau = 3 * 7 * 24 * 60 * 60 // seconds

// EffectiveScore returns claimScore * exp(-Δt/τ)
// port of RevKit's Decay.effectiveScore
func EffectiveScore(claimScore float64, lastDrivenAt, now time.Time) float64 {
	delta := now.Sub(lastDrivenAt).Seconds()
	if delta < 0 {
		delta = 0
	}
	return claimScore * math.Exp(-delta/Tau)
}
