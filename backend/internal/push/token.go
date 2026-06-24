package push

import (
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"sync"
	"time"
)

// providerToken signs and caches the short-lived JWT Apple wants in the
// Authorization header. Apple rejects tokens older than 1h and asks providers
// not to mint a new one more than once every 20 min, so it is refreshed on a
// fixed interval well inside that window.
type providerToken struct {
	keyID  string
	teamID string
	key    *ecdsa.PrivateKey
	now    func() time.Time

	mu        sync.Mutex
	cached    string
	issuedAt  time.Time
	refreshAt time.Duration
}

func newProviderToken(cfg *Config, now func() time.Time) *providerToken {
	if now == nil {
		now = time.Now
	}
	return &providerToken{
		keyID:     cfg.KeyID,
		teamID:    cfg.TeamID,
		key:       cfg.PrivateKey,
		now:       now,
		refreshAt: 50 * time.Minute,
	}
}

// current returns a valid signed token, reusing the cached one until it nears
// expiry.
func (p *providerToken) current() (string, error) {
	p.mu.Lock()
	defer p.mu.Unlock()

	now := p.now()
	if p.cached != "" && now.Sub(p.issuedAt) < p.refreshAt {
		return p.cached, nil
	}
	token, err := p.sign(now)
	if err != nil {
		return "", err
	}
	p.cached = token
	p.issuedAt = now
	return token, nil
}

func (p *providerToken) sign(now time.Time) (string, error) {
	header := map[string]string{"alg": "ES256", "kid": p.keyID, "typ": "JWT"}
	claims := map[string]any{"iss": p.teamID, "iat": now.Unix()}

	headerJSON, err := json.Marshal(header)
	if err != nil {
		return "", err
	}
	claimsJSON, err := json.Marshal(claims)
	if err != nil {
		return "", err
	}

	signingInput := base64URL(headerJSON) + "." + base64URL(claimsJSON)
	digest := sha256.Sum256([]byte(signingInput))
	r, s, err := ecdsa.Sign(rand.Reader, p.key, digest[:])
	if err != nil {
		return "", err
	}
	// JWS wants the raw R||S pair, each left-padded to the curve size (32 bytes
	// for P-256), not the ASN.1 DER encoding ecdsa.Sign would otherwise imply.
	keyBytes := (p.key.Curve.Params().BitSize + 7) / 8
	sig := make([]byte, 2*keyBytes)
	r.FillBytes(sig[:keyBytes])
	s.FillBytes(sig[keyBytes:])
	return signingInput + "." + base64URL(sig), nil
}

func base64URL(b []byte) string {
	return base64.RawURLEncoding.EncodeToString(b)
}
