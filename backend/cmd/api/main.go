package main

import (
	"log"
	"os"

	"github.com/pocketbase/pocketbase"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/plugins/migratecmd"

	"github.com/camden-git/rev-monorepo/backend/internal/hooks"
	"github.com/camden-git/rev-monorepo/backend/internal/notify"
	"github.com/camden-git/rev-monorepo/backend/internal/push"
	"github.com/camden-git/rev-monorepo/backend/internal/routes"
	"github.com/camden-git/rev-monorepo/backend/internal/stats"

	_ "github.com/camden-git/rev-monorepo/backend/migrations"
)

func main() {
	app := pocketbase.New()

	migratecmd.MustRegister(app, app.RootCmd, migratecmd.Config{
		Automigrate: true,
	})

	notifier := buildNotifier(app)

	hooks.RegisterDriveHooks(app, notifier)
	hooks.RegisterUserHooks(app)
	hooks.RegisterFollowHooks(app, notifier)
	routes.RegisterInviteAuthRoutes(app)
	routes.RegisterTileRoutes(app, notifier)
	routes.RegisterAccountRoutes(app)
	routes.RegisterSocialRoutes(app)
	routes.RegisterDeviceRoutes(app)
	stats.RegisterSnapshotCron(app)

	// local dev stuff
	app.OnServe().BindFunc(func(e *core.ServeEvent) error {
		if os.Getenv("REV_DEV_SEED") == "1" {
			if err := seedDevUser(e.App); err != nil {
				e.App.Logger().Error("dev seed failed", "error", err)
			} else {
				e.App.Logger().Info("dev user ready", "email", devUserEmail, "password", devUserPassword)
			}
		}
		return e.Next()
	})

	if err := app.Start(); err != nil {
		log.Fatal(err)
	}
}

// buildNotifier wires up APNs push if the credentials are present, otherwise a
// no-op so the server runs fine in environments without push configured.
func buildNotifier(app core.App) notify.Notifier {
	cfg, err := push.LoadConfig()
	if err != nil {
		app.Logger().Error("push config invalid, notifications disabled", "error", err)
		return notify.Noop{}
	}
	if cfg == nil {
		app.Logger().Info("push not configured, notifications disabled")
		return notify.Noop{}
	}
	app.Logger().Info("APNs push enabled", "topic", cfg.Topic)
	return notify.NewService(app, push.New(cfg))
}

const (
	devUserEmail    = "dev@test.driverev.app"
	devUserPassword = "driverev"
)

func seedDevUser(app core.App) error {
	if _, err := app.FindFirstRecordByData("users", "email", devUserEmail); err == nil {
		return nil // already seeded
	}
	col, err := app.FindCollectionByNameOrId("users")
	if err != nil {
		return err
	}
	rec := core.NewRecord(col)
	rec.SetEmail(devUserEmail)
	rec.SetPassword(devUserPassword)
	rec.SetVerified(true)
	rec.Set("display_name", "Dev")
	rec.Set("home_h3", "0")
	rec.Set("color", "#F59E0B")
	return app.Save(rec)
}
