#!/usr/bin/env bash
# Packages each built variant into a drag-to-Applications disk image:
#   build/release/squick-share-<version>-<arch>.dmg   (<arch> = universal, arm64 or x86_64)
#
# Usage:
#   ./scripts/make-dmg.sh                every variant in build/release/<arch>/
#   ./scripts/make-dmg.sh arm64 x86_64   only these variants
#
# Run ./scripts/build-release.sh first. Uses only hdiutil, which ships with macOS.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT="build/release"

VARIANTS=("$@")
if [[ ${#VARIANTS[@]} -eq 0 ]]; then
  for variant in universal arm64 x86_64; do
    [[ -d "$OUT/$variant/squick-share.app" ]] && VARIANTS+=("$variant")
  done
fi
[[ ${#VARIANTS[@]} -gt 0 ]] || { echo "Nothing to package. Run ./scripts/build-release.sh first." >&2; exit 1; }

for variant in "${VARIANTS[@]}"; do
  APP="$OUT/$variant/squick-share.app"
  [[ -d "$APP" ]] || { echo "No $APP. Run ./scripts/build-release.sh --arch $variant first." >&2; exit 1; }
  VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
  STAGE="build/dmg-stage-$variant"
  DMG="$OUT/squick-share-$VERSION-$variant.dmg"

  rm -rf "$STAGE" "$DMG"
  mkdir -p "$STAGE"
  ditto "$APP" "$STAGE/squick-share.app"
  ln -s /Applications "$STAGE/Applications"   # drag target shown next to the app

  hdiutil create -volname "squick-share $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
  rm -rf "$STAGE"
  hdiutil verify "$DMG" >/dev/null
  echo "Created $DMG ($(du -h "$DMG" | cut -f1), $(lipo -archs "$APP/Contents/MacOS/squick-share"))"
done
