#!/usr/bin/env python3
"""Generic Figma stand-in driven by a routing table, for tests that must exercise
several distinct endpoints in one run (e.g. cross-file source-component
resolution: a file fetch, a nodes fetch, a component-registry lookup, then
another file's own nodes fetch).

Usage: mock-figma-router.py <port> <routes.json>
routes.json: a JSON array of { "match": "<substring of the request path+query>",
  "file": "<path to a JSON fixture served verbatim>", "status": <int, default 200> }.
The first entry whose "match" is a substring of the request answers it; no match
-> 404. Requires an X-Figma-Token header, mirroring the real API's 403 without one.
"""
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1])
# utf-8-sig: PowerShell's `Set-Content -Encoding utf8` (used by
# Start-MockFigmaRouter) writes a UTF-8 BOM, which plain utf-8 would choke on
# with "Unexpected UTF-8 BOM" — utf-8-sig strips it when present and is a
# no-op otherwise, so this reads routes.json from either platform.
with open(sys.argv[2], encoding='utf-8-sig') as f:
    ROUTES = json.load(f)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        if not self.headers.get('X-Figma-Token'):
            self.send_response(403)
            self.end_headers()
            self.wfile.write(b'{"err":"no token"}')
            return
        for route in ROUTES:
            if route['match'] in self.path:
                status = route.get('status', 200)
                with open(route['file'], 'rb') as f:
                    body = f.read()
                self.send_response(status)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
        self.send_response(404)
        self.end_headers()


server = HTTPServer(('127.0.0.1', PORT), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
print('ready', flush=True)
try:
    threading.Event().wait()
except KeyboardInterrupt:
    pass  # expected on shutdown (the test harness kills this process directly)
