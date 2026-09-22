# Playnite native streaming

GBear implements its own LAN streaming stack. **Sunshine and Moonlight are not used.**

## Mac host (in-process)

| Component | Role |
|-----------|------|
| `PlayniteStreamHostManager` | Starts HTTP control server + capture readiness checks |
| `PlayniteStreamControlServer` | `playnite-stream/1` on port **28765** |
| `PlayniteScreenCapturePipeline` | ScreenCaptureKit permission probe (same app binary → one Screen Recording toggle) |

### HTTP API

- `GET /playnite/v1/status` — hostname, protocol, capture ready, ports, **`session`**, **`maxViewers`**
- `POST /playnite/v1/pair/request` — phone requests pairing (`deviceId`, `deviceName`)
- `GET /playnite/v1/pair/pending` — Mac polls pending requests
- `POST /playnite/v1/pair/approve` / `POST /playnite/v1/pair/deny` — Mac UI (`deviceId`)
- `GET /playnite/v1/pair/status?deviceId=` — phone polls `pending` | `paired` | `denied`
- `GET /playnite/v1/pair/clients` — paired device list
- `POST /playnite/v1/session/create` | `join` | `leave` | `reassign` | `cursor-owner` | `end` — co-op seats (max 2)
- `POST /playnite/v1/stream/start` — join seat + start or **attach** to capture (paired device only)
- `POST /playnite/v1/stream/stop` — leave seat; stop capture when empty (`deviceId` recommended)

Paired devices persist under:

`~/Library/Application Support/GBear/playnite-stream/paired-devices.json`

### Pairing flow (no PIN)

1. Phone: **Discover** → **Pair** → `POST /pair/request`.
2. Mac: **Streaming** shows “{device} is trying to pair” → **Pair** or **Deny**.
3. Phone polls `/pair/status` until `paired`.

### Co-op (2 players)

1. Both phones pair on LAN (or join via remote session invite).
2. Each **Start Desktop stream** — first starts capture; second **attaches** (same encode).
3. Seats **P1 / P2** shown on Mac Streaming tab; **Co-op pad mode** sends **`PNG1`** → Mac virtual HID pads.
4. Remote: run `services/gbear-session` (`GBEAR_DEV_AUTH=1 npm start`); Mac mints invite; friend redeems in companion Settings.

### Video (v1)

- Mac: ScreenCaptureKit → VideoToolbox H.264 → TCP port **28766** (`PNV1`), up to **2** clients.
- Phone: native full-screen player (`PlayniteVideoActivity` / `PlayniteVideoViewController`).

### Audio (v1)

- Mac: ScreenCaptureKit system audio → PCM s16le → UDP port **28767** (`PNA1` framed packets).
- Phone: sends `PNAS` subscribe, then plays PCM via `AudioTrack`.

### Touch input (v1)

- Phone: touch on video surface → UDP port **28768** (`PNI1` packets, normalized coordinates).
- Mac: `CGEvent` mouse move / click (requires **Accessibility** for GBear).

| Port | Protocol |
|------|----------|
| 28765 | HTTP control |
| 28766 | TCP video `PNV1` |
| 28767 | UDP audio `PNA1` / subscribe `PNAS` |
| 28768 | UDP input `PNI1` |

## Companion (Dart)

- `PlayniteHostClient` — HTTP client for the API above
- `StreamingBridge` — Flutter-facing facade
- Native **video decode** on iOS/Android is stubbed until a Playnite transport ships.

## Roadmap

1. Gamepad input over Playnite protocol (phone → Mac)
2. iOS audio + touch parity
3. Adaptive bitrate / resolution
4. mDNS discovery (no manual IP)

## Removed (do not re-add without explicit decision)

- `Vendor/streaming-repos/` clones
- `PlayniteSunshine` auxiliary binary
- Homebrew Sunshine
- Moonlight Android/iOS native modules in the companion app
