"""Server-side guards for the barcode scan fields.

WHY: the "checked quantity must equal the scanned quantity" rule shipped as a
**Client Script** `before_submit`. Anything that submits over the REST API (an
integration, a script, `curl`) skipped it entirely, so a Delivery Note could claim
a scanned quantity that was never checked against the real one.

These hooks are the server-side twin of the client script. They are deliberately
narrow: they only fire when the document actually uses the barcode validation
flags, so they cannot break normal documents.
"""

import frappe
from frappe import _


def _field(row, name):
    """Value of a custom field that may not exist on older sites."""
    try:
        return row.get(name)
    except Exception:
        return getattr(row, name, None)


def validate_scanned_quantities(doc, method=None):
    """Delivery Note: `checking_qty` must equal `qty` on every row when the
    document declares barcode validation."""
    if not _field(doc, "barcode_validation"):
        return

    mismatched = []
    for row in doc.get("items") or []:
        checking = _field(row, "checking_qty")
        if checking is None:
            continue
        if abs(float(checking or 0) - float(row.qty or 0)) > 1e-6:
            mismatched.append((row.idx, row.item_code, row.qty, checking))

    if mismatched:
        detail = ", ".join(
            _("row {0} ({1}): qty {2} vs checked {3}").format(idx, item, qty, checked)
            for idx, item, qty, checked in mismatched
        )
        frappe.throw(
            _("Barcode validation failed - the checked quantity does not match the delivered quantity: {0}").format(detail),
            title=_("Barcode quantity mismatch"),
        )


def validate_stock_entry_scans(doc, method=None):
    """Stock Entry: same rule for documents flagged with `scan_stock_entry_barcode`."""
    if not _field(doc, "scan_stock_entry_barcode"):
        return

    mismatched = []
    for row in doc.get("items") or []:
        checking = _field(row, "checking_qty")
        if checking is None:
            continue
        if abs(float(checking or 0) - float(row.qty or 0)) > 1e-6:
            mismatched.append((row.idx, row.item_code, row.qty, checking))

    if mismatched:
        detail = ", ".join(
            _("row {0} ({1}): qty {2} vs checked {3}").format(idx, item, qty, checked)
            for idx, item, qty, checked in mismatched
        )
        frappe.throw(
            _("Stock Entry barcode check failed - scanned quantity does not match quantity: {0}").format(detail),
            title=_("Barcode quantity mismatch"),
        )
