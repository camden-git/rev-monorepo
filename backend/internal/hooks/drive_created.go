package hooks

import (
	"errors"
	"fmt"
	"strconv"
	"time"

	"github.com/camden-git/rev-monorepo/backend/internal/game"
	"github.com/camden-git/rev-monorepo/backend/internal/h3util"
	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"
)

// RegisterDriveHooks attaches the drive-resolution hook to the app
func RegisterDriveHooks(app core.App) {
	app.OnRecordCreateRequest("drives").BindFunc(func(e *core.RecordRequestEvent) error {
		if err := stampDriveOwner(e); err != nil {
			return err
		}
		return e.Next()
	})

	app.OnRecordAfterCreateSuccess("drives").BindFunc(func(e *core.RecordEvent) error {
		// the drive is already persisted. Resolution runs in its own transaction,
		// if it fails we log and still return success so the client's upload queue
		// flips uploaded=true. the client reconciles tile state on the next delta-poll anyway
		if err := resolveDrive(e.App, e.Record); err != nil {
			e.App.Logger().Error("drive resolution failed", "drive", e.Record.Id, "error", err)
		}
		return e.Next()
	})
}

func stampDriveOwner(e *core.RecordRequestEvent) error {
	if e.Auth == nil || !e.Auth.Collection().IsAuth() || e.Auth.Collection().Name != "users" {
		return e.UnauthorizedError("Drive uploads require a signed-in user.", nil)
	}
	e.Record.Set("user", e.Auth.Id)
	return nil
}

// gpsSample is the slice of drives.raw_path the server uses
type gpsSample struct {
	Lat float64 `json:"lat"`
	Lng float64 `json:"lng"`
}

func resolveDrive(app core.App, drive *core.Record) error {
	userID := drive.GetString("user")
	if userID == "" {
		return errors.New("drive has no user")
	}

	var perTile map[string]float64
	if err := drive.UnmarshalJSONField("per_tile_scores", &perTile); err != nil {
		return fmt.Errorf("per_tile_scores: %w", err)
	}
	var rawPath []gpsSample
	if err := drive.UnmarshalJSONField("raw_path", &rawPath); err != nil {
		return fmt.Errorf("raw_path: %w", err)
	}

	now := time.Now()

	// TODO: re-derive per_tile_scores from raw_path via a ported TileScoring
	// for anticheat

	return app.RunInTransaction(func(txApp core.App) error {
		// 1: per-tile direct resolution
		claimedThisDrive := map[uint64]bool{}
		for h3str, score := range perTile {
			h3, err := strconv.ParseUint(h3str, 10, 64)
			if err != nil {
				continue // skip malformed keys rather than fail the whole drive
			}
			changed, err := resolveTile(txApp, h3, userID, score, now)
			if err != nil {
				return err
			}
			if changed {
				claimedThisDrive[h3] = true
			}
		}

		// 2: enclosure flood-fill
		if err := resolveEnclosure(txApp, drive, userID, rawPath, perTile, claimedThisDrive, now); err != nil {
			return err
		}

		// TODO: APNs silent push to affected owners
		return nil
	})
}

// ResolveDirectClaims applies a batch of direct per-tile claims for one user in a
// single transaction
//
// used by the live in-drive claim endpoint so captures broadcast over the `tiles`
// realtime topic as they happen instead of only when the drive is uploaded
func ResolveDirectClaims(app core.App, userID string, perTile map[string]float64, now time.Time) error {
	if userID == "" {
		return errors.New("claim batch has no user")
	}
	return app.RunInTransaction(func(txApp core.App) error {
		for h3str, score := range perTile {
			h3, err := strconv.ParseUint(h3str, 10, 64)
			if err != nil {
				continue // skip malformed keys rather than fail the whole batch
			}
			if _, err := resolveTile(txApp, h3, userID, score, now); err != nil {
				return err
			}
		}
		return nil
	})
}

// resolveTile applies one direct claim and reports whether the tile changed
func resolveTile(txApp core.App, h3 uint64, userID string, score float64, now time.Time) (bool, error) {
	h3str := strconv.FormatUint(h3, 10)
	existing := findTile(txApp, h3str)

	var current *game.TileState
	if existing != nil {
		current = &game.TileState{
			OwnerID:      existing.GetString("owner"),
			ClaimScore:   existing.GetFloat("claim_score"),
			LastDrivenAt: existing.GetDateTime("last_driven_at").Time(),
			IsHome:       existing.GetBool("is_home"),
		}
	}

	outcome := game.Resolve(current, userID, score, now)
	switch outcome.Kind {
	case game.NoChange:
		return false, nil

	case game.Created:
		if err := createTile(txApp, h3str, userID, outcome.Score, false, now); err != nil {
			return false, err
		}
		return true, nil

	case game.Reinforced:
		setTileWindowParent(existing, h3)
		existing.Set("claim_score", outcome.Score)
		existing.Set("last_driven_at", now)
		if err := txApp.Save(existing); err != nil {
			return false, err
		}
		return true, nil

	case game.Captured:
		setTileWindowParent(existing, h3)
		existing.Set("owner", userID)
		existing.Set("claim_score", outcome.Score)
		existing.Set("last_driven_at", now)
		if err := txApp.Save(existing); err != nil {
			return false, err
		}
		// append tile_history on ownership change
		if err := appendHistory(txApp, h3str, userID, outcome.Score, now); err != nil {
			return false, err
		}
		return true, nil
	}
	return false, nil
}

// resolveEnclosure detects the loop the drive closed and claims its interior
//
// game.Enclose assigns a linear diffusion gradient to the interior (falls to 0 by 20%)
// each interior cell is then claimed through the normal resolver (game.Resolve),
// exactly like the client's DriveTracker.captureEnclosureIfClosed,
// which calls store.claim per interior cell
func resolveEnclosure(
	txApp core.App,
	drive *core.Record,
	userID string,
	rawPath []gpsSample,
	perTile map[string]float64,
	claimedThisDrive map[uint64]bool,
	now time.Time,
) error {
	points := make([]game.Point, len(rawPath))
	for i, s := range rawPath {
		points[i] = game.Point{Lat: s.Lat, Lng: s.Lng}
	}
	trail := game.TilesCrossed(points)
	if len(trail) < 3 {
		return nil
	}

	homeCell := userHomeCell(txApp, userID)

	// walls = the user's currently-owned tiles, minus the home hex and minus the
	// tiles this very drive just claimed
	owned := map[uint64]bool{}
	ownedRecs, err := txApp.FindRecordsByFilter("tiles", "owner = {:u}", "", 0, 0, dbx.Params{"u": userID})
	if err != nil {
		return fmt.Errorf("load owned tiles: %w", err)
	}
	for _, r := range ownedRecs {
		h3, perr := strconv.ParseUint(r.GetString("h3"), 10, 64)
		if perr != nil || r.GetBool("is_home") || claimedThisDrive[h3] {
			continue
		}
		owned[h3] = true
	}

	opt := game.DefaultEncloseOptions(meanScore(perTile))
	opt.Owned = owned
	result := game.Enclose(trail, opt)

	// claim each interior cell through the same resolver as a direct drive
	for h3, score := range result.ScoredInterior {
		if score <= 0 || h3 == homeCell {
			continue
		}
		if _, err := resolveTile(txApp, h3, userID, score, now); err != nil {
			return err
		}
	}
	return nil
}

// MARK: helpers

func findTile(txApp core.App, h3str string) *core.Record {
	rec, err := txApp.FindFirstRecordByFilter("tiles", "h3 = {:h3}", dbx.Params{"h3": h3str})
	if err != nil {
		return nil
	}
	return rec
}

func createTile(txApp core.App, h3str, userID string, score float64, isHome bool, now time.Time) error {
	col, err := txApp.FindCollectionByNameOrId("tiles")
	if err != nil {
		return err
	}
	rec := core.NewRecord(col)
	rec.Set("h3", h3str)
	if h3, err := strconv.ParseUint(h3str, 10, 64); err == nil {
		setTileWindowParent(rec, h3)
	}
	rec.Set("owner", userID)
	rec.Set("claim_score", score)
	rec.Set("last_driven_at", now)
	rec.Set("is_home", isHome)
	return txApp.Save(rec)
}

func setTileWindowParent(rec *core.Record, h3 uint64) {
	if parent, ok := h3util.Parent(h3, h3util.TileWindowParentResolution); ok {
		rec.Set("h3_r8", strconv.FormatUint(parent, 10))
	}
}

func appendHistory(txApp core.App, h3str, userID string, score float64, now time.Time) error {
	col, err := txApp.FindCollectionByNameOrId("tile_history")
	if err != nil {
		return err
	}
	rec := core.NewRecord(col)
	rec.Set("h3", h3str)
	rec.Set("owner", userID)
	rec.Set("claim_score", score)
	rec.Set("occurred_at", now)
	return txApp.Save(rec)
}

func userHomeCell(txApp core.App, userID string) uint64 {
	user, err := txApp.FindRecordById("users", userID)
	if err != nil {
		return 0
	}
	h3, err := strconv.ParseUint(user.GetString("home_h3"), 10, 64)
	if err != nil {
		return 0
	}
	return h3
}

func meanScore(perTile map[string]float64) float64 {
	if len(perTile) == 0 {
		return 0
	}
	var sum float64
	for _, s := range perTile {
		sum += s
	}
	return sum / float64(len(perTile))
}
