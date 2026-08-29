#!/bin/zsh
# Build SafeRoutesMac (release) and assemble a double-clickable SafeRoutes.app
# into dist/. Usage: scripts/make_app.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$ROOT/SafeRoutesMac"
APP="$ROOT/dist/SafeRoutes.app"

swift build -c release --package-path "$PKG"
BIN="$(swift build -c release --package-path "$PKG" --show-bin-path)/SafeRoutes"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/SafeRoutes"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>SafeRoutes</string>
    <key>CFBundleIdentifier</key><string>au.syncs.saferoutes</string>
    <key>CFBundleName</key><string>SafeRoutes</string>
    <key>CFBundleDisplayName</key><string>SafeRoutes Sydney</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.navigation</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" 2>/dev/null || true
echo "Built $APP"
