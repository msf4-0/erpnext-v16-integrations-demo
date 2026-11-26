#!/usr/bin/env python3
"""Surface fixtures: the Python half of the drift guard.

`a2ui.py` is stdlib-only, so this runs on the host with no bench and no site:

    python3 tests/fixtures.py            # check fixtures/ against the builder
    python3 tests/fixtures.py --write    # regenerate after an intended change

The JSON produced here is canonical: it is the output of the producer that the
desk page already renders. The harness asserts the very same files with
`packages/a2ui-plugin/tests/surfaces.mjs`, so the two producers cannot drift
without one of the two checks going red.

Keep the copy byte-identical:

    diff -r <this>/fixtures <harness>/packages/a2ui-plugin/tests/fixtures
"""

import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import a2ui  # noqa: E402  (needs the app dir on sys.path, nothing else)

FIXTURES = HERE / "fixtures"

# Inputs shared with packages/a2ui-plugin/tests/surfaces.mjs. Change one side
# without the other and the check fails — which is the whole point.
INVENTORY_ROWS = [
    {"item_code": "SKU007", "item_name": "Television", "qty": 190, "status": "Optimal"},
    {"item_code": "SKU008", "item_name": "Television Stand", "qty": 4, "status": "Low Stock"},
]
INVENTORY_COLUMNS = [
    {"key": "item_code", "label": "Item"},
    {"key": "item_name", "label": "Name"},
    {"key": "qty", "label": "Qty", "align": "right"},
    {"key": "status", "label": "Status"},
]


def cases():
    return {
        "text_card.json": a2ui.build_text_card(
            "DSH Assistant", "Hello from the scripted producer."
        ),
        "inventory_table.json": a2ui.build_inventory_table(
            "Inventory: Stores - SD", INVENTORY_ROWS, INVENTORY_COLUMNS
        ),
        "order_preview.json": a2ui.build_order_preview(
            "Create Sales Order?",
            [
                ("Item code", "SKU008"),
                ("Qty", "2.0"),
                ("Customer", "Grant Plastics Ltd."),
                ("Delivery date", "2026-11-27"),
            ],
            {
                "name": "create_sales_order",
                "label": "Create Sales Order",
                "args": {
                    "item_code": "SKU008",
                    "qty": 2.0,
                    "customer": "Grant Plastics Ltd.",
                    "delivery_date": "2026-11-27",
                },
                "confirm_required": True,
                "token": "tok-fixture",
            },
        ),
        "success_card.json": a2ui.build_success_card(
            "Sales Order created",
            [
                ("Document", "SAL-ORD-0001"),
                ("Customer", "Grant Plastics Ltd."),
                ("Item", "SKU008"),
                ("Qty", "2"),
                ("Total", "SAR 2,000.00"),
            ],
            badge="Draft",
            link=("Open SAL-ORD-0001", "/app/sales-order/SAL-ORD-0001"),
        ),
        "error_card.json": a2ui.build_error_card(
            "This action expired or was already used. Run the prompt again."
        ),
    }


def normalized(surface):
    """surfaceId is random per build, so it is the one field not compared."""
    out = dict(surface)
    out["surfaceId"] = "<surfaceId>"
    return out


def main():
    write = "--write" in sys.argv
    FIXTURES.mkdir(exist_ok=True)

    expected_all = {name: normalized(surface) for name, surface in cases().items()}

    if write:
        for name, expected in expected_all.items():
            (FIXTURES / name).write_text(
                json.dumps(expected, indent=2, sort_keys=True) + "\n", encoding="utf-8"
            )
            print("wrote tests/fixtures/{0}".format(name))
        return 0

    drifted = []
    for name, expected in expected_all.items():
        path = FIXTURES / name
        if not path.exists():
            drifted.append("{0} (missing)".format(name))
            continue
        actual = normalized(json.loads(path.read_text(encoding="utf-8")))
        if actual != expected:
            drifted.append(name)

    if drifted:
        print("fixture drift: {0}".format(", ".join(drifted)))
        print("If the change was intended: python3 tests/fixtures.py --write")
        return 1

    print("fixtures ok ({0} surfaces)".format(len(expected_all)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
