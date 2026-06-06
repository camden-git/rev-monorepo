package migrations

import (
	"fmt"

	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

func init() {
	m.Register(requireAuthForTiles, openTilesToPublic)
}

// requireAuthForTiles closes the tiles collection so only signed-in users can
// read the map
func requireAuthForTiles(app core.App) error {
	tiles, err := app.FindCollectionByNameOrId("tiles")
	if err != nil {
		return fmt.Errorf("find tiles: %w", err)
	}

	tiles.ListRule = ptr(`@request.auth.id != ""`)
	tiles.ViewRule = ptr(`@request.auth.id != ""`)

	if err := app.Save(tiles); err != nil {
		return fmt.Errorf("save tiles auth rules: %w", err)
	}
	return nil
}

func openTilesToPublic(app core.App) error {
	tiles, err := app.FindCollectionByNameOrId("tiles")
	if err != nil {
		return fmt.Errorf("find tiles: %w", err)
	}

	tiles.ListRule = ptr("")
	tiles.ViewRule = ptr("")

	if err := app.Save(tiles); err != nil {
		return fmt.Errorf("restore tiles public rules: %w", err)
	}
	return nil
}
