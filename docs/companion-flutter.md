# Companion app (Flutter)

iOS and Android companion for pairing with GBear’s native stream host.

## Responsibilities

- **Settings** — Mac LAN IPv4 (`StreamingHostSettings`, port **28765** default)
- **Hosts** — `GBearHostClient.fetchStatus()` / discover
- **Pairing** — phone registers PIN; Mac confirms in Streaming tab
- **Session** — video start is stubbed until GBear transport ships
- **Controller** — gamepad mapping UI (applied when stream exists)

## Key Dart files

- `gbear_host_client.dart` — HTTP API client
- `streaming_bridge.dart` — `MethodChannel` for controllers + future native stream
- `streaming_host_settings.dart` — SharedPreferences
- `home_page.dart` — tab UI

## Native

- **Android / iOS** — Moonlight modules removed. `startStream` returns `stream_not_implemented`.
- **Controllers** — `listConnectedControllers` still works via platform APIs.

## Run

```bash
cd companion_app
flutter pub get
flutter run
```

iOS: `cd ios && pod install` after pod changes.

See [`streaming-quickstart.md`](streaming-quickstart.md).
