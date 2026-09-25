#!/usr/bin/env bash
# Archive the GBear companion app for iOS.
#
# Usage:
#   ./scripts/ios-archive.sh                  # App Store / TestFlight IPA
#   ./scripts/ios-archive.sh development      # Install on registered devices
#   ./scripts/ios-archive.sh archive-only     # .xcarchive only (open in Xcode Organizer)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

MODE="${1:-app-store}"

echo "==> flutter pub get"
flutter pub get

echo "==> pod install"
(cd ios && pod install)

case "$MODE" in
  archive-only)
    flutter build ipa --release --no-codesign
    echo ""
    echo "Archive (unsigned): build/ios/archive/Runner.xcarchive"
    echo "Open in Xcode: open build/ios/archive/Runner.xcarchive"
    ;;
  development)
    flutter build ipa --release --export-method development
    echo ""
    echo "Development IPA: build/ios/ipa/*.ipa"
  ;;
  app-store|*)
    flutter build ipa --release --export-method app-store
    echo ""
    echo "App Store IPA: build/ios/ipa/*.ipa"
    echo "Upload with Transporter or: xcrun altool --upload-app -f build/ios/ipa/*.ipa -t ios -u YOUR_APPLE_ID"
    ;;
esac
