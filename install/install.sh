#!/usr/bin/env bash
# Build MacJanitor.app, install the one LaunchAgent that runs the cleanup, and
# start the applet. Re-runnable: it replaces any previous install.
# Usage: ./install/install.sh     (undo: ./install/uninstall.sh)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

LABEL="com.ignacy.mac-janitor"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

pkill -x MacJanitor || true
"$HERE/build-app.sh"

# launchd runs the CLI inside the bundle where build-app.sh writes it, so a
# rebuild is picked up without reinstalling.
JANITOR="$ROOT/MacJanitor.app/Contents/MacOS/janitor"
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$JANITOR</string><string>run</string><string>--scheduled</string></array>
  <!-- Hourly wake; the janitor itself decides from config.json (intervalHours,
       lowDiskGB, paused) whether to run. Wakes missed during sleep coalesce. -->
  <key>StartInterval</key><integer>3600</integer>
  <key>ProcessType</key><string>Background</string>
  <key>LowPriorityIO</key><true/>
  <key>Nice</key><integer>10</integer>
  <!-- Each action is already in ~/Library/Logs/mac-janitor.log; this catches crashes. -->
  <key>StandardOutPath</key><string>/dev/null</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/mac-janitor.err.log</string>
</dict>
</plist>
PL

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST"
echo "Installed $PLIST. Run it now: launchctl kickstart $DOMAIN/$LABEL"

open "$ROOT/MacJanitor.app"
