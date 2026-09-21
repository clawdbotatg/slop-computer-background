# slop-config.sh — shared config for slop-setup.sh (full rig) and slop-lite.sh
# (mid-call recovery). Sourced, not run. One copy of the geometry so the two
# scripts can never drift apart.
#
# To recapture after re-arranging: python3 slop-capture.py (whole rig) or
# bash slop-setup.sh --capture (main-Chrome bounds only), then update here.

PORT=9911
BASE="http://localhost:${PORT}"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
PROFILE_FG="$HOME/.slop-chrome-fg"
PROFILE_BG="$HOME/.slop-chrome-bg"
PROFILE_MON="$HOME/.slop-chrome-mon"   # the hands.html monitor window (its own killable profile)

# The OBS window the hand detector reads: the Windowed Projector of the clean
# camera source ("Projector - Source: a6400 HDMI"). Substring match, and the
# detector takes the LARGEST matching window — so this has to name the source,
# not just "Source": on 2026-09-21 four "Projector - Source: macOS Screen
# Capture" windows (1920x1050) out-sized the camera projector (480x302) and the
# detector spent the day watching a black frame. Must match the source name in
# slop-obs-patch.py / the Rig2 scene.
# The detector sizes its capture ONCE at attach and never follows a resize: a
# projector shrunk afterwards gets painted top-left into the old, bigger buffer
# (black padding below) and every effect lands well ABOVE the hand (2026-09-21,
# ~30% north). Resize the projector, then re-run SLOP-Lite. The durable fix is
# normalizing by SCStreamFrameInfo.contentRect in slop-detector.swift — but a
# rebuild re-triggers the Screen Recording approval, so not on a show day.
DETECTOR_TITLE="Source: a6400 HDMI"

# Per-window size + position (top-left x,y), captured from where you placed them.
# Foreground is intentionally a touch taller than the background.
#
# Recaptured 2026-08-07 from the hand-arranged layout (see layout-2026-08-08-approved.txt).
# The LG went 5120x2880 -> 2160x3840 portrait @ -2160,-1301, so every LG-side Y
# moved a long way; the sizes barely changed. Displays at capture time:
#   LG M50QXM-K01  2160x3840 @ -2160,-1301   MAIN 2560x1440 @ 0,0   CF15T 1920x1080 @ 2560,360
FG_X=-2045; FG_Y=-1137; FG_W=1280; FG_H=766
# BG measured 1300x758, but 1280x748 is the 16:9-matched pair for FG that OBS is
# capturing (1280x720 inner + 28px chrome) — treating 1300 as drag-drift. If the
# background render looks letterboxed or cropped, this is the line to blame.
BG_X=-2132; BG_Y=-1197; BG_W=1280; BG_H=748
# hands.html monitor — where you placed it
MON_X=-2155; MON_Y=82; MON_W=960; MON_H=560
# iTerm window (running the setup/lite script + the detector) — the SLOP.app and
# SLOP-Lite.app launchers hardcode the same bounds
ITERM_BOUNDS="-2152, -572, -1533, -42"

# ── CONTROL WINDOW (main Chrome) ────────────────────────────────────────────────
# These URLs open as TABS in ONE main-Chrome window, positioned at {L, T, R, B}.
# This is the window the teleprompter captures. It lives ALONE on desktop 1 — the
# producer dashboards and both admins go on desktop 2, so flipping to desktop 2
# mid-show never disturbs what is being projected.
# Recaptured 2026-08-08 from Austin's hand placement (1943x1217 at 271,70).
# slop-obs-patch.py matches the control window by this exact rect and binds
# nothing if it does not find it, so this value has to stay true.
CONTROL_BOUNDS="271, 70, 2214, 1287"
# The two /admin pages used to be tabs here. They are now their own windows on
# desktop 2 (see ADMIN_* in slop-setup.sh) so they can sit scrolled to GO LIVE /
# fanout, and they MUST NOT be tabs here as well — the control-window de-dupe in
# slop-setup.sh skips any window holding an /admin tab, so leaving them would
# make the control window undeletable and every re-run would stack up a new one.
# The guest room (live.slop.computer/<slug>) is still opened by hand — the slug
# changes per episode.
CONTROL_URLS=(
  "https://slop.computer/"
  "https://slop.computer/checklist"
)
