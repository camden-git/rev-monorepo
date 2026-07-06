package game

import (
	"math"
	"testing"
	"time"
)

// port of: RevKit DecayTests.swift

var decayNow = time.Unix(1_000_000, 0)

func TestZeroElapsedKeepsFullScore(t *testing.T) {
	score := EffectiveScore(50, decayNow, decayNow)
	if math.Abs(score-50) >= 1e-9 {
		t.Fatalf("expected 50, got %v", score)
	}
}

func TestOneTauDecaysToAboutThirtySevenPercent(t *testing.T) {
	lastDriven := decayNow.Add(-time.Duration(Tau) * time.Second)
	score := EffectiveScore(100, lastDriven, decayNow)
	if math.Abs(score-100*math.Exp(-1)) >= 1e-6 { // ~36.79
		t.Fatalf("expected ~36.79, got %v", score)
	}
}

func TestTwoTauDecaysToAboutFourteenPercent(t *testing.T) {
	lastDriven := decayNow.Add(-2 * time.Duration(Tau) * time.Second)
	score := EffectiveScore(100, lastDriven, decayNow)
	if math.Abs(score-100*math.Exp(-2)) >= 1e-6 { // ~13.53
		t.Fatalf("expected ~13.53, got %v", score)
	}
}

func TestDecreasesMonotonicallyWithTime(t *testing.T) {
	const claim = 80.0
	previous := math.MaxFloat64
	for days := 0; days <= 28; days++ {
		lastDriven := decayNow.Add(-time.Duration(days) * 24 * time.Hour)
		score := EffectiveScore(claim, lastDriven, decayNow)
		if score > previous {
			t.Fatalf("score increased at day %d: %v > %v", days, score, previous)
		}
		previous = score
	}
}

func TestExpiryFollowsTheEffectiveScoreThreshold(t *testing.T) {
	if Expired(2.0, decayNow, decayNow) {
		t.Fatal("fresh tile should not be expired")
	}

	if !Expired(2.0, decayNow.Add(-5*7*24*time.Hour), decayNow) {
		t.Fatal("5-week-old 2.0 tile should be expired")
	}

	if !Expired(0.4, decayNow, decayNow) {
		t.Fatal("sub-threshold tile should be expired")
	}
}

func TestFutureLastDrivenIsClampedToFullScore(t *testing.T) {
	future := decayNow.Add(time.Duration(Tau) * time.Second)
	score := EffectiveScore(42, future, decayNow)
	if math.Abs(score-42) >= 1e-9 {
		t.Fatalf("expected 42, got %v", score)
	}
}
