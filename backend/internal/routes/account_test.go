package routes

import (
	"testing"

	"github.com/pocketbase/pocketbase/core"
)

func TestDeleteAccountRejectsMissingAuth(t *testing.T) {
	// defensive guard behind RequireAuth: a request without an auth record must
	// not reach the deletion transaction
	err := deleteAccount(&core.RequestEvent{})
	if err == nil {
		t.Fatal("deleteAccount returned nil error for missing auth")
	}
}
