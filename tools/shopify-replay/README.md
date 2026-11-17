# shopify-replay — demo the Shopify -> ERPNext mapping without a store

The Shopify bridge normally needs a real store, an Admin API token that expires
every 24 h, and (for the return leg) ngrok. That makes it impossible to show on a
fresh clone. This tool replays **recorded** Shopify order payloads through the
same code path the live sync uses:

```
shopify.retrieve_order.create_sales_order(shopify_order)
```

No network, no token, no store. It creates real Sales Orders (and missing Items /
Customers) in the demo site, tagged with `shopify_order_id`, exactly as the live
integration does.

## Run

Windows:

```powershell
powershell -File .\tools\shopify-replay\replay.ps1
powershell -File .\tools\shopify-replay\replay.ps1 -Payload payloads/order-1002-multi-line.json
```

Linux/macOS:

```bash
./tools/shopify-replay/replay.sh
./tools/shopify-replay/replay.sh payloads/order-1002-multi-line.json
```

Then open **Selling -> Sales Order** and look for `#1001` / `#1002` in the
Shopify order id column, or query it:

```bash
docker exec comp_demo-bench-1 bash -lc \
  "cd /home/frappe/frappe-bench && bench --site frontend execute frappe.db.get_value \
   --args \"['Sales Order', {'shopify_order_id': '9001001'}, 'name']\""
```

## What the payloads cover

| File | Case |
|---|---|
| `payloads/order-1001.json` | one line, existing-shaped customer, paid |
| `payloads/order-1002-multi-line.json` | two lines, pending, different customer |

SKUs that do not exist in ERPNext are **created** by the mapping code, which is
why the payloads can use `DEMO-SKU-*`.

## Why not the Node-RED flow

The flow in `sandbox/node-red/flows.json` is the ERPNext -> Shopify direction
(Delivery Note, Stock Entry, Stock Reconciliation webhooks). The inbound order
mapping is Python in `repos/shopify-shrdc-v16-fixed/shopify/retrieve_order.py`, so
replaying there exercises the code that actually ships.

## Limits

- Idempotent per Shopify order id: re-running the same payload returns the
  existing Sales Order instead of duplicating it.
- Does not exercise token minting, rate limits, pagination or webhook
  verification — those still need a real store.
