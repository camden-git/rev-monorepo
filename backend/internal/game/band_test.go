package game

import (
	"math"
	"testing"
)

func TestBandForClassFallsBackToUnknown(t *testing.T) {
	if got := BandForClass(ClassUnknown); got != unknownBand {
		t.Fatalf("expected unknown band for empty class, got %+v", got)
	}
	if got := BandForClass(RoadClass("none")); got != unknownBand {
		t.Fatalf("expected unknown band for sentinel, got %+v", got)
	}
	if BandForClass(ClassMotorway).Ceil <= BandForClass(ClassResidential).Ceil {
		t.Fatalf("expected motorway band to sit above residential")
	}
}

func TestClampReferenceZeroUsesPrior(t *testing.T) {
	band := BandForClass(ClassTrunk)
	if got := ClampReference(0, band); got != band.Prior {
		t.Fatalf("expected prior %v for zero ref, got %v", band.Prior, got)
	}
	if got := ClampReference(math.NaN(), band); got != band.Prior {
		t.Fatalf("expected prior for NaN ref, got %v", got)
	}
}

func TestClampReferenceCapsRunawayHotspot(t *testing.T) {
	band := BandForClass(ClassTrunk)
	if got := ClampReference(103, band); got != band.Ceil {
		t.Fatalf("expected runaway ref clamped to ceil %v, got %v", band.Ceil, got)
	}
}

func TestClampReferenceHoldsFloorInTraffic(t *testing.T) {
	band := BandForClass(ClassResidential)
	if got := ClampReference(2, band); got != band.Floor {
		t.Fatalf("expected ref floored at %v, got %v", band.Floor, got)
	}
}

func TestClampReferencePassesInBandValue(t *testing.T) {
	band := BandForClass(ClassPrimary)
	mid := (band.Floor + band.Ceil) / 2
	if got := ClampReference(mid, band); got != mid {
		t.Fatalf("expected in-band ref %v unchanged, got %v", mid, got)
	}
}
