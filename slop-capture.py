#!/usr/bin/env python3
"""Snapshot the whole rig so a hand-arranged layout can be folded back into slop-setup.sh.

Read-only. Touches nothing, moves nothing. Run it once the rig is arranged the way
you want it:

    python3 ~/clawd/slop-computer-background/slop-capture.py

The `--capture` flag in slop-setup.sh only dumps main-Chrome window bounds. This also
covers the isolated fg/bg/mon Chrome instances, OBS, iTerm, which display each window
is on, and how OBS's capture sources and projectors are currently bound -- i.e. every
value that has to be typed back into the constants at the top of slop-setup.sh.

Window rects print twice, because the script needs both forms:
  xywh  -> Chrome --window-position/--window-size, and FG_*/BG_*/MON_*
  LTRB  -> AppleScript `bounds of window`, and ITERM_BOUNDS/CONTROL_BOUNDS
"""

import json
import os
import re
import subprocess
import sys

import Quartz

SCENES = os.path.expanduser(
    "~/Library/Application Support/obs-studio/basic/scenes/Rig2.json"
)
# Chrome instances slop-setup.sh launches, keyed by their --user-data-dir leaf.
SLOP_PROFILES = {".slop-chrome-fg": "FG", ".slop-chrome-bg": "BG", ".slop-chrome-mon": "MON"}


def displays():
    _, ids, cnt = Quartz.CGGetActiveDisplayList(16, None, None)
    out = []
    for d in ids[:cnt]:
        b = Quartz.CGDisplayBounds(d)
        out.append(
            {
                "id": int(d),
                "x": int(b.origin.x),
                "y": int(b.origin.y),
                "w": int(b.size.width),
                "h": int(b.size.height),
                "main": bool(Quartz.CGDisplayIsMain(d)),
            }
        )
    # Left-to-right, top-to-bottom: matches how OBS numbers monitors closely enough
    # to sanity-check a projector's "monitor" index, though never blindly trust it.
    return sorted(out, key=lambda d: (d["x"], d["y"]))


def which_display(win, disps):
    """Display holding the window's center, or None if it is off in the void."""
    cx, cy = win["x"] + win["w"] / 2, win["y"] + win["h"] / 2
    for d in disps:
        if d["x"] <= cx < d["x"] + d["w"] and d["y"] <= cy < d["y"] + d["h"]:
            return d
    return None


def cmdline(pid):
    try:
        return subprocess.run(
            ["ps", "-o", "command=", "-p", str(pid)],
            capture_output=True, text=True, timeout=5,
        ).stdout.strip()
    except Exception:
        return ""


def profile_tag(pid, cache={}):
    """FG/BG/MON if this pid is one of the isolated slop Chrome instances."""
    if pid not in cache:
        cl = cmdline(pid)
        m = re.search(r"--user-data-dir=\S*?/([^/\s]+)", cl)
        cache[pid] = SLOP_PROFILES.get(m.group(1)) if m else None
    return cache[pid]


def windows(show_all=False):
    wl = Quartz.CGWindowListCopyWindowInfo(
        Quartz.kCGWindowListOptionAll | Quartz.kCGWindowListExcludeDesktopElements,
        Quartz.kCGNullWindowID,
    )
    out = []
    for w in wl:
        if w.get("kCGWindowLayer", 0) != 0:
            continue
        b = w.get("kCGWindowBounds", {})
        x, y = int(b.get("X", 0)), int(b.get("Y", 0))
        ww, hh = int(b.get("Width", 0)), int(b.get("Height", 0))
        # Menu-bar strips and shadow helpers, not real windows.
        if ww < 200 or hh < 100:
            continue
        onscreen = bool(w.get("kCGWindowIsOnscreen", False))
        title = w.get("kCGWindowName", "") or ""
        # Untitled AND not visible == AutoFill/Spotlight/save-panel scaffolding that
        # every app leaves lying around. Real windows on other Spaces keep their title.
        if not show_all and not onscreen and not title:
            continue
        pid = w.get("kCGWindowOwnerPID", 0)
        out.append(
            {
                "id": w.get("kCGWindowNumber"),
                "owner": w.get("kCGWindowOwnerName", "?"),
                "pid": pid,
                "title": title,
                "x": x, "y": y, "w": ww, "h": hh,
                "onscreen": onscreen,
                "profile": profile_tag(pid),
            }
        )
    return out


def obs_state(by_id):
    if not os.path.exists(SCENES):
        return None, None
    d = json.load(open(SCENES))
    projectors = [
        {"name": p.get("name"), "monitor": p.get("monitor"), "type": p.get("type")}
        for p in d.get("saved_projectors", [])
    ]
    caps = []
    for s in d.get("sources", []):
        if "screen_capture" not in s.get("id", ""):
            continue
        wid = s.get("settings", {}).get("window")
        t = by_id.get(wid)
        caps.append(
            {
                "source": s.get("name"),
                "window_id": wid,
                "bound_to": f"{t['owner']} — {t['title']}" if t else "*** DEAD WINDOW ID ***",
            }
        )
    return projectors, caps


def main():
    show_all = "--all" in sys.argv
    disps = displays()
    wins = windows(show_all)
    by_id = {w["id"]: w for w in wins}

    print("=" * 78)
    print("DISPLAYS")
    print("=" * 78)
    for i, d in enumerate(disps):
        print(
            f"  [{i}] id={d['id']:<4} origin=({d['x']},{d['y']})  {d['w']}x{d['h']}"
            f"{'   <- MAIN' if d['main'] else ''}"
        )

    print()
    print("=" * 78)
    print("WINDOWS  (grouped by display; xywh for Chrome flags, LTRB for AppleScript)")
    print("=" * 78)
    groups = {}
    for w in wins:
        d = which_display(w, disps)
        groups.setdefault(d["id"] if d else None, []).append(w)

    for d in disps:
        rows = groups.get(d["id"], [])
        print(f"\n--- display id={d['id']}  ({d['w']}x{d['h']} @ {d['x']},{d['y']}) ---")
        if not rows:
            print("    (empty)")
        for w in sorted(rows, key=lambda r: (r["y"], r["x"])):
            tag = f" [{w['profile']}]" if w["profile"] else ""
            vis = "" if w["onscreen"] else "  (other Space / hidden)"
            print(f"  {w['owner']}{tag}: {w['title']!r}{vis}")
            print(
                f"      xywh: x={w['x']} y={w['y']} w={w['w']} h={w['h']}"
                f"      LTRB: {w['x']}, {w['y']}, {w['x'] + w['w']}, {w['y'] + w['h']}"
                f"      winid={w['id']}"
            )

    orphans = groups.get(None, [])
    if orphans:
        print("\n--- OFF-SCREEN (center outside every display) ---")
        for w in orphans:
            print(f"  {w['owner']}: {w['title']!r}  @ {w['x']},{w['y']} {w['w']}x{w['h']}")

    projectors, caps = obs_state(by_id)
    if projectors is None:
        print(f"\n(no OBS scene file at {SCENES})")
        return
    print()
    print("=" * 78)
    print("OBS  (Rig2.json — reflects last save; OBS rewrites this on quit)")
    print("=" * 78)
    print("\n  saved_projectors:")
    for p in projectors:
        kind = "scene" if p["type"] == 1 else "source"
        mon = "windowed" if p["monitor"] == -1 else f"monitor {p['monitor']}"
        print(f"    {p['name']!r} ({kind}) -> {mon}")
    print("\n  capture sources -> live window bindings:")
    for c in caps:
        print(f"    {c['source']!r}  (window {c['window_id']})  ->  {c['bound_to']}")


if __name__ == "__main__":
    sys.exit(main())
