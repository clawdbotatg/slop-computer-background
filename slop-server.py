#!/usr/bin/env python3
"""
slop-server.py — static file server + tiny event relay for the SLOP rig.

Serves this folder (so ES module imports work) AND bridges the foreground and
background screens, which run as SEPARATE Chrome instances (so BroadcastChannel
can't reach between them):

    foreground.html  --POST /spawn-->  this server  --SSE /events-->  background.html

Stdlib only, no pip installs.  Usage:  python3 slop-server.py [port]
"""
import json, queue, threading, sys, os
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from functools import partial

DIR  = os.path.dirname(os.path.abspath(__file__))
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 9911

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
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
