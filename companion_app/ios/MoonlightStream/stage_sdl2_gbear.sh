#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
MOONLIGHT_IOS="${MOONLIGHT_IOS:-$ROOT/Vendor/streaming-repos/moonlight-ios}"
OUT="$SCRIPT_DIR/Vendor/prebuilt"

strip_uikit_main() {
  local sdk_dir="$1"
  local src="$MOONLIGHT_IOS/libs/SDL2/lib/$sdk_dir/libSDL2.a"
  local work="$OUT/SDL2-$sdk_dir"
  local dest="$OUT/libSDL2-$sdk_dir.a"
  local thin="$OUT/SDL2-$sdk_dir-thin.a"

  rm -rf "$work" "$dest" "$thin"
  mkdir -p "$work"
  cp "$src" "$thin"
  if lipo -info "$thin" 2>/dev/null | grep -q "Architectures"; then
    lipo "$thin" -thin arm64 -output "$thin" 2>/dev/null || true
  fi
  (cd "$work" && ar -x "$thin")
  rm -f "$work"/SDL_uikit_main*.o
  libtool -static -o "$dest" "$work"/*.o
  rm -rf "$work"
}

mkdir -p "$OUT"
strip_uikit_main iOS
strip_uikit_main iOS-Sim
echo "Built GBear SDL2 libraries in $OUT"
