#!/bin/bash
# slop-eye-install.sh — one-time setup of the gesture eye on the GOD MODE machine.
#
# After this, the per-show ritual is just: click 👁 in the god-mode menu bar.
# That opens the effects-free eye window; the always-running detector below
# latches onto it by title (SLOP-EYE) and streams hand landmarks to the
# relay, which routes them to whichever room the eye is open in. Close the
# window, gestures stop; open it in another room, they follow.
#
# What this installs:
#   1. slop-detector (built from source) — runs forever via launchd,
#      capturing any window titled SLOP-EYE in Chrome.
#   2. ~/Library/LaunchAgents/com.slop.eye.plist — keeps it running.
#   3. .slop-eye.env — the god password (never committed).
#
# Run it IN A TERMINAL (not over plain ssh): macOS shows a Screen Recording
# permission prompt on first detection — approve it once and it sticks.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
PLIST="$HOME/Library/LaunchAgents/com.slop.eye.plist"

# God password -> .slop-eye.env (prompt if missing).
if [ ! -f "$DIR/.slop-eye.env" ]; then
  read -r -s -p "God mode password: " GP; echo
  printf 'SLOP_GOD_PASSWORD=%s\n' "$GP" > "$DIR/.slop-eye.env"
  chmod 600 "$DIR/.slop-eye.env"
fi
# shellcheck disable=SC1091
source "$DIR/.slop-eye.env"

echo "Building slop-detector..."
swiftc "$DIR/slop-detector.swift" -o "$DIR/slop-detector"

# Run once in the foreground to trigger the Screen Recording prompt in THIS
# session (launchd can't show it reliably). It'll say "no match yet" over and
# over — that's fine, it just needs to touch the capture API once.
echo
echo ">>> Approve the Screen Recording prompt if macOS shows one, then press Ctrl-C. <<<"
echo "    (If no prompt appears and you see 'no match yet' lines, permission is already granted — Ctrl-C.)"
SLOP_GESTURE_KEY="$SLOP_GOD_PASSWORD" "$DIR/slop-detector" "Chrome" "SLOP-EYE" "https://live.slop.computer/v1/hands" || true

# Install the launchd agent so the detector always runs.
launchctl unload "$PLIST" 2>/dev/null || true
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.slop.eye</string>
  <key>ProgramArguments</key><array>
    <string>$DIR/slop-detector</string>
    <string>Chrome</string>
    <string>SLOP-EYE</string>
    <string>https://live.slop.computer/v1/hands</string>
  </array>
  <key>EnvironmentVariables</key><dict>
    <key>SLOP_GESTURE_KEY</key><string>$SLOP_GOD_PASSWORD</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/tmp/slop-eye-detector.log</string>
  <key>StandardErrorPath</key><string>/tmp/slop-eye-detector.log</string>
</dict></plist>
PLISTEOF
launchctl load "$PLIST"
sleep 2
tail -3 /tmp/slop-eye-detector.log || true
echo
echo "Installed. The detector now runs always (log: /tmp/slop-eye-detector.log)."
echo "Per show: click 👁 in the god-mode menu bar. That's it."
echo "Uninstall: launchctl unload $PLIST && rm $PLIST"
