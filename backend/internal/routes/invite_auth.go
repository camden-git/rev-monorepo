// Package routes registers Rev-specific HTTP endpoints beside PB's
// auto-generated API
package routes

import (
	"database/sql"
	"errors"
	"net/http"
	"net/mail"
	"strings"
	"time"

	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tools/security"
)

type inviteAuthRequest struct {
	DisplayName string `json:"display_name"`
	Email       string `json:"email"`
	Code        string `json:"code"`
}

type inviteAuthResponse struct {
	Token  string       `json:"token"`
	Record *core.Record `json:"record"`
}

// RegisterInviteAuthRoutes adds an invite-code auth bypass for Apple OAuth
func RegisterInviteAuthRoutes(app core.App) {
	app.OnRecordValidate("invite_codes").BindFunc(func(e *core.RecordEvent) error {
		e.Record.Set("code", normalizeInviteCode(e.Record.GetString("code")))
		return e.Next()
	})

	app.OnServe().BindFunc(func(e *core.ServeEvent) error {
		e.Router.POST("/api/rev/auth-with-invite", authWithInvite)
		return e.Next()
	})
}

func authWithInvite(e *core.RequestEvent) error {
	var form inviteAuthRequest
	if err := e.BindBody(&form); err != nil {
		return e.BadRequestError("Invalid invite request.", err)
	}

	displayName := strings.TrimSpace(form.DisplayName)
	email := strings.ToLower(strings.TrimSpace(form.Email))
	code := normalizeInviteCode(form.Code)
	if displayName == "" || email == "" || code == "" {
		return e.BadRequestError("Name, email, and invite code are required.", nil)
	}
	if _, err := mail.ParseAddress(email); err != nil {
		return e.BadRequestError("Enter a valid email address.", err)
	}

	var user *core.Record
	err := e.App.RunInTransaction(func(txApp core.App) error {
		invite, err := txApp.FindFirstRecordByData("invite_codes", "code", code)
		if errors.Is(err, sql.ErrNoRows) {
			return e.BadRequestError("Invalid invite code.", nil)
		}
		if err != nil {
			return err
		}
		if !invite.GetBool("active") {
			return e.BadRequestError("Invite code is inactive.", nil)
		}
		expiresAt := invite.GetDateTime("expires_at")
		if !expiresAt.IsZero() && expiresAt.Time().Before(time.Now()) {
			return e.BadRequestError("Invite code has expired.", nil)
		}
		uses := invite.GetInt("uses")
		maxUses := invite.GetInt("max_uses")
		if maxUses > 0 && uses >= maxUses {
			return e.BadRequestError("Invite code has no uses left.", nil)
		}

		users, err := txApp.FindCollectionByNameOrId("users")
		if err != nil {
			return err
		}
		existing, err := txApp.FindAuthRecordByEmail(users, email)
		switch {
		case errors.Is(err, sql.ErrNoRows):
			existing = core.NewRecord(users)
			existing.SetEmail(email)
			existing.SetPassword(security.RandomString(32))
			existing.SetVerified(true)
			existing.Set("home_h3", "0")
			existing.Set("color", "#2563EB")
		case err != nil:
			return err
		}

		existing.Set("display_name", displayName)
		if err := txApp.Save(existing); err != nil {
			return err
		}

		invite.Set("uses", uses+1)
		if err := txApp.Save(invite); err != nil {
			return err
		}

		user = existing
		return nil
	})
	if err != nil {
		return err
	}

	token, err := user.NewAuthToken()
	if err != nil {
		return e.InternalServerError("Failed to create auth token.", err)
	}
	user.IgnoreEmailVisibility(true)
	return e.JSON(http.StatusOK, inviteAuthResponse{Token: token, Record: user})
}

func normalizeInviteCode(code string) string {
	code = strings.TrimSpace(code)
	code = strings.ReplaceAll(code, " ", "")
	return strings.ToUpper(code)
}
