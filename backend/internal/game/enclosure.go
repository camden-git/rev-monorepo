package game

import (
	"math"

	"github.com/camden-git/rev-monorepo/backend/internal/h3util"
)

// enclosure geometry for capture mechanic
// (REF: docs/game-design.md §Trails & Enclosure, docs/tech-stack.md §Server-Authoritative).
//
// given the ordered res-10 cells a drive traversed and the driver's currently-owned cells, detect a
// closed loop and return the interior cells it encircles
//
// port of RevKit Enclosure.swift

// Result is the scored interior of a closed loop
type Result struct {
	ScoredInterior map[uint64]float64
}

// IsEmpty reports whether the enclosure produced nothing
func (r Result) IsEmpty() bool { return len(r.ScoredInterior) == 0 }

// EncloseOptions mirrors the defaulted parameters of RevKit Enclosure.enclose
// build one with DefaultEncloseOptions and override fields as needed
type EncloseOptions struct {
	// Owned cells act as walls so leaving and returning to your own territory
	// closes a loop without any perimeter-walking code
	Owned map[uint64]bool
	// LoopScore is the representative drive score (mph) used as the gradient's
	// boundary value
	LoopScore float64
	// MinArea is the minimum enclosed hexes to count (docs §Guardrails: >=3)
	MinArea int
	// MaxRadius / MaxInterior guard against enormous fills
	MaxRadius   int
	MaxInterior int
	// MaxAspect rejects long thin slivers
	MaxAspect float64
}

// DefaultEncloseOptions returns the same defaults as the Swift signature
func DefaultEncloseOptions(loopScore float64) EncloseOptions {
	return EncloseOptions{
		LoopScore:   loopScore,
		MinArea:     3,
		MaxRadius:   64,
		MaxInterior: 4096,
		MaxAspect:   5,
	}
}

// Enclose detects the loop closed by trail (possibly stitched through the
// driver's owned land) and returns the scored interior
func Enclose(trail []uint64, opt EncloseOptions) Result {
	// densify the trail into a contiguous ring of neighboring cells
	ring := contiguousRing(trail)
	if len(ring) < 3 {
		return Result{}
	}

	// reject long thin slivers
	if !aspectRatioOK(ring, opt.MaxAspect) {
		return Result{}
	}

	// wall = trail ring ∪ owned land
	walls := union(ring, opt.Owned)

	// bounding disk around the ring. radius = ring extent + margin so the disk's
	// outer edge is guaranteed to sit outside the loop (H3 has no rectangular bbox)
	anchor, ok := anyKey(ring)
	if !ok {
		return Result{}
	}
	radius := 0
	for cell := range ring {
		d, ok := h3util.GridDistance(anchor, cell)
		if !ok || d > opt.MaxRadius { // unreachable or already over the cap
			return Result{}
		}
		if d > radius {
			radius = d
		}
	}
	radius += 2
	if radius > opt.MaxRadius {
		return Result{}
	}
	regionCells, ok := h3util.GridDisk(anchor, radius)
	if !ok || len(regionCells) == 0 {
		return Result{}
	}
	region := sliceToSet(regionCells)

	interior := floodInterior(region, walls)
	if len(interior) < opt.MinArea || len(interior) > opt.MaxInterior {
		return Result{}
	}

	// diffusion gradient over BFS depth from the wall
	return Result{ScoredInterior: gradient(interior, walls, opt.LoopScore)}
}

// contiguousRing stitches consecutive trail cells into one contiguous set
func contiguousRing(trail []uint64) map[uint64]bool {
	ring := map[uint64]bool{}
	if len(trail) == 0 {
		return ring
	}
	ring[trail[0]] = true
	for i := 1; i < len(trail); i++ {
		a, b := trail[i-1], trail[i]
		if a == b {
			continue
		}
		if path, ok := h3util.GridPath(a, b); ok {
			for _, c := range path {
				ring[c] = true
			}
		} else {
			ring[b] = true // a far segment: accept possibly not closing
		}
	}
	return ring
}

// aspectRatioOK rejects loops whose geographic bbox is far longer in one axis
// than the other (long thin slivers)
func aspectRatioOK(ring map[uint64]bool, maxAspect float64) bool {
	minLat, maxLat := math.MaxFloat64, -math.MaxFloat64
	minLng, maxLng := math.MaxFloat64, -math.MaxFloat64
	for cell := range ring {
		lat, lng, ok := h3util.CellCenter(cell)
		if !ok {
			continue
		}
		minLat, maxLat = math.Min(minLat, lat), math.Max(maxLat, lat)
		minLng, maxLng = math.Min(minLng, lng), math.Max(maxLng, lng)
	}
	if !(maxLat >= minLat) {
		return false
	}
	const metersPerDegLat = 111_320.0
	midLat := (minLat + maxLat) / 2
	height := (maxLat - minLat) * metersPerDegLat
	width := (maxLng - minLng) * metersPerDegLat * math.Cos(midLat*math.Pi/180)
	lo, hi := math.Min(width, height), math.Max(width, height)
	if !(lo > 0) {
		return false
	}
	return hi/lo <= maxAspect
}

// floodInterior BFSes the open cells reachable from the disk's outer edge and
// returns the cells it cannot reach (the enclosed interior). empty if no
// exterior seed exists
func floodInterior(region, walls map[uint64]bool) map[uint64]bool {
	open := difference(region, walls)
	if len(open) == 0 {
		return map[uint64]bool{}
	}

	exterior := map[uint64]bool{}
	var queue []uint64
	for cell := range open {
		if hasNeighborOutside(cell, region) {
			if !exterior[cell] {
				exterior[cell] = true
				queue = append(queue, cell)
			}
		}
	}
	if len(queue) == 0 {
		return map[uint64]bool{}
	}

	for head := 0; head < len(queue); head++ {
		cell := queue[head]
		for _, n := range neighbors(cell) {
			if open[n] && !exterior[n] {
				exterior[n] = true
				queue = append(queue, n)
			}
		}
	}
	return difference(open, exterior)
}

// gradient assigns a linear diffusion gradient over BFS depth from the wall:
// loopScore at the wall falling to 0 once you penetrate 20% of the way to the
// deepest cell
func gradient(interior, walls map[uint64]bool, loopScore float64) map[uint64]float64 {
	depth := map[uint64]int{}
	var queue []uint64
	for cell := range interior {
		if hasNeighborIn(cell, walls) {
			depth[cell] = 1
			queue = append(queue, cell)
		}
	}

	for head := 0; head < len(queue); head++ {
		cell := queue[head]
		d := depth[cell]
		for _, n := range neighbors(cell) {
			if interior[n] {
				if _, seen := depth[n]; !seen {
					depth[n] = d + 1
					queue = append(queue, n)
				}
			}
		}
	}

	maxDepth := 1
	for _, d := range depth {
		if d > maxDepth {
			maxDepth = d
		}
	}

	scored := map[uint64]float64{}
	for cell := range interior {
		d, ok := depth[cell]
		if !ok {
			scored[cell] = 0 // disconnected from any wall-adjacent seed
			continue
		}
		penetration := 0.0
		if maxDepth != 1 {
			penetration = float64(d-1) / float64(maxDepth-1)
		}
		scored[cell] = loopScore * math.Max(0, 1-5*penetration)
	}
	return scored
}

// neighbors returns the up-to-6 immediate neighbors of a cell
func neighbors(cell uint64) []uint64 {
	disk, ok := h3util.GridDisk(cell, 1)
	if !ok {
		return nil
	}
	out := make([]uint64, 0, len(disk))
	for _, c := range disk {
		if c != cell {
			out = append(out, c)
		}
	}
	return out
}

func hasNeighborOutside(cell uint64, region map[uint64]bool) bool {
	for _, n := range neighbors(cell) {
		if !region[n] {
			return true
		}
	}
	return false
}

func hasNeighborIn(cell uint64, set map[uint64]bool) bool {
	for _, n := range neighbors(cell) {
		if set[n] {
			return true
		}
	}
	return false
}

// MARK: small set helpers

func union(a, b map[uint64]bool) map[uint64]bool {
	out := make(map[uint64]bool, len(a)+len(b))
	for k := range a {
		out[k] = true
	}
	for k := range b {
		out[k] = true
	}
	return out
}

func difference(a, b map[uint64]bool) map[uint64]bool {
	out := make(map[uint64]bool, len(a))
	for k := range a {
		if !b[k] {
			out[k] = true
		}
	}
	return out
}

func sliceToSet(cells []uint64) map[uint64]bool {
	out := make(map[uint64]bool, len(cells))
	for _, c := range cells {
		out[c] = true
	}
	return out
}

func anyKey(set map[uint64]bool) (uint64, bool) {
	for k := range set {
		return k, true
	}
	return 0, false
}
