#!/bin/bash
# Builds dist/DataRecover.app. The recovery engine is unchanged by this script.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
APP="dist/DataRecover.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/DataRecover "$APP/Contents/MacOS/DataRecover"
cp Support/Info.plist "$APP/Contents/Info.plist"
if [[ -f Support/AppIcon.icns ]]; then
  cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
chmod 755 "$APP/Contents/MacOS/DataRecover"
IDENTITY="Apple Development: Adam Perry (MJDP35MH5W)"
if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
  codesign --force --sign "$IDENTITY" --identifier "com.adamperry.DataRecover" "$APP"
else
  codesign --force --sign - "$APP"
fi
echo "Built $APP"
