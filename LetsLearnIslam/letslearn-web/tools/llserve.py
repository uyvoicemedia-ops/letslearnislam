#!/usr/bin/env python3
"""Serve the prototype to the whole room, and relay the quiz between devices.

    python3 tools/llserve.py [port]

`python3 -m http.server --bind 127.0.0.1` serves the file to THIS computer and
nobody else, which is why the quiz could only ever be played in two tabs of one
browser. This does three things instead:

  * binds every interface, and prints the address the children should type;
  * relays quiz messages between whatever devices are connected, over plain
    HTTP long-polling — no websockets, no npm, nothing to install;
  * sends no-cache headers, so a reload really does pick up new code.

Standard library only. Stop it with Ctrl-C.
"""
import json, os, re, socket, sys, threading, time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8765

ROOM_RE = re.compile(r"^[A-Za-z0-9_-]{1,24}$")
HOLD = 25.0          # how long a poll waits for something to happen
KEEP = 400           # messages remembered per room
IDLE = 2 * 3600      # a silent room is forgotten after two hours

_lock = threading.Lock()
_cv = threading.Condition(_lock)
_rooms = {}          # code -> {"seq": int, "msgs": [(seq, src, obj)], "at": float}


def _room(code):
    r = _rooms.get(code)
    if r is None:
        r = _rooms[code] = {"seq": 0, "msgs": [], "at": time.time()}
    return r


def _sweep():
    now = time.time()
    for k in [k for k, v in _rooms.items() if now - v["at"] > IDLE]:
        _rooms.pop(k, None)


class Handler(SimpleHTTPRequestHandler):
    server_version = "LetsLearn/1.0"

    def __init__(self, *a, **kw):
        super().__init__(*a, directory=ROOT, **kw)

    # --- keep the browser honest about our constantly-changing one file ---
    def end_headers(self):
        self.send_header("Cache-Control", "no-store, must-revalidate")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "content-type")
        super().end_headers()

    def log_message(self, fmt, *args):
        if "/api/quiz/" in (self.path or ""):
            return                      # the poll loop would drown the log
        super().log_message(fmt, *args)

    def _json(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_OPTIONS(self):
        self.send_response(204)
        self.end_headers()

    def do_GET(self):
        u = urlparse(self.path)
        if u.path == "/api/ping":
            self._json({"ok": True, "rooms": len(_rooms)})
            return
        if u.path.startswith("/api/quiz/"):
            self._poll(u)
            return
        super().do_GET()

    def do_POST(self):
        u = urlparse(self.path)
        if not u.path.startswith("/api/quiz/"):
            self._json({"error": "not found"}, 404)
            return
        code = u.path[len("/api/quiz/"):].strip("/").upper()
        if not ROOM_RE.match(code):
            self._json({"error": "bad room"}, 400)
            return
        try:
            n = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(n) or b"{}")
        except Exception:
            self._json({"error": "bad json"}, 400)
            return
        src = str(body.get("src") or "")[:40]
        msg = body.get("m")
        with _cv:
            _sweep()
            r = _room(code)
            r["seq"] += 1
            r["at"] = time.time()
            r["msgs"].append((r["seq"], src, msg))
            if len(r["msgs"]) > KEEP:
                del r["msgs"][:-KEEP]
            seq = r["seq"]
            _cv.notify_all()
        self._json({"seq": seq})

    def _poll(self, u):
        code = u.path[len("/api/quiz/"):].strip("/").upper()
        if not ROOM_RE.match(code):
            self._json({"error": "bad room"}, 400)
            return
        q = parse_qs(u.query or "")
        try:
            since = int((q.get("since") or ["0"])[0])
        except ValueError:
            since = 0
        src = (q.get("src") or [""])[0][:40]
        deadline = time.time() + HOLD
        with _cv:
            r = _room(code)
            r["at"] = time.time()
            # a client that asks for a `since` we have already forgotten, or
            # that is brand new, is caught up to "now" rather than replayed
            if since < 0:
                since = r["seq"]
            while True:
                out = [m for m in r["msgs"] if m[0] > since and m[1] != src]
                if out or time.time() >= deadline:
                    break
                if not _cv.wait(timeout=max(0.2, deadline - time.time())):
                    if time.time() >= deadline:
                        break
            seq = r["seq"]
        self._json({"seq": seq, "msgs": [m[2] for m in out]})


def lan_ips():
    ips = []
    try:                                   # the address the router gave us
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ips.append(s.getsockname()[0])
        s.close()
    except OSError:
        pass
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            ip = info[4][0]
            if ip not in ips and not ip.startswith("127."):
                ips.append(ip)
    except OSError:
        pass
    return ips


def main():
    httpd = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    httpd.daemon_threads = True
    print("LetsLearn is being served from", ROOT)
    print()
    print("  on this computer   http://127.0.0.1:%d/index.html" % PORT)
    for ip in lan_ips():
        print("  on the same wifi   http://%s:%d/index.html" % (ip, PORT))
    print()
    print("Anyone on the same wifi can open one of those and join the quiz.")
    print("Ctrl-C to stop.")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nstopped")


if __name__ == "__main__":
    main()
