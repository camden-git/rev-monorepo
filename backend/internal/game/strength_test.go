package game

import (
	"math"
	"testing"
)

func TestStrengthUsesLocalReferenceSpeed(t *testing.T) {
	downtown := Strength(35, 18)
	rural := Strength(100, 75)
	if downtown <= rural {
		t.Fatalf("expected downtown strength %v to exceed rural strength %v", downtown, rural)
	}
}

func TestStrengthUsesFloorAndCap(t *testing.T) {
	if got := Strength(50, 0); math.Abs(got-2) >= 1e-9 {
		t.Fatalf("expected prior-based strength 2, got %v", got)
	}
	if got := Strength(100, 1); got != StrengthCap {
		t.Fatalf("expected capped strength %v, got %v", StrengthCap, got)
	}
}

func TestUpdateReferenceLearnsByEWMA(t *testing.T) {
	got := UpdateReference(25, 35)
	want := 27.0
	if math.Abs(got-want) >= 1e-9 {
		t.Fatalf("expected %v, got %v", want, got)
	}
}

func TestTileValueRisesWithCaptures(t *testing.T) {
	if got := TileValue(0); got != 1 {
		t.Fatalf("expected base value 1, got %v", got)
	}
	if TileValue(5) <= TileValue(1) {
		t.Fatalf("expected value to rise with captures")
	}
}
