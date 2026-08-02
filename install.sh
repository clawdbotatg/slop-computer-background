#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
# install.sh — set up the SLOP rig on this Mac from a fresh clone.
# ═══════════════════════════════════════════════════════════════════════════════
#
#   git clone https://github.com/clawdbotatg/slop-computer-background.git
#   cd slop-computer-background && ./install.sh [path/to/service.json]
#
# Installs:
#   • SLOP.app + OBS-SLOP.app          -> ~/Desktop (launcher path baked in)
#   • OBS profile "Rig2"               -> ~/Library/Application Support/obs-studio
#   • OBS scene collection "Rig2"      -> (cockpit mp4 path resolved to this repo)
#   • RTMP credentials (service.json)  -> NEVER in git. Sourced from, in order:
#       1. an already-installed service.json with a real key (kept as-is)
#       2. the [path/to/service.json] argument
#       3. auto-detected /Volumes/*/slop-rig-creds/service.json (the creds USB)
#       4. interactive prompt for the stream key
#
# Idempotent: run it again any time; it won't clobber your stream key.
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RIG="$REPO_DIR/rig"
OBS_BASE="$HOME/Library/Application Support/obs-studio/basic"
PROFILE_DIR="$OBS_BASE/profiles/Rig2"
SCENE_FILE="$OBS_BASE/scenes/Rig2.json"
SERVICE_FILE="$PROFILE_DIR/service.json"
KEY_PLACEHOLDER="__STREAM_KEY__"

if pgrep -f "OBS.app/Contents/MacOS/OBS" >/dev/null 2>&1; then
  echo "!! OBS is running — quit it first (it rewrites its config on exit and"
  echo "   would clobber what this script installs)."
  exit 1
fi

# ── 1. Apps -> Desktop ─────────────────────────────────────────────────────────
echo "Installing SLOP.app + OBS-SLOP.app to ~/Desktop..."
for APP in SLOP OBS-SLOP; do
  rm -rf "$HOME/Desktop/$APP.app"
  ditto "$RIG/apps/$APP.app" "$HOME/Desktop/$APP.app"
done
# bake this repo's location into the SLOP launcher
sed -i '' "s|__REPO_DIR__|$REPO_DIR|g" "$HOME/Desktop/SLOP.app/Contents/MacOS/launcher"
chmod +x "$HOME/Desktop/SLOP.app/Contents/MacOS/launcher" \
         "$HOME/Desktop/OBS-SLOP.app/Contents/MacOS/launcher"
xattr -cr "$HOME/Desktop/SLOP.app" "$HOME/Desktop/OBS-SLOP.app" 2>/dev/null || true

# ── 2. OBS profile ─────────────────────────────────────────────────────────────
echo "Installing OBS profile Rig2..."
mkdir -p "$PROFILE_DIR" "$OBS_BASE/scenes"
sed "s|__HOME__|$HOME|g" "$RIG/obs/profiles/Rig2/basic.ini" > "$PROFILE_DIR/basic.ini"
cp "$RIG/obs/profiles/Rig2/streamEncoder.json" "$PROFILE_DIR/streamEncoder.json"

# ── 3. Stream credentials (the one secret — never in git) ──────────────────────
CREDS_SRC=""
if [ -f "$SERVICE_FILE" ] && ! grep -q "$KEY_PLACEHOLDER" "$SERVICE_FILE"; then
  echo "Keeping existing stream credentials ($SERVICE_FILE)."
else
  if [ -n "${1:-}" ] && [ -f "${1:-}" ]; then
    CREDS_SRC="$1"
  else
    for f in /Volumes/*/slop-rig-creds/service.json; do
      [ -f "$f" ] && CREDS_SRC="$f" && break
    done
  fi
  if [ -n "$CREDS_SRC" ]; then
    echo "Installing stream credentials from $CREDS_SRC"
    cp "$CREDS_SRC" "$SERVICE_FILE"
  else
    echo ""
    echo "No credentials found (no arg, no creds USB mounted)."
    read -r -p "Paste the RTMP stream key (from the old machine's service.json): " STREAM_KEY
    if [ -z "$STREAM_KEY" ]; then
      echo "!! No key entered — installing placeholder; streaming will NOT work"
      echo "   until you set it in OBS (Settings -> Stream) or re-run install.sh."
      STREAM_KEY="$KEY_PLACEHOLDER"
    fi
    # keys contain & and ? — build the JSON with python, not sed
    STREAM_KEY="$STREAM_KEY" python3 - "$RIG/obs/profiles/Rig2/service.json.template" "$SERVICE_FILE" <<'PY'
import json, os, sys
data = json.load(open(sys.argv[1]))
data["settings"]["key"] = os.environ["STREAM_KEY"]
json.dump(data, open(sys.argv[2], "w"))
PY
  fi
fi

# ── 4. Scene collection ────────────────────────────────────────────────────────
echo "Installing OBS scene collection Rig2..."
if [ -f "$SCENE_FILE" ]; then
  cp "$SCENE_FILE" "$SCENE_FILE.pre-install.bak"
  echo "  (existing scene backed up to Rig2.json.pre-install.bak)"
fi
sed "s|__COCKPIT_MP4__|$RIG/assets/cockpitvid.mp4|g" \
  "$RIG/obs/scenes/Rig2.json.template" > "$SCENE_FILE"

# ── 5. Done + the per-machine checklist ────────────────────────────────────────
cat <<CHECKLIST

✔ Installed. Before the first run of SLOP.app on a NEW machine:

  1. Install if missing: Google Chrome, OBS, iTerm2,
     Xcode CLT (xcode-select --install), and pyobjc:
       pip3 install pyobjc-framework-Quartz
  2. System Settings -> Privacy & Security -> Screen Recording: add iTerm2.
     (Accessibility for iTerm2 too, when prompted.)
  3. First run: click "Allow" on the camera prompt in the foreground
     window — the isolated Chrome profile remembers it forever.
  4. Open OBS via OBS-SLOP.app once and re-pick machine-specific sources:
     "a6400 HDMI" capture device and the Syphon client. Open a Windowed
     Projector on the camera source and enable Settings -> General ->
     "Save projectors on exit" (the hand detector reads that projector).
  5. Window positions in slop-setup.sh were captured on the original
     monitor layout. Place windows where you want, then run
       bash $REPO_DIR/slop-setup.sh --capture
     and copy the bounds into the CONFIG block of slop-setup.sh.

Then: double-click SLOP.app.
CHECKLIST
