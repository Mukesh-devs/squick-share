#!/usr/bin/env bash
# Renders the app's UI to PNGs for the README and the documentation site (docs/images/).
#
# Builds the Debug app and runs it in snapshot mode (SQUICKSHARE_SNAPSHOT=1): it fills the UI with
# sample data, renders every screen in light and dark mode, and quits without touching the network.
# The app's preferences are backed up, replaced with neutral sample values (so no real device names
# appear), and restored exactly afterwards. A running copy of squick-share is not affected.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BUNDLE_ID="tech.mukesh.squick-share"
CONTAINER="$HOME/Library/Containers/$BUNDLE_ID/Data"
PREFS="$CONTAINER/Library/Preferences/$BUNDLE_ID.plist"
BACKUP_DIR="build/prefs-backup"
OUT="docs/images"

xcodebuild -project SquickShare.xcodeproj -scheme SquickShare -configuration Debug \
  -destination 'generic/platform=macOS' -derivedDataPath build/DerivedData build 2>&1 \
  | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true
APP="build/DerivedData/Build/Products/Debug/squick-share.app"
[[ -d "$APP" ]] || { echo "Debug build failed" >&2; exit 1; }

# Back up preferences (if any) and restore them on exit, whatever happens.
mkdir -p "$BACKUP_DIR" "$(dirname "$PREFS")"
HAD_PREFS=false
if [[ -f "$PREFS" ]]; then
  defaults export "$PREFS" "$BACKUP_DIR/prefs.plist"
  HAD_PREFS=true
fi
restore() {
  # Delete every key, then import the backup, so sample keys never survive.
  local keys
  keys=$(defaults export "$PREFS" - 2>/dev/null \
         | python3 -c 'import plistlib,sys; print("\n".join(plistlib.loads(sys.stdin.buffer.read()).keys()))' 2>/dev/null || true)
  while IFS= read -r key; do
    [[ -n "$key" ]] && defaults delete "$PREFS" "$key" 2>/dev/null || true
  done <<< "$keys"
  if $HAD_PREFS; then defaults import "$PREFS" "$BACKUP_DIR/prefs.plist"; fi
  echo "Preferences restored"
}
trap restore EXIT

# Neutral sample settings for the screenshots.
TRUSTED=$(printf '[{"name":"Pixel 9","type":1,"added":780000000},{"name":"Galaxy Tab S9","type":2,"added":781000000}]' | xxd -p | tr -d '\n')
defaults write "$PREFS" deviceName "MacBook Pro"
defaults write "$PREFS" trustedDevices -data "$TRUSTED"
defaults write "$PREFS" autoAcceptTrusted -bool true
defaults write "$PREFS" verboseLogging -bool true
defaults write "$PREFS" notificationsEnabled -bool true
defaults write "$PREFS" visibility everyone
defaults delete "$PREFS" downloadFolderBookmark 2>/dev/null || true

rm -rf "$CONTAINER/tmp/snapshots"
SQUICKSHARE_SNAPSHOT=1 "$APP/Contents/MacOS/squick-share" 2>/dev/null || true
[[ -d "$CONTAINER/tmp/snapshots" ]] || { echo "No snapshots were rendered" >&2; exit 1; }

mkdir -p "$OUT"
cp "$CONTAINER"/tmp/snapshots/*.png "$OUT/"
cp SquickShare/Assets.xcassets/AppIcon.appiconset/icon_256x256@2x.png "$OUT/app-icon.png"
echo "Screenshots written to $OUT/:"
ls -1 "$OUT"
