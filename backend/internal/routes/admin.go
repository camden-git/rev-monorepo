package routes

import (
	"net/http"
	"strconv"
	"time"

	"github.com/camden-git/rev-monorepo/backend/internal/game"
	"github.com/camden-git/rev-monorepo/backend/internal/h3util"
	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
)

const maxAdminTiles = 8000

type adminTileOwner struct {
	ID          string `json:"id"`
	DisplayName string `json:"display_name"`
	Color       string `json:"color"`
}

type adminTile struct {
	ID             string  `json:"id"`
	H3             string  `json:"h3"`
	Owner          string  `json:"owner"`
	OwnerName      string  `json:"owner_name"`
	OwnerColor     string  `json:"owner_color"`
	ClaimScore     float64 `json:"claim_score"`
	EffectiveScore float64 `json:"effective_score"`
	IsHome         bool    `json:"is_home"`
	Captures       int     `json:"captures"`
	LastDrivenAt   string  `json:"last_driven_at"`
	// Boundary is the hexagon vertex ring as [lat, lng] pairs
	Boundary [][2]float64 `json:"boundary"`
}

type adminTileWindowResponse struct {
	Items     []adminTile `json:"items"`
	Truncated bool        `json:"truncated"`
}

type adminUnclaimRequest struct {
	// H3s is the list of res-10 cell ids (decimal strings) to unclaim
	H3s []string `json:"h3s"`
	// H3 is a convenience single-cell form
	H3 string `json:"h3"`
}

type adminUnclaimResponse struct {
	Removed int      `json:"removed"`
	Missing []string `json:"missing"`
}

func RegisterAdminRoutes(app core.App) {
	app.OnServe().BindFunc(func(e *core.ServeEvent) error {
		e.Router.GET("/admin/tiles", func(e *core.RequestEvent) error {
			return e.HTML(http.StatusOK, adminTilesPage)
		})
		e.Router.GET("/api/rev/admin/tiles", adminTileWindow).Bind(apis.RequireSuperuserAuth())
		e.Router.POST("/api/rev/admin/tiles/unclaim", adminUnclaimTiles).Bind(apis.RequireSuperuserAuth())
		return e.Next()
	})
}

// adminTileWindow returns every claimed tile whose center falls inside the
// requested lat/lng bounding box, with its hexagon boundary and owner styling
// resolved for direct rendering
func adminTileWindow(e *core.RequestEvent) error {
	q := e.Request.URL.Query()
	minLat, err1 := strconv.ParseFloat(q.Get("min_lat"), 64)
	minLng, err2 := strconv.ParseFloat(q.Get("min_lng"), 64)
	maxLat, err3 := strconv.ParseFloat(q.Get("max_lat"), 64)
	maxLng, err4 := strconv.ParseFloat(q.Get("max_lng"), 64)
	if err1 != nil || err2 != nil || err3 != nil || err4 != nil {
		return e.BadRequestError("min_lat, min_lng, max_lat, max_lng are required floats", nil)
	}
	if minLat > maxLat {
		minLat, maxLat = maxLat, minLat
	}
	if minLng > maxLng {
		minLng, maxLng = maxLng, minLng
	}

	tilesCol, err := e.App.FindCollectionByNameOrId("tiles")
	if err != nil {
		return e.InternalServerError("failed to load tiles collection", err)
	}
	records := []*core.Record{}
	if err := e.App.RecordQuery(tilesCol).All(&records); err != nil {
		return e.InternalServerError("failed to load tiles", err)
	}

	now := time.Now()
	items := make([]adminTile, 0, 256)
	ownerIDs := map[string]bool{}
	truncated := false
	for _, r := range records {
		h3str := r.GetString("h3")
		id, perr := strconv.ParseUint(h3str, 10, 64)
		if perr != nil {
			continue
		}
		lat, lng, ok := h3util.CellCenter(id)
		if !ok || lat < minLat || lat > maxLat || lng < minLng || lng > maxLng {
			continue
		}
		if len(items) >= maxAdminTiles {
			truncated = true
			break
		}
		boundary, ok := h3util.Boundary(id)
		if !ok {
			continue
		}
		owner := r.GetString("owner")
		if owner != "" {
			ownerIDs[owner] = true
		}
		claim := r.GetFloat("claim_score")
		lastDriven := r.GetDateTime("last_driven_at").Time()
		items = append(items, adminTile{
			ID:             r.Id,
			H3:             h3str,
			Owner:          owner,
			ClaimScore:     claim,
			EffectiveScore: game.EffectiveScore(claim, lastDriven, now),
			IsHome:         r.GetBool("is_home"),
			Captures:       int(r.GetFloat("captures")),
			LastDrivenAt:   r.GetString("last_driven_at"),
			Boundary:       boundary,
		})
	}

	owners := resolveOwners(e.App, ownerIDs)
	for i := range items {
		if o, ok := owners[items[i].Owner]; ok {
			items[i].OwnerName = o.DisplayName
			items[i].OwnerColor = o.Color
		}
	}

	return e.JSON(http.StatusOK, adminTileWindowResponse{Items: items, Truncated: truncated})
}

// adminUnclaimTiles deletes the tile records for the given h3 cells, returning
// them to the neutral (unclaimed) state
func adminUnclaimTiles(e *core.RequestEvent) error {
	var form adminUnclaimRequest
	if err := e.BindBody(&form); err != nil {
		return e.BadRequestError("invalid unclaim request", err)
	}
	wanted := map[string]bool{}
	if form.H3 != "" {
		wanted[form.H3] = true
	}
	for _, h := range form.H3s {
		if h != "" {
			wanted[h] = true
		}
	}
	if len(wanted) == 0 {
		return e.BadRequestError("no h3 cells provided", nil)
	}

	tilesCol, err := e.App.FindCollectionByNameOrId("tiles")
	if err != nil {
		return e.InternalServerError("failed to load tiles collection", err)
	}

	removed := 0
	missing := []string{}
	for h3str := range wanted {
		rec, ferr := e.App.FindFirstRecordByData(tilesCol, "h3", h3str)
		if ferr != nil || rec == nil {
			missing = append(missing, h3str)
			continue
		}
		if err := e.App.Delete(rec); err != nil {
			return e.InternalServerError("failed to delete tile "+h3str, err)
		}
		removed++
	}

	return e.JSON(http.StatusOK, adminUnclaimResponse{Removed: removed, Missing: missing})
}

func resolveOwners(app core.App, ids map[string]bool) map[string]adminTileOwner {
	out := map[string]adminTileOwner{}
	if len(ids) == 0 {
		return out
	}
	list := make([]string, 0, len(ids))
	for id := range ids {
		list = append(list, id)
	}
	records, err := app.FindRecordsByIds("users", list)
	if err != nil {
		return out
	}
	for _, r := range records {
		out[r.Id] = adminTileOwner{
			ID:          r.Id,
			DisplayName: r.GetString("display_name"),
			Color:       r.GetString("color"),
		}
	}
	return out
}
