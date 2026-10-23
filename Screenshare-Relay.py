import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOCK = threading.Condition()
FRAME = {"data": b"", "seq": 0, "ts": 0.0}
PORT = int(os.environ.get("PORT", "8090"))

PAGE = b"""<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>Screenshare</title>
<meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">
<style>
 html, body { margin: 0; padding: 0; background: #000; width: 100%; height: 100%; overflow: hidden; }
 img { display: block; position: fixed; top: 0; left: 0; width: 100vw; height: 100vh;
       object-fit: contain; object-position: center center; background: #000; }
</style>
</head>
<body>
<img src="/stream" alt="Screenshare">
</body>
</html>
"""


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def _send(self, code, ctype, body, extra=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        if extra:
            for k, v in extra.items():
                self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?")[0]

        if path in ("/", "/index.html"):
            self._send(200, "text/html; charset=utf-8", PAGE)

        elif path == "/latest.jpg":
            with LOCK:
                data = FRAME["data"]
            if not data:
                self._send(503, "text/plain", b"no frame yet")
                return
            self._send(200, "image/jpeg", data)

        elif path == "/status":
            with LOCK:
                info = {
                    "ok": True,
                    "seq": FRAME["seq"],
                    "age": round(time.time() - FRAME["ts"], 1) if FRAME["ts"] else None,
                    "bytes": len(FRAME["data"]),
                }
            self._send(200, "application/json", json.dumps(info).encode())

        elif path == "/stream":
            self.send_response(200)
            self.send_header("Content-Type", "multipart/x-mixed-replace; boundary=frame")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Pragma", "no-cache")
            self.send_header("Connection", "close")
            self.end_headers()
            last = -1
            try:
                while True:
                    with LOCK:
                        LOCK.wait_for(lambda: FRAME["seq"] != last, timeout=10)
                        seq = FRAME["seq"]
                        data = FRAME["data"]
                    if seq == last or not data:
                        continue
                    last = seq
                    self.wfile.write(b"--frame\r\nContent-Type: image/jpeg\r\nContent-Length: "
                                     + str(len(data)).encode() + b"\r\n\r\n")
                    self.wfile.write(data)
                    self.wfile.write(b"\r\n")
                    self.wfile.flush()
            except Exception:
                return

        else:
            self._send(404, "text/plain", b"not found")

    def do_POST(self):
        if self.path.split("?")[0] != "/push":
            self._send(404, "text/plain", b"not found")
            return
        try:
            n = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            n = 0
        if n <= 0 or n > 8000000:
            self._send(400, "text/plain", b"bad size")
            return
        try:
            data = self.rfile.read(n)
        except Exception:
            return
        if not data or data[:2] != b"\xff\xd8":
            self._send(400, "text/plain", b"not a jpeg")
            return
        with LOCK:
            FRAME["data"] = data
            FRAME["seq"] += 1
            FRAME["ts"] = time.time()
            LOCK.notify_all()
        self._send(200, "application/json", b'{"ok":true}')


if __name__ == "__main__":
    srv = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    srv.daemon_threads = True
    srv.serve_forever()
