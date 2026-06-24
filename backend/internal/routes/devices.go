package routes

import (
	"net/http"
	"strings"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
)

const maxDeviceTokenLen = 200

type deviceRegisterRequest struct {
	Token       string `json:"token"`
	Platform    string `json:"platform"`
	Environment string `json:"environment"`
}

type deviceUnregisterRequest struct {
	Token string `json:"token"`
}

// RegisterDeviceRoutes adds the APNs device-token endpoints. Registration is a
// custom route rather than direct collection writes so a token can move between
// accounts (same phone, new sign-in) without tripping the unique-token index.
func RegisterDeviceRoutes(app core.App) {
	app.OnServe().BindFunc(func(e *core.ServeEvent) error {
		e.Router.POST("/api/rev/devices", registerDevice).Bind(apis.RequireAuth("users"))
		e.Router.POST("/api/rev/devices/unregister", unregisterDevice).Bind(apis.RequireAuth("users"))
		return e.Next()
	})
}

// registerDevice upserts the caller's APNs token, claiming it for the signed-in
// user if it was previously tied to another account on the same device.
func registerDevice(e *core.RequestEvent) error {
	if e.Auth == nil {
		return e.UnauthorizedError("Device registration requires a signed-in user.", nil)
	}
	var form deviceRegisterRequest
	if err := e.BindBody(&form); err != nil {
		return e.BadRequestError("invalid device registration request.", err)
	}
	token := strings.TrimSpace(form.Token)
	if token == "" || len(token) > maxDeviceTokenLen {
		return e.BadRequestError("a valid device token is required.", nil)
	}
	env := form.Environment
	if env != "sandbox" && env != "production" {
		env = "production"
	}
	platform := form.Platform
	if platform == "" {
		platform = "ios"
	}

	existing, _ := e.App.FindFirstRecordByFilter("device_tokens", "token = {:t}", dbx.Params{"t": token})
	if existing != nil {
		existing.Set("user", e.Auth.Id)
		existing.Set("platform", platform)
		existing.Set("environment", env)
		if err := e.App.Save(existing); err != nil {
			return e.InternalServerError("failed to update device token.", err)
		}
		return e.JSON(http.StatusOK, map[string]bool{"ok": true})
	}

	col, err := e.App.FindCollectionByNameOrId("device_tokens")
	if err != nil {
		return e.InternalServerError("device tokens unavailable.", err)
	}
	rec := core.NewRecord(col)
	rec.Set("user", e.Auth.Id)
	rec.Set("token", token)
	rec.Set("platform", platform)
	rec.Set("environment", env)
	if err := e.App.Save(rec); err != nil {
		return e.InternalServerError("failed to register device token.", err)
	}
	return e.JSON(http.StatusOK, map[string]bool{"ok": true})
}

// unregisterDevice drops the caller's token, e.g. on sign-out, so the previous
// user stops receiving pushes on a shared device.
func unregisterDevice(e *core.RequestEvent) error {
	if e.Auth == nil {
		return e.UnauthorizedError("Device unregistration requires a signed-in user.", nil)
	}
	var form deviceUnregisterRequest
	if err := e.BindBody(&form); err != nil {
		return e.BadRequestError("invalid device unregistration request.", err)
	}
	token := strings.TrimSpace(form.Token)
	if token == "" {
		return e.BadRequestError("a device token is required.", nil)
	}

	rec, err := e.App.FindFirstRecordByFilter(
		"device_tokens",
		"token = {:t} && user = {:u}",
		dbx.Params{"t": token, "u": e.Auth.Id},
	)
	if err != nil || rec == nil {
		return e.JSON(http.StatusOK, map[string]bool{"ok": true}) // already gone
	}
	if err := e.App.Delete(rec); err != nil {
		return e.InternalServerError("failed to unregister device token.", err)
	}
	return e.JSON(http.StatusOK, map[string]bool{"ok": true})
}
