package game

import (
	"math"
	"testing"
	"time"
)

func at(sec float64, lat, lng float64) Sample {
	base := time.Date(2026, 6, 26, 12, 0, 0, 0, time.UTC)
	return Sample{
		TS:    base.Add(time.Duration(sec * float64(time.Second))),
		Lat:   lat,
		Lng:   lng,
		Speed: 0,
	}
}

// distanceMeters should be within ~0.5% of a known great-circle distance
func TestDistanceMetersSanity(t *testing.T) {
	a := Sample{Lat: 0, Lng: 0}
	b := Sample{Lat: 0, Lng: 1}
	got := distanceMeters(a, b)
	want := 111319.49 // meters per degree longitude at equator on a 6371km sphere
	if math.Abs(got-want)/want > 0.005 {
		t.Fatalf("distanceMeters = %.1f, want ~%.1f", got, want)
	}
}

func TestFilterOutliersDropsTeleportSpike(t *testing.T) {
	// a straight eastward crawl with one fix flung ~1km north and back
	samples := []Sample{
		at(0, 41.8800, -87.6300),
		at(1, 41.8800, -87.6290),
		at(2, 41.8900, -87.6280), // spike: ~1.1km north of the line
		at(3, 41.8800, -87.6270),
		at(4, 41.8800, -87.6260),
	}
	got := FilterOutliers(samples)
	for _, s := range got {
		if s.Lat > 41.885 {
			t.Fatalf("teleport spike survived the filter: %+v", s)
		}
	}
	if len(got) != 4 {
		t.Fatalf("expected 4 samples after dropping 1 spike, got %d", len(got))
	}
}

func TestFilterOutliersShortPathUntouched(t *testing.T) {
	samples := []Sample{at(0, 41.88, -87.63), at(1, 41.88, -87.629)}
	if got := FilterOutliers(samples); len(got) != 2 {
		t.Fatalf("two-sample path should pass through untouched, got %d", len(got))
	}
}
