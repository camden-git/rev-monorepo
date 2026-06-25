package roads

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/camden-git/rev-monorepo/backend/internal/game"
)

func TestCanonicalClassFoldsTags(t *testing.T) {
	cases := map[string]game.RoadClass{
		"motorway":      game.ClassMotorway,
		"motorway_link": game.ClassMotorway,
		"trunk_link":    game.ClassTrunk,
		"primary":       game.ClassPrimary,
		"Secondary":     game.ClassSecondary,
		"unclassified":  game.ClassTertiary,
		"living_street": game.ClassResidential,
		"service":       game.ClassService,
		"footway":       game.ClassUnknown,
		"":              game.ClassUnknown,
	}
	for tag, want := range cases {
		if got := canonicalClass(tag); got != want {
			t.Errorf("canonicalClass(%q) = %q, want %q", tag, got, want)
		}
	}
}

// When a centroid sits near both a service alley and the arterial it branches
// off
func TestClassAtPicksMostMajor(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"elements":[
			{"tags":{"highway":"service"}},
			{"tags":{"highway":"trunk","maxspeed":"45 mph"}},
			{"tags":{"highway":"residential"}}
		]}`))
	}))
	defer srv.Close()

	class, resolved, err := NewClient(srv.URL).ClassAt(context.Background(), 41.88, -87.6)
	if err != nil || !resolved {
		t.Fatalf("ClassAt failed: resolved=%v err=%v", resolved, err)
	}
	if class != game.ClassTrunk {
		t.Fatalf("expected trunk, got %q", class)
	}
}

func TestClassAtNoRoadResolvesUnknown(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"elements":[]}`))
	}))
	defer srv.Close()

	class, resolved, err := NewClient(srv.URL).ClassAt(context.Background(), 0, 0)
	if err != nil || !resolved {
		t.Fatalf("ClassAt failed: resolved=%v err=%v", resolved, err)
	}
	if class != game.ClassUnknown {
		t.Fatalf("expected unknown class, got %q", class)
	}
}

// A transient 429 must be retried in-place and recover
func TestClassAtRetriesThroughRateLimit(t *testing.T) {
	withFastBackoff(t)
	var calls int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if calls < 3 {
			http.Error(w, "slow down", http.StatusTooManyRequests)
			return
		}
		w.Write([]byte(`{"elements":[{"tags":{"highway":"primary"}}]}`))
	}))
	defer srv.Close()

	class, resolved, err := NewClient(srv.URL).ClassAt(context.Background(), 0, 0)
	if err != nil || !resolved {
		t.Fatalf("expected recovery after retries: resolved=%v err=%v", resolved, err)
	}
	if class != game.ClassPrimary {
		t.Fatalf("expected primary after retry, got %q", class)
	}
	if calls != 3 {
		t.Fatalf("expected 3 attempts (2 throttled + 1 ok), got %d", calls)
	}
}

// Persistent throttling exhausts retries and surfaces a retryable failure so the
// seeder leaves road_class empty and tries again on a later tick
func TestClassAtExhaustsRetries(t *testing.T) {
	withFastBackoff(t)
	var calls int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		http.Error(w, "slow down", http.StatusTooManyRequests)
	}))
	defer srv.Close()

	_, resolved, err := NewClient(srv.URL).ClassAt(context.Background(), 0, 0)
	if err == nil || resolved {
		t.Fatalf("expected exhaustion failure, got resolved=%v err=%v", resolved, err)
	}
	if calls != maxAttempts {
		t.Fatalf("expected %d attempts, got %d", maxAttempts, calls)
	}
}

// A non-retryable status (e.g. malformed query -> 400) fails fast
func TestClassAtBadRequestFailsFast(t *testing.T) {
	withFastBackoff(t)
	var calls int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		http.Error(w, "bad query", http.StatusBadRequest)
	}))
	defer srv.Close()

	if _, _, err := NewClient(srv.URL).ClassAt(context.Background(), 0, 0); err == nil {
		t.Fatal("expected error on 400")
	}
	if calls != 1 {
		t.Fatalf("expected a single attempt for non-retryable status, got %d", calls)
	}
}

func withFastBackoff(t *testing.T) {
	t.Helper()
	prevBase, prevMax := baseBackoff, maxBackoff
	baseBackoff, maxBackoff = time.Millisecond, 5*time.Millisecond
	t.Cleanup(func() { baseBackoff, maxBackoff = prevBase, prevMax })
}
