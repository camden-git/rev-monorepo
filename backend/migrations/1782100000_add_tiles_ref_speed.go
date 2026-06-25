package migrations

import (
	"fmt"

	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

func init() {
	m.Register(addTilesRefSpeed, removeTilesRefSpeed)
}

// addTilesRefSpeed restores the per-tile reference-speed columns
func addTilesRefSpeed(app core.App) error {
	tiles, err := app.FindCollectionByNameOrId("tiles")
	if err != nil {
		return fmt.Errorf("find tiles: %w", err)
	}
	changed := false
	if tiles.Fields.GetByName("ref_speed") == nil {
		tiles.Fields.Add(&core.NumberField{Name: "ref_speed"})
		changed = true
	}
	if tiles.Fields.GetByName("obs_count") == nil {
		tiles.Fields.Add(&core.NumberField{Name: "obs_count"})
		changed = true
	}
	if !changed {
		return nil
	}
	if err := app.Save(tiles); err != nil {
		return fmt.Errorf("save tiles: %w", err)
	}
	return nil
}

func removeTilesRefSpeed(app core.App) error {
	tiles, err := app.FindCollectionByNameOrId("tiles")
	if err != nil {
		return fmt.Errorf("find tiles: %w", err)
	}
	tiles.Fields.RemoveByName("ref_speed")
	tiles.Fields.RemoveByName("obs_count")
	if err := app.Save(tiles); err != nil {
		return fmt.Errorf("save tiles: %w", err)
	}
	return nil
}
