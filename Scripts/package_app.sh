#!/usr/bin/env bash
# Builds dist/EdgeStash.app (universal by default) and code-signs it.
#
#   SIGN_IDENTITY  codesign identity. "-" (default) = ad-hoc.
#                  Use "Developer ID Application: …" for public releases,
#                  or an "Apple Development: …" identity for local installs
#                  (a stable identity keeps the Accessibility grant across rebuilds).
#   ARCHS          default "arm64 x86_64"
set -euo pipefail
cd "$(dirname "$0")/.."
source version.env

APP_NAME=EdgeStash
BUNDLE_ID=${BUNDLE_ID:-io.github.marunouchir5.EdgeStash}
SIGN_IDENTITY=${SIGN_IDENTITY:--}
ARCHS=${ARCHS:-"arm64 x86_64"}
APP="dist/$APP_NAME.app"

arch_flags=()
for a in $ARCHS; do arch_flags+=(--arch "$a"); done

swift build -c release "${arch_flags[@]}"
BIN_DIR=$(swift build -c release "${arch_flags[@]}" --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$MARKETING_VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --sign - "$APP"
else
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"
echo "Built $APP ($MARKETING_VERSION build $BUILD_NUMBER, archs: $(lipo -archs "$APP/Contents/MacOS/$APP_NAME"))"
