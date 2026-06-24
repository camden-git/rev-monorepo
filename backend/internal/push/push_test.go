package push

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"math/big"
	"strings"
	"testing"
	"time"
)

func testKey(t *testing.T) *ecdsa.PrivateKey {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	return key
}

func TestProviderTokenSignsVerifiableES256(t *testing.T) {
	key := testKey(t)
	cfg := &Config{KeyID: "ABC123DEFG", TeamID: "TEAM123456", Topic: "app.driverev.Rev", PrivateKey: key}
	pt := newProviderToken(cfg, func() time.Time { return time.Unix(1_700_000_000, 0) })

	token, err := pt.current()
	if err != nil {
		t.Fatalf("current: %v", err)
	}

	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		t.Fatalf("expected 3 jwt segments, got %d", len(parts))
	}

	// header carries the key id and ES256 alg
	headerJSON, _ := base64.RawURLEncoding.DecodeString(parts[0])
	var header map[string]string
	if err := json.Unmarshal(headerJSON, &header); err != nil {
		t.Fatalf("header decode: %v", err)
	}
	if header["alg"] != "ES256" || header["kid"] != "ABC123DEFG" {
		t.Fatalf("unexpected header %v", header)
	}

	// claims carry the team id as issuer
	claimsJSON, _ := base64.RawURLEncoding.DecodeString(parts[1])
	var claims map[string]any
	if err := json.Unmarshal(claimsJSON, &claims); err != nil {
		t.Fatalf("claims decode: %v", err)
	}
	if claims["iss"] != "TEAM123456" {
		t.Fatalf("unexpected iss %v", claims["iss"])
	}

	// the signature verifies against the public key
	sig, _ := base64.RawURLEncoding.DecodeString(parts[2])
	if len(sig) != 64 {
		t.Fatalf("expected 64-byte raw signature, got %d", len(sig))
	}
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	r := new(big.Int).SetBytes(sig[:32])
	s := new(big.Int).SetBytes(sig[32:])
	if !ecdsa.Verify(&key.PublicKey, digest[:], r, s) {
		t.Fatal("signature did not verify")
	}
}

func TestProviderTokenCachesUntilRefresh(t *testing.T) {
	cfg := &Config{KeyID: "K", TeamID: "T", Topic: "app", PrivateKey: testKey(t)}
	current := time.Unix(1_700_000_000, 0)
	pt := newProviderToken(cfg, func() time.Time { return current })

	first, _ := pt.current()
	current = current.Add(10 * time.Minute)
	second, _ := pt.current()
	if first != second {
		t.Fatal("expected cached token within refresh window")
	}

	current = current.Add(55 * time.Minute)
	third, _ := pt.current()
	if third == second {
		t.Fatal("expected a fresh token past the refresh window")
	}
}

func TestPayloadEncode(t *testing.T) {
	badge := 3
	p := Payload{
		Title:    "Under attack",
		Body:     "Dev took 2 of your tiles",
		ThreadID: "tiles",
		Category: "TILE_CAPTURED",
		Badge:    &badge,
		Data:     map[string]any{"type": "tile_captured", "aps": "ignored"},
	}
	raw, err := p.encode()
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	var decoded map[string]any
	if err := json.Unmarshal(raw, &decoded); err != nil {
		t.Fatalf("decode: %v", err)
	}

	aps, ok := decoded["aps"].(map[string]any)
	if !ok {
		t.Fatalf("missing aps: %v", decoded)
	}
	alert := aps["alert"].(map[string]any)
	if alert["title"] != "Under attack" || alert["body"] != "Dev took 2 of your tiles" {
		t.Fatalf("unexpected alert %v", alert)
	}
	if aps["sound"] != "default" {
		t.Fatalf("expected default sound, got %v", aps["sound"])
	}
	if aps["badge"].(float64) != 3 {
		t.Fatalf("unexpected badge %v", aps["badge"])
	}
	if aps["thread-id"] != "tiles" || aps["category"] != "TILE_CAPTURED" {
		t.Fatalf("unexpected aps %v", aps)
	}
	if decoded["type"] != "tile_captured" {
		t.Fatalf("custom data not merged: %v", decoded)
	}
	// custom data must never overwrite the reserved aps key
	if _, isString := decoded["aps"].(string); isString {
		t.Fatal("custom aps key clobbered the reserved payload")
	}
}

func TestIsTokenInvalid(t *testing.T) {
	cases := []struct {
		status int
		reason string
		want   bool
	}{
		{410, "Unregistered", true},
		{400, "BadDeviceToken", true},
		{400, "DeviceTokenNotForTopic", true},
		{400, "PayloadTooLarge", false},
		{200, "", false},
		{429, "TooManyRequests", false},
	}
	for _, c := range cases {
		if got := isTokenInvalid(c.status, c.reason); got != c.want {
			t.Fatalf("isTokenInvalid(%d,%q)=%v want %v", c.status, c.reason, got, c.want)
		}
	}
}

func TestLoadConfigUnsetIsNoError(t *testing.T) {
	for _, k := range []string{"APNS_KEY_ID", "APNS_TEAM_ID", "APNS_BUNDLE_ID", "APNS_AUTH_KEY", "APNS_AUTH_KEY_PATH"} {
		t.Setenv(k, "")
	}
	cfg, err := LoadConfig()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg != nil {
		t.Fatalf("expected nil config when unconfigured, got %v", cfg)
	}
}
