#!/usr/bin/env bash
# Validate the barcode_shrdc recipe still parses and the v16 entry is intact.
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1
env/bin/python - /tmp/validate_recipe.yaml <<'PYEOF'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
v = d["versions"]["16"]
print("OK app=%s branch=%s extra_pip=%s verify=%s" %
      (d["app"], v.get("branch"), v.get("extra_pip"), v.get("verify_doctype")))
print("v16 notes length:", len(v.get("notes") or ""))
for needle in ("fix-barcode-v16.sh", "reportlab", "scan_barcode", "SerialBatchPackageSelector"):
    print("  notes mention %-28s %s" % (needle, needle in (v.get("notes") or "")))
# every version block must still be well-formed
for ver, blk in (d.get("versions") or {}).items():
    assert isinstance(blk, dict), ver
print("all version blocks OK:", sorted((d.get("versions") or {}).keys()))
PYEOF
