package migrations

import (
	"fmt"

	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

func init() {
	m.Register(requireDriveOwnerFromAuth, restoreDriveOwnerBodyRule)
}

func requireDriveOwnerFromAuth(app core.App) error {
	drives, err := app.FindCollectionByNameOrId("drives")
	if err != nil {
		return fmt.Errorf("find drives: %w", err)
	}

	drives.CreateRule = ptr(`@request.auth.id != ""`)
	if user, ok := drives.Fields.GetByName("user").(*core.RelationField); ok {
		user.Required = true
	}

	if err := app.Save(drives); err != nil {
		return fmt.Errorf("save drives owner rule: %w", err)
	}
	return nil
}

func restoreDriveOwnerBodyRule(app core.App) error {
	drives, err := app.FindCollectionByNameOrId("drives")
	if err != nil {
		return fmt.Errorf("find drives: %w", err)
	}

	drives.CreateRule = ptr(`@request.auth.id != "" && @request.body.user = @request.auth.id`)
	if user, ok := drives.Fields.GetByName("user").(*core.RelationField); ok {
		user.Required = false
	}

	if err := app.Save(drives); err != nil {
		return fmt.Errorf("restore drives owner rule: %w", err)
	}
	return nil
}
