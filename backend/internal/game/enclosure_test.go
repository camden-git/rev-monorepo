package game

import (
	"math"
	"testing"

	"github.com/camden-git/rev-monorepo/backend/internal/h3util"
)

// port of: RevKit EnclosureTests.swift

func testCenter(t *testing.T) uint64 {
	t.Helper()
	c, ok := Cell(41.8807, -87.6294)
	if !ok {
		t.Fatal("center cell conversion failed")
	}
	return c
}

func ring(t *testing.T, origin uint64, distance int) []uint64 {
	t.Helper()
	cells, ok := h3util.GridRing(origin, distance)
	if !ok {
		t.Fatalf("gridRing(%d) failed", distance)
	}
	return cells
}

func disk(t *testing.T, origin uint64, distance int) []uint64 {
	t.Helper()
	cells, ok := h3util.GridDisk(origin, distance)
	if !ok {
		t.Fatalf("gridDisk(%d) failed", distance)
	}
	return cells
}

func keySet(m map[uint64]float64) map[uint64]bool {
	out := make(map[uint64]bool, len(m))
	for k := range m {
		out[k] = true
	}
	return out
}

func sameSet(a map[uint64]bool, b []uint64) bool {
	if len(a) != len(b) {
		return false
	}
	for _, c := range b {
		if !a[c] {
			return false
		}
	}
	return true
}

func ownedSet(cells []uint64) map[uint64]bool {
	out := make(map[uint64]bool, len(cells))
	for _, c := range cells {
		out[c] = true
	}
	return out
}

// a closed ring captures exactly the cells it surrounds
func TestRingLoopEnclosesItsInterior(t *testing.T) {
	center := testCenter(t)
	result := Enclose(ring(t, center, 2), DefaultEncloseOptions(30))
	if !sameSet(keySet(result.ScoredInterior), disk(t, center, 1)) { // center + 6 inner cells
		t.Fatalf("interior != disk(center,1)")
	}
}

// an open path (no loop) encloses nothing
func TestOpenTrailEnclosesNothing(t *testing.T) {
	center := testCenter(t)
	far, ok := Cell(41.8807, -87.6194) // ~830 m east
	if !ok {
		t.Fatal("far cell failed")
	}
	line, ok := h3util.GridPath(center, far)
	if !ok {
		t.Fatal("path failed")
	}
	if !Enclose(line, DefaultEncloseOptions(30)).IsEmpty() {
		t.Fatal("open trail enclosed something")
	}
}

// a loop enclosing fewer than minArea hexes is rejected
func TestBelowMinAreaIsRejected(t *testing.T) {
	center := testCenter(t)
	// the 6 immediate neighbors surround only the single center cell
	if !Enclose(ring(t, center, 1), DefaultEncloseOptions(30)).IsEmpty() {
		t.Fatal("below-minArea loop was not rejected")
	}
}

// a trail with a dangling tail still encloses its loop body
func TestSelfTouchClosureIgnoresTail(t *testing.T) {
	center := testCenter(t)
	tailEnd, ok := Cell(41.8807, -87.6244) // ~415 m east of center
	if !ok {
		t.Fatal("tailEnd failed")
	}
	r2 := ring(t, center, 2)
	tail, ok := h3util.GridPath(r2[0], tailEnd)
	if !ok {
		t.Fatal("tail path failed")
	}
	result := Enclose(append(tail, r2...), DefaultEncloseOptions(30))
	if !sameSet(keySet(result.ScoredInterior), disk(t, center, 1)) {
		t.Fatal("tail closure interior != disk(center,1)")
	}
}

// leaving and returning to your own territory closes a loop
func TestOwnedTerritoryReentryClosesLoop(t *testing.T) {
	center := testCenter(t)
	r2 := ring(t, center, 2)
	ownedArc := ownedSet(r2[:4])
	partialTrail := r2[4:]

	opt := DefaultEncloseOptions(30)
	opt.Owned = ownedArc
	closed := Enclose(partialTrail, opt)
	if !sameSet(keySet(closed.ScoredInterior), disk(t, center, 1)) {
		t.Fatal("owned-reentry interior != disk(center,1)")
	}

	if !Enclose(partialTrail, DefaultEncloseOptions(30)).IsEmpty() {
		t.Fatal("partial trail without owned arc enclosed something")
	}
}

func TestInteriorScoreFallsToZeroPastTheEdge(t *testing.T) {
	center := testCenter(t)
	const loopScore = 40.0
	scored := Enclose(ring(t, center, 3), DefaultEncloseOptions(loopScore)).ScoredInterior

	// gradient reaches 0 after 20% penetration. interior depth runs 1..3, so only
	// the wall-adjacent ring (depth 1) scores; everything deeper is 0
	for _, cell := range ring(t, center, 2) {
		if math.Abs(scored[cell]-loopScore) >= 0.001 {
			t.Fatalf("ring2 cell expected %v, got %v", loopScore, scored[cell])
		}
	}
	for _, cell := range ring(t, center, 1) {
		if scored[cell] != 0 {
			t.Fatalf("ring1 cell expected 0, got %v", scored[cell])
		}
	}
	if scored[center] != 0 {
		t.Fatalf("center expected 0, got %v", scored[center])
	}
}

// enormous fills are capped both by bounding-disk radius and by interior cell count
func TestEnormousFillsAreCapped(t *testing.T) {
	center := testCenter(t)

	optRadius := DefaultEncloseOptions(30)
	optRadius.MaxRadius = 1
	if !Enclose(ring(t, center, 2), optRadius).IsEmpty() {
		t.Fatal("maxRadius cap not enforced")
	}

	optInterior := DefaultEncloseOptions(30)
	optInterior.MaxInterior = 3
	if !Enclose(ring(t, center, 2), optInterior).IsEmpty() {
		t.Fatal("maxInterior cap not enforced")
	}
}

// the squareness guard rejects elongated loops
func TestAspectRatioGuardRejectsNonSquareLoops(t *testing.T) {
	center := testCenter(t)
	square := ring(t, center, 2)
	if Enclose(square, DefaultEncloseOptions(30)).IsEmpty() {
		t.Fatal("near-square ring should enclose by default")
	}
	opt := DefaultEncloseOptions(30)
	opt.MaxAspect = 1.0
	if !Enclose(square, opt).IsEmpty() {
		t.Fatal("tightened aspect guard should reject")
	}
}
