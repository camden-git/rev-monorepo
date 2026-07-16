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
	m.Register(repairLegacySpeedScores, revertRepairLegacySpeedScores)
}

// suspectSpeedFloorMph: driven speeds above this are believably wrong
const suspectSpeedFloorMph = 180.0

// legacyMonumentSpeedMph is for the da
const legacyMonumentSpeedMph = 1000.0

// legacyNeutralStrength is the claim_score given when no honest re-derivation
// is possible
const legacyNeutralStrength = 1.0

// repairLegacySpeedScores fixes two classes of bad tile
func repairLegacySpeedScores(app core.App) error {
	tiles, err := app.FindCollectionByNameOrId("tiles")
	if err != nil {
		return fmt.Errorf("find tiles: %w", err)
	}

	suspect := []*core.Record{}
	if err := app.RecordQuery(tiles).
		AndWhere(dbx.Or(
			dbx.NewExp("driven_speed > {:floor} AND driven_speed < {:monument}",
				dbx.Params{"floor": suspectSpeedFloorMph, "monument": legacyMonumentSpeedMph}),
			dbx.NewExp("claim_score > {:cap}", dbx.Params{"cap": game.StrengthCap}),
		)).
		All(&suspect); err != nil {
		return fmt.Errorf("load suspect tiles: %w", err)
	}
	if len(suspect) == 0 {
		log.Print("repair-legacy-scores: no suspect tiles found")
		return nil
	}

	owners := map[string]bool{}
	for _, rec := range suspect {
		if owner := rec.GetString("owner"); owner != "" {
			owners[owner] = true
		}
	}

	// best honest per-tile speed observed across each owner's drives, re-scored
	// with the current pipeline
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
				continue // unreadable path, no evidence
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

	repaired := 0
	err = app.RunInTransaction(func(txApp core.App) error {
		for _, rec := range suspect {
			oldSpeed := rec.GetFloat("driven_speed")
			oldScore := rec.GetFloat("claim_score")
			owner := rec.GetString("owner")

			speedMph := 0.0
			if h3, perr := strconv.ParseUint(rec.GetString("h3"), 10, 64); perr == nil {
				speedMph = bestByOwnerTile[owner][h3]
			}

			band := game.BandForClass(game.RoadClass(rec.GetString("road_class")))
			ref := rec.GetFloat("ref_speed")
			if ref <= 0 {
				ref = band.Prior
			}
			strength := legacyNeutralStrength
			if speedMph > 0 {
				strength = game.Strength(speedMph, game.ClampReference(ref, band))
			}

			// trophy speeds
			if oldSpeed < legacyMonumentSpeedMph {
				rec.Set("driven_speed", speedMph)
			}
			if oldScore > game.StrengthCap || oldSpeed < legacyMonumentSpeedMph {
				rec.Set("claim_score", strength)
			}
			if err := txApp.Save(rec); err != nil {
				return fmt.Errorf("save tile %s: %w", rec.Id, err)
			}
			repaired++
			log.Printf("repair-legacy-scores: tile %s %.1f mph / score %.2f -> %.1f mph / score %.2f",
				rec.Id, oldSpeed, oldScore, rec.GetFloat("driven_speed"), rec.GetFloat("claim_score"))
		}
		return nil
	})
	if err != nil {
		return err
	}

	log.Printf("repair-legacy-scores: repaired %d tiles matching driven_speed %.0f-%.0f mph or claim_score > %.0f",
		repaired, suspectSpeedFloorMph, legacyMonumentSpeedMph, game.StrengthCap)
	return nil
}

func revertRepairLegacySpeedScores(app core.App) error {
	return nil
}
