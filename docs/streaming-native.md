# GBear native streaming

GBear implements its own LAN streaming stack. **Sunshine and Moonlight are not used.**

## Mac host (in-process)

| Component | Role |
|-----------|------|
| `GBearStreamHostManager` | Starts HTTP control server + capture readiness checks |
| `GBearStreamControlServer` | `gbear-stream/1` on port **28765** |
| `GBearScreenCapturePipeline` | ScreenCaptureKit permission probe (same app binary → one Screen Recording toggle) |

### HTTP API

- `GET /gbear/v1/status` — hostname, protocol, capture ready, ports, **`session`**, **`maxViewers`**
- `POST /gbear/v1/pair/request` — phone requests pairing (`deviceId`, `deviceName`)
- `GET /gbear/v1/pair/pending` — Mac polls pending requests
- `POST /gbear/v1/pair/approve` / `POST /gbear/v1/pair/deny` — Mac UI (`deviceId`)
- `GET /gbear/v1/pair/status?deviceId=` — phone polls `pending` | `paired` | `denied`
- `GET /gbear/v1/pair/clients` — paired device list
- **`POST /gbear/v1/session/create` | `join` | `join-local` | `host-player` | `leave` | `reassign` | `cursor-owner` | `end` — co-op seats (max 8; `clientKind` = `localHost` | `companion` | `computerGuest`; `playAsHost` claims Player 1 in place of the Mac)
- `POST /gbear/v1/stream/start` — join seat + start or **attach** to capture (paired device only)
- `POST /gbear/v1/stream/stop` — leave seat; stop capture when empty (`deviceId` recommended)

Paired devices persist under:

`~/Library/Application Support/GBear/gbear-stream/paired-devices.json`

### Pairing flow (no PIN)

1. Phone: **Discover** → **Pair** → `POST /pair/request`.
2. Mac: **Streaming** shows “{device} is trying to pair” → **Pair** or **Deny**.
3. Phone polls `/pair/status` until `paired`.

### Co-op (up to 8 players)

There are **8 pads**. This Mac uses one of them when it is playing, so **7 devices** can join. **8 devices** can join only when one of them **plays as the host** in place of this Mac (this Mac then leaves the pad list).

1. Host Mac is **Player 1** by default (local pad). On **Streaming**, **Host plays on** can point Player 1 at a paired companion instead — this Mac then leaves the slot, which is how an 8th device fits.
2. Phones pair on LAN (or join via remote session invite) and **Start Desktop stream**. Default is **join order** (Player 2, 3…). Optional slot override at join; companion **Play as the host** claims Player 1 in place of the Mac.
3. Another computer: Streaming → **Join another computer** (pair, then watch + send a local pad; join order unless a seat is picked).
4. After people have joined, Mac Streaming tab **Move to** swaps who is Player N without re-plugging (GBG1 `joinSeat` stays; host remaps).
5. Companion **Auto-map** fills GBG1 bindings; **Override** replaces one control.
6. Remote WAN: `services/gbear-session` still uses a 2-socket relay; 8-player mixes are LAN-first.

### Video (v1)

- Mac: ScreenCaptureKit → VideoToolbox H.264 → TCP port **28766** (`GBV1`), up to **8** clients.
- Phone: native full-screen player (`GBearVideoActivity` / `GBearVideoViewController`).

### Audio (v1)

- Mac: ScreenCaptureKit system audio → PCM s16le → UDP port **28767** (`GBA1` framed packets).
- Phone: sends `GBAS` subscribe, then plays PCM via `AudioTrack`.

### Touch input (v1)

- Phone: touch on video surface → UDP port **28768** (`GBI1` packets, normalized coordinates).
- Mac: `CGEvent` mouse move / click (requires **Accessibility** for GBear).

| Port | Protocol |
|------|----------|
| 28765 | HTTP control |
| 28766 | TCP video `GBV1` |
| 28767 | UDP audio `GBA1` / subscribe `GBAS` |
| 28768 | UDP input `GBI1` |

## Companion (Dart)

- `GBearHostClient` — HTTP client for the API above
- `StreamingBridge` — Flutter-facing facade
- Native **video decode** on iOS/Android is stubbed until a GBear transport ships.

## Roadmap

1. Gamepad input over GBear protocol (phone → Mac) — **done** (`GBG1` + Eden auto-map)
2. iOS audio + touch parity
3. Adaptive bitrate / resolution
4. mDNS discovery (no manual IP)

## Removed (do not re-add without explicit decision)

- `Vendor/streaming-repos/` clones
- `GBearSunshine` auxiliary binary
- Homebrew Sunshine
- Moonlight Android/iOS native modules in the companion app
