package push

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"time"
)

const (
	hostProduction = "https://api.push.apple.com"
	hostSandbox    = "https://api.sandbox.push.apple.com"
)

// Result reports the outcome of a single send.
type Result struct {
	Status int
	Reason string
	// TokenInvalid is true when APNs rejected the device token permanently
	// (unregistered or malformed). The caller should delete the token.
	TokenInvalid bool
}

// Sender delivers a payload to one device token.
type Sender interface {
	Send(ctx context.Context, deviceToken string, env Environment, p Payload) (Result, error)
}

// Client is the live APNs HTTP/2 sender.
type Client struct {
	cfg   *Config
	token *providerToken
	http  *http.Client
}

// New builds a live APNs client. The default transport negotiates HTTP/2 over
// ALPN, which APNs requires.
func New(cfg *Config) *Client {
	return &Client{
		cfg:   cfg,
		token: newProviderToken(cfg, time.Now),
		http:  &http.Client{Timeout: 30 * time.Second},
	}
}

func (c *Client) Send(ctx context.Context, deviceToken string, env Environment, p Payload) (Result, error) {
	body, err := p.encode()
	if err != nil {
		return Result{}, err
	}
	jwt, err := c.token.current()
	if err != nil {
		return Result{}, err
	}

	host := hostProduction
	if env == Sandbox {
		host = hostSandbox
	}
	url := fmt.Sprintf("%s/3/device/%s", host, deviceToken)

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return Result{}, err
	}
	req.Header.Set("authorization", "bearer "+jwt)
	req.Header.Set("apns-topic", c.cfg.Topic)
	req.Header.Set("apns-push-type", "alert")
	req.Header.Set("apns-priority", "10")

	resp, err := c.http.Do(req)
	if err != nil {
		return Result{}, err
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusOK {
		return Result{Status: resp.StatusCode}, nil
	}

	reason := decodeReason(resp)
	return Result{
		Status:       resp.StatusCode,
		Reason:       reason,
		TokenInvalid: isTokenInvalid(resp.StatusCode, reason),
	}, nil
}

// decodeReason pulls Apple's {"reason": "..."} error code out of the response.
func decodeReason(resp *http.Response) string {
	var payload struct {
		Reason string `json:"reason"`
	}
	_ = json.NewDecoder(resp.Body).Decode(&payload)
	return payload.Reason
}

// isTokenInvalid reports whether the failure means the token should be dropped.
func isTokenInvalid(status int, reason string) bool {
	if status == http.StatusGone { // 410 Unregistered
		return true
	}
	switch reason {
	case "BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic":
		return true
	}
	return false
}
