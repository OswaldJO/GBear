# Streaming quickstart (GBear native)

## Mac

1. Run **GBear** in Xcode (⌘R).
2. **Streaming** → grant Screen Recording for **GBear** → **Restart streaming host**.
3. Note **LAN IP** and keep this tab open for pairing approvals.

## Companion

```bash
cd companion_app
flutter pub get
flutter run
```

1. **Settings** → Mac LAN IP → save.
2. **Hosts** → **Discover** → **Pair** on your Mac.
3. On Mac **Streaming** → **Pairing requests** → **Pair** (or **Deny**).
4. **Session** → **Start Desktop 1080p60** when status shows Paired.

## Ports

| Port | Use |
|------|-----|
| 28765 | HTTP control (`gbear-stream/1`) |
| 28766 | H.264 video (`GBV1` framed TCP) |

## Reset

```bash
./Scripts/reset-streaming-state.sh
```
