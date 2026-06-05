package game

import "testing"

// TilesCrossed returns res-10 cells in first-seen order, de-duplicated
// port of RevKit TileScoring.tilesCrossed.
func TestTilesCrossedOrdersAndDedups(t *testing.T) {
	a, _ := Cell(41.8807, -87.6294)
	b, _ := Cell(41.8807, -87.6244)
	c, _ := Cell(41.8807, -87.6194)

	path := []Point{
		{Lat: 41.8807, Lng: -87.6294}, // a
		{Lat: 41.8807, Lng: -87.6294}, // a again (same cell, skipped)
		{Lat: 41.8807, Lng: -87.6244}, // b
		{Lat: 41.8807, Lng: -87.6194}, // c
		{Lat: 41.8807, Lng: -87.6244}, // b again (already seen, skipped)
	}

	got := TilesCrossed(path)
	want := []uint64{a, b, c}
	if len(got) != len(want) {
		t.Fatalf("expected %d cells, got %d", len(want), len(got))
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("at %d expected %d, got %d", i, want[i], got[i])
		}
	}
}

func TestTilesCrossedEmptyPath(t *testing.T) {
	if got := TilesCrossed(nil); len(got) != 0 {
		t.Fatalf("expected empty, got %v", got)
	}
}
