package hooks

import (
	"time"

	"github.com/camden-git/rev-monorepo/backend/internal/game"
	"github.com/pocketbase/pocketbase/core"
)

// RegisterExpiryCron schedules the hourly sweep that reverts fully-decayed
// tiles to unowned
func RegisterExpiryCron(app core.App) {
	app.Cron().MustAdd("tileExpiry", "0 * * * *", func() {
		if err := ExpireTiles(app, time.Now()); err != nil {
			app.Logger().Error("tile expiry sweep failed", "error", err)
		}
	})
}

// ExpireTiles deletes every non-home tile whose effective score has decayed
// below game.ExpiryThreshold
func ExpireTiles(app core.App, now time.Time) error {
	tiles, err := app.FindRecordsByFilter("tiles", "is_home = false", "", 0, 0)
	if err != nil {
		return err
	}
	expired := 0
	for _, rec := range tiles {
		if !game.Expired(rec.GetFloat("claim_score"), rec.GetDateTime("last_driven_at").Time(), now) {
			continue
		}
		if err := app.Delete(rec); err != nil {
			app.Logger().Error("failed to expire tile", "h3", rec.GetString("h3"), "error", err)
			continue
		}
		expired++
	}
	if expired > 0 {
		app.Logger().Info("tile expiry sweep", "expired", expired)
	}
	return nil
}
