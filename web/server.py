#!/usr/bin/env python3
import html
import mimetypes
import os
import pathlib
import socket
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CONF = "/etc/airbridge.conf"

def load_conf(path):
    out = {}
    try:
        for raw in pathlib.Path(path).read_text().splitlines():
            raw = raw.strip()
            if not raw or raw.startswith("#") or "=" not in raw:
                continue
            k, v = raw.split("=", 1)
            out[k.strip()] = v.strip().strip('"').strip("'")
    except FileNotFoundError:
        pass
    return out

CFG = load_conf(CONF)
ROOT = pathlib.Path(CFG.get("INCOMING_DIR", "/var/lib/airbridge/incoming")).resolve()
BIND = CFG.get("WEB_BIND", "10.55.0.1")
PORT = int(CFG.get("WEB_PORT", "8080"))
ROOT.mkdir(parents=True, exist_ok=True)

CSS = """
body{font-family:system-ui,-apple-system,sans-serif;max-width:980px;margin:40px auto;padding:0 20px;background:#111;color:#eee}
h1{font-size:32px;margin-bottom:4px}.sub{color:#aaa;margin-top:0}.card{background:#1d1d1f;border-radius:16px;padding:16px 20px;margin:10px 0;display:flex;gap:16px;align-items:center}.name{flex:1;min-width:0;overflow-wrap:anywhere}a{color:#8ab4ff;text-decoration:none}.meta{color:#aaa;font-size:13px;white-space:nowrap}.empty{padding:48px;text-align:center;color:#999}.pill{background:#2b2b2e;padding:4px 8px;border-radius:999px;font-size:12px;color:#bbb}
"""

def human_size(n):
    f=float(n)
    for unit in ("B","KB","MB","GB","TB"):
        if f < 1024 or unit == "TB": return f"{f:.0f} {unit}" if unit == "B" else f"{f:.1f} {unit}"
        f/=1024

class Handler(BaseHTTPRequestHandler):
    server_version = "LilBitDrop/0.1"

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/":
            return self.index()
        if parsed.path.startswith("/files/"):
            return self.file(parsed.path[len("/files/"):])
        if parsed.path == "/healthz":
            self.send_response(200); self.end_headers(); self.wfile.write(b"ok\n"); return
        self.send_error(404)

    def index(self):
        files=[]
        for p in ROOT.iterdir():
            try:
                if p.is_file(): files.append((p.stat().st_mtime,p))
            except OSError: pass
        files.sort(reverse=True)
        rows=[]
        for _, p in files:
            st=p.stat(); q=urllib.parse.quote(p.name)
            rows.append(f'<div class="card"><div class="name"><a href="/files/{q}">{html.escape(p.name)}</a></div><div class="meta">{human_size(st.st_size)}</div></div>')
        if not rows: rows=['<div class="empty">No AirDrop files received yet.</div>']
        body=f'''<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="refresh" content="5"><title>LilBitDrop</title><style>{CSS}</style><h1>LilBitDrop</h1><p class="sub">AirDrop inbox <span class="pill">{len(files)} files</span></p>{''.join(rows)}'''
        data=body.encode()
        self.send_response(200); self.send_header("Content-Type","text/html; charset=utf-8"); self.send_header("Content-Length",str(len(data))); self.end_headers(); self.wfile.write(data)

    def file(self, encoded):
        name=urllib.parse.unquote(encoded)
        if not name or name in (".","..") or "/" in name or "\\" in name:
            return self.send_error(400)
        p=(ROOT/name).resolve()
        if p.parent != ROOT or not p.is_file(): return self.send_error(404)
        ctype=mimetypes.guess_type(p.name)[0] or "application/octet-stream"
        st=p.stat(); self.send_response(200)
        self.send_header("Content-Type",ctype)
        self.send_header("Content-Length",str(st.st_size))
        safe=p.name.replace('"','')
        self.send_header("Content-Disposition",f'attachment; filename="{safe}"')
        self.end_headers()
        with p.open("rb") as f:
            while True:
                chunk=f.read(1024*1024)
                if not chunk: break
                self.wfile.write(chunk)

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt%args))

class Server(ThreadingHTTPServer):
    # Bind WEB_BIND even before airbridge-usb has put it on usb0.
    def server_bind(self):
        self.socket.setsockopt(socket.SOL_IP, getattr(socket, "IP_FREEBIND", 15), 1)
        super().server_bind()

if __name__ == "__main__":
    print(f"LilBitDrop web: http://{BIND}:{PORT}/ ; root={ROOT}")
    Server((BIND,PORT),Handler).serve_forever()
