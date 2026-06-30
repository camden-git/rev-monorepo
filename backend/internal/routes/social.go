package routes

import (
	"net/http"

	"github.com/camden-git/rev-monorepo/backend/internal/stats"
	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
)

const (
	maxProfileDrives = 20
	maxFeedItems     = 40
	maxStatPoints    = 365
)

// profileResponse is the public profile card for one player
type profileResponse struct {
	ID             string       `json:"id"`
	DisplayName    string       `json:"display_name"`
	Color          string       `json:"color"`
	HomeH3         string       `json:"home_h3"`
	IsPrivate      bool         `json:"is_private"`
	IsSelf         bool         `json:"is_self"`
	TilesHeld      int          `json:"tiles_held"`
	Strength       float64      `json:"strength"`
	Score          float64      `json:"score"`
	Rank           int          `json:"rank"`
	DriveCount     int          `json:"drive_count"`
	FollowerCount  int          `json:"follower_count"`
	FollowingCount int          `json:"following_count"`
	FollowState    string       `json:"follow_state"`
	FollowsYou     bool         `json:"follows_you"`
	CanViewDetails bool         `json:"can_view_details"`
	RecentDrives   []driveBrief `json:"recent_drives"`
}

type driveBrief struct {
	ID              string  `json:"id"`
	StartedAt       string  `json:"started_at"`
	DurationSeconds float64 `json:"duration_seconds"`
	Tiles           int     `json:"tiles"`
}

// feedItem is one heterogeneous activity moment
type feedItem struct {
	ID          string  `json:"id"`
	Type        string  `json:"type"`
	UserID      string  `json:"user_id"`
	DisplayName string  `json:"display_name"`
	Color       string  `json:"color"`
	OccurredAt  string  `json:"occurred_at"`
	Subtype     string  `json:"subtype,omitempty"`
	Value       float64 `json:"value"`
	PrevValue   float64 `json:"prev_value"`
	DriveID     string  `json:"drive_id,omitempty"`
	SubjectID   string  `json:"subject_id,omitempty"`
	SubjectName string  `json:"subject_name,omitempty"`
}

type feedResponse struct {
	Items []feedItem `json:"items"`
}

type statPoint struct {
	CapturedAt string  `json:"captured_at"`
	TilesHeld  int     `json:"tiles_held"`
	Strength   float64 `json:"strength"`
	Score      float64 `json:"score"`
	Rank       int     `json:"rank"`
}

type statsResponse struct {
	Items []statPoint `json:"items"`
}

func RegisterSocialRoutes(app core.App) {
	app.OnServe().BindFunc(func(e *core.ServeEvent) error {
		e.Router.GET("/api/rev/profile/{userId}", profile).Bind(apis.RequireAuth("users"))
		e.Router.GET("/api/rev/profile/{userId}/stats", profileStats).Bind(apis.RequireAuth("users"))
		e.Router.GET("/api/rev/feed", feed).Bind(apis.RequireAuth("users"))
		return e.Next()
	})
}

func profile(e *core.RequestEvent) error {
	if e.Auth == nil {
		return e.UnauthorizedError("Sign in required.", nil)
	}
	viewerID := e.Auth.Id
	targetID := e.Request.PathValue("userId")

	target, err := e.App.FindRecordById("users", targetID)
	if err != nil {
		return e.NotFoundError("Player not found.", err)
	}

	standings, err := stats.Standings(e.App)
	if err != nil {
		return e.InternalServerError("Failed to load standings.", err)
	}
	var standing stats.Standing
	for _, s := range standings {
		if s.UserID == targetID {
			standing = s
			break
		}
	}

	isSelf := viewerID == targetID
	isPrivate := target.GetBool("is_private")
	followState := followStatus(e.App, viewerID, targetID)
	canView := isSelf || !isPrivate || followState == "accepted"

	resp := profileResponse{
		ID:             target.Id,
		DisplayName:    target.GetString("display_name"),
		Color:          target.GetString("color"),
		HomeH3:         target.GetString("home_h3"),
		IsPrivate:      isPrivate,
		IsSelf:         isSelf,
		TilesHeld:      standing.TilesHeld,
		Strength:       standing.Strength,
		Score:          standing.Score,
		Rank:           standing.Rank,
		DriveCount:     countRecords(e.App, "drives", dbx.HashExp{"user": targetID}),
		FollowerCount:  countRecords(e.App, "follows", dbx.HashExp{"followee": targetID, "status": "accepted"}),
		FollowingCount: countRecords(e.App, "follows", dbx.HashExp{"follower": targetID, "status": "accepted"}),
		FollowState:    followState,
		FollowsYou:     !isSelf && followStatus(e.App, targetID, viewerID) == "accepted",
		CanViewDetails: canView,
		RecentDrives:   []driveBrief{},
	}
	if canView {
		resp.RecentDrives = recentDrives(e.App, targetID)
	}
	return e.JSON(http.StatusOK, resp)
}

func profileStats(e *core.RequestEvent) error {
	if e.Auth == nil {
		return e.UnauthorizedError("Sign in required.", nil)
	}
	viewerID := e.Auth.Id
	targetID := e.Request.PathValue("userId")

	target, err := e.App.FindRecordById("users", targetID)
	if err != nil {
		return e.NotFoundError("Player not found.", err)
	}
	if viewerID != targetID && target.GetBool("is_private") && followStatus(e.App, viewerID, targetID) != "accepted" {
		return e.ForbiddenError("This player's stats are private.", nil)
	}

	recs, err := e.App.FindRecordsByFilter(
		"empire_snapshots",
		"user = {:u}",
		"captured_at",
		maxStatPoints, 0,
		dbx.Params{"u": targetID},
	)
	if err != nil {
		return e.InternalServerError("Failed to load stat history.", err)
	}
	items := make([]statPoint, 0, len(recs))
	for _, r := range recs {
		items = append(items, statPoint{
			CapturedAt: r.GetString("captured_at"),
			TilesHeld:  r.GetInt("tiles_held"),
			Strength:   r.GetFloat("strength"),
			Score:      r.GetFloat("score"),
			Rank:       r.GetInt("rank"),
		})
	}
	return e.JSON(http.StatusOK, statsResponse{Items: items})
}

func feed(e *core.RequestEvent) error {
	if e.Auth == nil {
		return e.UnauthorizedError("Sign in required.", nil)
	}
	viewerID := e.Auth.Id

	edges, err := e.App.FindRecordsByFilter(
		"follows",
		"follower = {:u} && status = 'accepted'",
		"", 0, 0,
		dbx.Params{"u": viewerID},
	)
	if err != nil {
		return e.InternalServerError("Failed to load follows.", err)
	}
	if len(edges) == 0 {
		return e.JSON(http.StatusOK, feedResponse{Items: []feedItem{}})
	}

	ids := make([]any, 0, len(edges))
	for _, edge := range edges {
		ids = append(ids, edge.GetString("followee"))
	}

	eventsCol, err := e.App.FindCollectionByNameOrId("feed_events")
	if err != nil {
		return e.InternalServerError("Failed to load feed.", err)
	}
	records := []*core.Record{}
	if err := e.App.RecordQuery(eventsCol).
		AndWhere(dbx.In("actor", ids...)).
		OrderBy("occurred_at DESC").
		Limit(maxFeedItems).
		All(&records); err != nil {
		return e.InternalServerError("Failed to load feed.", err)
	}

	// resolve the players referenced by these events once (actors + capture
	// subjects) so each row carries a name and color without an N+1 fan-out.
	names := userLookup(e.App, records)

	items := make([]feedItem, 0, len(records))
	for _, ev := range records {
		actor := ev.GetString("actor")
		item := feedItem{
			ID:          ev.Id,
			Type:        ev.GetString("type"),
			UserID:      actor,
			DisplayName: names[actor].name,
			Color:       names[actor].color,
			OccurredAt:  ev.GetString("occurred_at"),
			Subtype:     ev.GetString("subtype"),
			Value:       ev.GetFloat("value"),
			PrevValue:   ev.GetFloat("prev_value"),
			DriveID:     ev.GetString("drive"),
		}
		if subject := ev.GetString("subject"); subject != "" {
			item.SubjectID = subject
			item.SubjectName = names[subject].name
		}
		items = append(items, item)
	}
	return e.JSON(http.StatusOK, feedResponse{Items: items})
}

type playerName struct {
	name  string
	color string
}

// userLookup resolves every actor and subject referenced by the feed events to
// their display name and color in one pass
func userLookup(app core.App, events []*core.Record) map[string]playerName {
	out := map[string]playerName{}
	want := map[string]bool{}
	for _, ev := range events {
		if a := ev.GetString("actor"); a != "" {
			want[a] = true
		}
		if s := ev.GetString("subject"); s != "" {
			want[s] = true
		}
	}
	for id := range want {
		if u, err := app.FindRecordById("users", id); err == nil {
			out[id] = playerName{name: u.GetString("display_name"), color: u.GetString("color")}
		}
	}
	return out
}

// MARK: helpers

// followStatus reports the edge from follower to followee: "none", "pending", or
// "accepted"
func followStatus(app core.App, followerID, followeeID string) string {
	rec, err := app.FindFirstRecordByFilter(
		"follows",
		"follower = {:f} && followee = {:t}",
		dbx.Params{"f": followerID, "t": followeeID},
	)
	if err != nil || rec == nil {
		return "none"
	}
	if status := rec.GetString("status"); status != "" {
		return status
	}
	return "pending"
}

func countRecords(app core.App, collection string, expr dbx.Expression) int {
	n, err := app.CountRecords(collection, expr)
	if err != nil {
		return 0
	}
	return int(n)
}

func recentDrives(app core.App, userID string) []driveBrief {
	recs, err := app.FindRecordsByFilter(
		"drives",
		"user = {:u}",
		"-started_at",
		maxProfileDrives, 0,
		dbx.Params{"u": userID},
	)
	if err != nil {
		return []driveBrief{}
	}
	out := make([]driveBrief, 0, len(recs))
	for _, r := range recs {
		out = append(out, driveBrief{
			ID:              r.Id,
			StartedAt:       r.GetString("started_at"),
			DurationSeconds: driveDuration(r),
			Tiles:           driveTileCount(r),
		})
	}
	return out
}

func driveDuration(d *core.Record) float64 {
	started := d.GetDateTime("started_at").Time()
	ended := d.GetDateTime("ended_at").Time()
	if ended.IsZero() || !ended.After(started) {
		return 0
	}
	return ended.Sub(started).Seconds()
}

func driveTileCount(d *core.Record) int {
	var perTile map[string]float64
	if err := d.UnmarshalJSONField("per_tile_scores", &perTile); err != nil {
		return 0
	}
	return len(perTile)
}
