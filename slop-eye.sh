#!/bin/bash
# slop-eye.sh — start the room's hand-gesture eye for a show.
#
#   ./slop-eye.sh 'https://live.slop.computer/<slug>?invite=...'
#
# Opens an effects-free spectator view of the room (?fx=0, god-mode auth) in
# a dedicated Chrome instance, then points slop-detector at that window and
# streams detected hand landmarks to the relay (/v1/hands, authed with the
# god password). The relay attributes hands to whichever camera window
# they're over — so EVERYONE visible on the show (host + guests) triggers
# gesture effects, with zero setup on their end.
#
# Secrets: reads SLOP_GOD_PASSWORD from gitignored .slop-eye.env next to this
# script. Stop everything: pkill -f slop-detector; pkill -f slop-eye-chrome.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
URL="${1:-}"
[ -n "$URL" ] || { echo "usage: $0 'https://live.slop.computer/<slug>?invite=...'"; exit 1; }

BASE="https://live.slop.computer"
SLUG=$(echo "$URL" | sed -E 's|https?://[^/]+/([^/?]+).*|\1|')
[ -n "$SLUG" ] || { echo "could not parse slug from URL"; exit 1; }

# shellcheck disable=SC1091
source "$DIR/.slop-eye.env" 2>/dev/null || true
[ -n "${SLOP_GOD_PASSWORD:-}" ] || { echo "missing SLOP_GOD_PASSWORD in $DIR/.slop-eye.env"; exit 1; }

EYE_URL="$BASE/$SLUG?godMode=$SLOP_GOD_PASSWORD&fx=0"
PROFILE="$HOME/.slop-eye-chrome"

# Fresh detector build if the source is newer (same rule as slop-setup.sh).
if [ ! -x "$DIR/slop-detector" ] || [ "$DIR/slop-detector.swift" -nt "$DIR/slop-detector" ]; then
  echo "Building slop-detector..."
  swiftc "$DIR/slop-detector.swift" -o "$DIR/slop-detector"
fi

# Kill any previous eye (Chrome instance + detector aimed at it).
pkill -f "slop-eye-chrome" 2>/dev/null || true
pkill -f "slop-detector" 2>/dev/null || true
sleep 1

# Dedicated Chrome instance (its own profile, --app window so the page title
# "SLOP-EYE" is the window title the detector matches). The three flags keep
# an occluded window painting + timing normally — the eye usually sits behind
# OBS and everything else, and Chrome otherwise stops rendering it.
nohup "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --user-data-dir="$PROFILE" \
  --no-first-run --no-default-browser-check \
  --disable-backgrounding-occluded-windows \
  --disable-renderer-backgrounding \
  --disable-background-timer-throttling \
  --window-size=1568,910 \
  --app="$EYE_URL" > /tmp/slop-eye-chrome.log 2>&1 &
echo "eye window opening (slug: $SLUG)..."
sleep 6

# Detector: capture the SLOP-EYE window, stream landmarks to the relay.
SLOP_GESTURE_KEY="$SLOP_GOD_PASSWORD" nohup "$DIR/slop-detector" \
  "Chrome" "SLOP-EYE" "$BASE/v1/hands?slug=$SLUG" > /tmp/slop-eye-detector.log 2>&1 &
sleep 3
tail -3 /tmp/slop-eye-detector.log
echo "eye running: room=$SLUG  (logs: /tmp/slop-eye-detector.log, /tmp/slop-eye-chrome.log)"
