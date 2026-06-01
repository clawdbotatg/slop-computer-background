#!/usr/bin/env python3
"""
Patch the SLOP (Rig2) OBS scene JSON with the foreground/background window IDs.

Matches by OWNER PID, not window title:
    slop-obs-patch.py <foreground_pid> <background_pid>

The foreground/background run in their own isolated Chrome instances (separate
--user-data-dir), so each has a distinct PID. CGWindowListCopyWindowInfo gives
each window's owner PID and window NUMBER (== the CGWindowID OBS stores) with NO
special permission — no Screen Recording, no title matching, no iTerm needed.
(kCGWindowName/title is the only field that needs Screen Recording; we don't use it.)

MUST run while OBS is CLOSED, or OBS overwrites the edit on its next save.
"""

import json, os, sys, time
import Quartz

OBS_SCENE = os.path.expanduser("~/Library/Application Support/obs-studio/basic/scenes/Rig2.json")

if len(sys.argv) < 3:
    print("usage: slop-obs-patch.py <foreground_pid> <background_pid>")
    sys.exit(2)
FRONT_PID  = int(sys.argv[1])
RENDER_PID = int(sys.argv[2])
TARGETS = {"sloptubefront": FRONT_PID, "sloptuberender": RENDER_PID}  # source -> pid

def find_window_ids():
    """Return {source_name: window_number} — the largest normal-layer window per pid."""
    wins = Quartz.CGWindowListCopyWindowInfo(
        Quartz.kCGWindowListOptionOnScreenOnly, Quartz.kCGNullWindowID)
    best = {}  # pid -> (area, window_number)
    for w in wins:
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

def patch(window_ids):
    with open(OBS_SCENE) as f:
        data = json.load(f)
    for source in data.get("sources", []):
        name = source.get("name")
        if name in window_ids:
            old = source["settings"].get("window")
            source["settings"]["window"] = window_ids[name]
            source["settings"]["type"] = 1  # window capture
            print(f"  {name}: {old} -> {window_ids[name]}  (pid {TARGETS[name]})")
    with open(OBS_SCENE, "w") as f:
        json.dump(data, f, indent=4)

if __name__ == "__main__":
    ids = {}
    for attempt in range(10):
        ids = find_window_ids()
        missing = [s for s in TARGETS if s not in ids]
        if not missing:
            break
        print(f"  attempt {attempt+1}/10: waiting for windows of pids {[TARGETS[s] for s in missing]}...")
        time.sleep(2)
    missing = [s for s in TARGETS if s not in ids]
    if missing:
        print(f"\nERROR: no on-screen window found for: " +
              ", ".join(f"{s} (pid {TARGETS[s]})" for s in missing))
        sys.exit(1)
    print("Patching Rig2 (SLOP) scene JSON by PID:")
    patch(ids)
    print("Done.")
