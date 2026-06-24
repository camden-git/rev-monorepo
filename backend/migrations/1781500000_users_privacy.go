package migrations

import (
	"fmt"

	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

func init() {
	m.Register(addUserPrivacy, dropUserPrivacy)
}

// addUserPrivacy gives each user a private-account flag. a private account holds
// new followers as requests and hides its drives + stat history from anyone who
// is not an accepted follower
func addUserPrivacy(app core.App) error {
	users, err := app.FindCollectionByNameOrId("users")
	if err != nil {
		return fmt.Errorf("find users: %w", err)
	}
	if users.Fields.GetByName("is_private") == nil {
		users.Fields.Add(&core.BoolField{Name: "is_private"})
	}
	if err := app.Save(users); err != nil {
		return fmt.Errorf("save users privacy field: %w", err)
	}
	return nil
}

func dropUserPrivacy(app core.App) error {
	users, err := app.FindCollectionByNameOrId("users")
	if err != nil {
		return fmt.Errorf("find users: %w", err)
	}
	users.Fields.RemoveByName("is_private")
	if err := app.Save(users); err != nil {
		return fmt.Errorf("save users: %w", err)
	}
	return nil
}
