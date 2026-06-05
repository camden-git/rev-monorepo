package migrations

import (
	"fmt"

	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

func init() {
	m.Register(openUsersRoster, closeUsersRoster)
}

// openUsersRoster broadens the users collection so any authenticated friend can
// read the roster
func openUsersRoster(app core.App) error {
	users, err := app.FindCollectionByNameOrId("users")
	if err != nil {
		return fmt.Errorf("find users: %w", err)
	}

	users.ListRule = ptr(`@request.auth.id != ""`)
	users.ViewRule = ptr(`@request.auth.id != ""`)
	users.UpdateRule = ptr(`@request.auth.id = id`)

	if err := app.Save(users); err != nil {
		return fmt.Errorf("save users roster rules: %w", err)
	}
	return nil
}

// closeUsersRoster restores PocketBase's default auth-collection rules
func closeUsersRoster(app core.App) error {
	users, err := app.FindCollectionByNameOrId("users")
	if err != nil {
		return fmt.Errorf("find users: %w", err)
	}

	users.ListRule = ptr(`@request.auth.id = id`)
	users.ViewRule = ptr(`@request.auth.id = id`)
	users.UpdateRule = ptr(`@request.auth.id = id`)

	if err := app.Save(users); err != nil {
		return fmt.Errorf("restore users rules: %w", err)
	}
	return nil
}
