package migrations

import (
	"fmt"

	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

func init() {
	m.Register(hideUsersEmail, showUsersEmail)
}

// hideUsersEmail removes `email` from the presentable set
func hideUsersEmail(app core.App) error {
	return setUsersEmailPresentable(app, false)
}

func showUsersEmail(app core.App) error {
	return setUsersEmailPresentable(app, true)
}

func setUsersEmailPresentable(app core.App, presentable bool) error {
	users, err := app.FindCollectionByNameOrId("users")
	if err != nil {
		return fmt.Errorf("find users: %w", err)
	}

	switch f := users.Fields.GetByName("email").(type) {
	case *core.EmailField:
		f.Presentable = presentable
	case *core.TextField:
		f.Presentable = presentable
	}

	if err := app.Save(users); err != nil {
		return fmt.Errorf("save users email presentable: %w", err)
	}
	return nil
}
