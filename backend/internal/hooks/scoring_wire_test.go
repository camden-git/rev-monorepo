package hooks

import (
	"encoding/json"
	"testing"

	"github.com/camden-git/rev-monorepo/backend/internal/game"
)

const sampleRawPathJSON = `[
  {"accuracy":5,"timestamp":"2026-06-27 00:00:00.000Z","lat":41.8807,"speed":15,"lng":-87.6294},
  {"accuracy":5,"timestamp":"2026-06-27 00:00:01.000Z","lat":41.8807,"speed":15,"lng":-87.6292},
  {"accuracy":5,"timestamp":"2026-06-27 00:00:02.000Z","lat":41.8807,"speed":15,"lng":-87.6290}
]`

func TestSamplesFromRawParsesClientWireFormat(t *testing.T) {
	var raw []RawSample
	if err := json.Unmarshal([]byte(sampleRawPathJSON), &raw); err != nil {
		t.Fatalf("unmarshal raw_path: %v", err)
	}
	samples := SamplesFromRaw(raw)
	if len(samples) != 3 {
		t.Fatalf("expected 3 parsed samples, got %d", len(samples))
	}
	// timestamps must advance by exactly 1s so the scorer sees real travel
	if d := samples[1].TS.Sub(samples[0].TS).Seconds(); d != 1 {
		t.Fatalf("expected 1s between fixes, got %.3fs (timestamp parse failed?)", d)
	}

	// the path should score the tile it crosses (a non-trivial moving speed)
	scores := game.PerTileScores(game.FilterOutliers(samples))
	if len(scores) == 0 {
		t.Fatal("expected at least one scored tile from a valid moving path")
	}
	for tile, mph := range scores {
		if mph <= 0 {
			t.Fatalf("tile %d scored non-positive mph %.2f", tile, mph)
		}
	}
}

func TestSamplesFromRawDropsUnparseableTimestamps(t *testing.T) {
	raw := []RawSample{
		{TS: "not-a-time", Lat: 1, Lng: 2, Speed: 3},
		{TS: "2026-06-27 00:00:00.000Z", Lat: 1, Lng: 2, Speed: 3},
	}
	if got := SamplesFromRaw(raw); len(got) != 1 {
		t.Fatalf("expected 1 sample after dropping the bad timestamp, got %d", len(got))
	}
}
