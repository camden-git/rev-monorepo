package migrations

import (
	"fmt"

	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

func init() {
	m.Register(up, down)
}

// ptr returns a pointer to a rule string
func ptr(s string) *string { return &s }

func up(app core.App) error {
	// users (extend PocketBase)
	users, err := app.FindCollectionByNameOrId("users")
	if err != nil {
		return fmt.Errorf("find users: %w", err)
	}
	users.Fields.Add(
		&core.TextField{Name: "display_name", Max: 100},
		// H3 cell id of the home hex
		// the reason this is stored as text instead of number is because res-10
		// ids exceed 2^53 so a float64 cant store them
		&core.TextField{Name: "home_h3", Max: 20},
		&core.TextField{Name: "color", Max: 9},
	)

	users.Indexes = append(users.Indexes, "CREATE INDEX idx_users_home_h3 ON users (home_h3)")
	if err := app.Save(users); err != nil {
		return fmt.Errorf("save users: %w", err)
	}

	// tiles - the claimed-tile state we query by h3
	tiles := core.NewBaseCollection("tiles")
	tiles.ListRule = ptr("")
	tiles.ViewRule = ptr("")
	tiles.Fields.Add(
		// h3 as TEXT (exact uint64), see note above about issue with float64
		&core.TextField{Name: "h3", Required: true, Max: 20},
		&core.RelationField{Name: "owner", CollectionId: users.Id, MaxSelect: 1, CascadeDelete: false},
		&core.NumberField{Name: "claim_score"}, // distance-weighted avg speed (mph)
		&core.DateField{Name: "last_driven_at"},
		&core.BoolField{Name: "is_home"},
		&core.AutodateField{Name: "created", OnCreate: true},
		&core.AutodateField{Name: "updated", OnCreate: true, OnUpdate: true},
	)
	tiles.Indexes = append(tiles.Indexes,
		"CREATE UNIQUE INDEX idx_tiles_h3 ON tiles (h3)",
		"CREATE INDEX idx_tiles_owner ON tiles (owner)",
		"CREATE INDEX idx_tiles_last_driven_at ON tiles (last_driven_at)",
		// the foreground delta-poll filters on this
		"CREATE INDEX idx_tiles_updated ON tiles (updated)",
	)
	if err := app.Save(tiles); err != nil {
		return fmt.Errorf("save tiles: %w", err)
	}

	// drives
	// authenticated users create/read only their own drives
	drives := core.NewBaseCollection("drives")
	drives.CreateRule = ptr(`@request.auth.id != "" && @request.body.user = @request.auth.id`)
	drives.ListRule = ptr("user = @request.auth.id")
	drives.ViewRule = ptr("user = @request.auth.id")
	drives.Fields.Add(
		&core.RelationField{Name: "user", CollectionId: users.Id, MaxSelect: 1, CascadeDelete: true},
		&core.DateField{Name: "started_at"},
		&core.DateField{Name: "ended_at"},
		&core.JSONField{Name: "raw_path", MaxSize: 5 << 20},        // [{ts,lat,lng,speed,accuracy}]
		&core.JSONField{Name: "per_tile_scores", MaxSize: 2 << 20}, // {h3: score}
		&core.AutodateField{Name: "created", OnCreate: true},
		&core.AutodateField{Name: "updated", OnCreate: true, OnUpdate: true},
	)
	drives.Indexes = append(drives.Indexes, "CREATE INDEX idx_drives_user ON drives (user)")
	if err := app.Save(drives); err != nil {
		return fmt.Errorf("save drives: %w", err)
	}

	// tile_history - append-only audit log of ownership changes
	history := core.NewBaseCollection("tile_history")
	history.Fields.Add(
		&core.TextField{Name: "h3", Required: true, Max: 20},
		&core.RelationField{Name: "owner", CollectionId: users.Id, MaxSelect: 1, CascadeDelete: false},
		&core.NumberField{Name: "claim_score"},
		&core.DateField{Name: "occurred_at"},
		&core.AutodateField{Name: "created", OnCreate: true},
	)
	history.Indexes = append(history.Indexes,
		"CREATE INDEX idx_tile_history_h3 ON tile_history (h3)",
		"CREATE INDEX idx_tile_history_occurred_at ON tile_history (occurred_at)",
	)
	if err := app.Save(history); err != nil {
		return fmt.Errorf("save tile_history: %w", err)
	}

	return nil
}

func down(app core.App) error {
	for _, name := range []string{"tile_history", "drives", "tiles"} {
		if c, err := app.FindCollectionByNameOrId(name); err == nil {
			if err := app.Delete(c); err != nil {
				return err
			}
		}
	}
	// strip the fields we added to users (leave the built-in collection intact)
	if users, err := app.FindCollectionByNameOrId("users"); err == nil {
		for _, f := range []string{"display_name", "home_h3", "color"} {
			users.Fields.RemoveByName(f)
		}
		if err := app.Save(users); err != nil {
			return err
		}
	}
	return nil
}
