#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MOONLIGHT_IOS="${MOONLIGHT_IOS:-$ROOT/Vendor/streaming-repos/moonlight-ios}"
COMMON_XCODEPROJ="$MOONLIGHT_IOS/moonlight-common/moonlight-common.xcodeproj"
DERIVED="${GBEAR_MOONLIGHT_DERIVED:-$HOME/.cache/gbear-moonlight-ios/DerivedData}"
OUT_DIR="${GBEAR_MOONLIGHT_VENDOR:-$ROOT/companion_app/ios/MoonlightStream/Vendor}"

if [[ ! -d "$COMMON_XCODEPROJ" ]]; then
  echo "moonlight-common.xcodeproj not found. Run Scripts/clone-streaming-forks.sh first." >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

build_one() {
  local sdk="$1"
  xcodebuild \
    -project "$COMMON_XCODEPROJ" \
    -scheme moonlight-common \
    -configuration Release \
    -sdk "$sdk" \
    -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO \
    ONLY_ACTIVE_ARCH=NO \
    build >/dev/null
}

build_one iphoneos
build_one iphonesimulator

DEVICE_LIB="$DERIVED/Build/Products/Release-iphoneos/libmoonlight-common.a"
SIM_LIB="$DERIVED/Build/Products/Release-iphonesimulator/libmoonlight-common.a"

if [[ ! -f "$DEVICE_LIB" || ! -f "$SIM_LIB" ]]; then
  echo "Expected moonlight-common static libraries were not produced." >&2
  exit 1
fi

XCFRAMEWORK="$OUT_DIR/moonlight-common.xcframework"
rm -rf "$XCFRAMEWORK"
xcodebuild -create-xcframework \
  -library "$DEVICE_LIB" \
  -library "$SIM_LIB" \
  -output "$XCFRAMEWORK"

echo "Built $XCFRAMEWORK"
