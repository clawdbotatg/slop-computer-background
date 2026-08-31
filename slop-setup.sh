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

# ── CONFIG (shared with slop-lite.sh — see slop-config.sh) ──────────────────────
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/slop-config.sh"

# ── SPACES ──────────────────────────────────────────────────────────────────────
# The rig uses two desktops on the main display, and which one a window lands on
# is decided at CREATION time — macOS has no API to move an existing window to
# another Space. So each window has to be opened while its desktop is active:
#
#   desktop 1  the show window, alone. This is what the teleprompter projects.
#   desktop 2  YouTube Studio, X Live Studio, and both admin pages — the things
#              Austin flips over to mid-show and flips back from.
#
# Keeping desktop 1 otherwise empty is the whole point: flipping to desktop 2
# during a show must never disturb what is being projected.
#
# current_desktop reads com.apple.spaces and falls back to "assume 1" if that
# lookup fails, which is the safe guess — the rig starts on desktop 1.
current_desktop() {
  defaults export com.apple.spaces - 2>/dev/null | python3 -c "
import plistlib, sys
try:
    d = plistlib.loads(sys.stdin.buffer.read())
    mon = d['SpacesDisplayConfiguration']['Management Data']['Monitors'][0]
    cur = (mon.get('Current Space') or {}).get('uuid', '')
    uuids = [s.get('uuid', '') for s in mon.get('Spaces', [])]
    print(uuids.index(cur) + 1 if cur in uuids else 1)
except Exception:
    print(1)
"
}

# goto_desktop N — ctrl-→ / ctrl-← until desktop N is active. Needs Accessibility
# permission for whatever runs this (iTerm has it; Terminal.app may not).
goto_desktop() {
  local target="$1" cur hops keycode i
  cur=$(current_desktop)
  hops=$((target - cur))
  [ "$hops" -eq 0 ] && return 0
  echo "  on desktop ${cur}, hopping to desktop ${target}..."
  if [ "$hops" -gt 0 ]; then keycode=124; else keycode=123; fi   # 124 = ctrl-→, 123 = ctrl-←
  for i in $(seq 1 ${hops#-}); do
    osascript -e "tell application \"System Events\" to key code $keycode using control down" 2>/dev/null
    sleep 0.8
  done
  sleep 0.5
}

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
# Ask OBS to quit nicely, but under a watchdog: a modal dialog (exit confirm,
# missing-files, crash recovery) makes the AppleScript quit block FOREVER and
# has stalled this whole script before. 6s, then we escalate.
osascript -e 'tell application "OBS" to quit' >/dev/null 2>&1 &
OSA_PID=$!
for i in $(seq 1 6); do kill -0 $OSA_PID 2>/dev/null || break; sleep 1; done
kill $OSA_PID 2>/dev/null || true
pkill -f "OBS.app/Contents/MacOS/OBS" 2>/dev/null || true
for i in $(seq 1 8); do pgrep -f "OBS.app/Contents/MacOS/OBS" >/dev/null || break; sleep 1; done
pgrep -f "OBS.app/Contents/MacOS/OBS" >/dev/null && { echo "  OBS ignored quit (dialog up?) — force-killing"; pkill -9 -f "OBS.app/Contents/MacOS/OBS"; }
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

# ── BRING UP slop.computer CONTROL WINDOWS in MAIN Chrome ───────────────────────
# This runs HERE — while the isolated fg/bg/mon Chrome instances are dead — on
# purpose: with several Chrome instances alive, AppleScript's
# 'tell application "Google Chrome"' can route to an isolated instance and
# silently no-op (no error, nothing closed, nothing positioned). Right after the
# kill above, main Chrome is the only instance, so the events land correctly.
# The teleprompter scene window-captures this window; the patcher below re-points
# it at the NEWEST main-Chrome window, i.e. the one created here.
echo "Bringing up slop.computer control window (4 tabs in main Chrome)..."
# De-dupe: close any existing main-Chrome window that already has a slop.computer
# tab (checks every tab, not just the active one). Errors go to the log, not
# /dev/null — an Automation-permission denial here is otherwise invisible.
#
# EXCEPTION: the two admin windows on desktop 2 are also slop.computer URLs, and
# they are scrolled to the GO LIVE / fanout buttons by hand. Closing and reopening
# them would throw that scroll position away mid-show, so any window holding an
# /admin tab is skipped here and merely repositioned later, same as the producer
# dashboards.
osascript >>/tmp/slop-chrome-osa.log 2>&1 <<'EOF'
tell application "Google Chrome"
  -- collect stable window IDs, not index references: closing a window renumbers
  -- the indices, so "close w" on stored references silently misses the rest
  set idsToClose to {}
  repeat with w in windows
    set isAdmin to false
    repeat with t in tabs of w
      try
        if (URL of t) contains "slop.computer/admin" then set isAdmin to true
      end try
    end repeat
    if not isAdmin then
      repeat with t in tabs of w
        try
          if (URL of t) contains "slop.computer" then
            set end of idsToClose to (id of w)
            exit repeat
          end if
        end try
      end repeat
    end if
  end repeat
  repeat with wid in idsToClose
    try
      close (first window whose id is (contents of wid))
    end try
  end repeat
end tell
EOF
# Open as tabs in ONE new window (binary launch lands in your main Chrome).
# On desktop 1 first: a new window is born on whatever desktop is active, and this
# one has to be alone on desktop 1 so flipping to the dashboards never covers it.
goto_desktop 1
"$CHROME" --new-window "${CONTROL_URLS[@]}" >/dev/null 2>&1 &
disown
sleep 3

# ── PREFLIGHT: is AppleScript actually talking to MAIN Chrome? ──────────────────
# 'tell application "Google Chrome"' addresses a bundle id, and several Chrome
# instances share it (the slop fg/bg/mon profiles, plus clawd-scheduler and
# clawd-scribe automation profiles this script never kills). When it routes to
# one of those, every 'set bounds' below runs against a browser that has none of
# these windows: no match, no error, nothing in the log, and every window is left
# wherever Chrome happened to cascade it. That failure is invisible unless we
# look for it, so look for it: we just opened a slop.computer window in main
# Chrome, so if AppleScript cannot see one, it is not talking to main Chrome.
SEES_CONTROL=$(osascript 2>>/tmp/slop-chrome-osa.log <<'EOF'
tell application "Google Chrome"
  repeat with w in windows
    repeat with t in tabs of w
      try
        if (URL of t) contains "slop.computer" then return "yes"
      end try
    end repeat
  end repeat
  return "no"
end tell
EOF
)
if [ "$SEES_CONTROL" != "yes" ]; then
  echo ""
  echo "  ##############################################################"
  echo "  ## AppleScript is NOT talking to your main Chrome.          ##"
  echo "  ## Every window placement below will silently do nothing    ##"
  echo "  ## and windows will land wherever Chrome cascades them.     ##"
  echo "  ##                                                          ##"
  echo "  ## Cause: another Chrome instance shares the bundle id.      ##"
  echo "  ## Live --user-data-dir instances right now:                ##"
  ps aux | grep "Google Chrome.app/Contents/MacOS/Google Chrome" | grep -v grep \
    | grep -oE -- "--user-data-dir=[^ ]*" | sort -u | sed 's/^/  ##   /'
  echo "  ## Quit those (or the automation profiles using them) and    ##"
  echo "  ## re-run. Continuing anyway — expect a wrong layout.        ##"
  echo "  ##############################################################"
  echo ""
fi
# Position that window (match the window holding the slop.computer tabs).
# Skip /admin windows for the same reason the de-dupe does — otherwise the admin
# windows on desktop 2 get yanked onto the main display at CONTROL_BOUNDS.
osascript >>/tmp/slop-chrome-osa.log 2>&1 <<EOF
tell application "Google Chrome"
  repeat with w in windows
    set isAdmin to false
    repeat with t in tabs of w
      try
        if (URL of t) contains "slop.computer/admin" then set isAdmin to true
      end try
    end repeat
    if not isAdmin then
      repeat with t in tabs of w
        try
          if (URL of t) contains "slop.computer" then
            set bounds of w to {$CONTROL_BOUNDS}
            exit repeat
          end if
        end try
      end repeat
    end if
  end repeat
end tell
EOF

# ── DESKTOP 2: YouTube Studio (Canary) + X producer (main Chrome) ───────────────
# Both live on the SECOND Spaces desktop of the main display. macOS has no API to
# move an existing window to another Space, but NEW windows open on the ACTIVE
# Space — so: hop to desktop 2 (ctrl-→), open whichever is missing, position it,
# hop back (ctrl-←). If a window is already up (e.g. a re-run mid-stream), it is
# ONLY repositioned, never closed — closing a live producer/stream dashboard
# would be a disaster. This runs here, while main Chrome is the only instance,
# for the same AppleScript-routing reason as the control window above.
# The space hop math reads com.apple.spaces for the current desktop index and
# falls back to "assume desktop 1" if that lookup fails.
YT_URL="https://studio.youtube.com/channel/UC_HI2i2peo1A-STdG22GFsA/livestreaming/manage"
X_URL="https://studio.x.com/live"     # was /producer — rig was on Live Studio 2026-08-07
CANARY="/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary"
CANARY_BOUNDS="38, 99, 1340, 1334"    # recaptured 2026-08-08 (1302x1235 at 38,99)
XPROD_BOUNDS="296, 41, 1652, 1140"    # recaptured 2026-08-08 (1356x1099 at 296,41)

# The two admin pages, added 2026-08-07. Austin scrolls these to the GO LIVE and
# fanout buttons, so once they exist they are only ever repositioned, never
# reopened. Stacked on the right of desktop 2. These started as guesses on
# 2026-08-07; Austin left them untouched through the 2026-08-08 pass, so they are
# now confirmed rather than assumed.
ADMIN_URL="https://slop.computer/admin"
LIVEADMIN_URL="https://live.slop.computer/admin"
ADMIN_BOUNDS="1400, 40, 2550, 700"
LIVEADMIN_BOUNDS="1400, 720, 2550, 1380"

echo "Bringing up YouTube Studio (Canary) + X Live Studio + both admins (desktop 2)..."
HAVE_YT="no"
if pgrep -f "Chrome Canary.app/Contents/MacOS/Google Chrome Canary" >/dev/null; then
  HAVE_YT=$(osascript 2>>/tmp/slop-chrome-osa.log <<'EOF'
tell application "Google Chrome Canary"
  repeat with w in windows
    repeat with t in tabs of w
      try
        if (URL of t) contains "studio.youtube.com" then return "yes"
      end try
    end repeat
  end repeat
  return "no"
end tell
EOF
  )
fi
HAVE_X=$(osascript 2>>/tmp/slop-chrome-osa.log <<'EOF'
tell application "Google Chrome"
  repeat with w in windows
    repeat with t in tabs of w
      try
        if (URL of t) contains "studio.x.com" then return "yes"
      end try
    end repeat
  end repeat
  return "no"
end tell
EOF
)
# "live.slop.computer/admin" contains "slop.computer/admin" as a substring, so the
# plain admin check has to explicitly reject the live one or they collapse together.
HAVE_ADMIN=$(osascript 2>>/tmp/slop-chrome-osa.log <<'EOF'
tell application "Google Chrome"
  repeat with w in windows
    repeat with t in tabs of w
      try
        if (URL of t) contains "slop.computer/admin" and (URL of t) does not contain "live.slop.computer" then return "yes"
      end try
    end repeat
  end repeat
  return "no"
end tell
EOF
)
HAVE_LIVEADMIN=$(osascript 2>>/tmp/slop-chrome-osa.log <<'EOF'
tell application "Google Chrome"
  repeat with w in windows
    repeat with t in tabs of w
      try
        if (URL of t) contains "live.slop.computer/admin" then return "yes"
      end try
    end repeat
  end repeat
  return "no"
end tell
EOF
)

if [ "$HAVE_YT" != "yes" ] || [ "$HAVE_X" != "yes" ] \
   || [ "$HAVE_ADMIN" != "yes" ] || [ "$HAVE_LIVEADMIN" != "yes" ]; then
  goto_desktop 2
  sleep 0.5
  [ "$HAVE_YT" != "yes" ] && { "$CANARY" --new-window "$YT_URL" >/dev/null 2>&1 & disown; }
  [ "$HAVE_X"  != "yes" ] && { "$CHROME" --new-window "$X_URL"  >/dev/null 2>&1 & disown; }
  # Stagger the two admins: launched back-to-back, Chrome sometimes folds the
  # second into the first window as a tab instead of making a new window.
  [ "$HAVE_ADMIN"     != "yes" ] && { "$CHROME" --new-window "$ADMIN_URL"     >/dev/null 2>&1 & disown; sleep 2; }
  [ "$HAVE_LIVEADMIN" != "yes" ] && { "$CHROME" --new-window "$LIVEADMIN_URL" >/dev/null 2>&1 & disown; }
  sleep 4
  # Back to desktop 1, where the show window lives — this is also the desktop the
  # run should end on, so the projected window is what is in front when it's done.
  goto_desktop 1
fi

# Position both (works whether they were just opened or already up).
osascript >>/tmp/slop-chrome-osa.log 2>&1 <<EOF
tell application "Google Chrome Canary"
  repeat with w in windows
    repeat with t in tabs of w
      try
        if (URL of t) contains "studio.youtube.com" then
          set bounds of w to {$CANARY_BOUNDS}
          exit repeat
        end if
      end try
    end repeat
  end repeat
end tell
EOF
osascript >>/tmp/slop-chrome-osa.log 2>&1 <<EOF
tell application "Google Chrome"
  repeat with w in windows
    repeat with t in tabs of w
      try
        if (URL of t) contains "studio.x.com" then
          set bounds of w to {$XPROD_BOUNDS}
          exit repeat
        end if
      end try
    end repeat
  end repeat
end tell
EOF
# Both admins. Repositioning preserves scroll, so the GO LIVE / fanout buttons
# stay where they were left.
osascript >>/tmp/slop-chrome-osa.log 2>&1 <<EOF
tell application "Google Chrome"
  repeat with w in windows
    repeat with t in tabs of w
      try
        if (URL of t) contains "slop.computer/admin" and (URL of t) does not contain "live.slop.computer" then
          set bounds of w to {$ADMIN_BOUNDS}
          exit repeat
        end if
      end try
    end repeat
  end repeat
end tell
EOF
osascript >>/tmp/slop-chrome-osa.log 2>&1 <<EOF
tell application "Google Chrome"
  repeat with w in windows
    repeat with t in tabs of w
      try
        if (URL of t) contains "live.slop.computer/admin" then
          set bounds of w to {$LIVEADMIN_BOUNDS}
          exit repeat
        end if
      end try
    end repeat
  end repeat
end tell
EOF

# ── VERIFY the placements actually took ─────────────────────────────────────────
# Every failure mode so far has been silent: AppleScript no-ops against the wrong
# Chrome, or a window opens on whichever display has focus and is never moved. So
# rather than trust 'set bounds', check with Quartz whether a window is really at
# each rect and say plainly which ones are not.
python3 - "$CONTROL_BOUNDS" "$CANARY_BOUNDS" "$XPROD_BOUNDS" "$ADMIN_BOUNDS" "$LIVEADMIN_BOUNDS" <<'PYEOF'
import sys, Quartz
NAMES = ["control window", "YouTube Studio", "X Live Studio",
         "slop.computer/admin", "live.slop.computer/admin"]
TOL = 12
rects = []
for a in sys.argv[1:6]:
    l, t, r, b = [int(v.strip()) for v in a.split(",")]
    rects.append((l, t, r - l, b - t))
wins = []
for w in Quartz.CGWindowListCopyWindowInfo(
        Quartz.kCGWindowListOptionAll | Quartz.kCGWindowListExcludeDesktopElements,
        Quartz.kCGNullWindowID):
    if w.get("kCGWindowLayer", 0) != 0:
        continue
    if not (w.get("kCGWindowOwnerName") or "").startswith("Google Chrome"):
        continue
    b = w.get("kCGWindowBounds") or {}
    wins.append((b.get("X", 0), b.get("Y", 0), b.get("Width", 0), b.get("Height", 0)))
# Windows sitting on a background Space get their X reported thousands of pixels
# to the left (one main-display width per Space), while Y, width and height stay
# true. Since the admins and both studio dashboards are SUPPOSED to be on desktop
# 2, matching on X would flag every one of them on a perfectly good run. So match
# size + Y, and treat X as advisory.
missing = []
for name, (x, y, ww, hh) in zip(NAMES, rects):
    same_shape = [a for a, bb, c, d in wins
                  if abs(c - ww) <= TOL and abs(d - hh) <= TOL and abs(bb - y) <= TOL]
    if not same_shape:
        missing.append(f"{name}  (expected {ww}x{hh} at y={y})")
if missing:
    print("  !! these windows are NOT the size/position the script asked for:")
    for m in missing:
        print(f"       - {m}")
    print("     Most likely AppleScript hit the wrong Chrome, or the window opened")
    print("     on whichever display had focus. Move them by hand, then run")
    print("     slop-capture.py so the rects can be corrected.")
else:
    print("  all Chrome window placements verified.")
PYEOF

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
# Also re-points the teleprompter scene's screen capture at the control window
# (its window ID rotates every launch), enforces SaveProjectors=true, and makes
# sure the teleprompter fullscreen projector (CF15T) + a6400 windowed projector
# are in saved_projectors so OBS reopens them on start.
echo "Patching OBS Rig2 scene (sloptubefront / sloptuberender / teleprompter)..."
python3 "$DIR/slop-obs-patch.py" "$FG_PID" "$BG_PID" --teleprompter "$CONTROL_BOUNDS" || { echo "Patch failed — are both windows open?"; }

# ── LAUNCH OBS-SLOP (reads the patched scene) ───────────────────────────────────
echo "Launching OBS-SLOP..."
open "$HOME/Desktop/OBS-SLOP.app"
# Wait for OBS's window to exist, then move/resize it to where you want it.
# (OBS isn't AppleScript-scriptable, so we drive it via System Events.)
OBS_POS="-1528, -1074"    # LG top band, portrait
OBS_SIZE="1280, 992"      # resized by hand 2026-08-08
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

echo ""
echo "SLOP rig up."
echo "  • OBS sources: sloptubefront → SLOPTUBE-FRONT,  sloptuberender → SLOPTUBE-BG"
echo "  • teleprompter scene → slop.computer control window; projector on CF15T"
echo "  • Hand monitor window open (hands.html)"
echo "  • Desktop 2: YouTube Studio (Canary) + X Live Studio + slop.computer/admin + live.slop.computer/admin"
echo "  • Guest room (live.slop.computer/<slug>) is still opened by hand"
echo ""

# ── POSITION THIS iTerm WINDOW next to the capture region ───────────────────────
osascript -e "tell application \"iTerm2\" to set bounds of current window to {$ITERM_BOUNDS}" 2>/dev/null || true

# ── KICK EVERYTHING OFF: run the hand detector in THIS terminal (foreground) ────
# Reads the OBS Source projector of the clean camera feed (e.g. "Projector -
# Source: a6400 HDMI") and POSTs hand landmarks to the relay. Auto-retries until
# that projector window exists, so:
#   • Open the camera source's Windowed Projector once, and enable OBS → Settings →
#     General → "Save projectors on exit" so OBS reopens it automatically.
# Title filter is "Source" (not "Projector"): OBS also restores "Projector -
# Preview" windows, and a phantom one from a missing display once out-sized the
# real feed and delivered zero frames — Source projectors match, Preview never.
# Ctrl-C here stops the detector. Closing this window ends the session's hand input.
if [ -x "$DIR/slop-detector" ]; then
  echo "Starting hand detector in this terminal (Ctrl-C to stop)..."
  exec "$DIR/slop-detector" OBS "Source"
else
  echo "slop-detector not built — hand detection won't run."
fi
