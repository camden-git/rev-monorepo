package migrations

import (
	"fmt"

	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

func init() {
	m.Register(addFollows, dropFollows)
}

// addFollows creates the directed follow graph
func addFollows(app core.App) error {
	if _, err := app.FindCollectionByNameOrId("follows"); err == nil {
		return nil
	}
	users, err := app.FindCollectionByNameOrId("users")
	if err != nil {
		return fmt.Errorf("find users: %w", err)
	}

	follows := core.NewBaseCollection("follows")
	follows.ListRule = ptr(`@request.auth.id != "" && (follower = @request.auth.id || followee = @request.auth.id)`)
	follows.ViewRule = ptr(`@request.auth.id != "" && (follower = @request.auth.id || followee = @request.auth.id)`)
	// the caller may only originate their own edge, and may not hand-pick a status
	// the create hook derives pending/accepted from the target's privacy flag
	follows.CreateRule = ptr(`@request.auth.id != "" && follower = @request.auth.id && @request.body.status:isset = false`)
	// only the followee answers a request
	follows.UpdateRule = ptr(`followee = @request.auth.id`)
	// either side can drop the edge (unfollow, or remove a follower)
	follows.DeleteRule = ptr(`follower = @request.auth.id || followee = @request.auth.id`)
	follows.Fields.Add(
		&core.RelationField{Name: "follower", CollectionId: users.Id, MaxSelect: 1, Required: true, CascadeDelete: true},
		&core.RelationField{Name: "followee", CollectionId: users.Id, MaxSelect: 1, Required: true, CascadeDelete: true},
		&core.TextField{Name: "status", Max: 16},
		&core.AutodateField{Name: "created", OnCreate: true},
		&core.AutodateField{Name: "updated", OnCreate: true, OnUpdate: true},
	)
	follows.Indexes = append(follows.Indexes,
		"CREATE UNIQUE INDEX idx_follows_pair ON follows (follower, followee)",
		"CREATE INDEX idx_follows_follower ON follows (follower)",
		"CREATE INDEX idx_follows_followee ON follows (followee)",
	)
	if err := app.Save(follows); err != nil {
		return fmt.Errorf("save follows: %w", err)
	}
	return nil
}

func dropFollows(app core.App) error {
	if c, err := app.FindCollectionByNameOrId("follows"); err == nil {
		return app.Delete(c)
	}
	return nil
}
