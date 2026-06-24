package notify

import (
	"context"
	"sync"
	"testing"

	"github.com/camden-git/rev-monorepo/backend/internal/push"
)

// fakeSender records the tokens it was asked to push and can mark some invalid.
type fakeSender struct {
	mu      sync.Mutex
	sent    []string
	invalid map[string]bool
	err     map[string]error
}

func (f *fakeSender) Send(_ context.Context, token string, _ push.Environment, _ push.Payload) (push.Result, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.sent = append(f.sent, token)
	if err := f.err[token]; err != nil {
		return push.Result{}, err
	}
	return push.Result{TokenInvalid: f.invalid[token]}, nil
}

func TestSendToDevicesPrunesOnlyDeadTokens(t *testing.T) {
	sender := &fakeSender{
		invalid: map[string]bool{"dead": true},
		err:     map[string]error{"erroring": context.Canceled},
	}
	devices := []registeredDevice{
		{id: "rec_live", token: "live", env: push.Production},
		{id: "rec_dead", token: "dead", env: push.Sandbox},
		{id: "rec_err", token: "erroring", env: push.Production},
	}

	prune := sendToDevices(sender, devices, push.Payload{Title: "hi"})

	if len(sender.sent) != 3 {
		t.Fatalf("expected all 3 devices attempted, got %v", sender.sent)
	}
	if len(prune) != 1 || prune[0] != "rec_dead" {
		t.Fatalf("expected only the dead token pruned, got %v", prune)
	}
}

func TestTileCapturedPayloadPluralizes(t *testing.T) {
	one := tileCapturedPayload("Dev", "att1", 1)
	if one.Body != "Dev captured one of your tiles" {
		t.Fatalf("singular body wrong: %q", one.Body)
	}
	many := tileCapturedPayload("Dev", "att1", 4)
	if many.Body != "Dev captured 4 of your tiles" {
		t.Fatalf("plural body wrong: %q", many.Body)
	}
	if many.Data["type"] != "tile_captured" || many.Data["attacker_id"] != "att1" {
		t.Fatalf("routing data wrong: %v", many.Data)
	}
	if many.Category != "TILE_CAPTURED" || many.ThreadID != "tiles" {
		t.Fatalf("unexpected category/thread: %q %q", many.Category, many.ThreadID)
	}
}

func TestSocialPayloads(t *testing.T) {
	follower := newFollowerPayload("Ada", "u1")
	if follower.Body != "Ada started following you" || follower.Data["type"] != "new_follower" {
		t.Fatalf("new follower payload wrong: %+v", follower)
	}
	request := followRequestPayload("Ada", "u1")
	if request.Body != "Ada wants to follow you" || request.Data["type"] != "follow_request" {
		t.Fatalf("follow request payload wrong: %+v", request)
	}
	accepted := followAcceptedPayload("Grace", "u2")
	if accepted.Body != "Grace accepted your follow request" || accepted.Data["type"] != "follow_accepted" {
		t.Fatalf("follow accepted payload wrong: %+v", accepted)
	}
}

// the no-op notifier must never panic or touch a sender
func TestNoopIsInert(t *testing.T) {
	var n Notifier = Noop{}
	n.TileCaptured("a", "b", 3)
	n.NewFollower("a", "b")
	n.FollowRequest("a", "b")
	n.FollowAccepted("a", "b")
}
