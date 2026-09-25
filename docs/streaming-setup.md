# Streaming setup

GBear Mac uses a **native** LAN streaming host built into GBear.

- **No Sunshine / Moonlight / Homebrew / vendor clones**
- Control plane: HTTP port **28765**, protocol `gbear-stream/1`

## Docs

- Quick start: [`streaming-quickstart.md`](streaming-quickstart.md)
- Architecture: [`streaming-native.md`](streaming-native.md)
- Companion app: [`companion-flutter.md`](companion-flutter.md)

## macOS permission

Grant **Screen Recording** via the system prompt: Mac → Streaming → **Allow Screen Recording** (or start a stream from the phone once). macOS adds **GBear** to the list automatically — you should not need the manual **+** button.

Routine checks use `CGPreflightScreenCaptureAccess()` only (no dialog). The consent dialog appears only when you tap **Allow** or start video without permission yet.

After changing the toggle in System Settings, use **Restart streaming host**.
