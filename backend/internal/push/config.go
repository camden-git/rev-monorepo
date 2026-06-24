package push

import (
	"crypto/ecdsa"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"os"
)

// Config holds the APNs token-based provider credentials. Everything is sourced
// from the environment so the key never lives in the repo.
type Config struct {
	// KeyID is the 10-char identifier of the APNs auth key (.p8).
	KeyID string
	// TeamID is the Apple developer team identifier.
	TeamID string
	// Topic is the app bundle id, sent as the apns-topic header.
	Topic string
	// PrivateKey is the ES256 signing key parsed from the .p8.
	PrivateKey *ecdsa.PrivateKey
}

// LoadConfig reads the APNs provider config from the environment. It returns a
// nil config (not an error) when nothing is set so the server runs fine without
// push configured. APNS_AUTH_KEY holds the .p8 PEM contents directly, or
// APNS_AUTH_KEY_PATH points at the file.
func LoadConfig() (*Config, error) {
	keyID := os.Getenv("APNS_KEY_ID")
	teamID := os.Getenv("APNS_TEAM_ID")
	topic := os.Getenv("APNS_BUNDLE_ID")
	keyPEM := os.Getenv("APNS_AUTH_KEY")
	keyPath := os.Getenv("APNS_AUTH_KEY_PATH")

	if keyID == "" && teamID == "" && topic == "" && keyPEM == "" && keyPath == "" {
		return nil, nil // push intentionally not configured
	}
	if keyID == "" || teamID == "" || topic == "" {
		return nil, errors.New("push: APNS_KEY_ID, APNS_TEAM_ID and APNS_BUNDLE_ID are all required")
	}

	pemBytes := []byte(keyPEM)
	if len(pemBytes) == 0 {
		if keyPath == "" {
			return nil, errors.New("push: set APNS_AUTH_KEY or APNS_AUTH_KEY_PATH")
		}
		data, err := os.ReadFile(keyPath)
		if err != nil {
			return nil, err
		}
		pemBytes = data
	}

	key, err := parseP8(pemBytes)
	if err != nil {
		return nil, err
	}
	return &Config{KeyID: keyID, TeamID: teamID, Topic: topic, PrivateKey: key}, nil
}

// parseP8 decodes an Apple .p8 PKCS#8 PEM into an ECDSA private key.
func parseP8(pemBytes []byte) (*ecdsa.PrivateKey, error) {
	block, _ := pem.Decode(pemBytes)
	if block == nil {
		return nil, errors.New("push: auth key is not valid PEM")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, err
	}
	key, ok := parsed.(*ecdsa.PrivateKey)
	if !ok {
		return nil, errors.New("push: auth key is not an ECDSA key")
	}
	return key, nil
}
