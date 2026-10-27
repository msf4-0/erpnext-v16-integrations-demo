#!/usr/bin/env bash
# Syntax-check the car_tracker files INSIDE the installed app (the copies that
# actually run), not the host tree. JS via node --check, Python via ast.parse.
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1

BASE=apps/car_tracker/car_tracker/car_tracker/doctype

echo "== JS syntax =="
node --check "$BASE/car/car.js" && echo "  car.js: OK"

echo
echo "== Python syntax =="
env/bin/python - "$BASE" <<'PYEOF'
import ast
import os
import sys

base = sys.argv[1]
files = [
    f"{base}/car/car.py",
    f"{base}/car/test_car.py",
    f"{base}/car_workshop/car_workshop.py",
    f"{base}/car_workshop/test_car_workshop.py",
    f"{base}/car_service_record/car_service_record.py",
]
for f in files:
    ast.parse(open(f).read())
    print(f"  {f}: OK")

echo_js = f"{base}/car/car.js"
print("\ncar.js contains validate promise pattern:",
      "return frappe.db" in open(echo_js).read())
PYEOF
