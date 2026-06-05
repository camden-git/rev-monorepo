package game

import (
	"testing"
	"time"
)

// port of: RevKit ClaimResolverTests.swift

var claimNow = time.Unix(2_000_000, 0)

func tileState(owner string, score float64, drivenAgo time.Duration, isHome bool) *TileState {
	return &TileState{
		OwnerID:      owner,
		ClaimScore:   score,
		LastDrivenAt: claimNow.Add(-drivenAgo),
		IsHome:       isHome,
	}
}

func expectOutcome(t *testing.T, got ClaimOutcome, kind OutcomeKind, score float64) {
	t.Helper()
	if got.Kind != kind {
		t.Fatalf("expected kind %d, got %d", kind, got.Kind)
	}
	if kind != NoChange && got.Score != score {
		t.Fatalf("expected score %v, got %v", score, got.Score)
	}
}

func TestUnownedTileIsCreatedAtDriverScore(t *testing.T) {
	expectOutcome(t, Resolve(nil, "me", 25, claimNow), Created, 25)
}

func TestHomeHexIsInviolableEvenAgainstHugeScore(t *testing.T) {
	home := tileState("rival", 1, 0, true)
	expectOutcome(t, Resolve(home, "me", 9999, claimNow), NoChange, 0)
}

func TestReDrivingOwnTileTakesTheMax(t *testing.T) {
	mine := tileState("me", 40, 0, false)
	expectOutcome(t, Resolve(mine, "me", 55, claimNow), Reinforced, 55)
	expectOutcome(t, Resolve(mine, "me", 30, claimNow), Reinforced, 40)
}

func TestBeatingDecayedOpponentCaptures(t *testing.T) {
	// 80 mph driven 2 weeks ago decays to ~11 mph; 25 > 11
	stale := tileState("rival", 80, 14*24*time.Hour, false)
	expectOutcome(t, Resolve(stale, "me", 25, claimNow), Captured, 25)
}

func TestLosingToFreshOpponentDoesNotFlip(t *testing.T) {
	fresh := tileState("rival", 80, 0, false)
	expectOutcome(t, Resolve(fresh, "me", 25, claimNow), NoChange, 0)
}

func TestExactTieIsLastWriteWins(t *testing.T) {
	other := tileState("rival", 30, 0, false) // effective == 30
	expectOutcome(t, Resolve(other, "me", 30, claimNow), Captured, 30)
}

func TestDecayMakesAStrongOpponentCapturableOverTime(t *testing.T) {
	claimedAt := claimNow
	opponent := &TileState{OwnerID: "rival", ClaimScore: 60, LastDrivenAt: claimedAt, IsHome: false}
	const incoming = 30.0

	// 30 < 60, no flip
	expectOutcome(t, Resolve(opponent, "me", incoming, claimedAt), NoChange, 0)

	// same claim after a week should flip due to decay
	later := claimedAt.Add(time.Duration(Tau) * time.Second)
	expectOutcome(t, Resolve(opponent, "me", incoming, later), Captured, incoming)
}
