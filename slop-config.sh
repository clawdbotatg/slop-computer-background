# slop-config.sh — shared config for slop-setup.sh (full rig) and slop-lite.sh
# (mid-call recovery). Sourced, not run. One copy of the geometry so the two
# scripts can never drift apart.
#
# Window positions were captured from where you placed them; to recapture, run
#   bash slop-setup.sh --capture
# and copy the bounds back in here.

PORT=9911
BASE="http://localhost:${PORT}"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
PROFILE_FG="$HOME/.slop-chrome-fg"
PROFILE_BG="$HOME/.slop-chrome-bg"
PROFILE_MON="$HOME/.slop-chrome-mon"   # the hands.html monitor window (its own killable profile)

# Per-window size + position (top-left x,y).
# Foreground is intentionally a touch taller than the background.
FG_X=-2430; FG_Y=454; FG_W=1280; FG_H=766
BG_X=-2495; BG_Y=409; BG_W=1280; BG_H=748
# hands.html monitor — where you placed it
MON_X=-2548; MON_Y=1181; MON_W=960; MON_H=560
# iTerm window (running the setup script + the detector) — SLOP.app's launcher
# hardcodes the same bounds
ITERM_BOUNDS="-2549, 537, -1930, 1067"

# slop.computer control window (4 tabs in ONE main-Chrome window): {L, T, R, B}
CONTROL_BOUNDS="166, 371, 1698, 1247"
CONTROL_URLS=(
  "https://slop.computer/"
  "https://slop.computer/admin"
  "https://slop.computer/checklist"
  "https://live.slop.computer/admin"
)
