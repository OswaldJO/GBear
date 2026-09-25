#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
MOONLIGHT_IOS="${MOONLIGHT_IOS:-$ROOT/Vendor/streaming-repos/moonlight-ios}"
OUT="$SCRIPT_DIR/Vendor/prebuilt"

mkdir -p "$OUT"

copy_lib() {
  local name="$1"
  local folder="$2"
  local filename="$3"
  local sdk_dir="$4"
  cp "$MOONLIGHT_IOS/libs/$folder/lib/$sdk_dir/$filename" "$OUT/lib${name}-${sdk_dir}.a"
}

for sdk in iOS iOS-Sim; do
  copy_lib opus opus libopus.a "$sdk"
  copy_lib avcodec FFmpeg libavcodec.a "$sdk"
  copy_lib avformat FFmpeg libavformat.a "$sdk"
  copy_lib avutil FFmpeg libavutil.a "$sdk"
done

bash "$SCRIPT_DIR/stage_sdl2_gbear.sh"
echo "Staged Moonlight prebuilt libraries in $OUT"
