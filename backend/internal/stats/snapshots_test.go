package stats

import "testing"

func TestAggregateRanksByScoreDescending(t *testing.T) {
	rows := []tileRow{
		// alice: home + two captured tiles
		{Owner: "alice", IsHome: 1},
		{Owner: "alice", ClaimScore: 2.0, Captures: 3},
		{Owner: "alice", ClaimScore: 1.5, Captures: 1},
		// bob: home only
		{Owner: "bob", IsHome: 1},
	}

	got := aggregate(rows)

	if len(got) != 2 {
		t.Fatalf("expected 2 standings, got %d", len(got))
	}
	if got[0].UserID != "alice" || got[0].Rank != 1 {
		t.Fatalf("expected alice ranked 1, got %+v", got[0])
	}
	if got[1].UserID != "bob" || got[1].Rank != 2 {
		t.Fatalf("expected bob ranked 2, got %+v", got[1])
	}
	if got[0].TilesHeld != 3 {
		t.Fatalf("expected alice 3 tiles, got %d", got[0].TilesHeld)
	}
	if got[0].Strength != 3.5 {
		t.Fatalf("expected alice strength 3.5, got %v", got[0].Strength)
	}
}

func TestAggregateTieBreaksByUserID(t *testing.T) {
	rows := []tileRow{
		{Owner: "zoe", IsHome: 1},
		{Owner: "amy", IsHome: 1},
	}

	got := aggregate(rows)

	if got[0].UserID != "amy" || got[1].UserID != "zoe" {
		t.Fatalf("expected amy before zoe on equal score, got %+v", got)
	}
}

func TestAggregateEmpty(t *testing.T) {
	if got := aggregate(nil); len(got) != 0 {
		t.Fatalf("expected no standings, got %d", len(got))
	}
}
