#!/usr/bin/env python3
"""Fix the shopify app's v16 `show_in_website` breakage.

ERPNext v16 dropped `Item.show_in_website`, but the shopify app still reads it:

    create_product.py:71   elif not doc.show_in_website:
    update_product.py:86   elif not doc.show_in_website:
    api.py:8               if not item.get("show_in_website"):
    api.py:36              "show_in_website",   # inside a frappe.get_all fields list

The first two raise AttributeError on EVERY item save once a Shopify Access
record exists (the guard only short-circuits when none is configured), which
silently breaks unrelated work such as adding an Item Barcode. The api.py field
list fails outright because the column does not exist.

Replacements default to True (publish as "active"), which matches the previous
behaviour for any store that had items published.

    env/bin/python /tmp/fix_shopify_show_in_website.py
"""
import os
import sys

os.chdir("/home/frappe/frappe-bench")
APP = "/home/frappe/frappe-bench/apps/shopify/shopify"

EDITS = [
    (
        "create_product.py",
        "    elif not doc.show_in_website:",
        '    elif not getattr(doc, "show_in_website", True):',
    ),
    (
        "update_product.py",
        "    elif not doc.show_in_website:",
        '    elif not getattr(doc, "show_in_website", True):',
    ),
    (
        "api.py",
        '    if not item.get("show_in_website"):',
        '    if not item.get("show_in_website", True):',
    ),
    (
        "api.py",
        '            "show_in_website",\n',
        "",
    ),
]


def main() -> int:
    changed = 0
    for filename, old, new in EDITS:
        path = os.path.join(APP, filename)
        with open(path) as fh:
            text = fh.read()
        if old not in text:
            print("SKIP %s: pattern not found (%r)" % (filename, old.strip()[:50]))
            continue
        text = text.replace(old, new)
        with open(path, "w") as fh:
            fh.write(text)
        print("PATCHED %s" % filename)
        changed += 1

    # drop stale bytecode so the running server does not keep the old code
    for root, dirs, files in os.walk(APP):
        if "__pycache__" in root:
            for name in files:
                if name.startswith(("create_product", "update_product", "api")):
                    os.remove(os.path.join(root, name))
    print("APPLIED %d edits" % changed)
    return 0


if __name__ == "__main__":
    sys.exit(main())
