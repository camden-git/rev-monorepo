// Package stats aggregates owned tiles into per-player empire standings and
// persists periodic snapshots so the app can chart size, strength, and rank over
// time
package stats

import (
	"fmt"
	"sort"
	"time"

	"github.com/camden-git/rev-monorepo/backend/internal/feed"
	"github.com/camden-git/rev-monorepo/backend/internal/game"
	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"
)

// Standing is one player's aggregated empire position at a moment in time
type Standing struct {
	UserID    string
	TilesHeld int
	// Strength sums each held tile's speed-weighted claim score
	Strength float64
	// Score is the value-weighted empire score (the home hex counts 1)
	Score float64
	// Rank is 1-based, by Score descending
	Rank int
}

// tileRow is the slice of a tile the aggregation reads
type tileRow struct {
	Owner      string  `db:"owner"`
	ClaimScore float64 `db:"claim_score"`
	Captures   float64 `db:"captures"`
	IsHome     float64 `db:"is_home"`
}

// Standings aggregates every owned tile into a ranked list of empire positions
func Standings(app core.App) ([]Standing, error) {
	var rows []tileRow
	err := app.DB().
		NewQuery("SELECT owner, claim_score, captures, is_home FROM tiles WHERE owner != ''").
		All(&rows)
	if err != nil {
		return nil, fmt.Errorf("query tiles: %w", err)
	}
	return aggregate(rows), nil
}

// aggregate folds raw tile rows into ranked standings
func aggregate(rows []tileRow) []Standing {
	byUser := map[string]*Standing{}
	for _, r := range rows {
		s := byUser[r.Owner]
		if s == nil {
			s = &Standing{UserID: r.Owner}
			byUser[r.Owner] = s
		}
		s.TilesHeld++
		s.Strength += r.ClaimScore
		if r.IsHome != 0 {
			s.Score += 1
		} else {
			s.Score += game.TileValue(int(r.Captures))
		}
	}

	standings := make([]Standing, 0, len(byUser))
	for _, s := range byUser {
		standings = append(standings, *s)
	}
	sort.Slice(standings, func(i, j int) bool {
		if standings[i].Score != standings[j].Score {
			return standings[i].Score > standings[j].Score
		}
		return standings[i].UserID < standings[j].UserID
	})
	for i := range standings {
		standings[i].Rank = i + 1
	}
	return standings
}

// GenerateAll writes one daily snapshot per ranked player
func GenerateAll(app core.App, now time.Time) error {
	standings, err := Standings(app)
	if err != nil {
		return err
	}
	for _, s := range standings {
		if snapshotExistsToday(app, s.UserID, now) {
			continue
		}
		if err := writeSnapshot(app, s, now); err != nil {
			app.Logger().Error("empire snapshot failed", "user", s.UserID, "error", err)
		}
	}
	return nil
}

// SnapshotUser records one user's current standing, at most once per day
func SnapshotUser(app core.App, userID string, now time.Time) error {
	if userID == "" || snapshotExistsToday(app, userID, now) {
		return nil
	}
	standings, err := Standings(app)
	if err != nil {
		return err
	}
	for _, s := range standings {
		if s.UserID == userID {
			return writeSnapshot(app, s, now)
		}
	}
	return nil
}

func writeSnapshot(app core.App, s Standing, now time.Time) error {
	col, err := app.FindCollectionByNameOrId("empire_snapshots")
	if err != nil {
		return err
	}

	prevRank, prevTiles := lastSnapshot(app, s.UserID)

	rec := core.NewRecord(col)
	rec.Set("user", s.UserID)
	rec.Set("captured_at", now)
	rec.Set("tiles_held", s.TilesHeld)
	rec.Set("strength", s.Strength)
	rec.Set("score", s.Score)
	rec.Set("rank", s.Rank)
	if err := app.Save(rec); err != nil {
		return err
	}
	feed.RecordEmpireMilestones(app, s.UserID, s.Rank, prevRank, s.TilesHeld, prevTiles, now)
	return nil
}

// lastSnapshot returns the rank and tiles_held of the player's latest snapshot
func lastSnapshot(app core.App, userID string) (rank, tiles int) {
	recs, err := app.FindRecordsByFilter(
		"empire_snapshots",
		"user = {:u}",
		"-captured_at",
		1, 0,
		dbx.Params{"u": userID},
	)
	if err != nil || len(recs) == 0 {
		return 0, 0
	}
	return recs[0].GetInt("rank"), recs[0].GetInt("tiles_held")
}

// snapshotExistsToday reports whether the user already has a snapshot dated today
// in UTC
func snapshotExistsToday(app core.App, userID string, now time.Time) bool {
	recs, err := app.FindRecordsByFilter(
		"empire_snapshots",
		"user = {:u}",
		"-captured_at",
		1, 0,
		dbx.Params{"u": userID},
	)
	if err != nil || len(recs) == 0 {
		return false
	}
	last := recs[0].GetDateTime("captured_at").Time().UTC()
	n := now.UTC()
	return last.Year() == n.Year() && last.YearDay() == n.YearDay()
}
