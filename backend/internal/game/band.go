package game

import "math"

// RoadClass is the canonical functional class of the road under a tile, derived
// from the OSM `highway=` tag (see internal/roads)
type RoadClass string

const (
	ClassMotorway    RoadClass = "motorway"
	ClassTrunk       RoadClass = "trunk"
	ClassPrimary     RoadClass = "primary"
	ClassSecondary   RoadClass = "secondary"
	ClassTertiary    RoadClass = "tertiary"
	ClassResidential RoadClass = "residential"
	ClassService     RoadClass = "service"
	ClassUnknown     RoadClass = "" // un-seeded or no road found
)

// Band is the plausible free-flow speed envelope for a road class, in mph
//   - Prior is the seed reference for a tile with no learned observations yet
//   - Floor / Ceil bound the learned reference so traffic can pull it up / down
type Band struct {
	Prior float64
	Floor float64
	Ceil  float64
}

// bands maps each canonical class to its envelope
var bands = map[RoadClass]Band{
	ClassMotorway:    {Prior: 60, Floor: 35, Ceil: 80},
	ClassTrunk:       {Prior: 45, Floor: 25, Ceil: 65},
	ClassPrimary:     {Prior: 35, Floor: 18, Ceil: 55},
	ClassSecondary:   {Prior: 30, Floor: 15, Ceil: 45},
	ClassTertiary:    {Prior: 28, Floor: 12, Ceil: 40},
	ClassResidential: {Prior: 22, Floor: 8, Ceil: 30},
	ClassService:     {Prior: 12, Floor: 5, Ceil: 20},
}

var unknownBand = Band{Prior: ReferenceSpeedPrior, Floor: ReferenceSpeedFloor, Ceil: 80}

// BandForClass returns the speed envelope for a road class, falling back to the
// unknown band for un-seeded tiles
func BandForClass(class RoadClass) Band {
	if b, ok := bands[class]; ok {
		return b
	}
	return unknownBand
}

// ClampReference constrains a reference speed to its class band
func ClampReference(refSpeed float64, band Band) float64 {
	if !validNonNegative(refSpeed) || refSpeed == 0 {
		return band.Prior
	}
	return math.Min(math.Max(refSpeed, band.Floor), band.Ceil)
}
