# The gesture eye — what lives in THIS repo

The full architecture doc is **`docs/GESTURES.md` in slop-computer-live**
(the relay + renderer live there). This repo holds the native half and the
operational scripts. Read the live-repo doc before changing anything; it
includes three failed architectures and why they failed.

## TL;DR

One native detector on the **god-mode machine** watches an effects-free
browser window of the room (`?fx=0`, titled `SLOP-EYE`) and streams hand
landmarks to the relay. The relay figures out whose camera window each hand
is over and broadcasts the effects. Everyone on the show — host and guests —
triggers gestures with zero setup.

- **One-time god-machine install:** `./slop-eye-install.sh` (interactive
  Terminal — it must show the macOS Screen Recording prompt). Installs
  slop-detector as an always-on launchd agent (`com.slop.eye`).
- **Per show:** click **👁** in the god-mode menu bar. Nothing else.
- **Kill switch:** close the 👁 window.
- **Manual/test mode:** `./slop-eye.sh '<room-url-with-invite>'` runs its
  own eye Chrome + detector on any machine, room pinned via `?slug`.

## Files

- `slop-detector.swift` — ScreenCaptureKit + Apple Vision; captures any
  Chrome window titled `SLOP-EYE` at 10fps, up to 6 hands, MediaPipe
  landmark order; POSTs `{hands, w, h}` with `X-Gesture-Key` (from env
  `SLOP_GESTURE_KEY`) to the relay. Slug-less POSTs route to whichever room
  has a live eye. **Rebuilding changes the binary signature and macOS
  silently revokes Screen Recording — every rebuild needs a human
  re-approval. Never rebuild the night of a show.**
- `slop-eye-install.sh` — god-machine one-time setup (build, TCC prompt,
  launchd agent, `.slop-eye.env` with the god password — gitignored).
- `slop-eye.sh` — single-machine manual eye (dedicated Chrome profile
  `~/.slop-eye-chrome` with occlusion-throttling flags).
- `slop-server.py` — back to its original job (static files + the local
  foreground↔background SSE bridge). The PNA/CORS preflight handling it
  gained is harmless leftover from the abandoned localhost-bridge design.
- `foreground.html` / `background.html` / `slop-shapes.js` — the retired
  OBS overlay. Kept because foreground.html is the **reference
  implementation of the gesture classifier** (fist/horns/claw/two-L,
  signed thumb-out, hold-to-activate); the relay's
  `packages/relay/src/gestures.ts` is a direct port and any tuning change
  should be reasoned against this original.

## Gestures

- ✊ fist → eth drops (streams while held, fires instantly)
- 🤘 horns → eth held on the hand, released to fly away
- 🦞 claw (thumb+index+middle up, thumb SPLAYED — that's what separates it
  from ✌️) → live claw, jaw follows your pinch
- 📐 two L-hands framing → the slop computer logo; on release it zooms at
  the screen
- 🫶 two-hand heart (index tips together on top, thumb tips together
  below, palms apart) → glowing heart between your hands, little hearts
  float out the top; the big heart floats away on release. **Relay-only**
  — added after the OBS rig retired, so foreground.html has no reference
  implementation for it (the four above are still 1:1 with it).

## Debugging quickies

- Detector log: `/tmp/slop-eye-detector.log` ("no match yet" = no SLOP-EYE
  window open; "Capturing:" + "hands: N" = healthy).
- Relay view: POST `/v1/hands` with the god key echoes the eye geometry it
  is mapping against.
- Effects render only while the person's camera window is open and visible
  on the desktop — that's a rule, not a bug.
