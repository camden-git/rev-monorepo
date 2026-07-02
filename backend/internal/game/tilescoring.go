package game

import (
	"math"

	"github.com/camden-git/rev-monorepo/backend/internal/h3util"
)

// Point is one GPS fix's coordinate (the lat/lng of a drives.raw_path entry)
type Point struct {
	Lat float64
	Lng float64
}

// Tile-scoring constants, mirrored from RevKit TileScoring
const (
	// MphPerMetersPerSecond is 1 m/s expressed in mph
	MphPerMetersPerSecond = 2.2369362920544
	// stoppedSpeedMetersPerSecond: segments slower than this count as "stopped"
	stoppedSpeedMetersPerSecond = 2.0 / MphPerMetersPerSecond
	// MaxSegmentGap is the max time (s) between fixes before a segment is treated
	// as a tracking gap rather than real travel
	MaxSegmentGap = 10.0
	// maxSegmentSpeed is the fastest a segment can imply (m/s, ~200 mph) before
	// it's treated as a GPS teleport rather than real travel
	maxSegmentSpeed = 134
	// subStepMeters is the target length each segment is broken into for tile
	// attribution (small relative to a ~130 m res-10 hex)
	subStepMeters = 8.0
	// maxSubSteps caps sub-steps per segment so a long GPS-gap segment can't blow
	// up the loop
	maxSubSteps = 64
	// minTileDistanceMeters is the minimum in-tile travel before a tile earns a
	// score; below this the tile is too noisy to trust
	minTileDistanceMeters = 12.0
)

// Cell returns the res-10 cell containing a coordinate
// Port of the `cell(lat:lng:)` helper in RevKit TileScoring
func Cell(lat, lng float64) (uint64, bool) {
	return h3util.LatLngToCell(lat, lng)
}

// PerTileScores computes the per-tile claim score (time-weighted average speed
// while moving, in mph) for each res-10 cell a filtered path crosses. Segment
// speed comes from the device's Doppler reading when valid
func PerTileScores(samples []Sample) map[uint64]float64 {
	if len(samples) <= 1 {
		return map[uint64]float64{}
	}

	distanceByTile := map[uint64]float64{}
	movingTimeByTile := map[uint64]float64{}

	speedTimeByTile := map[uint64]float64{}

	for i := 0; i+1 < len(samples); i++ {
		a, b := samples[i], samples[i+1]
		dt := b.TS.Sub(a.TS).Seconds()
		if dt <= 0 || dt > MaxSegmentGap {
			continue
		}
		distance := distanceMeters(a, b)
		segmentSpeed := distance / dt
		if segmentSpeed < stoppedSpeedMetersPerSecond {
			continue
		}
		if segmentSpeed > maxSegmentSpeed {
			continue // GPS teleport: don't interpolate a line between far-apart fixes
		}

		// score from the device's Doppler speed when both endpoints report a
		// valid reading. Doppler speed is far steadier than differentiating GPS
		// positions, which multipath (e.g. downtown urban canyons) inflates: a
		// gradual position wander only ever adds apparent path length and reads
		// as phantom speed, yet is too smooth to trip the spike/acceleration
		// filters. fall back to the position-derived speed when Doppler is
		// unavailable (negative CoreLocation speed = invalid fix).
		scoreSpeed := segmentSpeed
		if a.Speed >= 0 && b.Speed >= 0 {
			scoreSpeed = (a.Speed + b.Speed) / 2
		}

		// walk the segment in small steps and attribute each step's distance/time
		// to the tile it falls in
		steps := int(math.Ceil(distance / subStepMeters))
		if steps < 1 {
			steps = 1
		}
		if steps > maxSubSteps {
			steps = maxSubSteps
		}
		stepDistance := distance / float64(steps)
		stepTime := dt / float64(steps)
		for s := 0; s < steps; s++ {
			fraction := (float64(s) + 0.5) / float64(steps)
			lat := a.Lat + (b.Lat-a.Lat)*fraction
			lng := a.Lng + (b.Lng-a.Lng)*fraction
			tile, ok := h3util.LatLngToCell(lat, lng)
			if !ok {
				continue
			}
			distanceByTile[tile] += stepDistance
			movingTimeByTile[tile] += stepTime
			speedTimeByTile[tile] += scoreSpeed * stepTime
		}
	}

	scores := map[uint64]float64{}
	for tile, distance := range distanceByTile {
		if distance < minTileDistanceMeters {
			continue
		}
		movingTime := movingTimeByTile[tile]
		if movingTime <= 0 {
			continue
		}
		scores[tile] = (speedTimeByTile[tile] / movingTime) * MphPerMetersPerSecond
	}
	return scores
}

// TilesCrossed returns the ordered, de-duplicated res-10 cells a path passes
// through. port of RevKit TileScoring.tilesCrossed
func TilesCrossed(path []Point) []uint64 {
	seen := map[uint64]bool{}
	ordered := []uint64{}
	for _, p := range path {
		cell, ok := h3util.LatLngToCell(p.Lat, p.Lng)
		if !ok {
			continue
		}
		if !seen[cell] {
			seen[cell] = true
			ordered = append(ordered, cell)
		}
	}
	return ordered
}
