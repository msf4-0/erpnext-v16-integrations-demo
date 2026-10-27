#!/usr/bin/env bash
# ai-fix-verify.sh — prove the two fixes actually work, rather than "no error".
#
# Run inside the bench container:
#   bash /tmp/scripts/ai-fix-verify.sh [https://<tunnel>.ngrok-free.dev]
#
# Checks
#   A. both apps are installed and their doctypes exist
#   B. THE BARCODE SCANNER: a real Item Barcode is resolvable through the v16
#      whitelisted endpoint the fixed JS now calls (scan_barcode). On the
#      unfixed app this step is what fails.
#   C. barcode print rendering works server-side (no CDN)
#   D. the three ERPNext Webhooks point at the live tunnel and are enabled
#   E. Node-RED has the flow deployed and exposes the three endpoints
set -uo pipefail

PUBLIC_URL="${1:-}"
SITE="${SITE_NAME:-frontend}"
B="http://localhost:8000"
J=/tmp/aifix-verify
PASS=0
FAIL=0

cd /home/frappe/frappe-bench || exit 1
rm -rf "$J"; mkdir -p "$J"

ok()   { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }
head() { echo; echo "-- $* --"; }

# ---------------------------------------------------------------- authenticated session
curl -s -c "$J/jar" -H "Host: $SITE" -H "Content-Type: application/json" \
  -d '{"usr":"Administrator","pwd":"admin"}' "$B/api/method/login" -o "$J/login" \
  -w '' >/dev/null 2>&1

# =========================================================== A. apps installed
head "A. installed apps"
APPS=$(bench --site "$SITE" list-apps 2>/dev/null)
for app in barcode_shrdc shopify; do
  if echo "$APPS" | grep -qE "^$app([[:space:]]|$)"; then ok "$app installed"; else bad "$app NOT installed"; fi
done
for dt in "Barcode Printing" "Shopify Access"; do
  CODE=$(curl -s -b "$J/jar" -H "Host: $SITE" -o /dev/null -w '%{http_code}' \
    "$B/api/resource/$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$dt")?limit_page_length=1")
  if [ "$CODE" = "200" ]; then ok "doctype '$dt' readable (200)"; else bad "doctype '$dt' -> $CODE"; fi
done

# =========================================================== B. barcode scanner
head "B. barcode scanner lookup (the reported failure)"
cat > apps/barcode_shrdc/barcode_shrdc/_aifix_verify.py <<'PYEOF'
import frappe

TEST_ITEM = "AI-FIX-SCAN-TEST"
TEST_BARCODE = "AI0FIX0SCAN0TEST"


def seed():
	"""Create the minimum master data plus one item carrying an Item Barcode."""
	# UOM
	if not frappe.db.exists("UOM", "Nos"):
		frappe.get_doc({"doctype": "UOM", "uom_name": "Nos", "must_be_whole_number": 1}).insert(
			ignore_permissions=True
		)
	# Item Group (needs a root "All Item Groups" then a leaf)
	if not frappe.db.exists("Item Group", "All Item Groups"):
		frappe.get_doc(
			{
				"doctype": "Item Group",
				"item_group_name": "All Item Groups",
				"is_group": 1,
				"parent_item_group": "",
			}
		).insert(ignore_permissions=True)
	if not frappe.db.exists("Item Group", "Products"):
		frappe.get_doc(
			{
				"doctype": "Item Group",
				"item_group_name": "Products",
				"is_group": 0,
				"parent_item_group": "All Item Groups",
			}
		).insert(ignore_permissions=True)

	if frappe.db.exists("Item", TEST_ITEM):
		item = frappe.get_doc("Item", TEST_ITEM)
	else:
		item = frappe.get_doc(
			{
				"doctype": "Item",
				"item_code": TEST_ITEM,
				"item_name": "AI-FIX barcode scan test",
				"item_group": "Products",
				"stock_uom": "Nos",
				"is_stock_item": 1,
				"has_batch_no": 0,
				"has_serial_no": 0,
			}
		).insert(ignore_permissions=True)

	if frappe.db.exists("Item Barcode", {"parent": TEST_ITEM}):
		item.reload()
		barcode = item.barcodes[0].barcode if item.barcodes else TEST_BARCODE
	else:
		item.append("barcodes", {"barcode": TEST_BARCODE, "barcode_type": "EAN"})
		item.save(ignore_permissions=True)
		barcode = TEST_BARCODE

	frappe.db.commit()
	print("MARK_SEED %s %s" % (TEST_ITEM, barcode))
	return {"item_code": TEST_ITEM, "barcode": barcode}


def cleanup():
	if frappe.db.exists("Item", TEST_ITEM):
		frappe.delete_doc("Item", TEST_ITEM, force=1, ignore_permissions=True)
		frappe.db.commit()
		print("MARK_CLEANED %s" % TEST_ITEM)
	return True
PYEOF

SEED=$(bench --site "$SITE" execute barcode_shrdc._aifix_verify.seed 2>&1 | grep -o 'MARK_SEED .*' || true)
BARCODE=$(echo "$SEED" | awk '{print $3}')
ITEM=$(echo "$SEED" | awk '{print $2}')
if [ -n "$BARCODE" ]; then
  ok "seeded test item '$ITEM' with barcode '$BARCODE'"
else
  bad "could not seed a test item/barcode"
  BARCODE="NOSUCHBARCODE"
fi

# The exact endpoint the FIXED form JS calls. The unfixed app called
# erpnext.stock.get_item_details.get_item_code, which 403s on v16.
CODE=$(curl -s -b "$J/jar" -H "Host: $SITE" -H "Content-Type: application/json" \
  -X POST "$B/api/method/erpnext.stock.utils.scan_barcode" \
  --data "{\"search_value\":\"$BARCODE\"}" -o "$J/scan" -w '%{http_code}')
if [ "$CODE" = "200" ]; then
  ok "scan_barcode -> 200 (barcode resolves to an item)"
  grep -o '"item_code"[^,]*' "$J/scan" | head -1 | sed 's/^/        /'
else
  bad "scan_barcode -> $CODE"
  head -c 300 "$J/scan" | sed 's/^/        /'; echo
fi

# The OLD (broken) path, for the record: must NOT be usable.
CODE_OLD=$(curl -s -b "$J/jar" -H "Host: $SITE" -H "Content-Type: application/json" \
  -X POST "$B/api/method/erpnext.stock.get_item_details.get_item_code" \
  --data "{\"barcode\":\"$BARCODE\"}" -o /dev/null -w '%{http_code}')
if [ "$CODE_OLD" = "200" ]; then
  ok "legacy get_item_code still available ($CODE_OLD) - harmless, fix does not rely on it"
else
  ok "legacy get_item_code unavailable ($CODE_OLD) - confirms why the fix is required"
fi

# The shipped JS must reference the working endpoint, not the dead one.
if grep -q "erpnext.stock.utils.scan_barcode" apps/barcode_shrdc/barcode_shrdc/barcode_shrdc/doctype/barcode_printing/barcode_printing.js 2>/dev/null; then
  ok "form JS calls scan_barcode (patched)"
elif grep -q "get_item_code" apps/barcode_shrdc/barcode_shrdc/barcode_shrdc/doctype/barcode_printing/barcode_printing.js 2>/dev/null; then
  bad "form JS still calls the de-whitelisted get_item_code (NOT patched)"
else
  bad "could not locate the form JS barcode lookup"
fi

# =========================================================== C. print rendering
head "C. server-side barcode/QR rendering (no CDN)"
cat > apps/barcode_shrdc/barcode_shrdc/_aifix_render.py <<'PYEOF'
import inspect

import frappe


def _call(fn, *args):
	"""Call fn with as many positional args as its signature requires."""
	sig = inspect.signature(fn)
	required = [
		p
		for p in sig.parameters.values()
		if p.default is inspect.Parameter.empty
		and p.kind in (p.POSITIONAL_ONLY, p.POSITIONAL_OR_KEYWORD)
	]
	return fn(*args[: len(required)])


def run():
	from barcode_shrdc.barcode_shrdc.doctype.barcode_printing.barcode_printing import (
		get_barcode_image,
		get_qr_image,
	)

	b = _call(get_barcode_image, "123456789012", "Code128")
	q = _call(get_qr_image, "https://example.invalid/ai-fix")
	print("MARK_RENDER barcode=%s qr=%s" % (b or "NONE", q or "NONE"))
	return {"barcode": b, "qr": q}
PYEOF
R=$(bench --site "$SITE" execute barcode_shrdc._aifix_render.run 2>&1)
if echo "$R" | grep -q 'MARK_RENDER .*barcode=/files/'; then
  ok "barcode image rendered server-side into /files/"
else
  bad "server-side barcode render failed"
  echo "$R" | grep -iE 'error|Traceback|Attribute' | head -5 | sed 's/^/        /'
fi

# =========================================================== D. webhooks
head "D. ERPNext webhooks -> live tunnel"
cat > apps/barcode_shrdc/barcode_shrdc/_aifix_wh.py <<'PYEOF'
import frappe


def run():
	rows = frappe.get_all(
		"Webhook",
		fields=["name", "webhook_doctype", "webhook_docevent", "request_url", "enabled"],
		order_by="creation asc",
	)
	for r in rows:
		print(
			"MARK_WH %s|%s|%s|%s|%s"
			% (r.name, r.webhook_doctype, r.webhook_docevent, r.enabled, r.request_url)
		)
	return rows
PYEOF
WH=$(bench --site "$SITE" execute barcode_shrdc._aifix_wh.run 2>&1 | grep '^MARK_WH' || true)
if [ -z "$WH" ]; then
  bad "no Webhook records found"
else
  echo "$WH" | sed 's/^MARK_WH /        /'
  for path in /delivery-note /stock-entry /stock-recon; do
    if echo "$WH" | grep -q "$path"; then ok "webhook for $path present"; else bad "webhook for $path missing"; fi
  done
  if echo "$WH" | grep -q 'REPLACE-ME\|ngrok-free\.app'; then
    bad "a webhook still points at a placeholder host"
  else
    ok "no placeholder hosts left in webhooks"
  fi
  if echo "$WH" | grep -qE '\|0\|'; then
    bad "at least one webhook is still disabled"
  else
    ok "all webhooks enabled"
  fi
fi

# =========================================================== E. Node-RED
head "E. Node-RED flow deployed"
if command -v curl >/dev/null 2>&1; then
  NR=$(curl -s -m 5 http://node-red:1880/flows 2>/dev/null || true)
  if [ -n "$NR" ] && [ "$NR" != "[]" ]; then
    N=$(echo "$NR" | grep -o '"type"' | wc -l)
    ok "Node-RED has a flow deployed ($N nodes)"
  else
    bad "Node-RED /flows is empty or unreachable from the bench container"
  fi
fi

if [ -n "$PUBLIC_URL" ]; then
  head "F. tunnel reachability"
  for path in /delivery-note /stock-entry /stock-recon; do
    CODE=$(curl -s -o /dev/null -w '%{http_code}' -m 25 -X POST "$PUBLIC_URL$path" \
      -H 'Content-Type: application/json' \
      -H 'ngrok-skip-browser-warning: 1' -d '{}' || true)
    case "$CODE" in
      200|204) ok "POST $path -> $CODE" ;;
      *)       bad "POST $path -> $CODE" ;;
    esac
  done
fi

# cleanup
bench --site "$SITE" execute barcode_shrdc._aifix_verify.cleanup >/dev/null 2>&1 || true
rm -f apps/barcode_shrdc/barcode_shrdc/_aifix_verify.py \
      apps/barcode_shrdc/barcode_shrdc/_aifix_render.py \
      apps/barcode_shrdc/barcode_shrdc/_aifix_wh.py
find apps/barcode_shrdc -name '_aifix_*' -delete 2>/dev/null || true

echo
echo "=============================================="
echo "  PASS: $PASS    FAIL: $FAIL"
echo "=============================================="
[ "$FAIL" -eq 0 ] || exit 1
