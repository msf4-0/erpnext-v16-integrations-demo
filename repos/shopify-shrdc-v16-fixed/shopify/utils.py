import frappe

# Cache key for the "Shopify rejected our token" gate.
PAUSE_KEY = "shopify_sync_paused"


def get_shopify_access(name=None):
    """Return a Shopify Access doc carrying a live token, or None if none exists.

    The app previously did frappe.get_doc('Shopify Access',
    frappe.get_value('Shopify Access', {}, 'name')) inline in every
    handler. When no Shopify Access record exists, get_value returns None
    and get_doc('Shopify Access', None) throws 'Shopify Access None not
    found', which breaks unrelated operations (e.g. creating an Item).
    This helper returns None instead, and callers skip the sync.

    THE DOC IT RETURNS CARRIES A LIVE TOKEN: `shopify.auth` mints a
    client-credentials Admin API token (24 h lifetime on this store) and this
    helper stamps it onto `doc.access_token` / `doc.secret_key` in memory, so
    the `shopify_doc.access_token` call sites in every handler keep working
    without knowing about token expiry.  The doc is never saved, so nothing
    stale is ever persisted.
    """
    name = name or frappe.get_value('Shopify Access', {}, 'name')
    if not name:
        return None
    doc = frappe.get_doc('Shopify Access', name)
    try:
        from shopify.auth import apply_fresh_token

        apply_fresh_token(doc)
    except Exception:
        # Token minting must never break a save: keep the stored token.
        frappe.log_error(title="Shopify token refresh failed", message=frappe.get_traceback())
    return doc


def get_access_token(doc=None, force=False):
    """Shortcut so handlers can ask for a token without knowing the module."""
    from shopify.auth import get_access_token as _get

    return _get(doc, force=force)


def is_sync_paused():
    """True when Shopify recently rejected the stored Admin API token.

    While paused the document hooks return immediately, so saving an Item,
    Customer or Sales Order in ERPNext never raises and never spams the
    Error Log with one traceback per save.
    """
    try:
        return bool(frappe.cache().get_value(PAUSE_KEY))
    except Exception:
        return False


def pause_sync(reason, seconds=3600):
    """Stop calling Shopify for `seconds` after an auth rejection."""
    message = (reason or "Shopify API rejected the request")[:1400]
    try:
        frappe.cache().set_value(PAUSE_KEY, message, expires_in_sec=seconds)
    except Exception:
        pass
    if not frappe.cache().get_value(PAUSE_KEY + "_logged"):
        try:
            frappe.cache().set_value(PAUSE_KEY + "_logged", 1, expires_in_sec=seconds)
            frappe.log_error(title="Shopify sync paused - Admin API token rejected", message=message)
        except Exception:
            pass
    return None


def handle_response(response, context=""):
    """Normalise a Shopify response: auth failures pause the integration.

    Returns True when the caller may inspect the response normally, False when
    the integration is paused (the caller should give up quietly).
    """
    status = getattr(response, "status_code", None)
    if status in (401, 403):
        body = (getattr(response, "text", "") or "")[:600]
        pause_sync("%s: HTTP %s %s" % (context, status, body))
        return False
    return True


def parse_shopify_error(response):
    """Best-effort human-readable error text from a Shopify response."""
    try:
        data = response.json()
        if isinstance(data, dict):
            return str(data.get("errors") or data)
    except Exception:
        pass
    return (getattr(response, "text", "") or "")[:400]
