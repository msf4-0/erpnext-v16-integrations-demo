"""Shopify Admin API access tokens.

WHY THIS MODULE EXISTS
----------------------
The app was written against a *permanent* `shpat_...` Admin API token pasted
into `Shopify Access.access_token`.  The custom app on this store is a Dev
Dashboard app that hands out **short-lived** tokens (24 h) through the OAuth
`client_credentials` grant, so a stored token rots every day and every push
starts returning `401 Invalid API key or access token`.

Rather than pasting a new token every morning, the app now mints its own:

    POST https://{shop}.myshopify.com/admin/oauth/access_token
    { "client_id": ..., "client_secret": ..., "grant_type": "client_credentials" }
    -> { "access_token": "shpat_...", "expires_in": 86399, "scope": "..." }

The minted token is cached in Redis until ~5 minutes before it expires, so the
cost is one HTTP round-trip per ~24 h and every sync path can simply call
`get_access_token()`.

CREDENTIAL RESOLUTION ORDER (first hit wins)
--------------------------------------------
1. `site_config.json`   -> `shopify_client_id` / `shopify_client_secret`
2. process environment  -> `SHOPIFY_CLIENT_ID` / `SHOPIFY_CLIENT_SECRET`
3. `Shopify Access` doc -> `client_id` / `client_secret` fields (if present)

A static token still works: when no client credentials are configured the
module falls back to the stored `Shopify Access.access_token` unchanged, which
keeps older sites and the unit tests working.

Nothing in here is allowed to raise into an ERPNext save hook - every public
function swallows transport errors, logs once and returns `None`.
"""

import frappe

CACHE_KEY = "shopify_admin_access_token"
CACHE_META_KEY = "shopify_admin_access_token_meta"
FAILED_KEY = "shopify_admin_token_mint_failed"
# Refresh this many seconds BEFORE Shopify's own expiry.
EXPIRY_SAFETY_SEC = 300


def _cfg(key, default=None):
    """site_config.json first, then process env."""
    try:
        value = frappe.conf.get(key)
    except Exception:
        value = None
    if value:
        return value
    import os

    return os.environ.get(key.upper(), default)


def get_client_credentials(doc=None):
    """Return (client_id, client_secret) or (None, None) when not configured."""
    client_id = _cfg("shopify_client_id")
    client_secret = _cfg("shopify_client_secret")
    if doc is not None:
        client_id = client_id or getattr(doc, "client_id", None)
        client_secret = client_secret or getattr(doc, "client_secret", None)
    return (client_id or None, client_secret or None)


def store_host(doc=None):
    """`4e1075.myshopify.com` from the Shopify Access doc (or site config)."""
    candidates = []
    if doc is not None:
        candidates += [getattr(doc, "shopify_url", None), getattr(doc, "shop_domain_url", None)]
    candidates.append(_cfg("shopify_store"))
    for raw in candidates:
        if not raw:
            continue
        host = str(raw).strip()
        for prefix in ("https://", "http://"):
            if host.startswith(prefix):
                host = host[len(prefix):]
        host = host.split("/")[0].strip()
        if host:
            return host
    return None


def api_version(doc=None):
    for raw in (getattr(doc, "updated_version", None) if doc is not None else None,
                _cfg("shopify_api_version", "2026-04")):
        if raw:
            return str(raw).strip()
    return "2026-04"


def _clear_pause():
    """A fresh token means a previous 401 no longer applies."""
    try:
        from shopify.utils import PAUSE_KEY

        frappe.cache().delete_value(PAUSE_KEY)
        frappe.cache().delete_value(PAUSE_KEY + "_logged")
    except Exception:
        pass


def mint_access_token(store, client_id, client_secret, timeout=30):
    """client_credentials grant.  Returns the parsed JSON or None on failure."""
    import requests

    if not (store and client_id and client_secret):
        return None
    url = "https://%s/admin/oauth/access_token" % store
    try:
        response = requests.post(
            url,
            json={
                "client_id": client_id,
                "client_secret": client_secret,
                "grant_type": "client_credentials",
            },
            timeout=timeout,
        )
    except Exception as exc:  # DNS, TLS, timeout - never block the save
        frappe.log_error(title="Shopify token mint failed (transport)", message="%s: %s" % (type(exc).__name__, exc))
        return None

    if response.status_code not in (200, 201):
        body = (getattr(response, "text", "") or "")[:500]
        frappe.log_error(
            title="Shopify token mint failed",
            message="HTTP %s from %s\n%s" % (response.status_code, url, body),
        )
        return None
    try:
        data = response.json()
    except Exception:
        return None
    if not data.get("access_token"):
        return None
    return data


def get_access_token(doc=None, force=False):
    """A currently-valid Admin API token, or None when none can be obtained.

    Cached in Redis; `force=True` mints immediately (used after a 401).
    """
    cache = frappe.cache()
    if not force:
        try:
            cached = cache.get_value(CACHE_KEY)
        except Exception:
            cached = None
        if cached:
            return cached

    client_id, client_secret = get_client_credentials(doc)
    if not (client_id and client_secret):
        # No minting credentials: fall back to whatever is stored.
        return getattr(doc, "access_token", None) if doc is not None else None

    store = store_host(doc)
    data = mint_access_token(store, client_id, client_secret)
    if not data:
        # Minting failed: a stored (possibly stale) token is better than nothing.
        return getattr(doc, "access_token", None) if doc is not None else None

    token = data["access_token"]
    try:
        expires_in = int(data.get("expires_in") or 86399)
    except Exception:
        expires_in = 86399
    ttl = max(60, expires_in - EXPIRY_SAFETY_SEC)
    try:
        cache.set_value(CACHE_KEY, token, expires_in_sec=ttl)
        cache.set_value(
            CACHE_META_KEY,
            {
                "store": store,
                "api_version": api_version(doc),
                "scope": data.get("scope"),
                "expires_in": expires_in,
            },
            expires_in_sec=ttl,
        )
    except Exception:
        pass
    _clear_pause()
    return token


def apply_fresh_token(doc, force=False):
    """Stamp a live token onto a Shopify Access doc (in memory, never saved).

    Mutates the doc that every sync handler already holds, so the existing
    `shopify_doc.access_token` call sites keep working unchanged.
    """
    if doc is None:
        return None
    token = get_access_token(doc, force=force)
    if not token:
        return None
    for field in ("access_token", "secret_key"):
        try:
            if getattr(doc, field, None) != token:
                setattr(doc, field, token)
        except Exception:
            pass
    return token


@frappe.whitelist()
def refresh_token(shopify_access=None, force=True):
    """Whitelisted: `bench execute` / UI button / curl helper."""
    name = shopify_access or frappe.get_value("Shopify Access", {}, "name")
    if not name:
        return {"ok": False, "error": "no Shopify Access record"}
    doc = frappe.get_doc("Shopify Access", name)
    token = get_access_token(doc, force=bool(force))
    if not token:
        return {"ok": False, "error": "mint failed - see Error Log"}
    return {
        "ok": True,
        "shopify_access": name,
        "store": store_host(doc),
        "token_prefix": token[:12],
        "token_length": len(token),
        "api_version": api_version(doc),
    }


@frappe.whitelist()
def token_status():
    """Whitelisted: is a cached token present and which store does it belong to?"""
    cache = frappe.cache()
    token = cache.get_value(CACHE_KEY)
    meta = cache.get_value(CACHE_META_KEY) or {}
    doc = None
    try:
        name = frappe.get_value("Shopify Access", {}, "name")
        if name:
            doc = frappe.get_doc("Shopify Access", name)
    except Exception:
        doc = None
    client_id, client_secret = get_client_credentials(doc)
    return {
        "has_cached_token": bool(token),
        "token_prefix": (token or "")[:12],
        "store": meta.get("store") or store_host(doc),
        "api_version": meta.get("api_version") or api_version(doc),
        "scope_count": len((meta.get("scope") or "").split(",")) if meta.get("scope") else 0,
        "minting_configured": bool(client_id and client_secret),
        "client_id_suffix": (client_id or "")[-6:],
        "access_record": getattr(doc, "name", None),
    }
