package notify

import (
	"context"
	"fmt"
	"time"

	"github.com/camden-git/rev-monorepo/backend/internal/push"
	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"
)

// Notifier raises user-facing push notifications for game and social events. It
// is an interface so hooks can be tested without a live APNs connection, and so
// the server runs with a no-op when push is not configured.
type Notifier interface {
	// TileCaptured tells a player that another player took tiles from them.
	TileCaptured(victimID, attackerID string, tileCount int)
	// NewFollower tells a public-account player someone followed them.
	NewFollower(followeeID, followerID string)
	// FollowRequest tells a private-account player someone asked to follow.
	FollowRequest(followeeID, followerID string)
	// FollowAccepted tells a player their follow request was approved.
	FollowAccepted(followerID, accepterID string)
}

// Service is the live Notifier: it resolves a user's registered devices and
// pushes through APNs, pruning tokens APNs reports as dead.
type Service struct {
	app    core.App
	sender push.Sender
}

func NewService(app core.App, sender push.Sender) *Service {
	return &Service{app: app, sender: sender}
}

func (s *Service) TileCaptured(victimID, attackerID string, tileCount int) {
	if victimID == "" || victimID == attackerID || tileCount <= 0 {
		return
	}
	s.dispatch(victimID, tileCapturedPayload(s.displayName(attackerID), attackerID, tileCount))
}

func (s *Service) NewFollower(followeeID, followerID string) {
	s.dispatch(followeeID, newFollowerPayload(s.displayName(followerID), followerID))
}

func (s *Service) FollowRequest(followeeID, followerID string) {
	s.dispatch(followeeID, followRequestPayload(s.displayName(followerID), followerID))
}

func (s *Service) FollowAccepted(followerID, accepterID string) {
	s.dispatch(followerID, followAcceptedPayload(s.displayName(accepterID), accepterID))
}

// MARK: payload builders (pure)

func tileCapturedPayload(attackerName, attackerID string, count int) push.Payload {
	body := fmt.Sprintf("%s captured one of your tiles", attackerName)
	if count > 1 {
		body = fmt.Sprintf("%s captured %d of your tiles", attackerName, count)
	}
	return push.Payload{
		Title:    "Your territory is under attack",
		Body:     body,
		ThreadID: "tiles",
		Category: "TILE_CAPTURED",
		Data:     map[string]any{"type": "tile_captured", "attacker_id": attackerID},
	}
}

func newFollowerPayload(name, followerID string) push.Payload {
	return push.Payload{
		Title:    "New follower",
		Body:     fmt.Sprintf("%s started following you", name),
		ThreadID: "social",
		Category: "NEW_FOLLOWER",
		Data:     map[string]any{"type": "new_follower", "user_id": followerID},
	}
}

func followRequestPayload(name, followerID string) push.Payload {
	return push.Payload{
		Title:    "Follow request",
		Body:     fmt.Sprintf("%s wants to follow you", name),
		ThreadID: "social",
		Category: "FOLLOW_REQUEST",
		Data:     map[string]any{"type": "follow_request", "user_id": followerID},
	}
}

func followAcceptedPayload(name, accepterID string) push.Payload {
	return push.Payload{
		Title:    "Request accepted",
		Body:     fmt.Sprintf("%s accepted your follow request", name),
		ThreadID: "social",
		Category: "FOLLOW_ACCEPTED",
		Data:     map[string]any{"type": "follow_accepted", "user_id": accepterID},
	}
}

// MARK: delivery

// registeredDevice is one APNs target resolved from the device_tokens table.
type registeredDevice struct {
	id    string
	token string
	env   push.Environment
}

// sendToDevices pushes a payload to every device and returns the record ids of
// tokens APNs reported as permanently dead, which the caller should delete. It
// is pure (no DB) so it can be unit-tested with a fake sender.
func sendToDevices(sender push.Sender, devices []registeredDevice, payload push.Payload) []string {
	var prune []string
	for _, device := range devices {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		result, err := sender.Send(ctx, device.token, device.env, payload)
		cancel()
		if err != nil {
			continue
		}
		if result.TokenInvalid {
			prune = append(prune, device.id)
		}
	}
	return prune
}

// dispatch fans a payload out to a user's devices off the request goroutine so
// APNs latency never blocks a hook.
func (s *Service) dispatch(userID string, payload push.Payload) {
	if userID == "" {
		return
	}
	go func() {
		defer func() {
			if r := recover(); r != nil {
				s.app.Logger().Error("notify panic", "error", r)
			}
		}()
		s.deliver(userID, payload)
	}()
}

func (s *Service) deliver(userID string, payload push.Payload) {
	records, err := s.app.FindRecordsByFilter("device_tokens", "user = {:u}", "", 0, 0, dbx.Params{"u": userID})
	if err != nil {
		s.app.Logger().Error("notify device lookup failed", "user", userID, "error", err)
		return
	}
	devices := make([]registeredDevice, 0, len(records))
	byID := map[string]*core.Record{}
	for _, rec := range records {
		env := push.Production
		if rec.GetString("environment") == string(push.Sandbox) {
			env = push.Sandbox
		}
		devices = append(devices, registeredDevice{id: rec.Id, token: rec.GetString("token"), env: env})
		byID[rec.Id] = rec
	}

	for _, id := range sendToDevices(s.sender, devices, payload) {
		if rec := byID[id]; rec != nil {
			if delErr := s.app.Delete(rec); delErr != nil {
				s.app.Logger().Error("notify prune failed", "token", id, "error", delErr)
			}
		}
	}
}

func (s *Service) displayName(userID string) string {
	const fallback = "Someone"
	if userID == "" {
		return fallback
	}
	user, err := s.app.FindRecordById("users", userID)
	if err != nil {
		return fallback
	}
	if name := user.GetString("display_name"); name != "" {
		return name
	}
	return fallback
}

// Noop is the Notifier used when APNs is not configured. Every call is a no-op.
type Noop struct{}

func (Noop) TileCaptured(string, string, int) {}
func (Noop) NewFollower(string, string)       {}
func (Noop) FollowRequest(string, string)     {}
func (Noop) FollowAccepted(string, string)    {}
