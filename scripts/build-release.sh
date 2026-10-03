#!/usr/bin/env bash
# Builds Release squick-share.app variants and zips them:
#   build/release/<arch>/squick-share.app
#   build/release/squick-share-<version>-<arch>.zip
# where <arch> is universal (Apple Silicon + Intel), arm64 (Apple Silicon) or x86_64 (Intel).
#
# Usage:
#   ./scripts/build-release.sh                    universal only (default)
#   ./scripts/build-release.sh --arch arm64       one variant: universal | arm64 | x86_64
#   ./scripts/build-release.sh --all              all three variants
#   ./scripts/build-release.sh --install          also quit any running copy, replace
#                                                 /Applications/squick-share.app and open it
#                                                 (installs universal, or this Mac's architecture)
# Then ./scripts/make-dmg.sh packages every built variant as squick-share-<version>-<arch>.dmg.
#
# Signing (pick one):
#   (default)                                         ad-hoc ("Sign to Run Locally")
#   TEAM_ID=ABCDE12345                                free or paid Apple ID, "Apple Development" certificate
#   TEAM_ID=ABCDE12345 SIGN_IDENTITY="Developer ID Application" NOTARY_PROFILE=notary
#                                                     Developer ID + notarization (paid Apple Developer Program).
#     Create the notary profile once with:
#     xcrun notarytool store-credentials notary --apple-id you@example.com --team-id ABCDE12345
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT="$ROOT/build/release"

VARIANTS=()
INSTALL=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch)
      [[ $# -ge 2 ]] || { echo "--arch needs a value: universal, arm64 or x86_64" >&2; exit 1; }
      VARIANTS+=("$2"); shift 2 ;;
    --all) VARIANTS+=(universal arm64 x86_64); shift ;;
    --install) INSTALL=true; shift ;;
    *) echo "Unknown option: $1 (see the top of this script)" >&2; exit 1 ;;
  esac
done
[[ ${#VARIANTS[@]} -gt 0 ]] || VARIANTS=(universal)

SIGN_ARGS=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=)
if [[ -n "${TEAM_ID:-}" ]]; then
  IDENTITY="${SIGN_IDENTITY:-Apple Development}"
  SIGN_ARGS=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$IDENTITY" "DEVELOPMENT_TEAM=$TEAM_ID" "OTHER_CODE_SIGN_FLAGS=--timestamp")
  echo "Signing with \"$IDENTITY\" (team $TEAM_ID)"
else
  echo "Signing ad-hoc (other Macs need the README's \"Open Anyway\" step)"
fi
mkdir -p "$OUT"

build_variant() {
  local variant="$1" archs
  case "$variant" in
    universal) archs="arm64 x86_64" ;;
    arm64) archs="arm64" ;;
    x86_64) archs="x86_64" ;;
    *) echo "Unknown architecture \"$variant\": use universal, arm64 or x86_64" >&2; exit 1 ;;
  esac
  echo ""
  echo "== squick-share ($variant: $archs) =="

  local derived="$ROOT/build/DerivedData-release-$variant"
  local dest="$OUT/$variant"
  rm -rf "$dest" "$OUT"/squick-share-*-"$variant".zip
  mkdir -p "$dest"

  xcodebuild -project SquickShare.xcodeproj -scheme SquickShare -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$derived" ARCHS="$archs" ONLY_ACTIVE_ARCH=NO "${SIGN_ARGS[@]}" \
    clean build 2>&1 | grep -E "error:|warning:|BUILD (SUCCEEDED|FAILED)" | grep -v appintents || true

  local built="$derived/Build/Products/Release/squick-share.app"
  [[ -d "$built" ]] || { echo "build failed ($variant)" >&2; exit 1; }
  local app="$dest/squick-share.app"
  ditto "$built" "$app"

  local version actual
  version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")
  actual=$(lipo -archs "$app/Contents/MacOS/squick-share")
  echo "Architectures: $actual"
  [[ "$(echo "$actual" | tr ' ' '\n' | sort | xargs)" == "$(echo "$archs" | tr ' ' '\n' | sort | xargs)" ]] \
    || { echo "expected \"$archs\", got \"$actual\"" >&2; exit 1; }
  codesign --verify --deep --strict "$app" && echo "Signature verifies"
  codesign -dv "$app" 2>&1 | grep -E "flags|Authority|TeamIdentifier" || true

  local zip="$OUT/squick-share-$version-$variant.zip"
  ditto -c -k --keepParent "$app" "$zip"
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    echo "Submitting for notarization…"
    xcrun notarytool submit "$zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$app"
    rm "$zip"
    ditto -c -k --keepParent "$app" "$zip"
    spctl --assess --type execute --verbose "$app"
  fi
  echo "Done: $app and $(basename "$zip")"
}

for variant in "${VARIANTS[@]}"; do
  build_variant "$variant"
done

if $INSTALL; then
  host=$(uname -m)
  [[ "$host" == "x86_64" || "$host" == "arm64" ]] || host=universal
  source_app=""
  for candidate in universal "$host"; do
    if [[ -d "$OUT/$candidate/squick-share.app" ]] && [[ " ${VARIANTS[*]} " == *" $candidate "* ]]; then
      source_app="$OUT/$candidate/squick-share.app"
      break
    fi
  done
  [[ -n "$source_app" ]] || { echo "--install: no build for this Mac ($host) or universal" >&2; exit 1; }
  osascript -e 'quit app "squick-share"' 2>/dev/null || true
  # Also stop copies started from other locations (e.g. this build folder), so only one advertises.
  pkill -x squick-share 2>/dev/null || true
  sleep 1
  rm -rf /Applications/squick-share.app
  ditto "$source_app" /Applications/squick-share.app
  open /Applications/squick-share.app
  echo "Installed and opened /Applications/squick-share.app (from $source_app)"
fi
