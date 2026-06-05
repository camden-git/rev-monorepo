package migrations

import (
	"fmt"

	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

func init() {
	m.Register(addInviteCodes, dropInviteCodes)
}

func addInviteCodes(app core.App) error {
	if _, err := app.FindCollectionByNameOrId("invite_codes"); err == nil {
		return nil
	}

	invites := core.NewBaseCollection("invite_codes")
	invites.Fields.Add(
		&core.TextField{Name: "code", Required: true, Max: 64},
		&core.NumberField{Name: "max_uses", Required: true},
		&core.NumberField{Name: "uses"},
		&core.BoolField{Name: "active"},
		&core.DateField{Name: "expires_at"},
		&core.AutodateField{Name: "created", OnCreate: true},
		&core.AutodateField{Name: "updated", OnCreate: true, OnUpdate: true},
	)
	invites.Indexes = append(invites.Indexes,
		"CREATE UNIQUE INDEX idx_invite_codes_code ON invite_codes (code)",
		"CREATE INDEX idx_invite_codes_active ON invite_codes (active)",
	)
	if err := app.Save(invites); err != nil {
		return fmt.Errorf("save invite_codes: %w", err)
	}

	return nil
}

func dropInviteCodes(app core.App) error {
	if c, err := app.FindCollectionByNameOrId("invite_codes"); err == nil {
		return app.Delete(c)
	}
	return nil
}
