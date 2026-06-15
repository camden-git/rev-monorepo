package routes

import (
	"net/http"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
)

// RegisterAccountRoutes adds account-management endpoints. App Store guideline
// 5.1.1(v) requires an app that supports account creation to also let the user
// delete their account from inside the app.
func RegisterAccountRoutes(app core.App) {
	app.OnServe().BindFunc(func(e *core.ServeEvent) error {
		e.Router.POST("/api/rev/account/delete", deleteAccount).Bind(apis.RequireAuth("users"))
		return e.Next()
	})
}

// deleteAccount permanently removes the signed-in user and everything tied to
// them. drives cascade-delete through their user relation, but the tiles and
// tile_history owner relations do not cascade, so they are cleared explicitly
// (otherwise they would dangle pointing at a deleted user). everything runs in
// one transaction so a partial failure leaves the account intact.
func deleteAccount(e *core.RequestEvent) error {
	if e.Auth == nil {
		return e.UnauthorizedError("Account deletion requires a signed-in user.", nil)
	}
	userID := e.Auth.Id

	err := e.App.RunInTransaction(func(txApp core.App) error {
		if err := deleteOwned(txApp, "tiles", userID); err != nil {
			return err
		}
		if err := deleteOwned(txApp, "tile_history", userID); err != nil {
			return err
		}
		user, err := txApp.FindRecordById("users", userID)
		if err != nil {
			return err
		}
		return txApp.Delete(user) // cascades the user's drives
	})
	if err != nil {
		return e.InternalServerError("Failed to delete account.", err)
	}
	return e.JSON(http.StatusOK, map[string]bool{"ok": true})
}

// deleteOwned removes every record in a collection owned by the given user
func deleteOwned(txApp core.App, collection, userID string) error {
	records, err := txApp.FindRecordsByFilter(collection, "owner = {:u}", "", 0, 0, dbx.Params{"u": userID})
	if err != nil {
		return err
	}
	for _, r := range records {
		if err := txApp.Delete(r); err != nil {
			return err
		}
	}
	return nil
}
