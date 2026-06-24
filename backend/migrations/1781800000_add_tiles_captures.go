package migrations

import (
	"fmt"

	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

func init() {
	m.Register(addTilesCaptures, removeTilesCaptures)
}

func addTilesCaptures(app core.App) error {
	tiles, err := app.FindCollectionByNameOrId("tiles")
	if err != nil {
		return fmt.Errorf("find tiles: %w", err)
	}
	if tiles.Fields.GetByName("captures") != nil {
		return nil
	}
	tiles.Fields.Add(&core.NumberField{Name: "captures"})
	if err := app.Save(tiles); err != nil {
		return fmt.Errorf("save tiles: %w", err)
	}
	return nil
}

func removeTilesCaptures(app core.App) error {
	tiles, err := app.FindCollectionByNameOrId("tiles")
	if err != nil {
		return fmt.Errorf("find tiles: %w", err)
	}
	tiles.Fields.RemoveByName("captures")
	if err := app.Save(tiles); err != nil {
		return fmt.Errorf("save tiles: %w", err)
	}
	return nil
}
