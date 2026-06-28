package routes

import (
	"net/http"
	"os"
	"strings"

	"github.com/pocketbase/pocketbase/core"
)

// defaultMinAppVersion is the floor the client is gated against when no
// REV_MIN_APP_VERSION is set
const defaultMinAppVersion = "0.0.0"

type versionResponse struct {
	// the lowest app version still allowed to run
	MinimumVersion string `json:"minimum_version"`
	// the newest version available
	LatestVersion string `json:"latest_version"`
}

// RegisterVersionRoutes exposes the app-version gate
func RegisterVersionRoutes(app core.App) {
	app.OnServe().BindFunc(func(e *core.ServeEvent) error {
		e.Router.GET("/api/rev/version", appVersionGate)
		return e.Next()
	})
}

func appVersionGate(e *core.RequestEvent) error {
	minimum := strings.TrimSpace(os.Getenv("REV_MIN_APP_VERSION"))
	if minimum == "" {
		minimum = defaultMinAppVersion
	}
	latest := strings.TrimSpace(os.Getenv("REV_LATEST_APP_VERSION"))
	if latest == "" {
		latest = minimum
	}
	return e.JSON(http.StatusOK, versionResponse{
		MinimumVersion: minimum,
		LatestVersion:  latest,
	})
}
