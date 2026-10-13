#!/bin/bash
# Builds a signed, notarized, stapled DMG in dist/ ready to upload.
#   scripts/release.sh            full release
#   scripts/release.sh --no-notarize   sign and package only (for checking the DMG)
# Needs a notarytool keychain profile named in scripts/app.env (NOTARY_PROFILE). Create it once with:
#   xcrun notarytool store-credentials weio-notary --apple-id <apple id> --team-id H4T6Q9X2TH
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/app.env

NOTARIZE=1
[[ "${1:-}" == "--no-notarize" ]] && NOTARIZE=0

scripts/build-app.sh --release

APP="dist/$APP_NAME.app"
DMG="dist/$DMG_NAME"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# Staple the app itself first, so it opens without a network check even after it's copied out of the DMG.
if [[ $NOTARIZE == 1 ]]; then
  ditto -c -k --keepParent "$APP" "$STAGE/app.zip"
  xcrun notarytool submit "$STAGE/app.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm "$STAGE/app.zip"
fi

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
if [[ -f Support/dmg-background.png ]]; then
  mkdir "$STAGE/.background"
  cp Support/dmg-background.png "$STAGE/.background/background.png"
fi

rm -f "$DMG"
hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 "$DMG"
codesign --force --timestamp --sign "$RELEASE_IDENTITY" "$DMG"

if [[ $NOTARIZE == 1 ]]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi

echo
echo "Release: $DMG"
echo "SHA-256: $(shasum -a 256 "$DMG" | cut -d' ' -f1)   (for the Homebrew cask)"
echo "Size:    $(du -h "$DMG" | cut -f1)"
