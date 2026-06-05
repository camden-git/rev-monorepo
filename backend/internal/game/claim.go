package game

import (
	"math"
	"time"
)

// TileState is a snapshot of a tile's current stored state
// port of RevKit ClaimResolver.TileState
type TileState struct {
	OwnerID      string
	ClaimScore   float64
	LastDrivenAt time.Time
	IsHome       bool
}

// OutcomeKind enumerates how a direct claim resolved
type OutcomeKind int

const (
	// NoChange - the tile keeps its current owner/score
	NoChange OutcomeKind = iota
	// Created - first traversal of a previously-unowned tile
	Created
	// Reinforced - the claimant already owned it, score = max(current, incoming)
	Reinforced
	// Captured - the claimant beat the decayed owner so the tile flips
	Captured
)

// ClaimOutcome is the result of resolving one tile claim
// Score is the new stored claim score (used for Created/Reinforced/Captured)
type ClaimOutcome struct {
	Kind  OutcomeKind
	Score float64
}

// Resolve resolves a single tile claim (REF: docs/game-design.md §Direct Claims,
// §Re-Drive Floor, §Home Hex), port of RevKit ClaimResolver.resolve:
//
//   - nil current      -> created at the driver's score (first traversal)
//   - home hex         -> NoChange (inviolable by direct drive)
//   - claimant's tile  -> reinforced at max(current, incoming) (re-drive floor)
//   - someone else's   -> compare incoming against the decayed score; `>=` flips
//     it (Captured, ties last-write-wins), otherwise NoChange
func Resolve(current *TileState, claimantID string, incomingScore float64, now time.Time) ClaimOutcome {
	if current == nil {
		return ClaimOutcome{Kind: Created, Score: incomingScore}
	}
	if current.IsHome {
		return ClaimOutcome{Kind: NoChange}
	}
	if current.OwnerID == claimantID {
		return ClaimOutcome{Kind: Reinforced, Score: math.Max(current.ClaimScore, incomingScore)}
	}
	effective := EffectiveScore(current.ClaimScore, current.LastDrivenAt, now)
	if incomingScore >= effective {
		return ClaimOutcome{Kind: Captured, Score: incomingScore}
	}
	return ClaimOutcome{Kind: NoChange}
}
