// Package geofence reports whether a coordinate lies within Chicago
package geofence

import (
	_ "embed"
	"encoding/json"
	"fmt"
	"math"

	"github.com/camden-git/rev-monorepo/backend/internal/h3util"
)

// chicagoGeoJSON is the City of Chicago official boundary simplified to ~33m.
// it is a MultiPolygon
//
//go:embed chicago.geojson
var chicagoGeoJSON []byte

// bufferMeters expands the boundary outward so claims that drift just outside
// the city (e.g. GPS noise along the lakefront) still count as inside
const bufferMeters = 150

// metersPerDegLat is constant; longitude degrees shrink with latitude
const metersPerDegLat = 111_320.0

func metersPerDegLng(lat float64) float64 {
	return metersPerDegLat * math.Cos(lat*math.Pi/180)
}

// ring is a closed list of [lng, lat] vertices, matching GeoJSON axis order
type ring [][2]float64

// polygon is an outer ring followed by zero or more hole rings
type polygon []ring

var chicago []polygon

// bb is Chicago's bounding box, used to reject far-away points before the
// per-vertex ray cast
var bbMinLng, bbMinLat, bbMaxLng, bbMaxLat float64

func init() {
	var geo struct {
		Coordinates []polygon `json:"coordinates"`
	}
	if err := json.Unmarshal(chicagoGeoJSON, &geo); err != nil {
		panic(fmt.Sprintf("geofence: parse chicago boundary: %v", err))
	}
	chicago = geo.Coordinates
	if len(chicago) == 0 {
		panic("geofence: chicago boundary is empty")
	}

	bbMinLng, bbMinLat = math.Inf(1), math.Inf(1)
	bbMaxLng, bbMaxLat = math.Inf(-1), math.Inf(-1)
	for _, poly := range chicago {
		for _, v := range poly[0] {
			bbMinLng, bbMaxLng = math.Min(bbMinLng, v[0]), math.Max(bbMaxLng, v[0])
			bbMinLat, bbMaxLat = math.Min(bbMinLat, v[1]), math.Max(bbMaxLat, v[1])
		}
	}
}

// ContainsLatLng reports whether the coordinate falls inside the Chicago
// boundary, or within bufferMeters of it. a point inside an outer ring but
// within one of its holes is outside
func ContainsLatLng(lat, lng float64) bool {
	bufLat := bufferMeters / metersPerDegLat
	bufLng := bufferMeters / metersPerDegLng(lat)
	if lng < bbMinLng-bufLng || lng > bbMaxLng+bufLng || lat < bbMinLat-bufLat || lat > bbMaxLat+bufLat {
		return false
	}
	for _, poly := range chicago {
		if len(poly) == 0 || !poly[0].contains(lng, lat) {
			continue
		}
		inHole := false
		for _, hole := range poly[1:] {
			if hole.contains(lng, lat) {
				inHole = true
				break
			}
		}
		if !inHole {
			return true
		}
	}
	// outside the polygon, but keep it if it sits within the buffer of any edge
	return withinBuffer(lat, lng)
}

// withinBuffer reports whether the point lies within bufferMeters of any
// boundary edge (outer rings and holes alike)
func withinBuffer(lat, lng float64) bool {
	mLng := metersPerDegLng(lat)
	for _, poly := range chicago {
		for _, r := range poly {
			for i, j := 0, len(r)-1; i < len(r); j, i = i, i+1 {
				if segDistMeters(lng, lat, r[j], r[i], mLng) <= bufferMeters {
					return true
				}
			}
		}
	}
	return false
}

// segDistMeters is the distance from point (plng, plat) to segment a-b, using a
// local equirectangular projection (meters relative to the point)
func segDistMeters(plng, plat float64, a, b [2]float64, mLng float64) float64 {
	ax, ay := (a[0]-plng)*mLng, (a[1]-plat)*metersPerDegLat
	bx, by := (b[0]-plng)*mLng, (b[1]-plat)*metersPerDegLat
	dx, dy := bx-ax, by-ay
	if dx == 0 && dy == 0 {
		return math.Hypot(ax, ay)
	}
	t := -(ax*dx + ay*dy) / (dx*dx + dy*dy)
	t = math.Max(0, math.Min(1, t))
	return math.Hypot(ax+t*dx, ay+t*dy)
}

// ContainsCell reports whether the center of an h3 cell falls inside Chicago
func ContainsCell(id uint64) bool {
	lat, lng, ok := h3util.CellCenter(id)
	if !ok {
		return false
	}
	return ContainsLatLng(lat, lng)
}

// contains runs a ray-casting point-in-polygon test. x is lng, y is lat to
// match the stored [lng, lat] vertex order
func (r ring) contains(x, y float64) bool {
	inside := false
	for i, j := 0, len(r)-1; i < len(r); j, i = i, i+1 {
		xi, yi := r[i][0], r[i][1]
		xj, yj := r[j][0], r[j][1]
		if (yi > y) != (yj > y) && x < (xj-xi)*(y-yi)/(yj-yi)+xi {
			inside = !inside
		}
	}
	return inside
}
