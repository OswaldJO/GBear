#!/usr/bin/env bash
# Reset GBear native streaming host data (pairing + legacy Sunshine folders).
#
# Usage:
#   ./Scripts/reset-streaming-state.sh
#   ./Scripts/reset-streaming-state.sh --derived-data
set -euo pipefail

DERIVED=0
[[ "${1:-}" == "--derived-data" ]] && DERIVED=1

echo "Stopping legacy Sunshine processes (if any)…"
pkill -f "MacOS/GBearSunshine" 2>/dev/null || true
pkill -f "/sunshine" 2>/dev/null || true
sleep 0.5

APP_SUPPORT="${HOME}/Library/Application Support/GBear"
if [[ -d "${APP_SUPPORT}" ]]; then
  rm -rf "${APP_SUPPORT}/sunshine" "${APP_SUPPORT}/Sunshine"
  rm -rf "${APP_SUPPORT}/gbear-stream" "${APP_SUPPORT}/playnite-stream"
  echo "Cleared GBear streaming data under Application Support"
fi

if [[ -d "${HOME}/.config/sunshine" ]]; then
  rm -f "${HOME}/.config/sunshine/sunshine.log" "${HOME}/.config/sunshine/sunshine_state.json" 2>/dev/null || true
  echo "Cleared legacy ~/.config/sunshine logs (optional)"
fi

if [[ "${DERIVED}" -eq 1 ]]; then
  removed=0
  for dir in "${HOME}/Library/Developer/Xcode/DerivedData"/GBear-*; do
    if [[ -d "${dir}" ]]; then
      rm -rf "${dir}"
      echo "Removed ${dir}"
      removed=1
    fi
  done
  if [[ "${removed}" -eq 0 ]]; then
    echo "No DerivedData folder matching GBear-*"
  fi
fi

cat <<'EOF'

Next steps:
  1. In Xcode: Product → Clean Build Folder (Shift+Cmd+K)
  2. Product → Run (Cmd+R) on GBear
  3. System Settings → Screen Recording → enable GBear
  4. Mac → Streaming → Restart streaming host
  5. Companion → Settings → Mac LAN IP → pair again

Control plane: HTTP port 28765 (gbear-stream/1)

EOF
