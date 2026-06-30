package migrations

import (
	"fmt"

	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

func init() {
	m.Register(addFeedEvents, dropFeedEvents)
}

// addFeedEvents introduces the durable activity-event log that powers the
// following feed
func addFeedEvents(app core.App) error {
	if err := addDriveDeltaFields(app); err != nil {
		return err
	}

	if _, err := app.FindCollectionByNameOrId("feed_events"); err == nil {
		return nil
	}

	users, err := app.FindCollectionByNameOrId("users")
	if err != nil {
		return fmt.Errorf("find users: %w", err)
	}
	drives, err := app.FindCollectionByNameOrId("drives")
	if err != nil {
		return fmt.Errorf("find drives: %w", err)
	}

	events := core.NewBaseCollection("feed_events")

	events.ListRule = ptr(`actor = @request.auth.id`)
	events.ViewRule = ptr(`actor = @request.auth.id`)
	events.Fields.Add(
		&core.RelationField{Name: "actor", CollectionId: users.Id, MaxSelect: 1, Required: true, CascadeDelete: true},
		// the event kind: drive | capture | pr | rank_up | streak | achievement
		&core.TextField{Name: "type", Max: 32, Required: true},
		// optional discriminator within a type (pr kind, achievement id)
		&core.TextField{Name: "subtype", Max: 64},
		// the other player a capture event is about (the displaced owner)
		&core.RelationField{Name: "subject", CollectionId: users.Id, MaxSelect: 1, CascadeDelete: false},
		// the drive a drive/pr event came out of
		&core.RelationField{Name: "drive", CollectionId: drives.Id, MaxSelect: 1, CascadeDelete: true},
		&core.DateField{Name: "occurred_at"},
		// generic numeric payload; meaning is per-type (see internal/feed)
		&core.NumberField{Name: "value"},
		&core.NumberField{Name: "prev_value"},
		&core.AutodateField{Name: "created", OnCreate: true},
	)
	events.Indexes = append(events.Indexes,
		"CREATE INDEX idx_feed_events_actor_occurred ON feed_events (actor, occurred_at)",
		"CREATE INDEX idx_feed_events_occurred ON feed_events (occurred_at)",
		"CREATE INDEX idx_feed_events_actor_type ON feed_events (actor, type)",
	)
	if err := app.Save(events); err != nil {
		return fmt.Errorf("save feed_events: %w", err)
	}

	// backfill a drive event for every existing drive so the feed stays populated
	// on deploy (it used to read the drives table directly)
	if err := backfillDriveEvents(app); err != nil {
		return fmt.Errorf("backfill drive events: %w", err)
	}
	return nil
}

func backfillDriveEvents(app core.App) error {
	drives, err := app.FindRecordsByFilter("drives", "id != ''", "started_at", 0, 0)
	if err != nil {
		return err
	}
	events, err := app.FindCollectionByNameOrId("feed_events")
	if err != nil {
		return err
	}
	for _, d := range drives {
		user := d.GetString("user")
		if user == "" {
			continue
		}
		when := d.GetDateTime("ended_at")
		if when.IsZero() {
			when = d.GetDateTime("started_at")
		}
		var perTile map[string]float64
		_ = d.UnmarshalJSONField("per_tile_scores", &perTile)
		duration := 0.0
		if started, ended := d.GetDateTime("started_at").Time(), d.GetDateTime("ended_at").Time(); ended.After(started) {
			duration = ended.Sub(started).Seconds()
		}

		ev := core.NewRecord(events)
		ev.Set("actor", user)
		ev.Set("type", "drive")
		ev.Set("drive", d.Id)
		ev.Set("occurred_at", when)
		ev.Set("value", float64(len(perTile)))
		ev.Set("prev_value", duration)
		if err := app.Save(ev); err != nil {
			return err
		}
	}
	return nil
}

// addDriveDeltaFields stores the resolved per-drive ground deltas so personal
// records (most gained / most captured) can be derived from drive history
func addDriveDeltaFields(app core.App) error {
	drives, err := app.FindCollectionByNameOrId("drives")
	if err != nil {
		return fmt.Errorf("find drives: %w", err)
	}
	if drives.Fields.GetByName("tiles_gained") == nil {
		drives.Fields.Add(&core.NumberField{Name: "tiles_gained"})
	}
	if drives.Fields.GetByName("tiles_captured") == nil {
		drives.Fields.Add(&core.NumberField{Name: "tiles_captured"})
	}
	if err := app.Save(drives); err != nil {
		return fmt.Errorf("save drives delta fields: %w", err)
	}
	return nil
}

func dropFeedEvents(app core.App) error {
	if c, err := app.FindCollectionByNameOrId("feed_events"); err == nil {
		if err := app.Delete(c); err != nil {
			return fmt.Errorf("delete feed_events: %w", err)
		}
	}
	drives, err := app.FindCollectionByNameOrId("drives")
	if err != nil {
		return nil
	}
	drives.Fields.RemoveByName("tiles_gained")
	drives.Fields.RemoveByName("tiles_captured")
	if err := app.Save(drives); err != nil {
		return fmt.Errorf("remove drives delta fields: %w", err)
	}
	return nil
}
