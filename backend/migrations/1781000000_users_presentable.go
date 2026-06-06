package migrations

import (
	"fmt"

	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

func init() {
	m.Register(markUsersPresentable, unmarkUsersPresentable)
}

func markUsersPresentable(app core.App) error {
	return setUsersPresentable(app, true)
}

func unmarkUsersPresentable(app core.App) error {
	return setUsersPresentable(app, false)
}

func setUsersPresentable(app core.App, presentable bool) error {
	users, err := app.FindCollectionByNameOrId("users")
	if err != nil {
		return fmt.Errorf("find users: %w", err)
	}

	for _, name := range []string{"display_name", "email"} {
		if f, ok := users.Fields.GetByName(name).(*core.TextField); ok {
			f.Presentable = presentable
		} else if f, ok := users.Fields.GetByName(name).(*core.EmailField); ok {
			f.Presentable = presentable
		}
	}

	if err := app.Save(users); err != nil {
		return fmt.Errorf("save users presentable fields: %w", err)
	}
	return nil
}
