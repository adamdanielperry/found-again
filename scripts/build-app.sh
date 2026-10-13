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

# The icon is an Icon Composer file. actool turns it into Assets.car (layered, for macOS 26+) and an .icns for older systems.
ICON_SOURCE="Support/Icons/$ICON.icon"
if [[ -d "$ICON_SOURCE" ]]; then
  ICON_WORK="$(mktemp -d)"
  cp -R "$ICON_SOURCE" "$ICON_WORK/AppIcon.icon"
  xcrun actool "$ICON_WORK/AppIcon.icon" --compile "$PWD/$APP/Contents/Resources" --platform macosx \
    --minimum-deployment-target 14.0 --app-icon AppIcon --output-partial-info-plist "$ICON_WORK/partial.plist" >/dev/null
  rm -rf "$ICON_WORK"
fi
chmod 755 "$APP/Contents/MacOS/$APP_NAME"

# SwiftPM records the deployment target as the SDK version. macOS uses that field to decide whether the app
# gets the current system design, so record the SDK the app was really built with.
SDK_VERSION="$(xcrun --show-sdk-version)"
BINARY="$APP/Contents/MacOS/$APP_NAME"
for ARCH in $(lipo -archs "$BINARY"); do
  vtool -arch "$ARCH" -set-build-version macos 14.0 "$SDK_VERSION" -replace -output "$BINARY.tmp" "$BINARY"
  mv "$BINARY.tmp" "$BINARY"
done

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
