#!/usr/bin/env bash
# Remove the LaunchAgent and quit the applet. Logs, last-run.json and salvaged
# work in ~/Library/Application Support/MacJanitor are kept.
set -euo pipefail
LABEL="com.ignacy.mac-janitor"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
pkill -x MacJanitor || true
echo "Uninstalled $LABEL. Launch at login, if enabled, is under System Settings > General > Login Items."
