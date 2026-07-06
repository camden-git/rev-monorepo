package routes

import (
	"net/http"
	"strconv"
	"time"

	"github.com/camden-git/rev-monorepo/backend/internal/h3util"
	"github.com/camden-git/rev-monorepo/backend/internal/hooks"
	"github.com/camden-git/rev-monorepo/backend/internal/notify"
	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
)

const maxTileWindowParents = 256

// a single in-drive flush carries the raw GPS samples recorded since the last
// flush (a few seconds), so a generous cap still bounds abuse
const maxClaimSamples = 4096

type tileWindowRequest struct {
	ParentResolution int      `json:"parent_resolution"`
	Parents          []string `json:"parents"`
}

type tileWindowResponse struct {
	Items []*core.Record `json:"items"`
}

// tileClaimRequest carries the raw GPS samples for the in-drive batch
type tileClaimRequest struct {
	RawPath []hooks.RawSample `json:"raw_path"`
}

// tileClaimResponse acks a claim batch. Rejected lists the h3 ids the server
// refused to process (outside the Chicago geofence) so the client can drop its
// optimistic local claims for them
type tileClaimResponse struct {
	OK       bool     `json:"ok"`
	Rejected []string `json:"rejected,omitempty"`
}

// RegisterTileRoutes adds purpose-built map tile endpoints
func RegisterTileRoutes(app core.App, notifier notify.Notifier) {
	app.OnServe().BindFunc(func(e *core.ServeEvent) error {
		e.Router.POST("/api/rev/tiles/window", tileWindow).Bind(apis.RequireAuth("users"))
		e.Router.POST("/api/rev/tiles/claim", tileClaimHandler(notifier)).Bind(apis.RequireAuth("users"))
		return e.Next()
	})
}

// tileClaimHandler resolves a batch of direct claims for the signed-in user
// mid-drive so captured tiles broadcast live over the `tiles` realtime topic.
// enclosure is left to the end-of-drive upload, which has the full raw trail.
// displaced owners are pushed a capture notification as it happens.
func tileClaimHandler(notifier notify.Notifier) func(*core.RequestEvent) error {
	return func(e *core.RequestEvent) error {
		if e.Auth == nil {
			return e.UnauthorizedError("Tile claims require a signed-in user.", nil)
		}
		var form tileClaimRequest
		if err := e.BindBody(&form); err != nil {
			return e.BadRequestError("invalid tile claim request.", err)
		}
		if len(form.RawPath) == 0 {
			return e.JSON(http.StatusOK, tileClaimResponse{OK: true})
		}
		if len(form.RawPath) > maxClaimSamples {
			return e.BadRequestError("tile claim batch is too large", nil)
		}
		captures, rejected, err := hooks.ResolveDirectClaims(e.App, e.Auth.Id, hooks.SamplesFromRaw(form.RawPath), time.Now())
		if err != nil {
			return e.InternalServerError("failed to resolve tile claims", err)
		}
		if notifier != nil {
			for victimID, count := range captures {
				notifier.TileCaptured(victimID, e.Auth.Id, count)
			}
		}
		return e.JSON(http.StatusOK, tileClaimResponse{OK: true, Rejected: rejected})
	}
}

func tileWindow(e *core.RequestEvent) error {
	var form tileWindowRequest
	if err := e.BindBody(&form); err != nil {
		return e.BadRequestError("invalid tile window request.", err)
	}
	if form.ParentResolution != h3util.TileWindowParentResolution {
		return e.BadRequestError("unsupported tile parent resolution", nil)
	}
	if len(form.Parents) == 0 {
		return e.JSON(http.StatusOK, tileWindowResponse{Items: []*core.Record{}})
	}
	if len(form.Parents) > maxTileWindowParents {
		return e.BadRequestError("tile window is too large", nil)
	}

	parents := make([]any, 0, len(form.Parents))
	seen := map[string]bool{}
	for _, raw := range form.Parents {
		if raw == "" || seen[raw] {
			continue
		}
		if _, err := strconv.ParseUint(raw, 10, 64); err != nil {
			return e.BadRequestError("tile parent ids must be uint64 strings", err)
		}
		seen[raw] = true
		parents = append(parents, raw)
	}
	if len(parents) == 0 {
		return e.JSON(http.StatusOK, tileWindowResponse{Items: []*core.Record{}})
	}

	tiles, err := e.App.FindCollectionByNameOrId("tiles")
	if err != nil {
		return e.InternalServerError("failed to load tiles collection", err)
	}
	records := []*core.Record{}
	if err := e.App.RecordQuery(tiles).
		AndWhere(dbx.In("h3_r8", parents...)).
		OrderBy("updated ASC").
		All(&records); err != nil {
		return e.InternalServerError("failed to load tile window", err)
	}

	return e.JSON(http.StatusOK, tileWindowResponse{Items: records})
}
