#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
MOONLIGHT_IOS="${MOONLIGHT_IOS:-$ROOT/Vendor/streaming-repos/moonlight-ios}"
OUT="$SCRIPT_DIR/Vendor/prebuilt"
SRC="$SCRIPT_DIR/GBearSupport/GBearFFmpegAv1Stub.c"

FFMPEG_INCLUDE="$MOONLIGHT_IOS/libs/FFmpeg/include"
SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"

mkdir -p "$OUT"

build_stub() {
  local sdk="$1"
  local arch="$2"
  local out_name="$3"
  local obj="$OUT/stub-${sdk}.o"

  xcrun clang -c "$SRC" -o "$obj" \
    -isysroot "$SDK_PATH" \
    -arch "$arch" \
    -mios-version-min=12.0 \
    -I"$FFMPEG_INCLUDE" \
    -fembed-bitcode-marker 2>/dev/null || \
  xcrun clang -c "$SRC" -o "$obj" \
    -isysroot "$(xcrun --sdk "$sdk" --show-sdk-path)" \
    -arch "$arch" \
    -mios-version-min=12.0 \
    -I"$FFMPEG_INCLUDE"

  libtool -static -o "$OUT/$out_name" "$obj"
  rm -f "$obj"
}

build_stub iphoneos arm64 libgbear-ffmpeg-stubs-iOS.a
build_stub iphonesimulator arm64 libgbear-ffmpeg-stubs-iOS-Sim.a

echo "Built FFmpeg stub libraries in $OUT"
