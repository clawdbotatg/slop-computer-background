#!/usr/bin/env python3
"""
Re-point the Rig2 window captures at new fg/bg windows WHILE OBS IS RUNNING,
via obs-websocket (SetInputSettings). This is the mid-call companion to
slop-obs-patch.py, which edits the scene JSON and only works with OBS closed.

    slop-obs-live.py <foreground_pid> <background_pid>
    slop-obs-live.py --ping          # just check OBS websocket is reachable

Window lookup is the same PID -> largest-window trick as slop-obs-patch.py
(CGWindowListCopyWindowInfo needs no Screen Recording permission because we
never read titles).

The websocket port + password are read from OBS's own plugin config at
runtime (~/Library/Application Support/obs-studio/plugin_config/obs-websocket/
config.json) — never stored anywhere else.
"""

import asyncio, base64, hashlib, json, os, sys, time

OBS_WS_CONFIG = os.path.expanduser(
    "~/Library/Application Support/obs-studio/plugin_config/obs-websocket/config.json")
SOURCES = ("sloptubefront", "sloptuberender")  # fg, bg — order matches argv


def find_window_ids(front_pid, render_pid):
    """{source_name: window_number} — largest normal-layer window per pid."""
    import Quartz
    targets = {"sloptubefront": front_pid, "sloptuberender": render_pid}
    best = {}  # pid -> (area, window_number)
    for w in Quartz.CGWindowListCopyWindowInfo(
            Quartz.kCGWindowListOptionOnScreenOnly, Quartz.kCGNullWindowID):
        if w.get("kCGWindowLayer", 0) != 0:      # skip menubars/overlays
            continue
        pid = w.get("kCGWindowOwnerPID")
        if pid not in (front_pid, render_pid):
            continue
        b = w.get("kCGWindowBounds") or {}
        area = (b.get("Width", 0) or 0) * (b.get("Height", 0) or 0)
        if area > best.get(pid, (0, None))[0]:
            best[pid] = (area, w.get("kCGWindowNumber"))
    return {name: best[pid][1] for name, pid in targets.items() if pid in best}


def ws_config():
    cfg = json.load(open(OBS_WS_CONFIG))
    if not cfg.get("server_enabled"):
        raise RuntimeError("obs-websocket server_enabled is false")
    return cfg.get("server_port", 4455), cfg.get("server_password", "")


async def obs_session(work):
    """Connect + authenticate (obs-websocket v5), then run work(send_request)."""
    import websockets
    port, password = ws_config()
    async with websockets.connect(f"ws://127.0.0.1:{port}",
                                  subprotocols=["obswebsocket.json"],
                                  open_timeout=5, close_timeout=2) as ws:
        hello = json.loads(await asyncio.wait_for(ws.recv(), 5))
        identify = {"op": 1, "d": {"rpcVersion": 1}}
        auth = hello["d"].get("authentication")
        if auth:
            secret = base64.b64encode(hashlib.sha256(
                (password + auth["salt"]).encode()).digest())
            identify["d"]["authentication"] = base64.b64encode(hashlib.sha256(
                secret + auth["challenge"].encode()).digest()).decode()
        await ws.send(json.dumps(identify))
        identified = json.loads(await asyncio.wait_for(ws.recv(), 5))
        if identified.get("op") != 2:
            raise RuntimeError(f"obs-websocket auth failed: {identified}")

        async def request(req_type, req_data):
            """Returns (requestStatus, responseData)."""
            rid = f"slop-{time.time()}"
            await ws.send(json.dumps({"op": 6, "d": {
                "requestType": req_type, "requestId": rid,
                "requestData": req_data}}))
            while True:  # skip event messages (op 5) until our response
                msg = json.loads(await asyncio.wait_for(ws.recv(), 5))
                if msg.get("op") == 7 and msg["d"].get("requestId") == rid:
                    return (msg["d"]["requestStatus"],
                            msg["d"].get("responseData") or {})

        return await work(request)


async def ping(request):
    st, _ = await request("GetVersion", {})
    return st.get("result", False)


def main():
    if sys.argv[1:2] == ["--ping"]:
        ok = asyncio.run(obs_session(ping))
        print("obs-websocket: OK" if ok else "obs-websocket: request failed")
        sys.exit(0 if ok else 1)

    if len(sys.argv) < 3:
        print("usage: slop-obs-live.py <foreground_pid> <background_pid> | --ping")
        sys.exit(2)
    front_pid, render_pid = int(sys.argv[1]), int(sys.argv[2])

    ids = {}
    for attempt in range(10):
        ids = find_window_ids(front_pid, render_pid)
        if all(s in ids for s in SOURCES):
            break
        print(f"  attempt {attempt+1}/10: waiting for windows: "
              f"{[s for s in SOURCES if s not in ids]}...")
        time.sleep(2)
    missing = [s for s in SOURCES if s not in ids]
    if missing:
        print(f"ERROR: no on-screen window found for: {', '.join(missing)}")
        sys.exit(1)

    async def repoint(request):
        ok = True
        # Two passes with a bounce through window=0 in between: OBS's SCK
        # shareable-content list is a snapshot, and a window created seconds
        # ago is often missing from it — the first set then logs
        # "Invalid target window ID" and captures nothing. A couple of
        # seconds later the list has refreshed, and re-applying the same id
        # is a silent no-op, so bounce through 0 to force a real re-init.
        for round_ in range(2):
            for name in SOURCES:
                if round_:
                    await request("SetInputSettings", {
                        "inputName": name,
                        "inputSettings": {"type": 1, "window": 0},
                        "overlay": True})
                st, _ = await request("SetInputSettings", {
                    "inputName": name,
                    "inputSettings": {"type": 1, "window": ids[name]},
                    "overlay": True})
                if round_:
                    print(f"  {name} -> window {ids[name]}: "
                          f"{'ok' if st.get('result') else st}")
                    ok = ok and bool(st.get("result"))
            await asyncio.sleep(3)
        # Sanity: do the captures actually deliver pixels? A near-empty PNG
        # means SCK is handing OBS blank frames — on macOS 26 that is the
        # periodic screen-recording re-approval going stale (it broke the
        # whole rig on 2026-08-31 with "permission granted" still in the log).
        blank = []
        for name in SOURCES:
            _, data = await request("GetSourceScreenshot", {
                "sourceName": name, "imageFormat": "png", "imageWidth": 160})
            if len(data.get("imageData", "")) < 2000:  # blank/uniform 160px PNG
                blank.append(name)
        if blank:
            print(f"\n  !! {', '.join(blank)}: capture attached but OBS is "
                  "getting BLANK frames.")
            print("  !! Likely macOS screen-recording approval gone stale:")
            print("  !!   System Settings > Privacy & Security > Screen & System")
            print("  !!   Audio Recording > toggle OBS off/on, relaunch OBS.")
            print("  !!   (A reboot also clears it.)")
        return ok

    ok = asyncio.run(obs_session(repoint))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
