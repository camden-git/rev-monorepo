package routes

import (
	"net/http"
	"os"
	"runtime/debug"
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
	// the git revision this binary was built from ("unknown" without a VCS
	// stamp) so the deployed build is verifiable with one request
	Commit string `json:"commit"`
}

// buildCommit resolves the binary's git revision once at startup: Go stamps
// vcs.revision into the build info automatically when building from a git
// checkout. "-dirty" is appended for builds with uncommitted changes
var buildCommit = func() string {
	info, ok := debug.ReadBuildInfo()
	if !ok {
		return "unknown"
	}
	revision, dirty := "", false
	for _, s := range info.Settings {
		switch s.Key {
		case "vcs.revision":
			revision = s.Value
		case "vcs.modified":
			dirty = s.Value == "true"
		}
	}
	if revision == "" {
		return "unknown"
	}
	if len(revision) > 12 {
		revision = revision[:12]
	}
	if dirty {
		revision += "-dirty"
	}
	return revision
}()

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
		Commit:         buildCommit,
	})
}
