#!/usr/bin/env bash
# ai-fix-wire-webhooks.sh — point ERPNext's outbound Webhooks at the current
# ngrok public URL and enable them.
#
# This is the automated replacement for the manual "open Webhook List and
# replace REPLACE-ME.ngrok-free.app in all three records" step that the old
# setup required — and the reason the webhooks were permanently stale after
# every tunnel restart.
#
# Run inside the bench container:
#   bash /tmp/scripts/ai-fix-wire-webhooks.sh https://<id>.ngrok-free.dev
set -uo pipefail

PUBLIC_URL="${1:-}"
SITE="${SITE_NAME:-frontend}"

if [ -z "$PUBLIC_URL" ]; then
  echo "usage: $0 https://<your-tunnel>.ngrok-free.dev"
  exit 2
fi
PUBLIC_URL="${PUBLIC_URL%/}"

cd /home/frappe/frappe-bench || exit 1

cat > apps/barcode_shrdc/barcode_shrdc/_aifix_webhooks.py <<'PYEOF'
import frappe

BASE_URL = "__BASE_URL__"

SPECS = [
	{
		"label": "Delivery Note Webhook",
		"doctype": "Delivery Note",
		"event": "on_submit",
		"path": "/delivery-note",
		"data": [("delivery_note", "delivery_note")],
	},
	{
		"label": "Stock Entry Webhook",
		"doctype": "Stock Entry",
		"event": "on_submit",
		"path": "/stock-entry",
		"data": [
			("doctype", "doctype"),
			("name", "name"),
			("stock_entry_type", "stock_entry_type"),
		],
	},
	{
		"label": "Stock Reconciliation Webhook",
		"doctype": "Stock Reconciliation",
		"event": "on_submit",
		"path": "/stock-recon",
		"data": [
			("doctype", "doctype"),
			("name", "name"),
			("posting_date", "posting_date"),
		],
	},
]


def _data_row_fields():
	"""Fieldnames of the `Webhook Data` child table, so we only set real ones."""
	meta = frappe.get_meta("Webhook Data")
	return {df.fieldname for df in meta.fields}


def _header_row_fields():
	meta = frappe.get_meta("Webhook Header")
	return {df.fieldname for df in meta.fields}


def _find(spec):
	name = frappe.db.get_value(
		"Webhook",
		{"webhook_doctype": spec["doctype"], "webhook_docevent": spec["event"]},
		"name",
	)
	return frappe.get_doc("Webhook", name) if name else None


def _apply(doc, spec):
	request_url = BASE_URL + spec["path"]

	# Only set fields that exist on this ERPNext version.
	meta = frappe.get_meta("Webhook")
	for fieldname, value in (
		("webhook_doctype", spec["doctype"]),
		("webhook_docevent", spec["event"]),
		("request_url", request_url),
		("request_method", "POST"),
		("request_structure", "JSON"),
		("enabled", 1),
	):
		if meta.has_field(fieldname):
			doc.set(fieldname, value)

	data_fields = _data_row_fields()
	rows = []
	for fieldname, key in spec["data"]:
		row = {}
		if "fieldname" in data_fields:
			row["fieldname"] = fieldname
		if "key" in data_fields:
			row["key"] = key
		if row:
			rows.append(row)
	if rows and meta.has_field("webhook_data"):
		doc.set("webhook_data", rows)

	header_fields = _header_row_fields()
	header = {}
	if "key" in header_fields:
		header["key"] = "Content-Type"
	if "value" in header_fields:
		header["value"] = "application/json"
	if header and meta.has_field("webhook_headers"):
		doc.set("webhook_headers", [header])

	return request_url


def run():
	site = frappe.local.site
	results = []
	for spec in SPECS:
		doc = _find(spec)
		created = doc is None
		if created:
			doc = frappe.new_doc("Webhook")
			# Webhook.autoname is `prompt` ("Set by user"), so a name MUST be
			# supplied or save() dies with "Please set the document name".
			doc.name = spec["label"]
		url = _apply(doc, spec)
		doc.flags.ignore_permissions = True
		doc.save()
		results.append(
			{
				"site": site,
				"doctype": spec["doctype"],
				"event": spec["event"],
				"created": created,
				"enabled": doc.enabled,
				"request_url": url,
			}
		)
	frappe.db.commit()
	frappe.clear_cache()
	for row in results:
		print(
			"MARK_WEBHOOK %s | %s %s | enabled=%s | %s"
			% (
				"CREATED" if row["created"] else "UPDATED",
				row["doctype"],
				row["event"],
				row["enabled"],
				row["request_url"],
			)
		)
	return results
PYEOF

# Inject the tunnel URL (heredoc keeps the file readable; substitute after).
python3 - "$PUBLIC_URL" <<'PYSUB'
import sys, pathlib
p = pathlib.Path("apps/barcode_shrdc/barcode_shrdc/_aifix_webhooks.py")
text = p.read_text()
p.write_text(text.replace("__BASE_URL__", sys.argv[1]))
PYSUB

echo "-- configuring webhooks for $PUBLIC_URL"
OUT=$(bench --site "$SITE" execute barcode_shrdc._aifix_webhooks.run 2>&1)
echo "$OUT" | grep -E '^MARK_WEBHOOK|Error|Traceback' | sed 's/^MARK_WEBHOOK /  /' || true

rm -f apps/barcode_shrdc/barcode_shrdc/_aifix_webhooks.py
find apps/barcode_shrdc -name '_aifix_webhooks*' -delete 2>/dev/null || true

if echo "$OUT" | grep -q '^MARK_WEBHOOK'; then
  echo "-- webhooks configured and enabled"
  exit 0
fi
echo "ERROR: webhook configuration failed"
echo "$OUT" | tail -25
exit 1
