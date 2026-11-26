#!/usr/bin/env python3
"""Demo prompt sheet: the prompts you will actually type on stage, checked live.

    python3 repos/dsh/scripts/demo_prompts.py

Needs an authenticated cookie jar (POST /api/method/login once -> /tmp/jar).
Assertions are on the surface, never on prose: the model rewords answers.
"""
import json
import os
import re
import subprocess
import sys

BASE = os.environ.get("BASE", "http://localhost:8000")
JAR = os.environ.get("JAR", "/tmp/jar")

# (prompt, expected title substring or None, expected status, min rows)
CASES = [
    ("what warehouses are there?", "Warehouses", "success", 8),
    ("show me how many stuff we had right now", "all warehouses", "success", 1),
    ("how much television stock do we have?", "Television", "success", 1),
    ("how much backpack stock is left?", "items matching", "success", 1),
    ("what is in Stores - SD?", "Stores - SD", "success", 1),
    ("show me stock in Stores - S", None, "success", 0),          # twin-company trap
    ("order 2 x SKU008 for Grant Plastics Ltd", None, "pending_confirmation", 0),
    ("what is the weather in Kuala Lumpur?", None, "success", 0),  # must refuse
    ("cancel invoice ACC-SINV-2026-00001", None, "success", 0),    # no such tool
    ("who is the CEO of Samsung?", None, "success", 0),            # out of scope
]


def csrf() -> str:
    html = subprocess.run(
        ["curl", "-s", "-b", JAR, "-c", JAR, "-L", f"{BASE}/app/dsh-assistant"],
        capture_output=True, text=True,
    ).stdout
    match = re.search(r'csrf_token = "([^"]+)"', html)
    return match.group(1) if match else ""


def ask(prompt: str, session: str, token: str) -> dict:
    out = subprocess.run(
        ["curl", "-s", "-b", JAR, "-X", "POST",
         f"{BASE}/api/method/dsh_bridge.api.handle_chat",
         "-H", "Content-Type: application/json",
         "-H", f"X-Frappe-CSRF-Token: {token}",
         "-d", json.dumps({"prompt": prompt, "session_id": session})],
        capture_output=True, text=True,
    ).stdout
    try:
        return json.loads(out).get("message", {})
    except json.JSONDecodeError:
        return {"status": "transport-error", "reply": out[:200]}


def main() -> int:
    token = csrf()
    if not token:
        print("no CSRF token: log in first (POST /api/method/login)", file=sys.stderr)
        return 2

    session = "demo-sheet"
    failures = 0
    for prompt, title, status, min_rows in CASES:
        msg = ask(prompt, session, token)
        ui = msg.get("ui") or {}
        model = ui.get("dataModel") or {}
        got_title = str(model.get("title") or "")
        rows = model.get("rows") or []

        ok = msg.get("status") == status and len(rows) >= min_rows
        if title is not None:
            ok = ok and title.lower() in got_title.lower()
        if title is None and status == "success" and min_rows == 0:
            ok = ok and not rows           # a refusal must not invent a table

        failures += 0 if ok else 1
        print(f"{'PASS' if ok else 'FAIL'}  {prompt}")
        print(f"      status={msg.get('status')} mode={msg.get('mode')} "
              f"rows={len(rows)} title={got_title or '-'}")
        print(f"      reply={(msg.get('reply') or '')[:160]}")
    print(f"\n{len(CASES) - failures}/{len(CASES)} passed")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
