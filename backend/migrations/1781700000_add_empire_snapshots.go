package migrations

import (
	"fmt"

	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

func init() {
	m.Register(addEmpireSnapshots, dropEmpireSnapshots)
}

// addEmpireSnapshots stores a periodic record of each player's empire so the app
// can chart size, strength, and rank over time
func addEmpireSnapshots(app core.App) error {
	if _, err := app.FindCollectionByNameOrId("empire_snapshots"); err == nil {
		return nil
	}
	users, err := app.FindCollectionByNameOrId("users")
	if err != nil {
		return fmt.Errorf("find users: %w", err)
	}

	snaps := core.NewBaseCollection("empire_snapshots")
	snaps.ListRule = ptr(`user = @request.auth.id`)
	snaps.ViewRule = ptr(`user = @request.auth.id`)
	snaps.Fields.Add(
		&core.RelationField{Name: "user", CollectionId: users.Id, MaxSelect: 1, Required: true, CascadeDelete: true},
		&core.DateField{Name: "captured_at"},
		&core.NumberField{Name: "tiles_held"},
		&core.NumberField{Name: "strength"},
		&core.NumberField{Name: "score"},
		&core.NumberField{Name: "rank"},
		&core.AutodateField{Name: "created", OnCreate: true},
	)
	snaps.Indexes = append(snaps.Indexes,
		"CREATE INDEX idx_empire_snapshots_user_captured ON empire_snapshots (user, captured_at)",
		"CREATE INDEX idx_empire_snapshots_captured ON empire_snapshots (captured_at)",
	)
	if err := app.Save(snaps); err != nil {
		return fmt.Errorf("save empire_snapshots: %w", err)
	}
	return nil
}

func dropEmpireSnapshots(app core.App) error {
	if c, err := app.FindCollectionByNameOrId("empire_snapshots"); err == nil {
		return app.Delete(c)
	}
	return nil
}
