package hooks

import (
	"fmt"
	"strconv"
	"time"

	"github.com/camden-git/rev-monorepo/backend/internal/game"
	"github.com/camden-git/rev-monorepo/backend/internal/geofence"
	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"
)

// RegisterUserHooks keeps the tiles collection's home marker in sync with each
// user's home_h3
func RegisterUserHooks(app core.App) {
	sync := func(e *core.RecordEvent) error {
		if err := syncHomeTile(e.App, e.Record); err != nil {
			e.App.Logger().Error("home tile sync failed", "user", e.Record.Id, "error", err)
		}
		return e.Next()
	}
	app.OnRecordAfterCreateSuccess("users").BindFunc(sync)
	app.OnRecordAfterUpdateSuccess("users").BindFunc(sync)
}

// syncHomeTile reconciles the user's home hex onto the tiles collection
func syncHomeTile(app core.App, user *core.Record) error {
	homeStr := user.GetString("home_h3")
	home, err := strconv.ParseUint(homeStr, 10, 64)
	if err != nil || home == 0 {
		return nil // no home chosen yet, nothing to mark
	}
	if !geofence.ContainsCell(home) {
		return nil // Rev is only played in Chicago
	}

	return app.RunInTransaction(func(txApp core.App) error {
		// demote any previously-marked home tiles that aren't the current pick
		stale, err := txApp.FindRecordsByFilter(
			"tiles",
			"owner = {:u} && is_home = true && h3 != {:h3}",
			"", 0, 0,
			dbx.Params{"u": user.Id, "h3": homeStr},
		)
		if err != nil {
			return fmt.Errorf("load stale home tiles: %w", err)
		}
		for _, r := range stale {
			r.Set("is_home", false)
			if err := txApp.Save(r); err != nil {
				return err
			}
		}

		existing := findTile(txApp, homeStr)
		if existing == nil {
			return createTile(txApp, homeStr, user.Id, 0, true, game.ReferenceSpeedPrior, 0, 0, 0, time.Now())
		}
		if existing.GetString("owner") == user.Id && existing.GetBool("is_home") {
			return nil // already correct
		}
		setTileWindowParent(existing, home)
		existing.Set("owner", user.Id)
		existing.Set("is_home", true)
		return txApp.Save(existing)
	})
}
