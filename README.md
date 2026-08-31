# slop-computer-background

The SLOPTUBE streaming rig: everything needed to go from a fresh Mac to
double-clicking **SLOP.app** and getting the full OBS setup — foreground
(green-screen camera + hand detection) and background (tunnel render)
capture windows, the Rig2 OBS scene, the hands monitor, and the
slop.computer control tabs.

## Install on a new machine

```bash
git clone https://github.com/clawdbotatg/slop-computer-background.git ~/clawd/slop-computer-background
cd ~/clawd/slop-computer-background
./install.sh
```

`install.sh` copies `SLOP.app` + `OBS-SLOP.app` to the Desktop, installs
the OBS **Rig2** profile and scene collection, and sorts out the RTMP
stream credentials — the one thing that is **never in this (public)
repo**. It finds the key from an already-installed `service.json`, a
`service.json` you pass as an argument, a mounted USB stick with
`slop-rig-creds/service.json`, or an interactive prompt, in that order.
It also prints the per-machine checklist (permissions, camera grant,
OBS device re-picking, window-position capture). Re-running it is safe;
it never clobbers your stream key.

## What's what

| File | Role |
|---|---|
| `slop-setup.sh` | The bootstrapper SLOP.app runs in iTerm2 — kills stale instances, serves this folder on :9911, opens the capture windows, patches the scene, launches OBS, runs the detector |
| `slop-lite.sh` | Mid-call recovery, run by SLOP-Lite.app: restarts ONLY foreground + background + detector, re-pointing OBS live over obs-websocket (`slop-obs-live.py`) — OBS, main Chrome, control tabs and hands monitor untouched |
| `slop-config.sh` | Shared window geometry / ports / profiles, sourced by both scripts |
| `foreground.html` / `background.html` | The two 16:9 pages OBS window-captures |
| `hands.html` | Hand-landmark monitor window |
| `slop-server.py` | Static server + event relay (`/spawn`, `/events`, `/hands`) |
| `slop-obs-patch.py` | Rewrites the Rig2 scene's window-capture IDs by PID (needs pyobjc/Quartz; OBS must be closed) |
| `slop-obs-live.py` | Same re-point while OBS is RUNNING, via obs-websocket (needs the `websockets` pip package + OBS Tools → WebSocket Server enabled) |
| `slop-detector.swift` | Hand detector — reads the OBS source projector, POSTs landmarks; built automatically by `slop-setup.sh` |
| `rig/` | The installable payload: app bundles, OBS profile/scene templates, the cockpit mp4 |
| `install.sh` | New-machine setup (see above) |

## Secrets

`rig/obs/profiles/Rig2/service.json.template` has the stream key
blanked to `__STREAM_KEY__`. The real `service.json` is gitignored and
must never be committed — this repo is public.
