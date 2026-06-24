package migrations

import (
	"fmt"

	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

func init() {
	m.Register(addTilesDrivenSpeed, removeTilesDrivenSpeed)
}

// addTilesDrivenSpeed records the raw mph of the observation that set a tile's
// current claim_score, so the inspector can show the actual speed driven instead
// of reconstructing it from the (capped) strength
func addTilesDrivenSpeed(app core.App) error {
	tiles, err := app.FindCollectionByNameOrId("tiles")
	if err != nil {
		return fmt.Errorf("find tiles: %w", err)
	}
	if tiles.Fields.GetByName("driven_speed") != nil {
		return nil
	}
	tiles.Fields.Add(&core.NumberField{Name: "driven_speed"})
	if err := app.Save(tiles); err != nil {
		return fmt.Errorf("save tiles: %w", err)
	}
	return nil
}

func removeTilesDrivenSpeed(app core.App) error {
	tiles, err := app.FindCollectionByNameOrId("tiles")
	if err != nil {
		return fmt.Errorf("find tiles: %w", err)
	}
	tiles.Fields.RemoveByName("driven_speed")
	if err := app.Save(tiles); err != nil {
		return fmt.Errorf("save tiles: %w", err)
	}
	return nil
}
