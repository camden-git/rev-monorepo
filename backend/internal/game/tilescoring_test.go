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

func TestPerTileScoresPrefersDopplerOverJitteryPositions(t *testing.T) {
	const trueSpeed = 29.0 // m/s, ~65 mph
	var samples []Sample
	for i := 0; i < 12; i++ {
		lat := 41.8800
		if i%2 == 1 {
			lat += 0.0004 // ~44 m of lateral GPS wander
		}
		lng := -87.6300 + 0.00035*float64(i) // ~29 m/s eastward
		samples = append(samples, atSpeed(float64(i), lat, lng, trueSpeed))
	}

	scores := PerTileScores(samples)
	if len(scores) == 0 {
		t.Fatal("expected at least one scored tile")
	}
	wantMph := trueSpeed * MphPerMetersPerSecond // ~64.9
	for tile, mph := range scores {
		if mph < wantMph-4 || mph > wantMph+4 {
			t.Fatalf("tile %d scored %.1f mph, want ~%.1f from Doppler; position jitter must not inflate it", tile, mph, wantMph)
		}
	}
}

// with no valid Doppler reading the scorer falls back to position-derived speed
func TestPerTileScoresFallsBackToPositionWithoutDoppler(t *testing.T) {
	// 0.0002 deg longitude per second at lat 41.88 is ~16.5 m/s (~37 mph)
	var samples []Sample
	for i := 0; i < 12; i++ {
		samples = append(samples, at(float64(i), 41.8800, -87.6300+0.0002*float64(i))) // Speed: -1
	}
	scores := PerTileScores(samples)
	if len(scores) == 0 {
		t.Fatal("expected at least one scored tile")
	}
	for tile, mph := range scores {
		if mph < 34 || mph > 40 {
			t.Fatalf("tile %d scored %.1f mph, want ~37 from position fallback", tile, mph)
		}
	}
}

// a Doppler reading the fix positions can't possibly support is a chip glitch:
// the segment is dropped, not scored from either signal
func TestPerTileScoresDropsDopplerGlitchSegments(t *testing.T) {
	// positions crawl east at ~16.5 m/s while every fix claims ~670 m/s (~1500 mph)
	var samples []Sample
	for i := 0; i < 12; i++ {
		samples = append(samples, atSpeed(float64(i), 41.8800, -87.6300+0.0002*float64(i), 670))
	}
	if scores := PerTileScores(samples); len(scores) != 0 {
		t.Fatalf("glitched-Doppler segments should score nothing, got %v", scores)
	}
}

// there is no cap on legitimate speed: when Doppler and the positions agree on a
// very fast run, it scores at face value
func TestPerTileScoresKeepsLegitimateHighSpeed(t *testing.T) {
	// ~80 m/s (~179 mph) eastward, positions and Doppler in agreement
	// (0.000965 deg lng/s at lat 41.88 is ~80 m/s)
	const speed = 80.0
	var samples []Sample
	for i := 0; i < 12; i++ {
		samples = append(samples, atSpeed(float64(i), 41.8800, -87.6300+0.000965*float64(i), speed))
	}
	scores := PerTileScores(samples)
	if len(scores) == 0 {
		t.Fatal("expected at least one scored tile")
	}
	wantMph := speed * MphPerMetersPerSecond // ~179
	for tile, mph := range scores {
		if mph < wantMph-6 || mph > wantMph+6 {
			t.Fatalf("tile %d scored %.1f mph, want ~%.1f (legitimate speed must not be capped)", tile, mph, wantMph)
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
