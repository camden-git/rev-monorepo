package game

import "math"

const (
	ReferenceSpeedPrior = 25.0
	ReferenceSpeedFloor = 5.0
	ReferenceAlpha      = 0.2
	StrengthCap         = 5.0
	ValueGamma          = 0.5
)

// Strength converts a raw in-tile speed in mph into the dimensionless claim
// strength used for stored tile scores in Score Metric v2.
func Strength(speedMph, refSpeed float64) float64 {
	if !validNonNegative(speedMph) || speedMph == 0 {
		return 0
	}
	ref := normalizedRef(refSpeed)
	strength := speedMph / math.Max(ref, ReferenceSpeedFloor)
	return math.Min(strength, StrengthCap)
}

// UpdateReference applies the EWMA reference-speed learning step for one in-tile
// speed observation.
func UpdateReference(refSpeed, speedMph float64) float64 {
	ref := normalizedRef(refSpeed)
	if !validNonNegative(speedMph) {
		return ref
	}
	return ref + ReferenceAlpha*(speedMph-ref)
}

// TileValue is the leaderboard weight for a tile based on lifetime ownership
// changes.
func TileValue(captures int) float64 {
	if captures <= 0 {
		return 1
	}
	return 1 + ValueGamma*math.Log1p(float64(captures))
}

func normalizedRef(refSpeed float64) float64 {
	if !validNonNegative(refSpeed) || refSpeed == 0 {
		return ReferenceSpeedPrior
	}
	return refSpeed
}

func validNonNegative(v float64) bool {
	return !math.IsNaN(v) && !math.IsInf(v, 0) && v >= 0
}
