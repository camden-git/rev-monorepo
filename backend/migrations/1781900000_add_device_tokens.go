package migrations

import (
	"fmt"

	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

func init() {
	m.Register(addDeviceTokens, dropDeviceTokens)
}

// addDeviceTokens stores the APNs device tokens a user has registered so the
// server can push notifications to every device they are signed in on. writes go
// through the /api/rev/devices route (superuser context), so the collection API
// rules stay locked to the owner for reads only.
func addDeviceTokens(app core.App) error {
	if _, err := app.FindCollectionByNameOrId("device_tokens"); err == nil {
		return nil
	}
	users, err := app.FindCollectionByNameOrId("users")
	if err != nil {
		return fmt.Errorf("find users: %w", err)
	}

	tokens := core.NewBaseCollection("device_tokens")
	tokens.ListRule = ptr("user = @request.auth.id")
	tokens.ViewRule = ptr("user = @request.auth.id")
	tokens.Fields.Add(
		&core.RelationField{Name: "user", CollectionId: users.Id, MaxSelect: 1, Required: true, CascadeDelete: true},
		// the APNs device token as a lowercase hex string
		&core.TextField{Name: "token", Required: true, Max: 200},
		&core.TextField{Name: "platform", Max: 16},
		// "production" or "sandbox" - which APNs host the token is valid against
		&core.TextField{Name: "environment", Max: 16},
		&core.AutodateField{Name: "created", OnCreate: true},
		&core.AutodateField{Name: "updated", OnCreate: true, OnUpdate: true},
	)
	tokens.Indexes = append(tokens.Indexes,
		"CREATE UNIQUE INDEX idx_device_tokens_token ON device_tokens (token)",
		"CREATE INDEX idx_device_tokens_user ON device_tokens (user)",
	)
	if err := app.Save(tokens); err != nil {
		return fmt.Errorf("save device_tokens: %w", err)
	}
	return nil
}

func dropDeviceTokens(app core.App) error {
	if c, err := app.FindCollectionByNameOrId("device_tokens"); err == nil {
		return app.Delete(c)
	}
	return nil
}
