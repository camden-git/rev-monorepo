package migrations

import (
	"fmt"
	"strconv"
	"strings"

	"github.com/camden-git/rev-monorepo/backend/internal/h3util"
	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

func init() {
	m.Register(addTilesH3R8, removeTilesH3R8)
}

func addTilesH3R8(app core.App) error {
	tiles, err := app.FindCollectionByNameOrId("tiles")
	if err != nil {
		return fmt.Errorf("find tiles: %w", err)
	}

	changed := false
	if tiles.Fields.GetByName("h3_r8") == nil {
		tiles.Fields.Add(&core.TextField{Name: "h3_r8", Max: 20})
		changed = true
	}
	if !collectionHasIndex(tiles, "idx_tiles_h3_r8") {
		tiles.Indexes = append(tiles.Indexes, "CREATE INDEX idx_tiles_h3_r8 ON tiles (h3_r8)")
		changed = true
	}
	if changed {
		if err := app.Save(tiles); err != nil {
			return fmt.Errorf("save tiles: %w", err)
		}
	}

	records := []*core.Record{}
	if err := app.RecordQuery(tiles).All(&records); err != nil {
		return fmt.Errorf("load tiles: %w", err)
	}
	for _, rec := range records {
		if rec.GetString("h3_r8") != "" {
			continue
		}
		h3, err := strconv.ParseUint(rec.GetString("h3"), 10, 64)
		if err != nil {
			continue
		}
		parent, ok := h3util.Parent(h3, h3util.TileWindowParentResolution)
		if !ok {
			continue
		}
		rec.Set("h3_r8", strconv.FormatUint(parent, 10))
		if err := app.Save(rec); err != nil {
			return fmt.Errorf("backfill tile %s h3_r8: %w", rec.Id, err)
		}
	}
	return nil
}

func removeTilesH3R8(app core.App) error {
	tiles, err := app.FindCollectionByNameOrId("tiles")
	if err != nil {
		return fmt.Errorf("find tiles: %w", err)
	}
	tiles.Fields.RemoveByName("h3_r8")
	filtered := tiles.Indexes[:0]
	for _, idx := range tiles.Indexes {
		if !strings.Contains(idx, "idx_tiles_h3_r8") {
			filtered = append(filtered, idx)
		}
	}
	tiles.Indexes = filtered
	if err := app.Save(tiles); err != nil {
		return fmt.Errorf("save tiles: %w", err)
	}
	return nil
}

func collectionHasIndex(collection *core.Collection, name string) bool {
	for _, idx := range collection.Indexes {
		if strings.Contains(idx, name) {
			return true
		}
	}
	return false
}
