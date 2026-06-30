// Package feed records durable activity "moments" for the following feed
package feed

import (
	"math"
	"sort"
	"time"

	"github.com/camden-git/rev-monorepo/backend/internal/game"
	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"
)

// Event types
const (
	TypeDrive       = "drive"
	TypeCapture     = "capture"
	TypePR          = "pr"
	TypeRankUp      = "rank_up"
	TypeStreak      = "streak"
	TypeAchievement = "achievement"
)

// PR subtypes mirror RevKit's DrivePRKind
const (
	PRTilesDriven   = "tilesDriven"
	PRTilesGained   = "tilesGained"
	PRTilesCaptured = "tilesCaptured"
	PRDistance      = "distance"
	PRDuration      = "duration"
)

// Achievement subtypes
const (
	AchFirstDrive   = "first_drive"
	AchFirstCapture = "first_capture"
	AchTilesHeld    = "tiles_held" // value carries the threshold crossed
)

// streakMilestones are the consecutive-day streak lengths worth celebrating
var streakMilestones = []int{3, 7, 14, 30, 60, 100, 200, 365}

// tilesHeldMilestones are empire-size thresholds worth an achievement
var tilesHeldMilestones = []int{10, 25, 50, 100, 250, 500, 1000, 2500}

// rankUpCeiling bounds rank-up events to the part of the board where moving up
// is meaningful
const rankUpCeiling = 50

// DriveStats is the resolved outcome of one drive
type DriveStats struct {
	// Captures maps each displaced owner's id to how many of their tiles were taken
	Captures map[string]int
	// Gained is newly-won ground this drive (created + captured + enclosed; not reinforced)
	Gained int
	// Captured is the total tiles taken from rivals
	Captured int
}

// RecordDriveEvents turns one resolved drive into its feed moments
func RecordDriveEvents(app core.App, drive *core.Record, ds DriveStats, now time.Time) {
	actor := drive.GetString("user")
	if actor == "" {
		return
	}
	when := driveTime(drive, now)

	// the drive itself: value = tiles driven, prev_value = duration seconds
	tiles := driveTileCount(drive)
	emit(app, event{
		actor: actor, typ: TypeDrive, drive: drive.Id,
		occurred: when, value: float64(tiles), prevValue: driveDuration(drive),
	})

	// captures: one aggregated event per displaced owner (value = tiles taken)
	for victim, count := range ds.Captures {
		if victim == "" || count <= 0 {
			continue
		}
		emit(app, event{
			actor: actor, typ: TypeCapture, subject: victim,
			drive: drive.Id, occurred: when, value: float64(count),
		})
	}

	recordPRs(app, actor, drive, when)
	recordStreak(app, actor, when)
	recordDriveAchievements(app, actor, drive, ds, when)
}

// recordPRs emits a pr event for each drive-level personal record this drive set,
// comparing it against the best of the player's prior drives
func recordPRs(app core.App, actor string, drive *core.Record, when time.Time) {
	drives, err := app.FindRecordsByFilter("drives", "user = {:u}", "-started_at", 500, 0, dbx.Params{"u": actor})
	if err != nil || len(drives) < 2 {
		return
	}

	current := metricsOf(drive)
	bests := map[string]float64{}
	for _, d := range drives {
		if d.Id == drive.Id {
			continue
		}
		for kind, v := range metricsOf(d) {
			if v > bests[kind] {
				bests[kind] = v
			}
		}
	}

	// stable order so multiple PRs in one drive land deterministically
	kinds := make([]string, 0, len(current))
	for k := range current {
		kinds = append(kinds, k)
	}
	sort.Strings(kinds)
	for _, kind := range kinds {
		v := current[kind]
		if v > 0 && v > bests[kind] {
			emit(app, event{actor: actor, typ: TypePR, subtype: kind, drive: drive.Id, occurred: when, value: v})
		}
	}
}

// recordStreak emits a streak event when the player's active consecutive-day
// streak (ending today) reaches a milestone it has not already celebrated
func recordStreak(app core.App, actor string, when time.Time) {
	drives, err := app.FindRecordsByFilter("drives", "user = {:u}", "-started_at", 1000, 0, dbx.Params{"u": actor})
	if err != nil || len(drives) == 0 {
		return
	}
	dates := make([]time.Time, 0, len(drives))
	for _, d := range drives {
		if t := d.GetDateTime("started_at").Time(); !t.IsZero() {
			dates = append(dates, t)
		}
	}
	current := currentStreak(dates, when)
	if current <= 0 || !isMilestone(current, streakMilestones) {
		return
	}
	if eventExists(app, actor, TypeStreak, "", float64(current)) {
		return
	}
	emit(app, event{actor: actor, typ: TypeStreak, occurred: when, value: float64(current)})
}

// recordDriveAchievements emits first-time achievement unlocks tied to a drive
func recordDriveAchievements(app core.App, actor string, drive *core.Record, ds DriveStats, when time.Time) {
	if n, err := app.CountRecords("drives", dbx.HashExp{"user": actor}); err == nil && n == 1 {
		emit(app, event{actor: actor, typ: TypeAchievement, subtype: AchFirstDrive, drive: drive.Id, occurred: when, value: 1})
	}
	if ds.Captured > 0 && !eventExists(app, actor, TypeAchievement, AchFirstCapture, 0) {
		emit(app, event{actor: actor, typ: TypeAchievement, subtype: AchFirstCapture, drive: drive.Id, occurred: when, value: float64(ds.Captured)})
	}
}

// RecordEmpireMilestones emits a rank-up event when a player climbs the board and
// achievement events as their held-tile count crosses size milestones
func RecordEmpireMilestones(app core.App, actor string, newRank, prevRank, newTiles, prevTiles int, now time.Time) {
	if actor == "" {
		return
	}
	if prevRank > 0 && newRank > 0 && newRank < prevRank && newRank <= rankUpCeiling {
		emit(app, event{actor: actor, typ: TypeRankUp, occurred: now, value: float64(newRank), prevValue: float64(prevRank)})
	}
	if prevTiles > 0 {
		for _, threshold := range tilesHeldMilestones {
			if prevTiles < threshold && newTiles >= threshold {
				emit(app, event{actor: actor, typ: TypeAchievement, subtype: AchTilesHeld, occurred: now, value: float64(threshold)})
			}
		}
	}
}

// MARK: metrics

// metricsOf reduces a stored drive to the comparable values personal records
// track, keyed by PR subtype
func metricsOf(d *core.Record) map[string]float64 {
	return map[string]float64{
		PRTilesDriven:   float64(driveTileCount(d)),
		PRTilesGained:   d.GetFloat("tiles_gained"),
		PRTilesCaptured: d.GetFloat("tiles_captured"),
		PRDistance:      driveDistanceMeters(d),
		PRDuration:      driveDuration(d),
	}
}

func driveTileCount(d *core.Record) int {
	var perTile map[string]float64
	if err := d.UnmarshalJSONField("per_tile_scores", &perTile); err != nil {
		return 0
	}
	return len(perTile)
}

func driveDuration(d *core.Record) float64 {
	started := d.GetDateTime("started_at").Time()
	ended := d.GetDateTime("ended_at").Time()
	if ended.IsZero() || !ended.After(started) {
		return 0
	}
	return ended.Sub(started).Seconds()
}

// rawSample is the slice of a raw_path fix this package reads for distance
type rawSample struct {
	TS    string  `json:"timestamp"`
	Lat   float64 `json:"lat"`
	Lng   float64 `json:"lng"`
	Speed float64 `json:"speed"`
}

const rawPathTimeLayout = "2006-01-02 15:04:05.000Z"

// driveDistanceMeters sums the great-circle distance along the cleaned GPS path
func driveDistanceMeters(d *core.Record) float64 {
	var raw []rawSample
	if err := d.UnmarshalJSONField("raw_path", &raw); err != nil {
		return 0
	}
	samples := make([]game.Sample, 0, len(raw))
	for _, s := range raw {
		ts, err := time.Parse(rawPathTimeLayout, s.TS)
		if err != nil {
			if ts, err = time.Parse(time.RFC3339Nano, s.TS); err != nil {
				continue
			}
		}
		samples = append(samples, game.Sample{TS: ts, Lat: s.Lat, Lng: s.Lng, Speed: s.Speed})
	}
	cleaned := game.FilterOutliers(samples)
	var total float64
	for i := 1; i < len(cleaned); i++ {
		total += haversineMeters(cleaned[i-1].Lat, cleaned[i-1].Lng, cleaned[i].Lat, cleaned[i].Lng)
	}
	return total
}

const earthRadiusMeters = 6371000.0

func haversineMeters(lat1, lon1, lat2, lon2 float64) float64 {
	rad := math.Pi / 180
	dLat := (lat2 - lat1) * rad
	dLon := (lon2 - lon1) * rad
	a := math.Sin(dLat/2)*math.Sin(dLat/2) +
		math.Cos(lat1*rad)*math.Cos(lat2*rad)*math.Sin(dLon/2)*math.Sin(dLon/2)
	return earthRadiusMeters * 2 * math.Atan2(math.Sqrt(a), math.Sqrt(1-a))
}

// currentStreak is the active run of consecutive calendar days ending today or
// yesterday (one grace day)
func currentStreak(driveDates []time.Time, now time.Time) int {
	if len(driveDates) == 0 {
		return 0
	}
	daySet := map[int]bool{}
	for _, d := range driveDates {
		daySet[dayIndex(d)] = true
	}
	days := make([]int, 0, len(daySet))
	for d := range daySet {
		days = append(days, d)
	}
	sort.Ints(days)

	today := dayIndex(now)
	last := days[len(days)-1]
	if today-last > 1 {
		return 0
	}
	current := 1
	for i := len(days) - 1; i > 0; i-- {
		if days[i]-days[i-1] == 1 {
			current++
		} else {
			break
		}
	}
	return current
}

// dayIndex collapses a time to a whole-day ordinal in UTC so consecutive
// calendar days differ by exactly 1
func dayIndex(t time.Time) int {
	return int(t.UTC().Truncate(24*time.Hour).Unix() / 86400)
}

func isMilestone(n int, milestones []int) bool {
	for _, m := range milestones {
		if n == m {
			return true
		}
	}
	return false
}

// MARK: emit

type event struct {
	actor     string
	typ       string
	subtype   string
	subject   string
	drive     string
	occurred  time.Time
	value     float64
	prevValue float64
}

func emit(app core.App, e event) {
	col, err := app.FindCollectionByNameOrId("feed_events")
	if err != nil {
		app.Logger().Error("feed_events collection missing", "error", err)
		return
	}
	rec := core.NewRecord(col)
	rec.Set("actor", e.actor)
	rec.Set("type", e.typ)
	if e.subtype != "" {
		rec.Set("subtype", e.subtype)
	}
	if e.subject != "" {
		rec.Set("subject", e.subject)
	}
	if e.drive != "" {
		rec.Set("drive", e.drive)
	}
	if e.occurred.IsZero() {
		e.occurred = time.Now()
	}
	rec.Set("occurred_at", e.occurred)
	rec.Set("value", e.value)
	rec.Set("prev_value", e.prevValue)
	if err := app.Save(rec); err != nil {
		app.Logger().Error("feed event save failed", "actor", e.actor, "type", e.typ, "error", err)
	}
}

// eventExists reports whether the actor already has an event of this type
func eventExists(app core.App, actor, typ, subtype string, value float64) bool {
	filter := "actor = {:a} && type = {:t}"
	params := dbx.Params{"a": actor, "t": typ}
	if subtype != "" {
		filter += " && subtype = {:s}"
		params["s"] = subtype
	}
	if value != 0 {
		filter += " && value = {:v}"
		params["v"] = value
	}
	rec, err := app.FindFirstRecordByFilter("feed_events", filter, params)
	return err == nil && rec != nil
}

func driveTime(drive *core.Record, fallback time.Time) time.Time {
	if t := drive.GetDateTime("ended_at").Time(); !t.IsZero() {
		return t
	}
	if t := drive.GetDateTime("started_at").Time(); !t.IsZero() {
		return t
	}
	return fallback
}
