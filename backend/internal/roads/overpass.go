// Package roads resolves the functional class of the road beneath a play tile
// from OpenStreetMap, so per-tile reference speeds can be anchored to an
// unbiased prior instead of learned purely from the (selectively fast)
// players who drive a tile
package roads

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/camden-git/rev-monorepo/backend/internal/game"
)

// DefaultOverpassURL is the public Overpass endpoint
// TODO: self host this if issues appear
const DefaultOverpassURL = "https://overpass-api.de/api/interpreter"

// searchRadiusMeters is how far from a tile centroid we look for a road
const searchRadiusMeters = 30

const maxAttempts = 4

var (
	baseBackoff = 2 * time.Second
	maxBackoff  = 30 * time.Second
)

// Client queries Overpass for the road class at a coordinate
type Client struct {
	endpoint string
	http     *http.Client
}

// NewClient builds a client for the given endpoint (empty -> public default)
func NewClient(endpoint string) *Client {
	if endpoint == "" {
		endpoint = DefaultOverpassURL
	}
	return &Client{
		endpoint: endpoint,
		http:     &http.Client{Timeout: 25 * time.Second},
	}
}

type overpassResponse struct {
	Elements []struct {
		Tags map[string]string `json:"tags"`
	} `json:"elements"`
}

// ClassAt returns the most major road class within searchRadiusMeters of the
// coordinate
func (c *Client) ClassAt(ctx context.Context, lat, lng float64) (game.RoadClass, bool, error) {
	var lastErr error
	var retryAfter time.Duration
	for attempt := 0; attempt < maxAttempts; attempt++ {
		if attempt > 0 {
			if err := sleepCtx(ctx, backoffFor(attempt, retryAfter)); err != nil {
				return game.ClassUnknown, false, err
			}
		}
		class, hint, err := c.lookup(ctx, lat, lng)
		if err == nil {
			return class, true, nil
		}
		lastErr, retryAfter = err, hint
		if !retryable(err) {
			return game.ClassUnknown, false, err
		}
	}
	return game.ClassUnknown, false, fmt.Errorf("overpass exhausted %d attempts: %w", maxAttempts, lastErr)
}

func (c *Client) lookup(ctx context.Context, lat, lng float64) (game.RoadClass, time.Duration, error) {
	query := fmt.Sprintf(
		"[out:json][timeout:20];way(around:%d,%f,%f)[highway];out tags;",
		searchRadiusMeters, lat, lng,
	)

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.endpoint,
		strings.NewReader("data="+url.QueryEscape(query)))
	if err != nil {
		return game.ClassUnknown, 0, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("User-Agent", "rev-driverevapp/1.0 (road-class seeder)")

	resp, err := c.http.Do(req)
	if err != nil {
		return game.ClassUnknown, 0, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		retryAfter := parseRetryAfter(resp.Header.Get("Retry-After"))
		return game.ClassUnknown, retryAfter, &statusError{code: resp.StatusCode}
	}

	var parsed overpassResponse
	if err := json.NewDecoder(resp.Body).Decode(&parsed); err != nil {
		return game.ClassUnknown, 0, err
	}

	best := game.ClassUnknown
	bestRank := -1
	for _, el := range parsed.Elements {
		class := canonicalClass(el.Tags["highway"])
		if r := classRank(class); r > bestRank {
			best, bestRank = class, r
		}
	}
	return best, 0, nil
}

type statusError struct{ code int }

func (e *statusError) Error() string { return fmt.Sprintf("overpass status %d", e.code) }

// retryable reports whether an error is a transient throttle/overload worth
// retrying. Overpass returns 429 when rate-limited and 504 when overloaded
func retryable(err error) bool {
	var se *statusError
	if errors.As(err, &se) {
		return se.code == http.StatusTooManyRequests || se.code == http.StatusGatewayTimeout
	}
	return true
}

// backoffFor returns the delay before the given attempt, honoring a server
// Retry-After hint when it is longer than our exponential default.
func backoffFor(attempt int, retryAfter time.Duration) time.Duration {
	d := baseBackoff << (attempt - 1) // 2s, 4s, 8s ...
	if d > maxBackoff {
		d = maxBackoff
	}
	if retryAfter > d {
		d = retryAfter
		if d > maxBackoff {
			d = maxBackoff
		}
	}
	return d
}

func parseRetryAfter(h string) time.Duration {
	if h == "" {
		return 0
	}
	if secs, err := strconv.Atoi(strings.TrimSpace(h)); err == nil && secs > 0 {
		return time.Duration(secs) * time.Second
	}
	return 0
}

// sleepCtx sleeps for d but aborts early if the context is cancelled (e.g. app
// shutdown), returning the context error so the caller stops cleanly.
func sleepCtx(ctx context.Context, d time.Duration) error {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
}

// classRank orders classes by how major the road is, so a centroid near both a
// service alley and the arterial it branches off resolves to the arterial.
func classRank(class game.RoadClass) int {
	switch class {
	case game.ClassMotorway:
		return 7
	case game.ClassTrunk:
		return 6
	case game.ClassPrimary:
		return 5
	case game.ClassSecondary:
		return 4
	case game.ClassTertiary:
		return 3
	case game.ClassResidential:
		return 2
	case game.ClassService:
		return 1
	default:
		return 0
	}
}

// canonicalClass folds the long tail of OSM highway values into the handful of
// classes we band. `*_link` ramps inherit their parent
func canonicalClass(highway string) game.RoadClass {
	highway = strings.TrimSuffix(strings.ToLower(strings.TrimSpace(highway)), "_link")
	switch highway {
	case "motorway":
		return game.ClassMotorway
	case "trunk":
		return game.ClassTrunk
	case "primary":
		return game.ClassPrimary
	case "secondary":
		return game.ClassSecondary
	case "tertiary", "unclassified":
		return game.ClassTertiary
	case "residential", "living_street":
		return game.ClassResidential
	case "service":
		return game.ClassService
	default:
		return game.ClassUnknown
	}
}
