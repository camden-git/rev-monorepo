package migrations

import (
	"fmt"
	"log"
	"strconv"

	"github.com/camden-git/rev-monorepo/backend/internal/geofence"
	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

func init() {
	m.Register(deleteTilesOutsideChicago, revertDeleteTilesOutsideChicago)
}

// deleteTilesOutsideChicago deletes every tile whose center is outside Chicago
func deleteTilesOutsideChicago(app core.App) error {
	tiles, err := app.FindCollectionByNameOrId("tiles")
	if err != nil {
		return fmt.Errorf("find tiles: %w", err)
	}

	records := []*core.Record{}
	if err := app.RecordQuery(tiles).All(&records); err != nil {
		return fmt.Errorf("load tiles: %w", err)
	}

	deleted := 0
	err = app.RunInTransaction(func(txApp core.App) error {
		for _, rec := range records {
			h3, perr := strconv.ParseUint(rec.GetString("h3"), 10, 64)
			if perr == nil && geofence.ContainsCell(h3) {
				continue
			}
			if perr != nil {
				// an unparseable h3 id can never be played, so drop it too
				log.Printf("delete-outside-chicago: tile %s has invalid h3 %q, deleting", rec.Id, rec.GetString("h3"))
			}
			if err := txApp.Delete(rec); err != nil {
				return fmt.Errorf("delete tile %s: %w", rec.Id, err)
			}
			deleted++
		}
		return nil
	})
	if err != nil {
		return err
	}

	log.Printf("delete-outside-chicago: deleted %d of %d tiles outside Chicago", deleted, len(records))
	return nil
}

// revertDeleteTilesOutsideChicago is a no-op: deleted tiles cannot be restored
func revertDeleteTilesOutsideChicago(app core.App) error {
	return nil
}
