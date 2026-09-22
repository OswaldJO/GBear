# GBear session coordinator

Small Node service for **session tunnel** auth, invites, ICE signaling, TURN credentials, and a TCP/WebSocket **relay** (DERP-like) when direct connectivity fails.

## Run locally

```bash
cd services/gbear-session
npm install
GBEAR_DEV_AUTH=1 npm start
# listens on :8787
```

## Environment

| Variable | Purpose |
|----------|---------|
| `PORT` | HTTP/WS port (default `8787`) |
| `GBEAR_GOOGLE_CLIENT_ID` | Google OAuth client ID for ID token verify |
| `GBEAR_DEV_AUTH=1` | Accept `Bearer dev:you@gmail.com` without Google |
| `GBEAR_TURN_HOST` | coturn hostname |
| `GBEAR_TURN_SECRET` | coturn REST shared secret |
| `GBEAR_TURN_TTL` | Credential TTL seconds |
| `GBEAR_INVITE_TTL_MS` | Invite lifetime (default 30 min) |

## API sketch

- `POST /v1/auth/register-device` — register Mac/phone under Google account
- `POST /v1/session/create` — host creates session
- `POST /v1/session/invite` — owner mint invite code
- `POST /v1/session/redeem-invite` — friend joins as seat 2
- `POST /v1/session/join` — own-account device joins without invite
- `POST /v1/signal` / `GET /v1/signal/poll` — SDP/ICE mailbox
- `POST /v1/turn/credentials` — STUN (+ TURN if configured)
- `WS /v1/ws?deviceId=&sessionId=&mode=signal|relay` — live signaling or byte relay

Owner devices under the same Google email join without an invite. Friends need a short-lived invite code.
