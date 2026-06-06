package migrations

import (
	"fmt"

	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

func init() {
	m.Register(enableInviteRateLimit, disableInviteRateLimit)
}

const inviteRateLimitLabel = "POST /api/rev/auth-with-invite"

func enableInviteRateLimit(app core.App) error {
	settings := app.Settings()
	settings.RateLimits.Enabled = true

	if !hasRateLimitRule(settings, inviteRateLimitLabel) {
		settings.RateLimits.Rules = append(settings.RateLimits.Rules, core.RateLimitRule{
			Label:       inviteRateLimitLabel,
			MaxRequests: 5,
			Duration:    60,
		})
	}

	if err := app.Save(settings); err != nil {
		return fmt.Errorf("save rate limit settings: %w", err)
	}
	return nil
}

func disableInviteRateLimit(app core.App) error {
	settings := app.Settings()

	filtered := settings.RateLimits.Rules[:0]
	for _, rule := range settings.RateLimits.Rules {
		if rule.Label != inviteRateLimitLabel {
			filtered = append(filtered, rule)
		}
	}
	settings.RateLimits.Rules = filtered
	settings.RateLimits.Enabled = false

	if err := app.Save(settings); err != nil {
		return fmt.Errorf("restore rate limit settings: %w", err)
	}
	return nil
}

func hasRateLimitRule(settings *core.Settings, label string) bool {
	for _, rule := range settings.RateLimits.Rules {
		if rule.Label == label {
			return true
		}
	}
	return false
}
