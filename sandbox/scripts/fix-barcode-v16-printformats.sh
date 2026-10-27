#!/usr/bin/env bash
# Fix barcode_shrdc on ERPNext v16 — print formats (server-side barcode/QR).
#
# Symptom: the print formats rendered barcodes/QRs with client-side JsBarcode
# loaded from the jsdelivr CDN (<svg> + <script>), plus `resize: both` /
# `overflow: auto` / a fixed container height. In frappe's print/PDF pipeline
# the CDN script never runs, so the barcode was blank; the resize/overflow CSS
# also clipped item text. The QR format only printed `doc.qrcodes` (empty unless
# "Create QR" was clicked).
#
# Fix: replace the three "Barcode Shrdc" print formats' html+css with the
# server-side versions that call get_barcode_image()/get_qr_image() (rendered as
# real public PNGs), and register those renderers as Jinja globals in hooks.py.
#
# Input: the TRACKED data file lib/barcode_v16_print_formats.json (the 3 fixed
# "Barcode Shrdc" records). It is self-contained — it does NOT depend on the
# gitignored local fork, so a fresh clone can apply this fix.
# Idempotent.
set -uo pipefail
APP=/home/frappe/frappe-bench/apps/barcode_shrdc/barcode_shrdc
FIXTURE="$APP/fixtures/print_format.json"
FIXED=/tmp/barcode_v16_print_formats.json
SITE=frontend
cd /home/frappe/frappe-bench || exit 1

if [ ! -f "$FIXED" ]; then
  echo "ERROR: $FIXED missing (docker compose cp ./sandbox/scripts/lib/barcode_v16_print_formats.json $FIXED)"
  exit 1
fi

echo "== 1) merge the 3 fixed formats into the app fixture =="
env/bin/python - "$FIXTURE" "$FIXED" <<'PYEOF'
import io, json, sys

fx_path, fixed_path = sys.argv[1], sys.argv[2]
app = json.load(io.open(fx_path, encoding="utf-8"))
fixed = json.load(io.open(fixed_path, encoding="utf-8"))

WANT = {"Barcode Printing Format", "Barcode Printing Format A4", "QR Code Printing Format"}
by_name = {r.get("name"): r for r in fixed if r.get("module") == "Barcode Shrdc"}
repl = {n: by_name[n] for n in WANT if n in by_name}
missing = WANT - set(repl)
if missing:
    print("  ERROR: fixed fixture missing:", sorted(missing)); sys.exit(1)

changed = 0
for i, rec in enumerate(app):
    if rec.get("name") in repl:
        new = repl[rec["name"]]
        for k in ("html", "css", "modified", "format_data"):
            if new.get(k) != rec.get(k):
                rec[k] = new.get(k)
        changed += 1
io.open(fx_path, "w", encoding="utf-8").write(json.dumps(app, indent=1, sort_keys=True))
print("  app fixture: updated %d record(s)" % changed)
for n in sorted(WANT):
    html = repl[n].get("html") or ""
    print("    %-28s html=%d  jsdelivr=%s  get_barcode_image=%s  get_qr_image=%s"
          % (n, len(html), "jsdelivr" in html, "get_barcode_image" in html, "get_qr_image" in html))
PYEOF

echo
echo "== 2) update the DB Print Format records =="
# `bench console` mangles multi-line loops, so use the documented rule-7
# pattern: a helper MODULE inside an installed app, invoked via bench execute.
HELPER="$APP/pf_sync_helper.py"
cat > "$HELPER" <<'PYEOF'
import io, json
import frappe


def run():
	fixed = json.load(io.open("/tmp/barcode_v16_print_formats.json", encoding="utf-8"))
	names = ["Barcode Printing Format", "Barcode Printing Format A4", "QR Code Printing Format"]
	now = frappe.utils.now()
	for n in names:
		rec = next((r for r in fixed if r.get("name") == n and r.get("module") == "Barcode Shrdc"), None)
		if not rec:
			print("MARK missing in fixture:", n)
			continue
		if not frappe.db.exists("Print Format", n):
			print("MARK no DB record:", n)
			continue
		frappe.db.set_value(
			"Print Format",
			n,
			{
				"html": rec.get("html"),
				"css": rec.get("css"),
				"format_data": rec.get("format_data"),
				"modified": now,
			},
		)
		print("MARK updated:", n)
	frappe.db.commit()
	frappe.clear_cache()
	print("MARK cache cleared")
PYEOF
bench --site "$SITE" execute barcode_shrdc.pf_sync_helper.run 2>&1 | grep -E '^MARK|Error|Traceback' | sed 's/^/  /'

echo
echo "== 3) register the Jinja methods in hooks.py =="
# Also make the v15+ 'Custom Script' -> 'Client Script' fixture rename safe: a
# hooks.py reset (e.g. git checkout) can leave the stale name behind, and migrate
# then fails on the missing tabCustom Script table.
CS="$APP/fixtures/custom_script.json"
CL="$APP/fixtures/client_script.json"
if [ -f "$CS" ] && [ ! -f "$CL" ]; then
  python3 - "$CS" <<'PYEOF'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
for x in d:
    x["doctype"] = "Client Script"
json.dump(d, open(p, "w"), indent=1)
PYEOF
  mv "$CS" "$CL"
  echo "  fixtures: custom_script.json -> client_script.json (doctype flipped)"
fi

python3 - "$APP/hooks.py" <<'PYEOF'
import io, re, sys

path = sys.argv[1]
src = io.open(path, encoding="utf-8").read()

# On v15+ the 'Custom Script' doctype was renamed to 'Client Script' (and
# common.sh renames the fixture file, but a hooks.py reset — e.g. by a git
# checkout while debugging — can leave the stale name). Make the fixtures list
# consistent so migrate does not fail on the missing tabCustom Script table.
if "'Custom Script'" in src or '"Custom Script"' in src:
    src = src.replace("'Custom Script'", "'Client Script'").replace('"Custom Script"', '"Client Script"')
    io.open(path, "w", encoding="utf-8").write(src)
    print("  hooks.py: fixtures 'Custom Script' -> 'Client Script'")

if re.search(r"^jinja\s*=\s*\{", src, re.M):
    print("  hooks.py: jinja hook already present")
else:
    # Insert the jinja hook right after the `fixtures = [...]` line, matching
    # WHATEVER its current contents are. Anchoring on the literal upstream line
    # was brittle and silently did nothing on a fresh checkout.
    block = (
        "\n# Jinja globals exposed to print-format templates (server-side rendering of\n"
        "# barcodes/QRs so they appear in print/PDF, not just the on-screen preview).\n"
        "jinja = {\n"
        '\t"methods": [\n'
        '\t\t"barcode_shrdc.barcode_shrdc.doctype.barcode_printing.barcode_printing.get_barcode_image",\n'
        '\t\t"barcode_shrdc.barcode_shrdc.doctype.barcode_printing.barcode_printing.get_qr_image",\n'
        "\t]\n"
        "}\n"
    )
    m = re.search(r"^fixtures\s*=\s*\[[^\]]*\]\s*$", src, re.M)
    if not m:
        print("  hooks.py: MARKER NOT FOUND — add the jinja hook by hand")
    else:
        insert_at = m.end()
        src = src[:insert_at] + "\n" + block + src[insert_at:]
        io.open(path, "w", encoding="utf-8").write(src)
        print("  hooks.py: jinja hook ADDED")
PYEOF
grep -n "fixtures = \|jinja = {" -A 7 "$APP/hooks.py" | sed 's/^/  /'

echo
echo "== 4) syntax checks =="
env/bin/python -m py_compile "$APP/hooks.py" && echo "  hooks.py OK"
env/bin/python -c "import json;json.load(open('$FIXTURE'));print('  fixture JSON OK')"
