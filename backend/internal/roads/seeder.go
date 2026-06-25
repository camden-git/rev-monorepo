package roads

import (
	"context"
	"os"
	"strconv"
	"sync"
	"time"

	"github.com/camden-git/rev-monorepo/backend/internal/game"
	"github.com/camden-git/rev-monorepo/backend/internal/h3util"
	"github.com/pocketbase/pocketbase/core"
)

// sentinelNoRoad is stored in tiles.road_class once a tile has been looked up
// but no drivable road was found nearby
const sentinelNoRoad = "none"

// SeederConfig tunes the background road-class backfill
type SeederConfig struct {
	Enabled  bool
	Endpoint string
	// Batch is how many un-seeded tiles to resolve per run
	Batch int
	// Spacing is the delay between Overpass calls
	Spacing time.Duration
}

// ConfigFromEnv reads seeder configuration
func ConfigFromEnv() SeederConfig {
	cfg := SeederConfig{
		Enabled:  os.Getenv("REV_ROAD_SEED") != "0",
		Endpoint: os.Getenv("REV_OVERPASS_URL"),
		Batch:    8,
		Spacing:  2 * time.Second,
	}
	if b, err := strconv.Atoi(os.Getenv("REV_ROAD_SEED_BATCH")); err == nil && b > 0 {
		cfg.Batch = b
	}
	if cfg.Endpoint != "" {
		cfg.Spacing = 0
	}
	return cfg
}

// RegisterSeeder schedules the road-class backfill
func RegisterSeeder(app core.App, cfg SeederConfig) {
	if !cfg.Enabled {
		app.Logger().Info("road-class seeding disabled")
		return
	}
	client := NewClient(cfg.Endpoint)

	var running sync.Mutex
	app.Cron().MustAdd("roadClassSeed", "* * * * *", func() {
		if !running.TryLock() {
			return
		}
		defer running.Unlock()
		if err := SeedBatch(context.Background(), app, client, cfg); err != nil {
			app.Logger().Error("road-class seed batch failed", "error", err)
		}
	})
	app.Logger().Info("road-class seeding enabled", "endpoint", client.endpoint, "batch", cfg.Batch)
}

// SeedBatch resolves up to cfg.Batch tiles whose road_class is still empty
func SeedBatch(ctx context.Context, app core.App, client *Client, cfg SeederConfig) error {
	tiles, err := app.FindRecordsByFilter("tiles", "road_class = ''", "", cfg.Batch, 0)
	if err != nil {
		return err
	}
	for i, tile := range tiles {
		if i > 0 && cfg.Spacing > 0 {
			time.Sleep(cfg.Spacing)
		}
		if err := seedTile(ctx, app, client, tile); err != nil {
			// a failed lookup is transient
			app.Logger().Warn("road-class lookup failed", "h3", tile.GetString("h3"), "error", err)
		}
	}
	return nil
}

func seedTile(ctx context.Context, app core.App, client *Client, tile *core.Record) error {
	h3, err := strconv.ParseUint(tile.GetString("h3"), 10, 64)
	if err != nil {
		// malformed key
		tile.Set("road_class", sentinelNoRoad)
		return app.Save(tile)
	}
	lat, lng, ok := h3util.CellCenter(h3)
	if !ok {
		tile.Set("road_class", sentinelNoRoad)
		return app.Save(tile)
	}

	class, resolved, err := client.ClassAt(ctx, lat, lng)
	if err != nil {
		return err
	}
	if !resolved {
		return nil // shouldn't happen without an error, but don't mark resolved
	}

	stored := string(class)
	if class == game.ClassUnknown {
		stored = sentinelNoRoad
	}
	tile.Set("road_class", stored)

	band := game.BandForClass(class)
	if tile.GetInt("obs_count") == 0 {
		tile.Set("ref_speed", band.Prior)
	} else {
		tile.Set("ref_speed", game.ClampReference(tile.GetFloat("ref_speed"), band))
	}
	return app.Save(tile)
}
