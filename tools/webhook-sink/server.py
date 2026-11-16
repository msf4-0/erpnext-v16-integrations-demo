#!/usr/bin/env python3
"""Tunnel-free webhook receiver for the comp_demo stack.

ERPNext can post its Delivery Note / Stock Entry / Stock Reconciliation webhooks
straight to this service on the compose network, so the webhook demo no longer
needs ngrok, a public URL, or a Shopify account.

Endpoints
  GET  /healthz              -> {"ok": true}
  POST /webhook/<name>       -> stores the payload, 200 {"ok": true, "id": n}
  POST /<name>               -> same as /webhook/<name>
  GET  /received?limit=20    -> most recent payloads (newest last)
  GET  /received/<id>        -> one payload

Environment
  SINK_PORT   default 8088
  SINK_DATA   default /data/received.jsonl (append-only JSONL)
  FORWARD_URL optional; each payload is also POSTed there (e.g. an ERPNext
              method) and the upstream status is recorded.
"""

import json
import os
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("SINK_PORT", "8088"))
DATA = os.environ.get("SINK_DATA", "/data/received.jsonl")
FORWARD_URL = os.environ.get("FORWARD_URL", "").strip()
LOCK = threading.Lock()
COUNTER = {"n": 0}


def _append(record):
    os.makedirs(os.path.dirname(DATA) or ".", exist_ok=True)
    with open(DATA, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(record, ensure_ascii=False) + "\n")


def _read(limit=20):
    if not os.path.exists(DATA):
        return []
    with open(DATA, encoding="utf-8") as fh:
        lines = fh.readlines()[-limit:]
    out = []
    for line in lines:
        try:
            out.append(json.loads(line))
        except ValueError:
            continue
    return out


def _forward(body, content_type):
    if not FORWARD_URL:
        return None
    req = urllib.request.Request(
        FORWARD_URL, data=body, method="POST",
        headers={"Content-Type": content_type or "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return resp.status
    except Exception as exc:  # noqa: BLE001 - recorded, never raised
        return "error: {0}".format(exc)


class Handler(BaseHTTPRequestHandler):
    server_version = "compdemo-webhook-sink/1.0"

    def _send(self, code, payload):
        raw = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def log_message(self, fmt, *args):  # quieter, single line
        print("sink: " + (fmt % args), flush=True)

    def do_GET(self):  # noqa: N802
        if self.path.split("?")[0] == "/healthz":
            return self._send(200, {"ok": True, "stored": len(_read(100000))})
        if self.path.startswith("/received"):
            if "/received/" in self.path:
                try:
                    want = int(self.path.rsplit("/", 1)[-1].split("?")[0])
                except ValueError:
                    return self._send(400, {"error": "bad id"})
                for rec in reversed(_read(100000)):
                    if rec.get("id") == want:
                        return self._send(200, rec)
                return self._send(404, {"error": "not found"})
            limit = 20
            if "limit=" in self.path:
                try:
                    limit = max(1, min(500, int(self.path.split("limit=")[1].split("&")[0])))
                except ValueError:
                    pass
            return self._send(200, {"items": _read(limit)})
        return self._send(404, {"error": "not found"})

    def do_POST(self):  # noqa: N802
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        ctype = self.headers.get("Content-Type", "")
        try:
            parsed = json.loads(body.decode("utf-8")) if body else None
        except (ValueError, UnicodeDecodeError):
            parsed = None
        with LOCK:
            COUNTER["n"] += 1
            rec_id = COUNTER["n"]
        record = {
            "id": rec_id,
            "ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
            "path": self.path,
            "content_type": ctype,
            "headers": {k: v for k, v in self.headers.items()
                        if k.lower() in ("x-shopify-topic", "x-shopify-hmac-sha256",
                                         "x-shopify-shop-domain", "user-agent")},
            "body": parsed if parsed is not None else body.decode("utf-8", "replace")[:20000],
            "forwarded_status": _forward(body, ctype),
        }
        with LOCK:
            _append(record)
        print("sink: received {0} on {1} ({2} bytes)".format(rec_id, self.path, len(body)), flush=True)
        return self._send(200, {"ok": True, "id": rec_id})


if __name__ == "__main__":
    print("sink: listening on :{0}, data={1}, forward={2}".format(
        PORT, DATA, FORWARD_URL or "(off)"), flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
