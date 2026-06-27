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

// PerTileScores reports each tile's distance-weighted average moving speed in
// mph
func TestPerTileScoresMatchesSteadySpeed(t *testing.T) {
	// 0.0002 deg longitude per second at lat 41.88 is ~16.5 m/s (~37 mph)
	var samples []Sample
	for i := 0; i < 12; i++ {
		samples = append(samples, at(float64(i), 41.8800, -87.6300+0.0002*float64(i)))
	}
	const wantMph = 37.0

	scores := PerTileScores(samples)
	if len(scores) == 0 {
		t.Fatal("expected at least one scored tile")
	}
	for tile, mph := range scores {
		if mph < wantMph-3 || mph > wantMph+3 {
			t.Fatalf("tile %d scored %.1f mph, want ~%.1f", tile, mph, wantMph)
		}
	}
}

// a path whose every segment is below the stopped-speed threshold earns no
// tile scores
func TestPerTileScoresIgnoresStoppedPath(t *testing.T) {
	var samples []Sample
	for i := 0; i < 10; i++ {
		samples = append(samples, at(float64(i), 41.8800, -87.6300+0.000006*float64(i)))
	}
	if scores := PerTileScores(samples); len(scores) != 0 {
		t.Fatalf("stopped path should score nothing, got %v", scores)
	}
}

// a gap longer than MaxSegmentGap between two fixes is treated as a tracking
// gap
func TestPerTileScoresSkipsTrackingGaps(t *testing.T) {
	samples := []Sample{
		at(0, 41.8800, -87.6300),
		at(60, 41.8900, -87.6100), // 60s gap, far away
	}
	if scores := PerTileScores(samples); len(scores) != 0 {
		t.Fatalf("tracking-gap segment should score nothing, got %v", scores)
	}
}
