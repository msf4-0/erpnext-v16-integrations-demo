#!/usr/bin/env bash
# Extract ONLY the 3 fixed "Barcode Shrdc" print-format records into a small
# tracked data file, so fix-barcode-v16-printformats.sh no longer depends on the
# gitignored local fork (./repos/barcode-shrdc-fixed).
#
# Output: /tmp/barcode_v16_print_formats.json  (docker compose cp it to
#         ./sandbox/scripts/lib/barcode_v16_print_formats.json)
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1

SRC=/tmp/print_format_fixed.json
if [ ! -f "$SRC" ]; then
  echo "ERROR: $SRC not found (copy the fork's fixture in first)"
  exit 1
fi

env/bin/python - "$SRC" /tmp/barcode_v16_print_formats.json <<'PYEOF'
import io, json, sys
src, out = sys.argv[1], sys.argv[2]
data = json.load(io.open(src, encoding="utf-8"))
WANT = {"Barcode Printing Format", "Barcode Printing Format A4", "QR Code Printing Format"}
keep = [r for r in data if r.get("name") in WANT and r.get("module") == "Barcode Shrdc"]
missing = WANT - {r.get("name") for r in keep}
assert not missing, "missing records: %s" % sorted(missing)
# keep only the fields the patch actually needs
FIELDS = ("name", "module", "doc_type", "html", "css", "format_data", "custom_format",
          "print_format_type", "disabled")
slim = [{k: r.get(k) for k in FIELDS} for r in keep]
io.open(out, "w", encoding="utf-8").write(json.dumps(slim, indent=1, sort_keys=True))
print("wrote %s with %d records" % (out, len(slim)))
for r in slim:
    print("  %-28s html=%d css=%d" % (r["name"], len(r.get("html") or ""), len(r.get("css") or "")))
PYEOF

ls -la /tmp/barcode_v16_print_formats.json
