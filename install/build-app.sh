#!/usr/bin/env bash
# Build a menu-bar-only MacJanitor.app (LSUIElement, no Dock icon) at the repo root,
# bundling the `janitor` CLI beside the applet. The launchd job runs that same copy.
# Usage: ./install/build-app.sh     then: open MacJanitor.app
#        (rebuilding under a running applet: pkill -x MacJanitor first)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="MacJanitor"
echo "Building release..."
swift build -c release

BIN_DIR="$(swift build -c release --show-bin-path)"
APP="$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "$BIN_DIR/janitor" "$APP/Contents/MacOS/janitor"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>MacJanitor</string>
  <key>CFBundleDisplayName</key><string>Mac Janitor</string>
  <key>CFBundleIdentifier</key><string>com.ignacy.mac-janitor.applet</string>
  <key>CFBundleExecutable</key><string>MacJanitor</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# macOS remembers privacy grants (Full Disk Access) by code identity. Ad-hoc code is
# identified by its hash, which every rebuild changes, so grants would reset each time;
# a certificate identity stays the same. MACJANITOR_SIGN_IDENTITY picks one, "-" is ad hoc.
IDENTITY="${MACJANITOR_SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
  | awk -F'"' '/Developer ID Application|Apple Development/ { print $2; exit }')}"
if [ -z "$IDENTITY" ] || [ "$IDENTITY" = "-" ]; then
  echo "warning: signing ad hoc; macOS will forget Full Disk Access after every rebuild" >&2
  IDENTITY="-"
fi
codesign --force --sign "$IDENTITY" --identifier com.ignacy.mac-janitor.janitor "$APP/Contents/MacOS/janitor"
codesign --force --sign "$IDENTITY" "$APP"
echo "Signed with: $IDENTITY"

echo "Built $ROOT/$APP"
echo "Launch:  open $ROOT/$APP"
