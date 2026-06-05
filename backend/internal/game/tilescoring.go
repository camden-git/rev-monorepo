package game

import "github.com/camden-git/rev-monorepo/backend/internal/h3util"

// Point is one GPS fix's coordinate (the lat/lng of a drives.raw_path entry)
type Point struct {
	Lat float64
	Lng float64
}

// Cell returns the res-10 cell containing a coordinate
// Port of the `cell(lat:lng:)` helper in RevKit TileScoring
func Cell(lat, lng float64) (uint64, bool) {
	return h3util.LatLngToCell(lat, lng)
}

// TilesCrossed returns the ordered, de-duplicated res-10 cells a path passes
// through. port of RevKit TileScoring.tilesCrossed
//
// NOTE: the distance-weighted scoring half of TileScoring is intentionally
// not ported. this depends on CLLocation.distance (WGS84 ellipsoidal geodesy),
// which a Go haversine can't reproduce bit-for-bit, and the server trusts the
// client-supplied per_tile_scores for now (REF: docs/tech-stack.md
// §Server-Authoritative). this likely needs to be fixed if cheating becomes an issue
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
