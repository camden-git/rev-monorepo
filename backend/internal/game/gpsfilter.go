package game

import (
	"math"
	"time"
)

// Sample is one raw GPS fix from a drive's raw_path
type Sample struct {
	TS       time.Time
	Lat      float64
	Lng      float64
	Speed    float64 // m/s as reported by CoreLocation, negative when invalid
	Accuracy float64 // horizontal accuracy in meters, negative when the fix is invalid
}

// GPS outlier-filter constants
const (
	// maxAcceleration is the implied-acceleration rejection threshold in m/s/s
	maxAcceleration = 9.80665
	// maxDopplerAcceleration is the plausibility threshold (m/s/s, ~1.5g) for a
	// jump in the device-reported Doppler speed between consecutive fixes. no
	// street vehicle sustains this, while a chip glitch jumps by hundreds
	maxDopplerAcceleration = 15.0
	// smoothingWindow is the centered moving-average width over the speed field
	smoothingWindow = 3
	// spikeExcursionMeters is how far a fix must fling from the path before it's
	// even considered a teleport spike
	spikeExcursionMeters = 50.0
	// spikeDetourRatio is how much longer the in-and-out detour through a fix
	// must be than the straight hop past it before it's treated as a spike
	spikeDetourRatio = 4.0
	// maxHorizontalAccuracyMeters is the coarsest fix worth trusting; beyond it
	// the position can be off far enough to manufacture phantom speed
	maxHorizontalAccuracyMeters = 35.0
)

// earthRadiusMeters is the mean Earth radius used for the server's haversine
// distance
const earthRadiusMeters = 6371000.0

// FilterOutliers cleans a raw GPS path before scoring
//  1. drop fixes the device flags as too inaccurate to trust
//  2. reject GPS teleport spikes by geometry
//  3. reject any sample implying >1g sustained acceleration vs. the prior retained sample
//  4. invalidate spike-shaped Doppler readings (the position filters above never
//     look at the reported speed, and it's the value scoring actually stores)
//  5. smooth the remaining samples' reported speeds
func FilterOutliers(samples []Sample) []Sample {
	samples = rejectLowAccuracy(samples)
	if len(samples) <= 2 {
		return samples
	}
	return smoothSpeeds(invalidateDopplerSpikes(rejectAccelerationOutliers(rejectPositionSpikes(samples))))
}

// rejectLowAccuracy drops fixes CoreLocation marks untrustworthy: a negative
// accuracy means the coordinate is invalid, a large one means the position can
// be far enough off that the distance to the next fix implies a speed that never
// happened
func rejectLowAccuracy(samples []Sample) []Sample {
	kept := make([]Sample, 0, len(samples))
	for _, s := range samples {
		if s.Accuracy < 0 || s.Accuracy > maxHorizontalAccuracyMeters {
			continue
		}
		kept = append(kept, s)
	}
	return kept
}

func rejectPositionSpikes(samples []Sample) []Sample {
	if len(samples) <= 2 {
		return samples
	}
	kept := []Sample{samples[0]}
	for i := 1; i < len(samples)-1; i++ {
		prev := kept[len(kept)-1]
		if isSpike(prev, samples[i], samples[i+1]) {
			continue
		}
		kept = append(kept, samples[i])
	}
	kept = append(kept, samples[len(samples)-1])

	// the first and last fixes have only one neighbour, so the detour test can't
	// triangulate them. fall back to a relative-speed check.
	if len(kept) > 2 && endpointIsSpike(kept[0], kept[1], kept[2]) {
		kept = kept[1:]
	}
	if len(kept) > 2 && endpointIsSpike(kept[len(kept)-1], kept[len(kept)-2], kept[len(kept)-3]) {
		kept = kept[:len(kept)-1]
	}
	return kept
}

// isSpike reports whether cur is a teleport spike between prev and next
func isSpike(prev, cur, next Sample) bool {
	excursion := distanceMeters(prev, cur)
	if excursion <= spikeExcursionMeters {
		return false
	}
	detour := excursion + distanceMeters(cur, next)
	direct := distanceMeters(prev, next)
	return detour > spikeDetourRatio*math.Max(direct, 1)
}

// endpointIsSpike reports whether endpoint a (with inward neighbours b then c)
// is an uncorroborated spike
func endpointIsSpike(a, b, c Sample) bool {
	dtAB := math.Abs(b.TS.Sub(a.TS).Seconds())
	dtBC := math.Abs(c.TS.Sub(b.TS).Seconds())
	if dtAB <= 0 || dtBC <= 0 {
		return false
	}
	excursion := distanceMeters(a, b)
	if excursion <= spikeExcursionMeters {
		return false
	}
	hopSpeed := excursion / dtAB
	trustedSpeed := distanceMeters(b, c) / dtBC
	return hopSpeed > spikeDetourRatio*math.Max(trustedSpeed, 1)
}

// rejectAccelerationOutliers drops any sample implying >1g sustained
// acceleration vs. the prior retained sample
func rejectAccelerationOutliers(samples []Sample) []Sample {
	if len(samples) <= 2 {
		return samples
	}
	retained := []Sample{samples[0]}
	var prevImpliedSpeed float64
	havePrev := false

	for _, candidate := range samples[1:] {
		anchor := retained[len(retained)-1]
		dt := candidate.TS.Sub(anchor.TS).Seconds()
		if dt <= 0 { // non-advancing timestamps are useless
			continue
		}
		impliedSpeed := distanceMeters(anchor, candidate) / dt
		if havePrev {
			acceleration := math.Abs(impliedSpeed-prevImpliedSpeed) / dt
			if acceleration > maxAcceleration {
				continue
			}
		}
		retained = append(retained, candidate)
		prevImpliedSpeed = impliedSpeed
		havePrev = true
	}
	return retained
}

// invalidateDopplerSpikes marks spike-shaped Doppler readings invalid (speed -1)
// so scoring falls back to position-derived speed there. a spike is implausible
// acceleration away from both neighbours while they agree with each other: a
// glitched chip reading, not hard driving, which moves all three together
func invalidateDopplerSpikes(samples []Sample) []Sample {
	if len(samples) <= 2 {
		return samples
	}
	out := make([]Sample, len(samples))
	copy(out, samples)
	for i := 1; i+1 < len(samples); i++ {
		prev, cur, next := samples[i-1], samples[i], samples[i+1]
		if prev.Speed < 0 || cur.Speed < 0 || next.Speed < 0 {
			continue
		}
		dtIn := cur.TS.Sub(prev.TS).Seconds()
		dtOut := next.TS.Sub(cur.TS).Seconds()
		dtAcross := next.TS.Sub(prev.TS).Seconds()
		if dtIn <= 0 || dtOut <= 0 || dtAcross <= 0 {
			continue
		}
		accelIn := math.Abs(cur.Speed-prev.Speed) / dtIn
		accelOut := math.Abs(next.Speed-cur.Speed) / dtOut
		accelAcross := math.Abs(next.Speed-prev.Speed) / dtAcross
		if accelIn > maxDopplerAcceleration && accelOut > maxDopplerAcceleration && accelAcross <= maxDopplerAcceleration {
			out[i].Speed = -1
		}
	}
	return out
}

// smoothSpeeds applies a window-3 centered moving average over the speed field.
// invalid readings (negative = no Doppler fix) are excluded and stay invalid:
// fabricating a speed would drag real speeds down and defeat the position fallback
func smoothSpeeds(samples []Sample) []Sample {
	if len(samples) < smoothingWindow {
		return samples
	}
	half := smoothingWindow / 2
	out := make([]Sample, len(samples))
	for i := range samples {
		out[i] = samples[i]
		if samples[i].Speed < 0 {
			continue
		}
		lower := i - half
		if lower < 0 {
			lower = 0
		}
		upper := i + half
		if upper > len(samples)-1 {
			upper = len(samples) - 1
		}
		var sum float64
		count := 0
		for j := lower; j <= upper; j++ {
			if samples[j].Speed < 0 {
				continue
			}
			sum += samples[j].Speed
			count++
		}
		out[i].Speed = sum / float64(count)
	}
	return out
}

// distanceMeters is the great-circle distance between two fixes (haversine)
func distanceMeters(a, b Sample) float64 {
	lat1 := a.Lat * math.Pi / 180
	lat2 := b.Lat * math.Pi / 180
	dLat := (b.Lat - a.Lat) * math.Pi / 180
	dLng := (b.Lng - a.Lng) * math.Pi / 180
	h := math.Sin(dLat/2)*math.Sin(dLat/2) +
		math.Cos(lat1)*math.Cos(lat2)*math.Sin(dLng/2)*math.Sin(dLng/2)
	return 2 * earthRadiusMeters * math.Asin(math.Min(1, math.Sqrt(h)))
}
