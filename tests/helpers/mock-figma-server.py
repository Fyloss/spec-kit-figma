#!/usr/bin/env python3
"""Minimal Figma stand-in for the export tests.

Serves exactly what figma-export-images.sh talks to:
  GET /v1/images/<key>?ids=...&format=...  -> {"err":null,"images":{id: url}}
  GET /img/<name>                          -> the rendered bytes

The rendered URL deliberately points back at this same server on a path that
requires NO token: the real one is a signed CDN URL, and a download that sent the
PAT to it would be a credential leak the test must be able to catch.
"""
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs

PORT = int(sys.argv[1])
# Node ids the server refuses to render, to exercise the "no image returned" path.
UNRENDERABLE = set(sys.argv[2].split(',')) if len(sys.argv) > 2 and sys.argv[2] else set()
SEEN_AUTH_ON_CDN = []


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path.startswith('/v1/images/'):
            if not self.headers.get('X-Figma-Token'):
                self.send_response(403)
                self.end_headers()
                self.wfile.write(b'{"err":"no token"}')
                return
            ids = parse_qs(parsed.query).get('ids', [''])[0]
            fmt = parse_qs(parsed.query).get('format', ['png'])[0]
            images = {}
            for node in [i for i in ids.split(',') if i]:
                node = node.replace('%3B', ';')
                if node in UNRENDERABLE:
                    images[node] = None
                else:
                    images[node] = f'http://127.0.0.1:{PORT}/img/{node.replace(":", "_")}.{fmt}'
            body = json.dumps({'err': None, 'images': images}).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if parsed.path.startswith('/img/'):
            # Record whether the downloader leaked the PAT to the CDN.
            if self.headers.get('X-Figma-Token'):
                SEEN_AUTH_ON_CDN.append(self.path)
            body = b'PNGDATA:' + parsed.path.encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/octet-stream')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if parsed.path == '/leaked':
            body = json.dumps({'leaked': SEEN_AUTH_ON_CDN}).encode()
            self.send_response(200)
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
    pass
