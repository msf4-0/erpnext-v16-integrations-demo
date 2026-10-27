# Shopify to ERPNext v16 - Node-RED fix

## What was broken

1. **Stale ngrok webhook URL.** ERPNext was posting to
   `https://claudine-nonprintable-sartorially.ngrok-free.dev/delivery-note`.
   DNS still resolves, but the endpoint returns **404** because that ngrok
   session no longer exists.
2. **No Node-RED instance or flow export was present on this machine.**
   `shopify_erpnext_integration.json`, `flows*.json`, `%USERPROFILE%\.node-red`,
   a Node-RED container, and a listener on port 1880 were all absent.
3. **The Shopify app was not installed on the v16 site.**
   `Shopify Access` did not exist and `Webhook` returned zero records.
4. **The app used a stale auth pattern.** Outbound calls used HTTP Basic auth
   with the API key/secret instead of `X-Shopify-Access-Token`.
5. **The v16 defaults for imported customers were invalid.**
   `All Customer Groups` and `All Territories` are group nodes. ERPNext v16
   rejects them with `Cannot select a Group type Customer Group`.

## Code fixes in this fork

- `shopify/create_product.py`: token header, JSON body, timeout, non-blocking
  `after_insert`, honours `ignore_shopify_update`.
- `shopify/create_order.py`: initialised `shopify_order`, fixed `item_name`,
  sku/product lookup, guest email handling, non-blocking failures.
- `shopify/api.py`: only skips items that already have `shopify_product_id`;
  fetches all rows; per-item error logging.
- `shopify/retrieve_customer.py`: pagination, idempotent upsert, no import-time
  hook, leaf customer group/territory defaults.
- `shopify/retrieve_order.py`: guest/null customer handling, valid customer
  group/territory, item-group helper, per-order error logging.
- `shopify/retrieve_product.py`: item-group helper, `shopify_product_id`
  backfill, guarded `on_submit`.
- `shopify/automated_orders.py`, `create_customer.py`, `update_customer.py`,
  `update_product.py`, `update_product_price.py`, `delete_order.py`,
  `update_order.py`: scheduler guards, non-blocking hooks, no import-time
  DocType monkey-patching.

## Runtime state on the v16 stack

Stack: `frappe_docker-1`, compose file `F:\ERPNEXT\frappe_docker-1\pwd.yml`,
site `frontend`, ERPNext `16.35.0`.

The patched fork is installed at
`/home/frappe/frappe-bench/apps/shopify` inside the `backend` container.
`bench --site frontend list-apps` now includes `shopify 0.0.1`.

A `Shopify Access` record exists for
`https://4e1075.myshopify.com/admin/api/2026-04/` with company `test`,
bank account `Bank Accounts - T`, and API version `2026-04`. The access token
is stored only in the database and is not in this repository.

Three disabled webhooks exist so they do not post to a dead tunnel:

| Name | DocType | Event | Request URL |
| --- | --- | --- | --- |
| Delivery Note Webhook | Delivery Note | on_submit | `https://REPLACE-ME.ngrok-free.app/delivery-note` |
| Stock Entry Webhook | Stock Entry | on_submit | `https://REPLACE-ME.ngrok-free.app/stock-entry` |
| Stock Reconciliation Webhook | Stock Reconciliation | on_submit | `https://REPLACE-ME.ngrok-free.app/stock-recon` |

## Webhook definitions

All three use `Request Structure: JSON` and `Content-Type: application/json`.

Delivery Note:

```json
{
  "delivery_note": "{{ doc.name }}"
}
```

Stock Entry:

```json
{
  "doctype": "{{ doc.doctype }}",
  "name": "{{ doc.name }}",
  "stock_entry_type": "{{ doc.stock_entry_type }}"
}
```

Stock Reconciliation:

```json
{
  "doctype": "{{ doc.doctype }}",
  "name": "{{ doc.name }}",
  "posting_date": "{{ doc.posting_date }}"
}
```

The original documentation also added `X-Webhook-Secret: admin123` to the
Delivery Note webhook. Keep that header only if the Node-RED HTTP input checks
it; otherwise remove it.

## Remaining manual steps

1. Start Node-RED with the production flows:

   ```powershell
   node-red
   ```

2. Start the tunnel and copy the new public URL:

   ```powershell
   ngrok http 1880
   ```

3. In ERPNext, open **Webhook List** and replace
   `https://REPLACE-ME.ngrok-free.app` in all three records with the new
   `https://<id>.ngrok-free.app` host. Keep the existing paths
   (`/delivery-note`, `/stock-entry`, `/stock-recon`).

4. Enable the three webhooks only after Node-RED is reachable:

   ```powershell
   # ERPNext UI: Webhook -> open record -> Enabled -> Save
   ```

5. Confirm each endpoint from the host before enabling:

   ```powershell
   curl.exe -i -X POST "https://<id>.ngrok-free.app/delivery-note" `
     -H "Content-Type: application/json" `
     -d '{\"delivery_note\":\"TEST\"}'
   ```

6. Re-import the Node-RED flow if it is missing. The flow must expose:

   - `POST /delivery-note` -> read Delivery Note -> create Shopify fulfillment.
   - `POST /stock-entry` -> read Stock Entry -> update Shopify inventory.
   - `POST /stock-recon` -> read Stock Reconciliation -> update Shopify inventory.
   - The Sales Invoice automation flow that creates/submits invoices.

7. Rotate the Shopify Admin API token after testing. The token used during
   this work was pasted into chat and must be treated as compromised.

## Verification

Run these from `F:\ERPNEXT\frappe_docker-1`:

```powershell
docker compose -p frappe_docker-1 -f pwd.yml exec -T backend `
  bench --site frontend list-apps

docker compose -p frappe_docker-1 -f pwd.yml exec -T backend `
  bench --site frontend execute shopify.tmp_test.check
```

The second command is only for the temporary probe module and should be
removed. Use the ERPNext UI or:

```powershell
docker compose -p frappe_docker-1 -f pwd.yml exec -T backend `
  bench --site frontend mariadb -e "select name,enabled,request_url from tabWebhook;"
```

Expected after the fix: one `Shopify Access` record, three enabled webhooks
pointing at the current tunnel, a live `POST` returning HTTP 200 from Node-RED,
and a Shopify fulfillment created from a submitted Delivery Note.
