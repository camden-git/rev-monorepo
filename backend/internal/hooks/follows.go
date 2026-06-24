package hooks

import (
	"github.com/pocketbase/pocketbase/core"
)

func RegisterFollowHooks(app core.App) {
	app.OnRecordCreateRequest("follows").BindFunc(func(e *core.RecordRequestEvent) error {
		if e.Auth == nil || !e.Auth.Collection().IsAuth() || e.Auth.Collection().Name != "users" {
			return e.UnauthorizedError("Following requires a signed-in user.", nil)
		}
		e.Record.Set("follower", e.Auth.Id)

		followee := e.Record.GetString("followee")
		if followee == "" || followee == e.Auth.Id {
			return e.BadRequestError("You cannot follow yourself.", nil)
		}
		target, err := e.App.FindRecordById("users", followee)
		if err != nil {
			return e.NotFoundError("That player does not exist.", err)
		}

		if target.GetBool("is_private") {
			e.Record.Set("status", "pending")
		} else {
			e.Record.Set("status", "accepted")
		}
		return e.Next()
	})

	app.OnRecordUpdateRequest("follows").BindFunc(func(e *core.RecordRequestEvent) error {
		original := e.Record.Original()
		if e.Auth == nil || original.GetString("followee") != e.Auth.Id {
			return e.ForbiddenError("Only the followed player can answer a request.", nil)
		}
		// accepting a pending request is the one supported transition
		e.Record.Set("follower", original.GetString("follower"))
		e.Record.Set("followee", original.GetString("followee"))
		e.Record.Set("status", "accepted")
		return e.Next()
	})
}
