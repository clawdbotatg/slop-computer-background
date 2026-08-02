#!/usr/bin/env python3
"""
Patch the SLOP (Rig2) OBS scene JSON with the foreground/background window IDs.

    slop-obs-patch.py <foreground_pid> <background_pid> [--teleprompter "L, T, R, B"]

fg/bg match by OWNER PID, not window title:
The foreground/background run in their own isolated Chrome instances (separate
--user-data-dir), so each has a distinct PID. CGWindowListCopyWindowInfo gives
each window's owner PID and window NUMBER (== the CGWindowID OBS stores) with NO
special permission — no Screen Recording, no title matching, no iTerm needed.
(kCGWindowName/title is the only field that needs Screen Recording; we don't use it.)

--teleprompter re-points the teleprompter scene's "macOS Screen Capture" source
at the slop.computer control window in MAIN Chrome. Main Chrome owns many
windows under one PID, so matching goes:
  1. the window sitting at CONTROL_BOUNDS (slop-setup.sh has already positioned
     it there by the time this runs) — pass the same "{left, top, right,
     bottom}" string as the rect argument;
  2. fallback: the NEWEST big main-Chrome window (CGWindowIDs increase
     monotonically; the control window was created seconds ago). "Big" filters
     out popups the admin tabs may spawn (a 320x238 wallet popup once stole
     the match here).
Windows of the isolated slop Chrome instances (--user-data-dir=~/.slop-chrome-*)
are excluded by inspecting each owner PID's command line.

Also enforced on every run (all of this only sticks while OBS is CLOSED):
  • SaveProjectors=true in obs-studio/user.ini — without it OBS neither
    restores saved projectors on launch nor saves them on exit, which silently
    kills both the hand detector's source projector and the CF15T teleprompter.
  • saved_projectors entries for the "teleprompter" fullscreen scene projector
    (CF15T) and the "a6400 HDMI" windowed source projector (the hand detector
    reads that one). Existing entries are left alone (so you can reposition
    them); they're only re-added if missing.

MUST run while OBS is CLOSED, or OBS overwrites the edit on its next save.
"""

import json, os, re, subprocess, sys, time
import Quartz

OBS_SCENE = os.path.expanduser("~/Library/Application Support/obs-studio/basic/scenes/Rig2.json")
OBS_USER_INI = os.path.expanduser("~/Library/Application Support/obs-studio/user.ini")
TELE_SOURCE = "macOS Screen Capture"   # the capture source inside the teleprompter scene
BOUNDS_TOL = 12                        # px slack when matching the control window

# Known-good saved-projector snapshots (captured 2026-08-02 on this machine's
# monitor layout: monitor 1 == CF15T 1920x1080). Only used when the entry has
# gone missing from the scene JSON — e.g. the projector was closed before OBS
# exited, so OBS saved the collection without it.
PROJECTOR_DEFAULTS = [
    {
        "name": "a6400 HDMI",
        "monitor": -1,   # windowed Source projector — the hand detector reads it
        "type": 0,
        "geometry": "AdnQywADAAD///gtAAAFb///+gwAAAad///4LQAABY////oMAAAGnQAAAAIAAAAACgD///gtAAAFj///+gwAAAad",
        "alwaysOnTopOverridden": False,
    },
    {
        "name": "teleprompter",
        "monitor": 1,    # fullscreen Scene projector on the CF15T
        "type": 1,
        "geometry": "AdnQywADAAAAAAoAAAABaAAAEX8AAAWfAAAKAAAAAWgAABF/AAAFnwAAAAEABAAAB4AAAAoAAAABaAAAEX8AAAWf",
        "alwaysOnTopOverridden": False,
    },
]

if len(sys.argv) < 3:
    print("usage: slop-obs-patch.py <foreground_pid> <background_pid> [--teleprompter 'L, T, R, B']")
    sys.exit(2)
FRONT_PID  = int(sys.argv[1])
RENDER_PID = int(sys.argv[2])
TARGETS = {"sloptubefront": FRONT_PID, "sloptuberender": RENDER_PID}  # source -> pid

TELE_RECT = None  # (x, y, w, h) of the control window, from --teleprompter
if "--teleprompter" in sys.argv:
    raw = sys.argv[sys.argv.index("--teleprompter") + 1]
    l, t, r, b = [int(v) for v in re.split(r"[,\s]+", raw.strip()) if v]
    TELE_RECT = (l, t, r - l, b - t)

def window_list():
    return Quartz.CGWindowListCopyWindowInfo(
        Quartz.kCGWindowListOptionOnScreenOnly, Quartz.kCGNullWindowID)

def find_window_ids():
    """Return {source_name: window_number} — the largest normal-layer window per pid."""
    best = {}  # pid -> (area, window_number)
    for w in window_list():
        if w.get("kCGWindowLayer", 0) != 0:      # skip menubars/overlays
            continue
        pid = w.get("kCGWindowOwnerPID")
        if pid not in (FRONT_PID, RENDER_PID):
            continue
        b = w.get("kCGWindowBounds") or {}
        area = (b.get("Width", 0) or 0) * (b.get("Height", 0) or 0)
        if area > best.get(pid, (0, None))[0]:
            best[pid] = (area, w.get("kCGWindowNumber"))
    return {name: best[pid][1] for name, pid in TARGETS.items() if pid in best}

def slop_chrome_pids():
    """PIDs of the isolated slop Chrome instances (fg/bg/mon profiles)."""
    try:
        out = subprocess.run(["pgrep", "-f", r"user-data-dir=.*\.slop-chrome"],
                             capture_output=True, text=True).stdout
        return {int(p) for p in out.split()}
    except Exception:
        return set()

def find_control_window():
    """The main-Chrome control window: at CONTROL_BOUNDS first, newest-big fallback."""
    if TELE_RECT is None:
        return None
    skip = slop_chrome_pids() | {FRONT_PID, RENDER_PID}
    x, y, wid, hgt = TELE_RECT
    at_rect, newest_big = None, None
    for w in window_list():
        if w.get("kCGWindowLayer", 0) != 0:
            continue
        if w.get("kCGWindowOwnerName") != "Google Chrome":
            continue
        if w.get("kCGWindowOwnerPID") in skip:
            continue
        b = w.get("kCGWindowBounds") or {}
        n = w.get("kCGWindowNumber")
        if (abs(b.get("X", 1e9) - x) <= BOUNDS_TOL and abs(b.get("Y", 1e9) - y) <= BOUNDS_TOL
                and abs(b.get("Width", 0) - wid) <= BOUNDS_TOL and abs(b.get("Height", 0) - hgt) <= BOUNDS_TOL):
            if at_rect is None or n > at_rect:
                at_rect = n
        if b.get("Width", 0) >= 700 and b.get("Height", 0) >= 500:
            if newest_big is None or n > newest_big:
                newest_big = n
    return at_rect if at_rect is not None else newest_big

def patch(window_ids, tele_id):
    with open(OBS_SCENE) as f:
        data = json.load(f)
    if tele_id is not None:
        window_ids = dict(window_ids, **{TELE_SOURCE: tele_id})
    for source in data.get("sources", []):
        name = source.get("name")
        if name in window_ids:
            old = source["settings"].get("window")
            source["settings"]["window"] = window_ids[name]
            source["settings"]["type"] = 1  # window capture
            print(f"  {name}: {old} -> {window_ids[name]}")
    projectors = data.setdefault("saved_projectors", [])
    have = {(p.get("name"), p.get("type")) for p in projectors}
    for dflt in PROJECTOR_DEFAULTS:
        if (dflt["name"], dflt["type"]) not in have:
            projectors.append(dict(dflt))
            print(f"  saved_projectors: re-added {dflt['name']!r} (monitor {dflt['monitor']})")
    with open(OBS_SCENE, "w") as f:
        json.dump(data, f, indent=4)

def enforce_user_ini():
    """SaveProjectors=true — else OBS won't reopen projectors on launch.
    ConfirmOnExit=false — the exit dialog blocks slop-setup's 'quit OBS' step
    forever (AppleScript quit never returns while the dialog is up)."""
    try:
        with open(OBS_USER_INI) as f:
            ini = f.read()
    except FileNotFoundError:
        print(f"  !! {OBS_USER_INI} not found — skipping user.ini checks")
        return
    changed = False
    for section, key, val in (("BasicWindow", "SaveProjectors", "true"),
                              ("General", "ConfirmOnExit", "false")):
        if re.search(rf"^{key}={val}$", ini, flags=re.M):
            continue
        if re.search(rf"^{key}=.*$", ini, flags=re.M):
            ini = re.sub(rf"^{key}=.*$", f"{key}={val}", ini, flags=re.M)
        elif f"[{section}]" in ini:
            ini = ini.replace(f"[{section}]", f"[{section}]\n{key}={val}", 1)
        else:
            ini += f"\n[{section}]\n{key}={val}\n"
        changed = True
        print(f"  user.ini: {key} -> {val}")
    if changed:
        with open(OBS_USER_INI, "w") as f:
            f.write(ini)

if __name__ == "__main__":
    ids, tele_id = {}, None
    for attempt in range(10):
        ids = find_window_ids()
        tele_id = find_control_window()
        missing = [s for s in TARGETS if s not in ids]
        if TELE_RECT is not None and tele_id is None:
            missing.append("teleprompter/control")
        if not missing:
            break
        print(f"  attempt {attempt+1}/10: waiting for windows: {missing}...")
        time.sleep(2)
    if any(s not in ids for s in TARGETS):
        print("\nERROR: no on-screen window found for: " +
              ", ".join(f"{s} (pid {TARGETS[s]})" for s in TARGETS if s not in ids))
        sys.exit(1)
    if TELE_RECT is not None and tele_id is None:
        print("  !! control window not found at CONTROL_BOUNDS — teleprompter capture NOT re-pointed")
    print("Patching Rig2 (SLOP) scene JSON:")
    patch(ids, tele_id)
    enforce_user_ini()
    print("Done.")
