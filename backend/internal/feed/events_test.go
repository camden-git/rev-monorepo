package feed

import (
	"math"
	"testing"
	"time"
)

// fixed clock so streak math is deterministic
var now = time.Date(2026, 6, 29, 12, 0, 0, 0, time.UTC)

func day(offset int) time.Time {
	return now.AddDate(0, 0, offset).Add(3 * time.Hour) // arbitrary time-of-day
}

func TestCurrentStreakEmptyIsZero(t *testing.T) {
	if got := currentStreak(nil, now); got != 0 {
		t.Fatalf("expected 0, got %d", got)
	}
}

func TestCurrentStreakCountsConsecutiveDaysEndingToday(t *testing.T) {
	dates := []time.Time{day(0), day(-1), day(-2)}
	if got := currentStreak(dates, now); got != 3 {
		t.Fatalf("expected streak 3, got %d", got)
	}
}

func TestCurrentStreakCollapsesMultipleDrivesPerDay(t *testing.T) {
	// two drives today + one yesterday is still a 2-day streak
	dates := []time.Time{day(0), now.Add(8 * time.Hour), day(-1)}
	if got := currentStreak(dates, now); got != 2 {
		t.Fatalf("expected streak 2, got %d", got)
	}
}

func TestCurrentStreakGraceDayEndingYesterday(t *testing.T) {
	dates := []time.Time{day(-1), day(-2)}
	if got := currentStreak(dates, now); got != 2 {
		t.Fatalf("expected streak 2 (grace), got %d", got)
	}
}

func TestCurrentStreakBrokenWhenLastDriveTooOld(t *testing.T) {
	dates := []time.Time{day(-2), day(-3)}
	if got := currentStreak(dates, now); got != 0 {
		t.Fatalf("expected broken streak 0, got %d", got)
	}
}

func TestCurrentStreakStopsAtGap(t *testing.T) {
	// today, yesterday, then a gap (no -2), then -3/-4: current run is just 2
	dates := []time.Time{day(0), day(-1), day(-3), day(-4)}
	if got := currentStreak(dates, now); got != 2 {
		t.Fatalf("expected streak 2 up to the gap, got %d", got)
	}
}

func TestIsMilestone(t *testing.T) {
	if !isMilestone(7, streakMilestones) {
		t.Fatal("7 should be a streak milestone")
	}
	if isMilestone(8, streakMilestones) {
		t.Fatal("8 should not be a streak milestone")
	}
}

func TestHaversineMetersKnownDistance(t *testing.T) {
	// ~1 degree of latitude is ~111 km
	d := haversineMeters(0, 0, 1, 0)
	if math.Abs(d-111195) > 500 {
		t.Fatalf("expected ~111195 m, got %.0f", d)
	}
	if haversineMeters(40.0, -105.0, 40.0, -105.0) != 0 {
		t.Fatal("identical points should be 0 m apart")
	}
}
