#!/usr/bin/env bash
# Builds a universal (Apple Silicon + Intel) Release squick-share.app into build/release/.
#
# Signing (pick one):
#   ./scripts/build-release.sh                       ad-hoc ("Sign to Run Locally"); runs on this Mac
#   TEAM_ID=ABCDE12345 ./scripts/build-release.sh    free or paid Apple ID, "Apple Development" certificate
#   TEAM_ID=ABCDE12345 SIGN_IDENTITY="Developer ID Application" NOTARY_PROFILE=notary ./scripts/build-release.sh
#                                                    Developer ID + notarization (paid Apple Developer Program).
#     Create the notary profile once with:
#     xcrun notarytool store-credentials notary --apple-id you@example.com --team-id ABCDE12345
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT="$ROOT/build/release"
DERIVED="$ROOT/build/DerivedData-release"
rm -rf "$OUT"
mkdir -p "$OUT"

SIGN_ARGS=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=)
if [[ -n "${TEAM_ID:-}" ]]; then
  IDENTITY="${SIGN_IDENTITY:-Apple Development}"
  SIGN_ARGS=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$IDENTITY" "DEVELOPMENT_TEAM=$TEAM_ID" "OTHER_CODE_SIGN_FLAGS=--timestamp")
  echo "Signing with \"$IDENTITY\" (team $TEAM_ID)"
else
  echo "Signing ad-hoc (runs on this Mac; other Macs need right-click → Open)"
fi

xcodebuild -project SquickShare.xcodeproj -scheme SquickShare -configuration Release \
  -derivedDataPath "$DERIVED" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO "${SIGN_ARGS[@]}" \
  clean build | grep -E "error:|warning:|BUILD (SUCCEEDED|FAILED)" || true

APP="$DERIVED/Build/Products/Release/squick-share.app"
[[ -d "$APP" ]] || { echo "build failed" >&2; exit 1; }
ditto "$APP" "$OUT/squick-share.app"

echo "Architectures: $(lipo -archs "$OUT/squick-share.app/Contents/MacOS/squick-share")"
codesign --verify --deep --strict "$OUT/squick-share.app" && echo "Signature verifies"
codesign -dv "$OUT/squick-share.app" 2>&1 | grep -E "flags|Authority|TeamIdentifier" || true

ditto -c -k --keepParent "$OUT/squick-share.app" "$OUT/squick-share.zip"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  echo "Submitting for notarization…"
  xcrun notarytool submit "$OUT/squick-share.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$OUT/squick-share.app"
  rm "$OUT/squick-share.zip"
  ditto -c -k --keepParent "$OUT/squick-share.app" "$OUT/squick-share.zip"
  spctl --assess --type execute --verbose "$OUT/squick-share.app"
fi

echo "Done: $OUT/squick-share.app (and squick-share.zip)"
