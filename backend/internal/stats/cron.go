package stats

import (
	"time"

	"github.com/pocketbase/pocketbase/core"
)

// RegisterSnapshotCron schedules the daily empire-snapshot sweep so every
// player's size, strength, and rank history advances even on days they did not
// drive. runs at 06:00 UTC.
func RegisterSnapshotCron(app core.App) {
	app.Cron().MustAdd("empireSnapshots", "0 6 * * *", func() {
		if err := GenerateAll(app, time.Now()); err != nil {
			app.Logger().Error("empire snapshot cron failed", "error", err)
		}
	})
}
