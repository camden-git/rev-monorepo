package migrations

import (
	"fmt"

	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

func init() {
	m.Register(addTilesRoadClass, removeTilesRoadClass)
}

// addTilesRoadClass adds the per-tile OSM road class used to anchor reference
// speed to an unbiased, road-aware prior
func addTilesRoadClass(app core.App) error {
	tiles, err := app.FindCollectionByNameOrId("tiles")
	if err != nil {
		return fmt.Errorf("find tiles: %w", err)
	}
	if tiles.Fields.GetByName("road_class") != nil {
		return nil
	}
	tiles.Fields.Add(&core.TextField{Name: "road_class", Max: 20})
	if err := app.Save(tiles); err != nil {
		return fmt.Errorf("save tiles: %w", err)
	}
	return nil
}

func removeTilesRoadClass(app core.App) error {
	tiles, err := app.FindCollectionByNameOrId("tiles")
	if err != nil {
		return fmt.Errorf("find tiles: %w", err)
	}
	tiles.Fields.RemoveByName("road_class")
	if err := app.Save(tiles); err != nil {
		return fmt.Errorf("save tiles: %w", err)
	}
	return nil
}
