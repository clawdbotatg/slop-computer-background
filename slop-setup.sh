#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
# slop-setup.sh — SLOPTUBE streaming session bootstrapper
# ═══════════════════════════════════════════════════════════════════════════════
#
# WHAT IT DOES (run by SLOP.app, which wraps it in iTerm2 for Screen Recording):
#   1. Kills OBS and the slop foreground/background browser instances.
#   2. Serves this folder over http (needed: ES module imports don't work on file://).
#   3. Opens FOREGROUND + BACKGROUND as isolated Chrome --app windows at a matched
#      16:9 size (inner 16:9 + the title/menu bar), so OBS can window-capture them.
#   4. Patches Rig2.json: sloptubefront -> foreground window, sloptuberender -> bg.
#   5. Launches OBS-SLOP (Rig2) — it reads the freshly-patched scene.
#   6. Brings up the slop.computer control windows in your MAIN Chrome.
#
# WHY iTerm2: slop-obs-patch.py uses Quartz CGWindowListCopyWindowInfo to find
# window IDs, which needs Screen Recording permission. iTerm2 has it; Terminal
# does not. SLOP.app handles launching this inside iTerm2.
#
# WHY ISOLATED PROFILES for fg/bg: they get their own --user-data-dir so killing
# and relaunching them never touches your main Chrome, Chrome's own
# --window-position/--window-size flags place them (no cross-instance AppleScript),
# and the camera grant persists in the profile (allow it once, first run only).
# ═══════════════════════════════════════════════════════════════════════════════

set -u

# ── CONFIG ──────────────────────────────────────────────────────────────────────
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT=9911
BASE="http://localhost:${PORT}"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
PROFILE_FG="$HOME/.slop-chrome-fg"
PROFILE_BG="$HOME/.slop-chrome-bg"
PROFILE_MON="$HOME/.slop-chrome-mon"   # the hands.html monitor window (its own killable profile)

# Per-window size + position (top-left x,y), captured from where you placed them.
# Foreground is intentionally a touch taller than the background.
FG_X=-2832; FG_Y=-813; FG_W=1280; FG_H=766
BG_X=-3114; BG_Y=-801; BG_W=1280; BG_H=748
# hands.html monitor — where you placed it
MON_X=-3141; MON_Y=-711; MON_W=960; MON_H=560
# iTerm window (running this script + the detector) — set by SLOP.app's launcher too
ITERM_BOUNDS="-3195, -594, -2615, -54"

# ── CONTROL WINDOW (main Chrome) ────────────────────────────────────────────────
# These four URLs open as TABS in ONE main-Chrome window, positioned at:
# {Left, Top, Right, Bottom}. Adjust after you see it.
CONTROL_BOUNDS="622, 67, 2252, 1090"
CONTROL_URLS=(
  "https://slop.computer/"
  "https://slop.computer/admin"
  "https://slop.computer/checklist"
  "https://live.slop.computer/admin"
)

# ── --capture helper: dump current main-Chrome window bounds, then exit ─────────
if [ "${1:-}" = "--capture" ]; then
  osascript <<'EOF'
tell application "Google Chrome"
  set out to ""
  repeat with w in windows
    try
      set out to out & (URL of active tab of w) & "   ->   " & (item 1 of (bounds of w)) & ", " & (item 2 of (bounds of w)) & ", " & (item 3 of (bounds of w)) & ", " & (item 4 of (bounds of w)) & linefeed
    end try
  end repeat
  return out
end tell
EOF
  exit 0
fi

# ── KILL OBS + slop browsers + server + detector ───────────────────────────────
echo "Killing OBS, slop browsers, server, detector..."
osascript -e 'tell application "OBS" to quit' 2>/dev/null || true
pkill -f "OBS.app/Contents/MacOS/OBS" 2>/dev/null || true
# Only the isolated slop Chrome instances — main Chrome is untouched.
pkill -f -- "--user-data-dir=$PROFILE_FG" 2>/dev/null || true
pkill -f -- "--user-data-dir=$PROFILE_BG" 2>/dev/null || true
pkill -f -- "--user-data-dir=$PROFILE_MON" 2>/dev/null || true
pkill -f "slop-server.py" 2>/dev/null || true     # restart fresh so it has current routes
pkill -f "slop-detector" 2>/dev/null || true
sleep 2
until ! pgrep -f -- "--user-data-dir=$PROFILE_FG" >/dev/null \
   && ! pgrep -f -- "--user-data-dir=$PROFILE_BG" >/dev/null \
   && ! pgrep -f -- "--user-data-dir=$PROFILE_MON" >/dev/null; do sleep 1; done

# ── BUILD the detector if needed ────────────────────────────────────────────────
if [ ! -x "$DIR/slop-detector" ] || [ "$DIR/slop-detector.swift" -nt "$DIR/slop-detector" ]; then
  echo "Building slop-detector..."
  swiftc "$DIR/slop-detector.swift" -o "$DIR/slop-detector" || echo "  (detector build failed — hand detection won't run)"
fi

# ── SERVE the slop folder + event relay (slop-server.py: static + /spawn + /events + /hands)
echo "Starting slop-server on ${PORT}..."
( cd "$DIR" && nohup python3 "$DIR/slop-server.py" "$PORT" >/tmp/slop-server.log 2>&1 & disown )
for i in $(seq 1 20); do
  curl -s -o /dev/null "http://localhost:${PORT}/foreground.html" && break
  sleep 0.3
done

# ── OPEN BACKGROUND (tunnel) and FOREGROUND (green/luma + detection) ────────────
# Each in its own isolated, persistent profile so it's independently killable and
# Chrome's window flags place it. Foreground gets auto camera grant.
echo "Opening background (${BG_W}x${BG_H}) + foreground (${FG_W}x${FG_H}) capture windows..."
# open -n forces a NEW Chrome instance — running the binary directly while your
# main Chrome is up just gets absorbed by it (no isolated instance, no profile).
open -n -a "Google Chrome" --args --user-data-dir="$PROFILE_BG" \
  --app="${BASE}/background.html?t=SLOPTUBE-BG" \
  --window-position=${BG_X},${BG_Y} --window-size=${BG_W},${BG_H} \
  --no-first-run --no-default-browser-check >/dev/null 2>&1
sleep 1
open -n -a "Google Chrome" --args --user-data-dir="$PROFILE_FG" \
  --app="${BASE}/foreground.html?t=SLOPTUBE-FRONT" \
  --window-position=${FG_X},${FG_Y} --window-size=${FG_W},${FG_H} \
  --no-first-run --no-default-browser-check >/dev/null 2>&1
# NOTE: camera permission — click "Allow" ONCE in the foreground window on the
# first run; the persistent profile ($PROFILE_FG) remembers it forever after.
# (We avoid --use-fake-ui-for-media-stream because it shows an "unsupported flag"
# banner that would appear in the capture.)

# give the pages time to create their windows
echo "Waiting for capture windows to load..."
sleep 5

# Capture each isolated instance's main process PID (the one launched with --app,
# not the renderer/gpu helpers which carry --type=). The patcher matches windows
# by owner PID -> window number, so no titles / Screen Recording needed.
# match the main process (has the profile dir AND --app; helpers carry --type= instead)
BG_PID=$(pgrep -f "slop-chrome-bg.*--app" | head -1)
FG_PID=$(pgrep -f "slop-chrome-fg.*--app" | head -1)
echo "  foreground pid=$FG_PID  background pid=$BG_PID"

# ── PATCH the Rig2 (SLOP) scene with the new window IDs (OBS must be closed) ─────
echo "Patching OBS Rig2 scene (sloptubefront / sloptuberender)..."
python3 "$DIR/slop-obs-patch.py" "$FG_PID" "$BG_PID" || { echo "Patch failed — are both windows open?"; }

# ── LAUNCH OBS-SLOP (reads the patched scene) ───────────────────────────────────
echo "Launching OBS-SLOP..."
open "$HOME/Desktop/OBS-SLOP.app"
# Wait for OBS's window to exist, then move/resize it to where you want it.
# (OBS isn't AppleScript-scriptable, so we drive it via System Events.)
OBS_POS="-1492, -752"      # captured from where you placed it
OBS_SIZE="1464, 831"
for i in $(seq 1 40); do
  if osascript -e 'tell application "System Events" to tell process "OBS" to exists front window' 2>/dev/null | grep -q true; then break; fi
  sleep 0.5
done
osascript -e "tell application \"System Events\" to tell process \"OBS\" to set position of front window to {$OBS_POS}" 2>/dev/null
osascript -e "tell application \"System Events\" to tell process \"OBS\" to set size of front window to {$OBS_SIZE}" 2>/dev/null

# ── OPEN THE HANDS MONITOR (hands.html) as its own killable --app window ────────
echo "Opening hands monitor..."
open -n -a "Google Chrome" --args --user-data-dir="$PROFILE_MON" \
  --app="${BASE}/hands.html" \
  --window-position=${MON_X},${MON_Y} --window-size=${MON_W},${MON_H} \
  --no-first-run --no-default-browser-check >/dev/null 2>&1

# ── BRING UP slop.computer CONTROL WINDOWS in MAIN Chrome ───────────────────────
echo "Bringing up slop.computer control window (4 tabs in main Chrome)..."
# De-dupe: close any existing main-Chrome window that already has a slop.computer
# tab (checks every tab, not just the active one).
osascript >/dev/null 2>&1 <<'EOF'
tell application "Google Chrome"
  set toClose to {}
  repeat with w in windows
    repeat with t in tabs of w
      try
        if (URL of t) contains "slop.computer" then
          set end of toClose to w
          exit repeat
        end if
      end try
    end repeat
  end repeat
  repeat with w in toClose
    try
      close w
    end try
  end repeat
end tell
EOF
# Open all four as tabs in ONE new window (binary launch lands in your main Chrome).
"$CHROME" --new-window "${CONTROL_URLS[@]}" >/dev/null 2>&1 &
disown
sleep 3
# Position that window (match the window holding the slop.computer tabs).
osascript >/dev/null 2>&1 <<EOF
tell application "Google Chrome"
  repeat with w in windows
    repeat with t in tabs of w
      try
        if (URL of t) contains "slop.computer" then
          set bounds of w to {$CONTROL_BOUNDS}
          exit repeat
        end if
      end try
    end repeat
  end repeat
end tell
EOF

echo ""
echo "SLOP rig up."
echo "  • OBS sources: sloptubefront → SLOPTUBE-FRONT,  sloptuberender → SLOPTUBE-BG"
echo "  • Hand monitor window open (hands.html)"
echo ""

# ── POSITION THIS iTerm WINDOW next to the capture region ───────────────────────
osascript -e "tell application \"iTerm2\" to set bounds of current window to {$ITERM_BOUNDS}" 2>/dev/null || true

# ── KICK EVERYTHING OFF: run the hand detector in THIS terminal (foreground) ────
# Reads the OBS "Windowed Projector (Source) - Syphon Client" (clean feed) and POSTs
# hand landmarks to the relay. Auto-retries until that projector window exists, so:
#   • Open the Syphon source's Windowed Projector once, and enable OBS → Settings →
#     General → "Save projectors on exit" so OBS reopens it automatically.
# Ctrl-C here stops the detector. Closing this window ends the session's hand input.
if [ -x "$DIR/slop-detector" ]; then
  echo "Starting hand detector in this terminal (Ctrl-C to stop)..."
  exec "$DIR/slop-detector"
else
  echo "slop-detector not built — hand detection won't run."
fi
