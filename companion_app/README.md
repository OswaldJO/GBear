# GBear companion app

Flutter app (iOS + Android) for LAN pairing with Mac Game Library’s native stream host.

## Setup

```bash
flutter pub get
flutter run
```

**Settings:** enter the Mac’s LAN IPv4 from Mac → Streaming (port **28765** is automatic).

**Pairing:** phone starts pairing first; Mac confirms the same PIN in Streaming.

**Video:** not wired yet — pairing and discovery work over `gbear-stream/1`.

## iOS

```bash
cd ios && pod install && cd ..
flutter run
```

Moonlight pods were removed; only Flutter + GameController remain.

### Physical iPhone / iPad (blank white screen + `flutter run` stuck)

On **real devices** running **iOS 18.4 or newer**, Apple blocks the JIT that Flutter **debug** builds need. The app can install but shows a **white screen**, crash in `Dart_Initialize`, and the terminal sits on **“Installing and launching…”** / **“Dart VM Service was not discovered”** because the engine never starts.

**Fix — use profile (or release) mode on the device:**

```bash
flutter run --profile
# or
./scripts/run-ios-device.sh
```

- **Simulator** and **Android** can still use plain `flutter run` (debug + hot reload).
- Profile mode has no hot reload; stop and re-run after code changes.
- If profile still fails, try `flutter upgrade` (newer Flutter adds debug fallbacks on recent iOS), then `flutter clean && flutter pub get`.

**Settings on device:** Mac **LAN IP** only (e.g. `192.168.1.14`), not `127.0.0.1`.

### Archive for TestFlight / App Store

Prerequisites:

1. **Apple Developer Program** membership (team `AFYV687T82` is already set in Xcode).
2. **Free disk space** — keep at least ~5 GB free; Xcode archives fail when the disk is full.
3. **Bundle ID** `com.funnybearapps.gbearcompanion` registered in [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list) and an app record in App Store Connect with the same ID.

From the repo:

```bash
cd companion_app
./scripts/ios-archive.sh              # App Store / TestFlight IPA
./scripts/ios-archive.sh development  # Install on your registered devices
```

Or manually:

```bash
flutter pub get
cd ios && pod install && cd ..
flutter build ipa --release --export-method app-store   # TestFlight
flutter build ipa --release --export-method development # sideload to device
```

**Xcode (Organizer):**

```bash
open ios/Runner.xcworkspace
```

1. Select **Any iOS Device (arm64)** as the run destination.
2. **Product → Archive**.
3. When the Organizer opens: **Distribute App** → App Store Connect (or Development).

Outputs:

| Artifact | Path |
|----------|------|
| Archive | `build/ios/archive/Runner.xcarchive` |
| IPA | `build/ios/ipa/*.ipa` |

**Note:** Flutter iOS plugin integration uses CocoaPods here (`flutter config --no-enable-swift-package-manager`) because SPM resolution for `file_picker` was failing on this machine. The Podfile sets `Pod::PICKER_MEDIA = false` and `Pod::PICKER_AUDIO = false` so only document picking is linked (JSON controller profiles) — avoiding ITMS-90683 photo-library purpose-string rejection.

## Android

No NDK / Moonlight module. `startStream` returns a clear “not implemented” error until native decode lands.
