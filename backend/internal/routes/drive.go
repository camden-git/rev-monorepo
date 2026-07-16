package routes

import (
	"math"
	"net/http"
	"strconv"
	"sync"

	"github.com/camden-git/rev-monorepo/backend/internal/game"
	"github.com/camden-git/rev-monorepo/backend/internal/hooks"
	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
)

// maxDrivePathPoints caps the polyline returned by the drive detail endpoint
const maxDrivePathPoints = 500

// driveDetailResponse is one drive expanded for a feed detail view
type driveDetailResponse struct {
	ID              string           `json:"id"`
	UserID          string           `json:"user_id"`
	DisplayName     string           `json:"display_name"`
	Color           string           `json:"color"`
	StartedAt       string           `json:"started_at"`
	EndedAt         string           `json:"ended_at"`
	DurationSeconds float64          `json:"duration_seconds"`
	Tiles           int              `json:"tiles"`
	TilesGained     int              `json:"tiles_gained"`
	TilesCaptured   int              `json:"tiles_captured"`
	DistanceMeters  float64          `json:"distance_meters"`
	Path            [][2]float64     `json:"path"`
	TileScores      []driveTileScore `json:"tile_scores"`
}

// driveTileScore is one hex the drive scored, for the detail map overlay
type driveTileScore struct {
	H3  string  `json:"h3"`
	Mph float64 `json:"mph"`
}

func RegisterDriveRoutes(app core.App) {
	app.OnServe().BindFunc(func(e *core.ServeEvent) error {
		e.Router.GET("/api/rev/drives/{driveId}", driveDetail).Bind(apis.RequireAuth("users"))
		return e.Next()
	})
}

func driveDetail(e *core.RequestEvent) error {
	if e.Auth == nil {
		return e.UnauthorizedError("Sign in required.", nil)
	}
	viewerID := e.Auth.Id

	drive, err := e.App.FindRecordById("drives", e.Request.PathValue("driveId"))
	if err != nil {
		return e.NotFoundError("Drive not found.", err)
	}

	ownerID := drive.GetString("user")
	owner, err := e.App.FindRecordById("users", ownerID)
	if err != nil {
		return e.NotFoundError("Drive not found.", err)
	}

	// same visibility rule as the profile card: self, public account, or an
	// accepted follow
	if viewerID != ownerID && owner.GetBool("is_private") && followStatus(e.App, viewerID, ownerID) != "accepted" {
		return e.ForbiddenError("This player's drives are private.", nil)
	}

	path, distance, tileScores := cachedDrivePath(drive)
	return e.JSON(http.StatusOK, driveDetailResponse{
		ID:              drive.Id,
		UserID:          ownerID,
		DisplayName:     owner.GetString("display_name"),
		Color:           owner.GetString("color"),
		StartedAt:       drive.GetString("started_at"),
		EndedAt:         drive.GetString("ended_at"),
		DurationSeconds: driveDuration(drive),
		Tiles:           driveTileCount(drive),
		TilesGained:     drive.GetInt("tiles_gained"),
		TilesCaptured:   drive.GetInt("tiles_captured"),
		DistanceMeters:  distance,
		Path:            path,
		TileScores:      tileScores,
	})
}

// drivePathCache memoizes the parsed/scored view of a drive
var drivePathCache = struct {
	sync.Mutex
	entries map[string]drivePathResult
}{entries: map[string]drivePathResult{}}

const maxDrivePathCacheEntries = 256

type drivePathResult struct {
	path       [][2]float64
	distance   float64
	tileScores []driveTileScore
}

func cachedDrivePath(drive *core.Record) ([][2]float64, float64, []driveTileScore) {
	drivePathCache.Lock()
	if hit, ok := drivePathCache.entries[drive.Id]; ok {
		drivePathCache.Unlock()
		return hit.path, hit.distance, hit.tileScores
	}
	drivePathCache.Unlock()

	path, distance, tileScores := drivePath(drive)

	drivePathCache.Lock()
	if len(drivePathCache.entries) >= maxDrivePathCacheEntries {
		drivePathCache.entries = map[string]drivePathResult{}
	}
	drivePathCache.entries[drive.Id] = drivePathResult{path: path, distance: distance, tileScores: tileScores}
	drivePathCache.Unlock()
	return path, distance, tileScores
}

// drivePath cleans the drive's raw GPS trace like scoring does, then returns a
// downsampled polyline, the distance along the cleaned path, and the re-derived
// per-tile speeds
func drivePath(drive *core.Record) ([][2]float64, float64, []driveTileScore) {
	var raw []hooks.RawSample
	if err := drive.UnmarshalJSONField("raw_path", &raw); err != nil {
		return [][2]float64{}, 0, []driveTileScore{}
	}
	cleaned := game.FilterOutliers(hooks.SamplesFromRaw(raw))

	tileScores := []driveTileScore{}
	for h3, mph := range game.PerTileScores(cleaned) {
		tileScores = append(tileScores, driveTileScore{H3: strconv.FormatUint(h3, 10), Mph: mph})
	}

	var distance float64
	for i := 1; i < len(cleaned); i++ {
		distance += pathHaversineMeters(cleaned[i-1].Lat, cleaned[i-1].Lng, cleaned[i].Lat, cleaned[i].Lng)
	}

	n := len(cleaned)
	if n == 0 {
		return [][2]float64{}, distance, tileScores
	}
	stride := 1
	if n > maxDrivePathPoints {
		stride = (n + maxDrivePathPoints - 1) / maxDrivePathPoints
	}
	path := make([][2]float64, 0, (n+stride-1)/stride+1)
	for i := 0; i < n; i += stride {
		path = append(path, [2]float64{cleaned[i].Lat, cleaned[i].Lng})
	}
	// always keep the final fix so the polyline reaches the drive's end
	if last := cleaned[n-1]; len(path) == 0 || path[len(path)-1] != [2]float64{last.Lat, last.Lng} {
		path = append(path, [2]float64{last.Lat, last.Lng})
	}
	return path, distance, tileScores
}

// pathHaversineMeters matches the feed package's formulation so a drive's
// detail distance agrees with the distance its PR events were computed from
func pathHaversineMeters(lat1, lon1, lat2, lon2 float64) float64 {
	const earthRadius = 6371000.0
	rad := math.Pi / 180
	dLat := (lat2 - lat1) * rad
	dLon := (lon2 - lon1) * rad
	a := math.Sin(dLat/2)*math.Sin(dLat/2) +
		math.Cos(lat1*rad)*math.Cos(lat2*rad)*math.Sin(dLon/2)*math.Sin(dLon/2)
	return 2 * earthRadius * math.Atan2(math.Sqrt(a), math.Sqrt(1-a))
}
