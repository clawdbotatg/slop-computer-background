#!/usr/bin/env python3
"""
slop-server.py — static file server + tiny event relay for the SLOP rig.

Serves this folder (so ES module imports work) AND bridges the foreground and
background screens, which run as SEPARATE Chrome instances (so BroadcastChannel
can't reach between them):

    foreground.html  --POST /spawn-->  this server  --SSE /events-->  background.html

Stdlib only, no pip installs.  Usage:  python3 slop-server.py [port]
"""
import json, queue, threading, sys, os, time, urllib.request
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from functools import partial

DIR  = os.path.dirname(os.path.abspath(__file__))
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 9911

# ---- optional: forward spawns to the shared slop-computer desktop ----------
# When configured, every /spawn (an object released to the background) is ALSO
# POSTed to live.slop.computer's relay (/v1/gesture), which broadcasts it to
# every screen in the room — god mode included, so it lands on the stream.
# Unconfigured = fully inert (the rig works exactly as before). Config lives
# in gitignored .slop-relay.env next to this file (KEY=VALUE lines; the token
# is a room-scoped agent token minted via /v1/agent-token) or plain env vars,
# which win. Roll back = delete the env file or revert this commit.
def _load_relay_cfg():
    cfg = {}
    try:
        with open(os.path.join(DIR, '.slop-relay.env')) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#') and '=' in line:
                    k, v = line.split('=', 1)
                    cfg[k.strip()] = v.strip()
    except OSError:
        pass
    cfg.update({k: v for k, v in os.environ.items() if k.startswith('SLOP_RELAY_')})
    url, tok, room = cfg.get('SLOP_RELAY_URL'), cfg.get('SLOP_RELAY_TOKEN'), cfg.get('SLOP_RELAY_ROOM')
    # SLOP_RELAY_ANCHOR: whose camera window effects anchor to (the host's
    # handle/address) — the rig's agent token is an anon session, so without
    # this the shared desktop can't find the right window and shows nothing.
    anchor = cfg.get('SLOP_RELAY_ANCHOR', '')
    return (url.rstrip('/'), tok, room, anchor) if url and tok and room else None

RELAY = _load_relay_cfg()
RELAY_KINDS = {'eth', 'claw', 'computer'}
# Token bucket: bursts pass (two hands release claws milliseconds apart — a
# flat min-gap ate the second one), sustained streams get throttled to 1/s so
# the fist's 150ms eth stream can't drain the relay's chat bucket (burst 5,
# refill 1/s — our burst must stay below its).
RELAY_BURST = 3.0
RELAY_REFILL_PER_S = 1.0
_relay_q = queue.Queue(maxsize=8)   # bounded fire-and-forget; drop rather than back up the rig

def _relay_worker():
    url, tok, room, anchor = RELAY
    tokens, last = RELAY_BURST, time.monotonic()
    while True:
        body = _relay_q.get()
        now = time.monotonic()
        tokens = min(RELAY_BURST, tokens + (now - last) * RELAY_REFILL_PER_S)
        last = now
        if tokens < 1:
            continue
        tokens -= 1
        try:
            d = json.loads(body)
            if d.get('kind') not in RELAY_KINDS:
                continue
            out = {k: d[k] for k in ('kind', 'x', 'y', 's', 'spin', 'angle', 'open') if k in d}
            if anchor:
                out['anchor'] = anchor
            payload = json.dumps(out).encode()
            req = urllib.request.Request(
                f'{url}/v1/gesture?slug={room}', data=payload,
                headers={'Authorization': f'Bearer {tok}', 'Content-Type': 'application/json'})
            urllib.request.urlopen(req, timeout=3).read()
            last_sent = now
        except Exception as e:
            print(f'relay forward failed: {e}', file=sys.stderr)

if RELAY:
    threading.Thread(target=_relay_worker, daemon=True).start()

def relay_spawn(body):
    if not RELAY:
        return
    try:
        _relay_q.put_nowait(body)
    except queue.Full:
        pass

# two channels: "spawn" (foreground -> background) and "hands" (detector -> foreground)
channels = {"spawn": set(), "hands": set()}
clients_lock = threading.Lock()

class Handler(SimpleHTTPRequestHandler):
    def log_message(self, *a): pass  # quiet

    def _sse(self, channel):
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Cache-Control', 'no-cache')
        self.send_header('Connection', 'keep-alive')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        q = queue.Queue(maxsize=4)  # bounded so a slow client can't back up the hand stream
        with clients_lock:
            channels[channel].add(q)
        try:
            self.wfile.write(b': connected\n\n'); self.wfile.flush()
            while True:
                try:
                    msg = q.get(timeout=15)
                    self.wfile.write(f'data: {msg}\n\n'.encode()); self.wfile.flush()
                except queue.Empty:
                    self.wfile.write(b': ping\n\n'); self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            with clients_lock:
                channels[channel].discard(q)

    def _pub(self, channel):
        n = int(self.headers.get('Content-Length', 0) or 0)
        body = self.rfile.read(n).decode('utf-8', 'ignore')
        if channel == 'spawn':
            relay_spawn(body)
        with clients_lock:
            targets = list(channels[channel])
        for q in targets:
            try: q.put_nowait(body)
            except queue.Full:
                try: q.get_nowait(); q.put_nowait(body)  # drop oldest, keep latest
                except queue.Empty: pass
        self.send_response(204)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()

    def do_GET(self):
        if self.path == '/events':       # spawn channel (background subscribes)
            return self._sse("spawn")
        if self.path == '/hands.sse':    # hand-landmark channel (foreground subscribes)
            return self._sse("hands")
        return super().do_GET()

    def do_POST(self):
        if self.path == '/spawn':        # foreground -> background
            return self._pub("spawn")
        if self.path == '/hands':        # detector -> foreground
            return self._pub("hands")
        self.send_response(404); self.end_headers()

if __name__ == '__main__':
    srv = ThreadingHTTPServer(('127.0.0.1', PORT), partial(Handler, directory=DIR))
    print(f'slop-server on http://localhost:{PORT}  (static + POST /spawn + SSE /events)')
    print(f'shared-desktop forward: {"ON -> " + RELAY[0] + " room " + RELAY[2] if RELAY else "off (no .slop-relay.env)"}')
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
