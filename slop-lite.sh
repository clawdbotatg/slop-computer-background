#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
# slop-lite.sh — mid-call recovery: fg + bg + hand detector ONLY.
# ═══════════════════════════════════════════════════════════════════════════════
#
# The surgical sibling of slop-setup.sh, safe to run LIVE while streaming /
# on a call. It touches nothing visible except the two capture windows:
#
#   • kills + relaunches the FOREGROUND and BACKGROUND capture windows
#   • re-points OBS's window captures at them WITHOUT restarting OBS
#     (obs-websocket via slop-obs-live.py; scene-JSON patch fallback only
#     if OBS turns out to be dead, in which case OBS-SLOP is relaunched)
#   • restarts the hand detector in this terminal
#   • starts slop-server only if it isn't already answering
#
# It does NOT touch: OBS (if alive), your main Chrome, the slop.computer
# control tabs, the teleprompter projector, or the hands monitor window.
#
# Run by SLOP-Lite.app inside iTerm2 (the detector's ScreenCaptureKit read of
# the OBS projector needs Screen Recording permission; iTerm2 has it).
# ═══════════════════════════════════════════════════════════════════════════════

set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/slop-config.sh"

# A python3 that has BOTH Quartz (pyobjc) and websockets — homebrew's usually
# has neither, the CLT/system one has both on this machine.
PYBIN=python3
python3 -c "import Quartz, websockets" 2>/dev/null || PYBIN=/usr/bin/python3

# ── KILL only the capture windows + detector ───────────────────────────────────
echo "LITE: killing foreground/background windows + detector (OBS stays up)..."
pkill -f -- "--user-data-dir=$PROFILE_FG" 2>/dev/null || true
pkill -f -- "--user-data-dir=$PROFILE_BG" 2>/dev/null || true
pkill -f "slop-detector" 2>/dev/null || true
sleep 1
until ! pgrep -f -- "--user-data-dir=$PROFILE_FG" >/dev/null \
   && ! pgrep -f -- "--user-data-dir=$PROFILE_BG" >/dev/null; do sleep 1; done

# ── BUILD the detector if needed ───────────────────────────────────────────────
if [ ! -x "$DIR/slop-detector" ] || [ "$DIR/slop-detector.swift" -nt "$DIR/slop-detector" ]; then
  echo "Building slop-detector..."
  swiftc "$DIR/slop-detector.swift" -o "$DIR/slop-detector" || echo "  (detector build failed — hand detection won't run)"
fi

# ── SERVER: leave it alone if healthy, start it if not ─────────────────────────
if ! curl -s -o /dev/null --max-time 2 "${BASE}/foreground.html"; then
  echo "slop-server not answering — starting it on ${PORT}..."
  pkill -f "slop-server.py" 2>/dev/null || true
  ( cd "$DIR" && nohup python3 "$DIR/slop-server.py" "$PORT" >/tmp/slop-server.log 2>&1 & disown )
  for i in $(seq 1 20); do
    curl -s -o /dev/null "${BASE}/foreground.html" && break
    sleep 0.3
  done
else
  echo "slop-server already up — leaving it alone."
fi

# ── RELAUNCH background + foreground capture windows ───────────────────────────
echo "Opening background (${BG_W}x${BG_H}) + foreground (${FG_W}x${FG_H})..."
# The two --disable-*backgrounding flags keep Chrome painting even when the
# window is covered or its display naps — an occluded window otherwise stops
# rendering and OBS captures a frozen/blank frame. (Neither is on Chrome's
# bad-flags list, so no "unsupported flag" banner in the capture.)
open -n -a "Google Chrome" --args --user-data-dir="$PROFILE_BG" \
  --app="${BASE}/background.html?t=SLOPTUBE-BG" \
  --window-position=${BG_X},${BG_Y} --window-size=${BG_W},${BG_H} \
  --disable-backgrounding-occluded-windows --disable-renderer-backgrounding \
  --no-first-run --no-default-browser-check >/dev/null 2>&1
sleep 1
open -n -a "Google Chrome" --args --user-data-dir="$PROFILE_FG" \
  --app="${BASE}/foreground.html?t=SLOPTUBE-FRONT" \
  --window-position=${FG_X},${FG_Y} --window-size=${FG_W},${FG_H} \
  --disable-backgrounding-occluded-windows --disable-renderer-backgrounding \
  --no-first-run --no-default-browser-check >/dev/null 2>&1

echo "Waiting for capture windows to load..."
sleep 5

BG_PID=$(pgrep -f "slop-chrome-bg.*--app" | head -1)
FG_PID=$(pgrep -f "slop-chrome-fg.*--app" | head -1)
echo "  foreground pid=$FG_PID  background pid=$BG_PID"

# ── RE-POINT OBS at the new windows (live — no OBS restart) ────────────────────
if pgrep -f "OBS.app/Contents/MacOS/OBS" >/dev/null; then
  echo "Re-pointing OBS captures live (obs-websocket)..."
  "$PYBIN" "$DIR/slop-obs-live.py" "$FG_PID" "$BG_PID" || \
    echo "  !! live re-point failed — check OBS Tools > WebSocket Server Settings"
else
  # OBS died? Patch the scene JSON while it's closed, then bring it back.
  echo "OBS is not running — patching scene JSON + relaunching OBS-SLOP..."
  "$PYBIN" "$DIR/slop-obs-patch.py" "$FG_PID" "$BG_PID" || echo "  !! patch failed"
  open "$HOME/Desktop/OBS-SLOP.app"
fi

echo ""
echo "SLOP lite recovery done: foreground + background + detector."
echo ""

# ── PARK THIS iTerm WINDOW next to the capture region ──────────────────────────
osascript -e "tell application \"iTerm2\" to set bounds of current window to {$ITERM_BOUNDS}" 2>/dev/null || true

# ── RUN the hand detector in THIS terminal (Ctrl-C stops it) ───────────────────
if [ -x "$DIR/slop-detector" ]; then
  echo "Starting hand detector in this terminal (Ctrl-C to stop)..."
  exec "$DIR/slop-detector" OBS "Source"
else
  echo "slop-detector not built — hand detection won't run."
fi
