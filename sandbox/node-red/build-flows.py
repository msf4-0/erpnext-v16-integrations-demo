#!/usr/bin/env python3
"""Build a deployable Node-RED flows.json from the operator's flow export.

The downloaded export (F:\\shopify_erpnext_integration.json) cannot run as-is
inside a containerised stack. Three classes of problem are rewritten here:

1. ADDRESSING -- every ERPNext node pointed at ``http://localhost:8000``.
   ``localhost`` inside the Node-RED *container* is Node-RED itself, so every
   call to ERPNext silently failed. Rewritten to the compose service URL.

2. CREDENTIALS -- the export carries a site-specific ERPNext API token
   (``39aed010f1e8cbc:...``) that does not exist on a freshly provisioned site,
   and TWO different Shopify Admin tokens (``shpat_a43a...`` on the http
   request nodes, ``shpat_5c1a...`` inside a function node). Only one can be
   right. Both are replaced from configuration.

3. A REAL BUG -- function node 16 ("function 16") rebuilt ``msg.headers`` with
   ``"X-Shopify-Access-Token": ""``, wiping the token configured on the
   downstream http request node. Every inventory sync died on a 401. The empty
   value is filled in.

Usage (see sandbox/up.ps1, which calls this):
    python build-flows.py --src <export.json> --out <flows.json> \
        --erpnext-url http://bench:8000 --erpnext-token key:secret \
        --shopify-store <store>.myshopify.com --shopify-version 2026-04 \
        --shopify-token shpat_xxx --site frontend

Exit code 0 on success, 2 if the produced flow would still be broken.
"""

from __future__ import annotations

import argparse
import json
import re
import sys

# --- patterns found in the shipped export -----------------------------------
RE_LOCAL_ERPNEXT = re.compile(r"https?://(?:localhost|127\.0\.0\.1):8000")
RE_SHOPIFY_BASE = re.compile(r"https://[A-Za-z0-9-]+\.myshopify\.com/admin/api/[0-9A-Za-z-]+")
RE_ERPNEXT_TOKEN = re.compile(r"token\s+[0-9A-Za-z]{6,}:[0-9A-Za-z]{6,}")
RE_SHOPIFY_TOKEN = re.compile(r"shpat_[0-9A-Za-z]+")
RE_EMPTY_SHOPIFY_HEADER = re.compile(r'("X-Shopify-Access-Token"\s*:\s*)""')

SHOPIFY_HEADER = "x-shopify-access-token"


class Counter(dict):
    def add(self, key: str, n: int = 1) -> None:
        if n:
            self[key] = self.get(key, 0) + n


stats = Counter()


def transform_string(value: str, cfg: dict) -> str:
    """Apply every textual rewrite to one string."""
    out = value

    # 1. ERPNext addressing: localhost -> the compose service name.
    out, n = RE_LOCAL_ERPNEXT.subn(cfg["erpnext_url"], out)
    stats.add("erpnext_url_rewritten", n)

    # 2. Shopify Admin API base (store host + API version).
    out, n = RE_SHOPIFY_BASE.subn(cfg["shopify_base"], out)
    stats.add("shopify_base_rewritten", n)

    # 3. ERPNext Authorization: token <key>:<secret>
    if cfg["erpnext_token"]:
        out, n = RE_ERPNEXT_TOKEN.subn("token " + cfg["erpnext_token"], out)
        stats.add("erpnext_token_rewritten", n)

    # 4. Shopify Admin tokens (there were two different, conflicting ones).
    if cfg["shopify_token"]:
        out, n = RE_SHOPIFY_TOKEN.subn(cfg["shopify_token"], out)
        stats.add("shopify_token_rewritten", n)
        # 5. The empty-token bug inside function 16.
        out, n = RE_EMPTY_SHOPIFY_HEADER.subn(r'\1"%s"' % cfg["shopify_token"], out)
        stats.add("empty_shopify_token_fixed", n)

    return out


def transform(node, cfg: dict):
    """Recursively rewrite every string in the flow structure."""
    if isinstance(node, str):
        return transform_string(node, cfg)
    if isinstance(node, list):
        return [transform(item, cfg) for item in node]
    if isinstance(node, dict):
        result = {}
        for key, val in node.items():
            # Node-RED stores http-request headers as a list of
            # {keyType,keyValue,valueType,valueValue} objects. Normalise by KEY
            # so an empty/incorrect token is corrected even when the value is
            # not plain text we can regex.
            if key == "headers" and isinstance(val, list):
                fixed = []
                for header in val:
                    if isinstance(header, dict) and str(
                        header.get("keyValue", "")
                    ).lower() == SHOPIFY_HEADER:
                        if not header.get("valueValue") and cfg["shopify_token"]:
                            header = dict(header, valueValue=cfg["shopify_token"])
                            stats.add("header_token_filled", 1)
                        elif cfg["shopify_token"] and header.get("valueValue") != cfg[
                            "shopify_token"
                        ]:
                            header = dict(header, valueValue=cfg["shopify_token"])
                            stats.add("header_token_normalised", 1)
                    fixed.append(transform(header, cfg))
                result[key] = fixed
            else:
                result[key] = transform(val, cfg)
        return result
    return node


def main() -> int:
    ap = argparse.ArgumentParser(description="Build a deployable Node-RED flows.json")
    ap.add_argument("--src", required=True, help="downloaded Node-RED export")
    ap.add_argument("--out", required=True, help="flows.json to write")
    ap.add_argument("--erpnext-url", default="http://bench:8000")
    ap.add_argument("--erpnext-token", default="", help="api_key:api_secret")
    ap.add_argument("--shopify-store", default="4e1075.myshopify.com")
    ap.add_argument("--shopify-version", default="2026-04")
    ap.add_argument("--shopify-token", default="")
    ap.add_argument("--site", default="frontend", help="ERPNext site name (for --site)")
    ap.add_argument(
        "--allow-missing-tokens",
        action="store_true",
        help="write the flow even if tokens are blank (endpoints will 401)",
    )
    args = ap.parse_args()

    cfg = {
        "erpnext_url": args.erpnext_url.rstrip("/"),
        "erpnext_token": args.erpnext_token.strip(),
        "shopify_base": "https://%s/admin/api/%s"
        % (args.shopify_store, args.shopify_version),
        "shopify_token": args.shopify_token.strip(),
    }

    with open(args.src, "r", encoding="utf-8") as handle:
        original = json.load(handle)
    if not isinstance(original, list):
        print("ERROR: %s is not a Node-RED flow array" % args.src, file=sys.stderr)
        return 2

    built = transform(original, cfg)

    # --- validation --------------------------------------------------------
    problems: list[str] = []
    blob = json.dumps(built)
    if "localhost:8000" in blob or "127.0.0.1:8000" in blob:
        problems.append("a Node-RED node still targets localhost:8000")
    stray = sorted(set(RE_SHOPIFY_TOKEN.findall(blob)))
    if cfg["shopify_token"]:
        stray = [tok for tok in stray if tok != cfg["shopify_token"]]
    if stray:
        problems.append("stray Shopify token(s) remain: %s" % ", ".join(stray))
    if not cfg["erpnext_token"]:
        problems.append("no ERPNext API token supplied (Authorization will 401)")
    if not cfg["shopify_token"]:
        problems.append("no Shopify Admin token supplied (Shopify calls will 401)")

    hard = [p for p in problems if "stray" in p or "localhost" in p]
    if hard:
        for problem in hard:
            print("ERROR: " + problem, file=sys.stderr)
        return 2
    if problems and not args.allow_missing_tokens:
        for problem in problems:
            print("WARN: " + problem, file=sys.stderr)

    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump(built, handle, indent=2)
        handle.write("\n")

    # --- report ------------------------------------------------------------
    print("built %s -> %s (%d nodes)" % (args.src, args.out, len(built)))
    for key in sorted(stats):
        print("  %-28s %d" % (key, stats[key]))
    http_in = [n for n in built if isinstance(n, dict) and n.get("type") == "http in"]
    print("  webhook endpoints:")
    for node in http_in:
        print("    POST %-16s (%s)" % (node.get("url"), node.get("method", "").upper()))
    print("  ERPNext base : %s" % cfg["erpnext_url"])
    print("  Shopify base : %s" % cfg["shopify_base"])
    print("  ERPNext token: %s" % ("set" if cfg["erpnext_token"] else "MISSING"))
    print("  Shopify token: %s" % ("set" if cfg["shopify_token"] else "MISSING"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
