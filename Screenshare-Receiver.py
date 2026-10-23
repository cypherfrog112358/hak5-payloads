#!/usr/bin/env python3
"""Screenshare-Receiver - nimmt JPEG-Bilder vom "Screenshare-Over-LAN-V2" Sender an.

Start (nur Standardbibliothek, kein pip noetig):
    python Screenshare-Receiver.py [PORT] [TOKEN]

Beispiel:
    python Screenshare-Receiver.py 8090 geheim

Dann im Browser:
    http://<IP-dieses-Rechners>:8090/?token=geheim

PORT und TOKEN muessen im Sender (Screenshare-Over-LAN-V2.ps1) gleich
eingestellt sein. Beim ersten Start fragt die Windows-Firewall einmal nach -
"Inbound-Regeln fuer Python zulassen" bestaetigen.
"""

import json
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8090
TOKEN = sys.argv[2] if len(sys.argv) > 2 else "geheim"

lock = threading.Condition()
state = {"frame": None, "ts": 0.0, "size": 0, "client": "", "count": 0}

PAGE = """<!doctype html>
<html><head><meta charset="utf-8">
<title>Screenshare</title>
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<style>
 html,body{margin:0;height:100%;background:#000;overflow:hidden}
 img{position:fixed;inset:0;width:100vw;height:100vh;object-fit:contain}
 #s{position:fixed;left:8px;bottom:8px;color:#8f8;font:12px monospace;
    background:#000a;padding:4px 8px;border-radius:4px}
</style></head><body>
<img src="/stream?token=%%TOKEN%%" alt="stream">
<div id="s">verbinde ...</div>
<script>
const T = %%TOKEN_JSON%%;
async function tick(){
  try{
    const r = await fetch('/status?token=' + T);
    const d = await r.json();
    document.getElementById('s').textContent = d.ts
      ? 'Empfangen ' + new Date(d.ts*1000).toLocaleTimeString() + '  ' + d.size + ' B  von ' + d.client + '  (' + d.count + ' Bilder)'
      : 'noch keine Bilder';
  }catch(e){ document.getElementById('s').textContent = 'keine Verbindung'; }
}
setInterval(tick, 1000); tick();
</script>
</body></html>
"""


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def _send(self, code, ctype, body=b"", extra=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if body:
            self.wfile.write(body)

    def _token(self):
        q = parse_qs(urlparse(self.path).query)
        return (q.get("token") or [""])[0]

    def _forbidden(self):
        self._send(403, "text/plain", b"forbidden")

    def do_GET(self):
        if self._token() != TOKEN:
            return self._forbidden()
        path = urlparse(self.path).path

        if path == "/":
            html = PAGE.replace("%%TOKEN%%", TOKEN).replace("%%TOKEN_JSON%%", json.dumps(TOKEN))
            return self._send(200, "text/html; charset=utf-8", html.encode("utf-8"))

        if path == "/latest.jpg":
            with lock:
                frame = state["frame"]
            if not frame:
                return self._send(404, "text/plain", b"no frame")
            return self._send(200, "image/jpeg", frame)

        if path == "/status":
            with lock:
                d = {k: state[k] for k in ("ts", "size", "client", "count")}
            d["age"] = round(time.time() - d["ts"], 1) if d["ts"] else None
            return self._send(200, "application/json", json.dumps(d).encode())

        if path == "/stream":
            self.send_response(200)
            self.send_header("Content-Type", "multipart/x-mixed-replace; boundary=frame")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            try:
                while True:
                    with lock:
                        frame = state["frame"]
                    if frame:
                        self.wfile.write(b"--frame\r\n")
                        self.wfile.write(b"Content-Type: image/jpeg\r\n")
                        self.wfile.write(("Content-Length: %d\r\n\r\n" % len(frame)).encode())
                        self.wfile.write(frame)
                        self.wfile.write(b"\r\n")
                        self.wfile.flush()
                    time.sleep(0.125)
            except (BrokenPipeError, ConnectionResetError):
                pass
            return

        self._send(404, "text/plain", b"not found")

    def do_POST(self):
        if self._token() != TOKEN:
            return self._forbidden()
        if urlparse(self.path).path != "/upload":
            return self._send(404, "text/plain", b"not found")
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            n = 0
        data = self.rfile.read(n)
        if len(data) < 4 or data[:2] != b"\xff\xd8":
            return self._send(400, "text/plain", b"not a jpeg")
        with lock:
            state["frame"] = data
            state["ts"] = time.time()
            state["size"] = len(data)
            state["client"] = self.client_address[0]
            state["count"] += 1
            lock.notify_all()
        self._send(204, "text/plain", b"")


def lan_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except OSError:
        return "127.0.0.1"


def main():
    ip = lan_ip()
    print("Screenshare-Receiver")
    print("  Port   : %d" % PORT)
    print("  Token  : %s" % TOKEN)
    print("  Im Browser: http://%s:%d/?token=%s" % (ip, PORT, TOKEN))
    print("  Beenden: STRG+C")
    print()
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nbeendet")


if __name__ == "__main__":
    main()
