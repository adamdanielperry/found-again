#!/bin/bash
# Builds dist/<Name>.app as a universal (Apple silicon + Intel) app.
#   scripts/build-app.sh            development build, signed for this Mac
#   scripts/build-app.sh --release  Developer ID signature with the hardened runtime, ready to notarize
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/app.env

MODE="${1:-}"
ARCHS=(--arch arm64 --arch x86_64)
if [[ "$MODE" != "--release" && "${UNIVERSAL:-0}" != "1" ]]; then
  ARCHS=()
fi

swift build -c release ${ARCHS[@]+"${ARCHS[@]}"}
BIN_DIR="$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)"

APP="dist/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/DataRecover" "$APP/Contents/MacOS/$APP_NAME"
cp Support/Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleExecutable -string "$APP_NAME" "$APP/Contents/Info.plist"
plutil -replace CFBundleName -string "$APP_NAME" "$APP/Contents/Info.plist"
plutil -replace CFBundleDisplayName -string "$APP_NAME" "$APP/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD" "$APP/Contents/Info.plist"

if [[ -f Support/Assets.car ]]; then
  cp Support/Assets.car "$APP/Contents/Resources/Assets.car"
fi
if [[ -f Support/AppIcon.icns ]]; then
  cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
chmod 755 "$APP/Contents/MacOS/$APP_NAME"

if [[ "$MODE" == "--release" ]]; then
  codesign --force --options runtime --timestamp \
    --entitlements Support/App.entitlements \
    --sign "$RELEASE_IDENTITY" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
elif security find-identity -v -p codesigning | grep -q "$DEV_IDENTITY"; then
  codesign --force --sign "$DEV_IDENTITY" --entitlements Support/App.entitlements "$APP"
else
  codesign --force --sign - "$APP"
fi
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/$APP_NAME"))"
