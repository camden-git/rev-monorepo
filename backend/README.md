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
  internal/push/             # APNs (stub, post-MVP)
  internal/routes/           # custom routes
  deploy/                    # Caddyfile / systemd (todo)
```
