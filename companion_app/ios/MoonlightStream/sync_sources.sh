#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
MOONLIGHT_IOS="${MOONLIGHT_IOS:-$ROOT/Vendor/streaming-repos/moonlight-ios}"
CACHE="${GBEAR_MOONLIGHT_SOURCES_CACHE:-$HOME/.cache/gbear-moonlight-ios/sources}"
DEST="$SCRIPT_DIR/Sources"

if [[ ! -d "$MOONLIGHT_IOS/Limelight" ]]; then
  echo "Missing $MOONLIGHT_IOS/Limelight — run Scripts/clone-streaming-forks.sh first." >&2
  exit 1
fi

mkdir -p "$CACHE"

rsync -a --delete \
  --exclude AppDelegate.m \
  --exclude main.m \
  --exclude MainFrameViewController.m \
  --exclude LoadingFrameViewController.m \
  --exclude SettingsViewController.m \
  --exclude SWRevealViewController.m \
  --exclude DiscoveryManager.m \
  --exclude DiscoveryWorker.m \
  --exclude MDNSManager.m \
  --exclude UIAppView.m \
  --exclude UIComputerView.m \
  --exclude ComputerScrollView.m \
  --exclude AppCollectionView.m \
  --exclude PairManager.m \
  --exclude AppAssetManager.m \
  --exclude AppAssetRetriever.m \
  --exclude DataManager.m \
  --exclude DataManager.h \
  --exclude TemporaryHost.m \
  --exclude TemporaryApp.m \
  --exclude TemporaryApp.h \
  --exclude TemporarySettings.m \
  --exclude TemporarySettings.h \
  --exclude AppAssetManager.h \
  --exclude AppAssetManager.m \
  --exclude AppAssetRetriever.h \
  --exclude AppAssetRetriever.m \
  --exclude AppAssetResponse.m \
  --exclude UIAppView.h \
  --exclude UIAppView.m \
  --exclude UIComputerView.h \
  --exclude UIComputerView.m \
  --exclude WakeOnLanManager.m \
  --exclude AppListResponse.m \
  --exclude ConnectionHelper.m \
  --exclude IdManager.m \
  --exclude TemporaryHost.h \
  --exclude '*.xcdatamodeld' \
  "$MOONLIGHT_IOS/Limelight/" "$CACHE/Limelight/"

cp "$SCRIPT_DIR/GBearSupport/GBearTemporaryHost.h" "$CACHE/Limelight/Database/TemporaryHost.h"
cp "$SCRIPT_DIR/GBearSupport/GBearTemporaryHost.m" "$CACHE/Limelight/Database/TemporaryHost.m"

COMMON_SRC="$MOONLIGHT_IOS/moonlight-common/moonlight-common-c/src"
mkdir -p "$CACHE/moonlight-common-c"
rsync -a --delete "$COMMON_SRC/" "$CACHE/moonlight-common-c/"

python3 "$SCRIPT_DIR/patch_moonlight_sources.py" "$CACHE/Limelight"

rm -rf "$DEST"
mkdir -p "$DEST"
rsync -a "$CACHE/Limelight/" "$DEST/Limelight/"
rsync -a "$CACHE/moonlight-common-c/" "$DEST/moonlight-common-c/"

echo "Synced patched Moonlight sources to $DEST"
