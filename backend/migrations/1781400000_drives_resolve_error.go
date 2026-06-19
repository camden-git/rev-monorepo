package migrations

import (
	"fmt"

	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

func init() {
	m.Register(addDrivesResolveError, dropDrivesResolveError)
}

// addDrivesResolveError adds a server-written marker recording why a drive's
// post-create resolution failed
func addDrivesResolveError(app core.App) error {
	drives, err := app.FindCollectionByNameOrId("drives")
	if err != nil {
		return fmt.Errorf("find drives: %w", err)
	}

	if drives.Fields.GetByName("resolve_error") == nil {
		drives.Fields.Add(&core.TextField{Name: "resolve_error", Max: 1024})
	}

	if err := app.Save(drives); err != nil {
		return fmt.Errorf("save drives resolve_error: %w", err)
	}
	return nil
}

func dropDrivesResolveError(app core.App) error {
	drives, err := app.FindCollectionByNameOrId("drives")
	if err != nil {
		return fmt.Errorf("find drives: %w", err)
	}

	drives.Fields.RemoveByName("resolve_error")

	if err := app.Save(drives); err != nil {
		return fmt.Errorf("remove drives resolve_error: %w", err)
	}
	return nil
}
