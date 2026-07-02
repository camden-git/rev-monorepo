package hooks

import (
	"errors"
	"fmt"
	"strconv"
	"time"

	"github.com/camden-git/rev-monorepo/backend/internal/feed"
	"github.com/camden-git/rev-monorepo/backend/internal/game"
	"github.com/camden-git/rev-monorepo/backend/internal/geofence"
	"github.com/camden-git/rev-monorepo/backend/internal/h3util"
	"github.com/camden-git/rev-monorepo/backend/internal/notify"
	"github.com/camden-git/rev-monorepo/backend/internal/stats"
	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"
)

// RegisterDriveHooks attaches the drive-resolution hook to the app
func RegisterDriveHooks(app core.App, notifier notify.Notifier) {
	app.OnRecordCreateRequest("drives").BindFunc(func(e *core.RecordRequestEvent) error {
		if err := stampDriveOwner(e); err != nil {
			return err
		}
		return e.Next()
	})

	app.OnRecordAfterCreateSuccess("drives").BindFunc(func(e *core.RecordEvent) error {
		// the drive is already persisted. Resolution runs in its own transaction,
		// if it fails we log and still return success so the client's upload queue
		// flips uploaded=true. the client reconciles tile state on the next delta-poll anyway.
		// Also persist the failure on the drive so it is queryable/retryable
		// rather than living only in the logs
		if err := resolveDrive(e.App, e.Record, notifier); err != nil {
			e.App.Logger().Error("drive resolution failed", "drive", e.Record.Id, "error", err)
			e.Record.Set("resolve_error", err.Error())
			if saveErr := e.App.Save(e.Record); saveErr != nil {
				e.App.Logger().Error("failed to record drive resolve_error", "drive", e.Record.Id, "error", saveErr)
			}
		}
		// fold the new territory into the driver's stat history
		if err := stats.SnapshotUser(e.App, e.Record.GetString("user"), time.Now()); err != nil {
			e.App.Logger().Error("post-drive snapshot failed", "drive", e.Record.Id, "error", err)
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

// RawSample is one drives.raw_path entry as stored on the wire. It mirrors the
// RevKit GPSSample JSON shape ({timestamp, lat, lng, speed, accuracy}); the
// server reads timestamp, lat, lng, speed, and accuracy
type RawSample struct {
	TS       string  `json:"timestamp"`
	Lat      float64 `json:"lat"`
	Lng      float64 `json:"lng"`
	Speed    float64 `json:"speed"`
	Accuracy float64 `json:"accuracy"`
}

// rawPathTimeLayout is the datetime format RevKit's PocketBaseCoding writes into
// raw_path timestamps (see ios .../Sync/PocketBaseCoding.swift)
const rawPathTimeLayout = "2006-01-02 15:04:05.000Z"

// SamplesFromRaw parses raw_path entries into scoring samples, dropping any whose
// timestamp can't be parsed (a sample with no usable time can't be scored)
func SamplesFromRaw(raw []RawSample) []game.Sample {
	out := make([]game.Sample, 0, len(raw))
	for _, s := range raw {
		ts, err := time.Parse(rawPathTimeLayout, s.TS)
		if err != nil {
			if ts, err = time.Parse(time.RFC3339Nano, s.TS); err != nil {
				continue
			}
		}
		out = append(out, game.Sample{TS: ts, Lat: s.Lat, Lng: s.Lng, Speed: s.Speed, Accuracy: s.Accuracy})
	}
	return out
}

func resolveDrive(app core.App, drive *core.Record, notifier notify.Notifier) error {
	userID := drive.GetString("user")
	if userID == "" {
		return errors.New("drive has no user")
	}

	var rawPath []RawSample
	if err := drive.UnmarshalJSONField("raw_path", &rawPath); err != nil {
		return fmt.Errorf("raw_path: %w", err)
	}

	now := time.Now()

	// server-authoritative scoring: re-derive per-tile scores from the raw GPS
	// path itself rather than trusting the client-supplied per_tile_scores (kept
	// only for the client's own optimistic in-drive preview)
	cleaned := game.FilterOutliers(SamplesFromRaw(rawPath))
	perTile := game.PerTileScores(cleaned)

	// owners this drive displaced, tallied so each victim gets one aggregated
	// push rather than one per tile. populated inside the transaction, dispatched
	// only after it commits.
	captures := map[string]int{}
	// gained = newly-won ground (created + captured + enclosed; not reinforced),
	// accumulated for the drive's feed event and personal records
	gained := 0
	err := app.RunInTransaction(func(txApp core.App) error {
		// 1: per-tile direct resolution
		claimedThisDrive := map[uint64]bool{}
		strengths := map[uint64]float64{}
		for h3, score := range perTile {
			changed, strength, capturedFrom, kind, err := resolveTile(txApp, h3, userID, score, now)
			if err != nil {
				return err
			}
			strengths[h3] = strength
			if changed {
				claimedThisDrive[h3] = true
			}
			if kind == game.Created || kind == game.Captured {
				gained++
			}
			if capturedFrom != "" {
				captures[capturedFrom]++
			}
		}

		// 2: enclosure flood-fill over the same cleaned path
		enclosedGained, err := resolveEnclosure(txApp, drive, userID, cleaned, strengths, claimedThisDrive, now, captures)
		if err != nil {
			return err
		}
		gained += enclosedGained
		return nil
	})
	if err != nil {
		return err
	}
	notifyCaptures(notifier, userID, captures)

	// persist the resolved deltas, then record the drive's feed moments (drive,
	// captures, PRs, streak, achievements)
	captured := 0
	for _, c := range captures {
		captured += c
	}
	drive.Set("tiles_gained", gained)
	drive.Set("tiles_captured", captured)
	if err := app.Save(drive); err != nil {
		app.Logger().Error("failed to persist drive deltas", "drive", drive.Id, "error", err)
	}
	feed.RecordDriveEvents(app, drive, feed.DriveStats{Captures: captures, Gained: gained, Captured: captured}, now)
	return nil
}

// notifyCaptures raises one aggregated push per displaced owner.
func notifyCaptures(notifier notify.Notifier, attackerID string, captures map[string]int) {
	if notifier == nil {
		return
	}
	for victimID, count := range captures {
		notifier.TileCaptured(victimID, attackerID, count)
	}
}

// ResolveDirectClaims scores a batch of raw GPS samples for one user and applies
// the resulting direct per-tile claims in a single transaction
//
// used by the live in-drive claim endpoint so captures broadcast over the `tiles`
// realtime topic as they happen instead of only when the drive is uploaded. like
// the end-of-drive resolution it derives per-tile scores from the raw path
// server-side, so a live capture is just as authoritative as the final upload
//
// returns the owners this batch displaced (victim id -> tile count) so the live
// claim route can push capture notifications as they happen. captures are
// collected inside the transaction but only returned after it commits, so a
// rolled-back batch raises nothing.
func ResolveDirectClaims(app core.App, userID string, samples []game.Sample, now time.Time) (map[string]int, error) {
	if userID == "" {
		return nil, errors.New("claim batch has no user")
	}
	perTile := game.PerTileScores(game.FilterOutliers(samples))
	captures := map[string]int{}
	err := app.RunInTransaction(func(txApp core.App) error {
		for h3, score := range perTile {
			_, _, capturedFrom, _, err := resolveTile(txApp, h3, userID, score, now)
			if err != nil {
				return err
			}
			if capturedFrom != "" {
				captures[capturedFrom]++
			}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return captures, nil
}

// resolveTile applies one direct raw-mph observation and reports whether the
// ownership state changed, the normalized claim strength used for comparison,
// the id of the owner displaced on a capture ("" when none), and how the claim
// resolved (so callers can tally newly-won ground)
func resolveTile(txApp core.App, h3 uint64, userID string, speedMph float64, now time.Time) (bool, float64, string, game.OutcomeKind, error) {
	// Rev is only played in Chicago
	if !geofence.ContainsCell(h3) {
		return false, 0, "", game.NoChange, nil
	}
	h3str := strconv.FormatUint(h3, 10)
	existing := findTile(txApp, h3str)

	band := game.BandForClass(game.ClassUnknown)
	refSpeed := band.Prior
	obsCount := 0
	var current *game.TileState
	if existing != nil {
		band = game.BandForClass(game.RoadClass(existing.GetString("road_class")))
		if storedRef := existing.GetFloat("ref_speed"); storedRef > 0 {
			refSpeed = storedRef
		} else {
			refSpeed = band.Prior
		}
		obsCount = existing.GetInt("obs_count")
		current = &game.TileState{
			OwnerID:      existing.GetString("owner"),
			ClaimScore:   existing.GetFloat("claim_score"),
			LastDrivenAt: existing.GetDateTime("last_driven_at").Time(),
			IsHome:       existing.GetBool("is_home"),
		}
	}

	// clamp into the band before scoring and before folding in the new sample so
	// neither the score nor the stored reference can leave the road's envelope
	effectiveRef := game.ClampReference(refSpeed, band)
	strength := game.Strength(speedMph, effectiveRef)
	nextRef := game.ClampReference(game.UpdateReference(effectiveRef, speedMph), band)
	nextObs := obsCount + 1

	outcome := game.Resolve(current, userID, strength, now)
	switch outcome.Kind {
	case game.NoChange:
		if existing != nil {
			setTileReference(existing, nextRef, nextObs)
			if err := txApp.Save(existing); err != nil {
				return false, strength, "", game.NoChange, err
			}
		}
		return false, strength, "", game.NoChange, nil

	case game.Created:
		if err := createTile(txApp, h3str, userID, outcome.Score, false, nextRef, nextObs, 0, speedMph, now); err != nil {
			return false, strength, "", game.Created, err
		}
		return true, strength, "", game.Created, nil

	case game.Reinforced:
		setTileWindowParent(existing, h3)
		setTileReference(existing, nextRef, nextObs)
		existing.Set("claim_score", outcome.Score)

		if current != nil && strength >= current.ClaimScore {
			existing.Set("driven_speed", speedMph)
		}
		existing.Set("last_driven_at", now)
		if err := txApp.Save(existing); err != nil {
			return false, strength, "", game.Reinforced, err
		}
		return true, strength, "", game.Reinforced, nil

	case game.Captured:
		previousOwner := existing.GetString("owner")
		captures := existing.GetInt("captures") + 1
		setTileWindowParent(existing, h3)
		setTileReference(existing, nextRef, nextObs)
		existing.Set("owner", userID)
		existing.Set("claim_score", outcome.Score)
		existing.Set("captures", captures)
		existing.Set("driven_speed", speedMph)
		existing.Set("last_driven_at", now)
		if err := txApp.Save(existing); err != nil {
			return false, strength, "", game.Captured, err
		}
		// append tile_history on ownership change
		if err := appendHistory(txApp, h3str, userID, outcome.Score, now); err != nil {
			return false, strength, "", game.Captured, err
		}
		return true, strength, previousOwner, game.Captured, nil
	}
	return false, strength, "", game.NoChange, nil
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
	cleaned []game.Sample,
	perTileStrengths map[uint64]float64,
	claimedThisDrive map[uint64]bool,
	now time.Time,
	captures map[string]int,
) (int, error) {
	points := make([]game.Point, len(cleaned))
	for i, s := range cleaned {
		points[i] = game.Point{Lat: s.Lat, Lng: s.Lng}
	}
	trail := game.TilesCrossed(points)
	if len(trail) < 3 {
		return 0, nil
	}

	homeCell := userHomeCell(txApp, userID)

	// walls = the user's currently-owned tiles, minus the home hex and minus the
	// tiles this very drive just claimed
	owned := map[uint64]bool{}
	ownedRecs, err := txApp.FindRecordsByFilter("tiles", "owner = {:u}", "", 0, 0, dbx.Params{"u": userID})
	if err != nil {
		return 0, fmt.Errorf("load owned tiles: %w", err)
	}
	for _, r := range ownedRecs {
		h3, perr := strconv.ParseUint(r.GetString("h3"), 10, 64)
		if perr != nil || r.GetBool("is_home") || claimedThisDrive[h3] {
			continue
		}
		owned[h3] = true
	}

	opt := game.DefaultEncloseOptions(meanScore(perTileStrengths))
	opt.Owned = owned
	result := game.Enclose(trail, opt)

	// claim each interior cell through the same resolver as a direct drive
	gained := 0
	for h3, score := range result.ScoredInterior {
		if score <= 0 || h3 == homeCell {
			continue
		}
		_, _, capturedFrom, kind, err := resolveStrengthTile(txApp, h3, userID, score, now)
		if err != nil {
			return gained, err
		}
		if kind == game.Created || kind == game.Captured {
			gained++
		}
		if capturedFrom != "" {
			captures[capturedFrom]++
		}
	}
	return gained, nil
}

func resolveStrengthTile(txApp core.App, h3 uint64, userID string, strength float64, now time.Time) (bool, float64, string, game.OutcomeKind, error) {
	// Rev is only played in Chicago
	if !geofence.ContainsCell(h3) {
		return false, 0, "", game.NoChange, nil
	}
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

	outcome := game.Resolve(current, userID, strength, now)
	switch outcome.Kind {
	case game.NoChange:
		return false, strength, "", game.NoChange, nil
	case game.Created:

		if err := createTile(txApp, h3str, userID, outcome.Score, false, game.ReferenceSpeedPrior, 0, 0, 0, now); err != nil {
			return false, strength, "", game.Created, err
		}
		return true, strength, "", game.Created, nil
	case game.Reinforced:
		setTileWindowParent(existing, h3)
		existing.Set("claim_score", outcome.Score)

		if current != nil && strength >= current.ClaimScore {
			existing.Set("driven_speed", 0)
		}
		existing.Set("last_driven_at", now)
		if err := txApp.Save(existing); err != nil {
			return false, strength, "", game.Reinforced, err
		}
		return true, strength, "", game.Reinforced, nil
	case game.Captured:
		previousOwner := existing.GetString("owner")
		captures := existing.GetInt("captures") + 1
		setTileWindowParent(existing, h3)
		existing.Set("owner", userID)
		existing.Set("claim_score", outcome.Score)
		existing.Set("captures", captures)
		existing.Set("driven_speed", 0)
		existing.Set("last_driven_at", now)
		if err := txApp.Save(existing); err != nil {
			return false, strength, "", game.Captured, err
		}
		if err := appendHistory(txApp, h3str, userID, outcome.Score, now); err != nil {
			return false, strength, "", game.Captured, err
		}
		return true, strength, previousOwner, game.Captured, nil
	}
	return false, strength, "", game.NoChange, nil
}

// MARK: helpers

func findTile(txApp core.App, h3str string) *core.Record {
	rec, err := txApp.FindFirstRecordByFilter("tiles", "h3 = {:h3}", dbx.Params{"h3": h3str})
	if err != nil {
		return nil
	}
	return rec
}

// drivenSpeed is the raw mph that produced score, or 0 when the claim has no
// measured speed behind it (e.g. an enclosure fill)
func createTile(txApp core.App, h3str, userID string, score float64, isHome bool, refSpeed float64, obsCount int, captures int, drivenSpeed float64, now time.Time) error {
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
	rec.Set("ref_speed", refSpeed)
	rec.Set("obs_count", obsCount)
	rec.Set("captures", captures)
	rec.Set("driven_speed", drivenSpeed)
	rec.Set("last_driven_at", now)
	rec.Set("is_home", isHome)
	return txApp.Save(rec)
}

func setTileReference(rec *core.Record, refSpeed float64, obsCount int) {
	rec.Set("ref_speed", refSpeed)
	rec.Set("obs_count", obsCount)
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

func meanScore(perTile map[uint64]float64) float64 {
	if len(perTile) == 0 {
		return 0
	}
	var sum float64
	for _, s := range perTile {
		sum += s
	}
	return sum / float64(len(perTile))
}
