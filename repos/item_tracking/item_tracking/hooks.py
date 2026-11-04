# -*- coding: utf-8 -*-
from __future__ import unicode_literals

app_name = "item_tracking"
app_title = "Individual Item Tracking"
app_publisher = "erpnextcomp_demo"
app_description = "Per-physical-unit tracking with unique ID, QR code and barcode, driven by stock transactions."
app_icon = "octicon octicon-package"
app_color = "grey"
app_email = "support@example.com"
app_license = "MIT"

# JS injected on every Desk page so the scan popup is available app-wide.
app_include_js = ["/assets/item_tracking/js/item_tracking_scan.js"]

# Item-form actions ("Tracked Units" / "Create Tracked Units") so the tracker is
# reachable from the product master rather than a detached link.
doctype_js = {
    "Item": "public/js/item_tracker_item.js",
    "Tracked Item": "public/js/item_tracking_tracked_item.js",
}

# Item list-view bulk action: select many items and mass-create their tracked
# units (one barcode/QR each) in a single click.
doctype_list_js = {"Item": "public/js/item_list_view.js"}

# Document events: the only place locations/history change is on real
# transaction lifecycle events (submit/cancel), never on scan.
doc_events = {
    "Stock Entry": {
        "before_submit": "item_tracking.item_tracking.events.validate_stock_entry_tracked_items",
        "on_submit": "item_tracking.item_tracking.events.on_stock_entry_submit",
        "on_cancel": "item_tracking.item_tracking.events.on_stock_entry_cancel",
    },
    "Purchase Receipt": {
        "on_submit": "item_tracking.item_tracking.events.on_purchase_receipt_submit",
    },
    "Delivery Note": {
        "on_submit": "item_tracking.item_tracking.events.on_delivery_note_submit",
    },
}

fixtures = ["Custom Field", "Client Script", "Property Setter"]

# Expose server-side rasterisation to print formats.
jinja = {
    "methods": [
        "item_tracking.item_tracking.doctype.tracked_item.tracked_item.get_tracking_qr_image",
        "item_tracking.item_tracking.doctype.tracked_item.tracked_item.get_tracking_barcode_image",
    ]
}
