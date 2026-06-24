# Rev Backend

built with PocketBase!

## Layout

```
backend/
  cmd/api/main.go            # entrypoint
  migrations/                # Go collection startup migrations
  internal/game/             # ported logic (Decay, Claim, Enclosure, tilesCrossed) + tests
  internal/h3util/           # uber/h3-go wrappers in uint64 cell-id space
  internal/hooks/            # OnRecordAfterCreateSuccess("drives") resolution hook
  internal/push/             # APNs HTTP/2 sender (token-based auth)
  internal/notify/           # turns game/social events into device pushes
  internal/routes/           # custom routes
  deploy/                    # Caddyfile / systemd (todo)
```

## Push notifications (APNs)

Push is optional: with none of the variables below set the server logs
`push not configured` and runs normally. Set all of them to enable it.

| env var | meaning |
| --- | --- |
| `APNS_KEY_ID` | the 10-char key id of the APNs auth key (.p8) |
| `APNS_TEAM_ID` | Apple developer team id |
| `APNS_BUNDLE_ID` | app bundle id, sent as `apns-topic` (e.g. `app.driverev.Rev`) |
| `APNS_AUTH_KEY` | the .p8 PEM contents, or set `APNS_AUTH_KEY_PATH` to a file |

Token-based auth is used (one ES256 JWT signed from the .p8, cached ~50min), so
no certificates and no per-environment keys. The same key works for sandbox and
production; each registered device records which host its token is valid against
(dev builds -> sandbox, TestFlight/App Store -> production) and the server picks
the matching APNs endpoint. Tokens APNs reports as `410 Unregistered` /
`BadDeviceToken` are pruned automatically.

Setup once on the Apple side: enable the Push Notifications capability on the App
ID and create an APNs auth key (Keys -> APNs) in the developer portal. On the
client the `aps-environment` entitlement plus automatic signing handle the
dev/prod split (Xcode bumps it to `production` for distribution archives).
