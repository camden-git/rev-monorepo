package main

import (
	"log"
	"os"

	"github.com/pocketbase/pocketbase"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/plugins/migratecmd"

	"github.com/camden-git/rev-monorepo/backend/internal/hooks"
	"github.com/camden-git/rev-monorepo/backend/internal/routes"

	_ "github.com/camden-git/rev-monorepo/backend/migrations"
)

func main() {
	app := pocketbase.New()

	migratecmd.MustRegister(app, app.RootCmd, migratecmd.Config{
		Automigrate: true,
	})

	hooks.RegisterDriveHooks(app)
	hooks.RegisterUserHooks(app)
	routes.RegisterInviteAuthRoutes(app)
	routes.RegisterTileRoutes(app)

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
