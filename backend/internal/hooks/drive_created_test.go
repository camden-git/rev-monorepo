package hooks

import (
	"testing"

	"github.com/pocketbase/pocketbase/core"
)

func TestStampDriveOwnerUsesAuthenticatedUser(t *testing.T) {
	users := core.NewAuthCollection("users")
	auth := core.NewRecord(users)
	auth.Id = "user_auth_123"

	drives := core.NewBaseCollection("drives")
	drive := core.NewRecord(drives)
	drive.Set("user", "client_supplied_wrong_user")

	err := stampDriveOwner(&core.RecordRequestEvent{
		RequestEvent: &core.RequestEvent{Auth: auth},
		Record:       drive,
	})
	if err != nil {
		t.Fatalf("stampDriveOwner returned error: %v", err)
	}
	if got := drive.GetString("user"); got != auth.Id {
		t.Fatalf("drive user = %q, want %q", got, auth.Id)
	}
}

func TestStampDriveOwnerRejectsMissingAuth(t *testing.T) {
	drives := core.NewBaseCollection("drives")
	drive := core.NewRecord(drives)

	err := stampDriveOwner(&core.RecordRequestEvent{
		RequestEvent: &core.RequestEvent{},
		Record:       drive,
	})
	if err == nil {
		t.Fatal("stampDriveOwner returned nil error for missing auth")
	}
	if got := drive.GetString("user"); got != "" {
		t.Fatalf("drive user = %q, want empty", got)
	}
}
