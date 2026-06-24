package main

import (
	"bufio"
	"log"
	"os"
	"strings"

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
	// load backend/.env when present so local runs pick up config (APNs creds,
	// dev seed) without exporting vars by hand. real env vars always win, and a
	// missing file is a silent no-op (production sets the environment directly).
	loadDotEnv(".env")

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

// loadDotEnv reads simple KEY=VALUE lines from the given file and sets any that
// are not already present in the environment. Comments (#) and blank lines are
// skipped; surrounding quotes are stripped. A missing file is not an error.
func loadDotEnv(path string) {
	file, err := os.Open(path)
	if err != nil {
		return
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		key = strings.TrimSpace(key)
		value = strings.Trim(strings.TrimSpace(value), `"'`)
		if key == "" {
			continue
		}
		if _, exists := os.LookupEnv(key); !exists {
			_ = os.Setenv(key, value)
		}
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
