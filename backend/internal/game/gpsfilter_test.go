package game

import (
	"math"
	"testing"
	"time"
)

// at builds a sample with an invalid Doppler speed (-1) so PerTileScores falls
// back to its position-derived speed
func at(sec float64, lat, lng float64) Sample {
	base := time.Date(2026, 6, 26, 12, 0, 0, 0, time.UTC)
	return Sample{
		TS:    base.Add(time.Duration(sec * float64(time.Second))),
		Lat:   lat,
		Lng:   lng,
		Speed: -1,
	}
}

// atSpeed is at with an explicit Doppler speed (m/s) attached to the fix
func atSpeed(sec float64, lat, lng, speed float64) Sample {
	s := at(sec, lat, lng)
	s.Speed = speed
	return s
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

// a single glitched Doppler reading (impossible acceleration in and out while
// its neighbours agree) is invalidated, and must not bleed into its neighbours'
// smoothed speeds
func TestFilterOutliersInvalidatesDopplerSpike(t *testing.T) {
	var samples []Sample
	for i := 0; i < 7; i++ {
		speed := 29.0
		if i == 3 {
			speed = 670 // ~1500 mph chip glitch on one fix
		}
		samples = append(samples, atSpeed(float64(i), 41.8800, -87.6300+0.00035*float64(i), speed))
	}
	got := FilterOutliers(samples)
	if len(got) != 7 {
		t.Fatalf("expected all 7 samples retained, got %d", len(got))
	}
	if got[3].Speed >= 0 {
		t.Fatalf("glitched Doppler reading should be invalidated, still reads %.1f m/s", got[3].Speed)
	}
	for i, s := range got {
		if i == 3 {
			continue
		}
		if s.Speed < 27 || s.Speed > 31 {
			t.Fatalf("sample %d smoothed to %.1f m/s; the spike must not bleed into neighbours", i, s.Speed)
		}
	}
}

// invalid Doppler readings stay invalid through smoothing (so the scorer's
// position fallback still triggers) and don't drag neighbours toward zero
func TestSmoothSpeedsPreservesInvalidDoppler(t *testing.T) {
	samples := []Sample{
		atSpeed(0, 41.8800, -87.6300, 29),
		at(1, 41.8800, -87.6297), // no Doppler fix
		atSpeed(2, 41.8800, -87.6294, 29),
	}
	got := smoothSpeeds(samples)
	if got[1].Speed >= 0 {
		t.Fatalf("invalid Doppler should stay invalid, got %.1f", got[1].Speed)
	}
	for _, i := range []int{0, 2} {
		if got[i].Speed != 29 {
			t.Fatalf("sample %d speed %.1f; an invalid neighbour must not drag it down", i, got[i].Speed)
		}
	}
}

func TestFilterOutliersShortPathUntouched(t *testing.T) {
	samples := []Sample{at(0, 41.88, -87.63), at(1, 41.88, -87.629)}
	if got := FilterOutliers(samples); len(got) != 2 {
		t.Fatalf("two-sample path should pass through untouched, got %d", len(got))
	}
}
