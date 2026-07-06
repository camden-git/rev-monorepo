package migrations

import (
	"fmt"
	"log"
	"strconv"

	"github.com/camden-git/rev-monorepo/backend/internal/game"
	"github.com/camden-git/rev-monorepo/backend/internal/hooks"
	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

func init() {
	m.Register(repairGlitchedDrivenSpeeds, revertRepairGlitchedDrivenSpeeds)
}

// glitchedSpeedFloorMph mirrors game.maxSegmentSpeed (134 m/s ≈ 300 mph): a
// legitimate reading can never pass the teleport bound, so anything above is a
// stored chip glitch
const glitchedSpeedFloorMph = 300.0

// monumentSpeedMph: glitch tiles at or above this are kept as trophies, absurd
// enough to be obviously unreal. only the believably-wrong band below is
// repaired since it quietly distorts tile history
const monumentSpeedMph = 1000.0

// neutralStrength is the claim_score given to a glitched tile when no honest
// re-derivation is possible: strength 1.0 = "drove it at the road's usual pace"
const neutralStrength = 1.0

// repairGlitchedDrivenSpeeds re-derives driven_speed and claim_score for tiles
// holding physically impossible speeds, using the owner's stored drive raw_paths
// through the current filter + scorer. tiles with no honest evidence fall back
// to driven_speed 0 (how enclosure tiles represent "no measured speed") and a
// neutral claim_score. monument tiles are left untouched on purpose
func repairGlitchedDrivenSpeeds(app core.App) error {
	tiles, err := app.FindCollectionByNameOrId("tiles")
	if err != nil {
		return fmt.Errorf("find tiles: %w", err)
	}

	glitched := []*core.Record{}
	if err := app.RecordQuery(tiles).
		AndWhere(dbx.NewExp("driven_speed > {:floor} AND driven_speed < {:monument}",
			dbx.Params{"floor": glitchedSpeedFloorMph, "monument": monumentSpeedMph})).
		All(&glitched); err != nil {
		return fmt.Errorf("load glitched tiles: %w", err)
	}
	if len(glitched) == 0 {
		log.Print("repair-glitched-speeds: no tiles in the repairable glitch band")
		return nil
	}

	owners := map[string]bool{}
	for _, rec := range glitched {
		if owner := rec.GetString("owner"); owner != "" {
			owners[owner] = true
		}
	}

	// best honest per-tile speed observed across each owner's drives, re-scored
	// with the current pipeline (Doppler spikes invalidated, envelope enforced)
	bestByOwnerTile := map[string]map[uint64]float64{}
	if len(owners) > 0 {
		ownerIDs := make([]any, 0, len(owners))
		for id := range owners {
			ownerIDs = append(ownerIDs, id)
		}
		drivesCol, err := app.FindCollectionByNameOrId("drives")
		if err != nil {
			return fmt.Errorf("find drives: %w", err)
		}
		drives := []*core.Record{}
		if err := app.RecordQuery(drivesCol).AndWhere(dbx.In("user", ownerIDs...)).All(&drives); err != nil {
			return fmt.Errorf("load drives: %w", err)
		}
		for _, drive := range drives {
			var rawPath []hooks.RawSample
			if err := drive.UnmarshalJSONField("raw_path", &rawPath); err != nil {
				continue // an unreadable path just contributes no evidence
			}
			perTile := game.PerTileScores(game.FilterOutliers(hooks.SamplesFromRaw(rawPath)))
			owner := drive.GetString("user")
			if bestByOwnerTile[owner] == nil {
				bestByOwnerTile[owner] = map[uint64]float64{}
			}
			for h3, mph := range perTile {
				if mph > bestByOwnerTile[owner][h3] {
					bestByOwnerTile[owner][h3] = mph
				}
			}
		}
	}

	err = app.RunInTransaction(func(txApp core.App) error {
		for _, rec := range glitched {
			oldSpeed := rec.GetFloat("driven_speed")
			owner := rec.GetString("owner")
			h3, perr := strconv.ParseUint(rec.GetString("h3"), 10, 64)

			speedMph := 0.0
			if perr == nil {
				speedMph = bestByOwnerTile[owner][h3]
			}

			band := game.BandForClass(game.RoadClass(rec.GetString("road_class")))
			ref := rec.GetFloat("ref_speed")
			if ref <= 0 {
				ref = band.Prior
			}
			strength := neutralStrength
			if speedMph > 0 {
				strength = game.Strength(speedMph, game.ClampReference(ref, band))
			}

			rec.Set("driven_speed", speedMph)
			rec.Set("claim_score", strength)
			if err := txApp.Save(rec); err != nil {
				return fmt.Errorf("save tile %s: %w", rec.Id, err)
			}
			log.Printf("repair-glitched-speeds: tile %s %.1f mph -> %.1f mph (claim_score %.2f)",
				rec.Id, oldSpeed, speedMph, strength)
		}
		return nil
	})
	if err != nil {
		return err
	}

	log.Printf("repair-glitched-speeds: repaired %d tiles in the %.0f-%.0f mph glitch band (monuments above kept)",
		len(glitched), glitchedSpeedFloorMph, monumentSpeedMph)
	return nil
}

// revertRepairGlitchedDrivenSpeeds is a no-op: the glitched values are not worth restoring
func revertRepairGlitchedDrivenSpeeds(app core.App) error {
	return nil
}
