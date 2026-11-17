# webhook-sink — tunnel-free webhook receiver

Replaces the ngrok requirement for the **webhook demo**. ERPNext posts its
Delivery Note / Stock Entry / Stock Reconciliation webhooks to this container on
the compose network; every payload is stored as JSONL and readable over HTTP.

## Why

`docs/DISTRIBUTION.md` criterion: a colleague without an ngrok account must
still be able to show webhooks firing. ngrok also changes URL on every start and
needs a host binary.

## Run

```bash
docker compose up -d webhook-sink
curl -s http://localhost:8088/healthz
```

Send a test payload:

```bash
curl -s -X POST http://localhost:8088/webhook/delivery-note \
  -H 'Content-Type: application/json' \
  -d '{"name":"DN-TEST-0001","customer":"Demo Buyer"}'
curl -s 'http://localhost:8088/received?limit=5'
```

## Point ERPNext at it (no tunnel)

Inside the compose network the sink is reachable as
`http://webhook-sink:8088/webhook/<name>`. Create/point the three Webhooks
(Delivery Note, Stock Entry, Stock Reconciliation) to:

| DocType | URL |
|---|---|
| Delivery Note | `http://webhook-sink:8088/webhook/delivery-note` |
| Stock Entry | `http://webhook-sink:8088/webhook/stock-entry` |
| Stock Reconciliation | `http://webhook-sink:8088/webhook/stock-recon` |

Then submit a Delivery Note and read `/received`. The ERPNext request must not
be blocked: the sink answers 200 immediately.

## Forwarding

Set `FORWARD_URL` to chain the same payload to another consumer (for example the
Node-RED flow or an ERPNext method). The upstream status is recorded per payload
in `forwarded_status`; errors are recorded, never raised.

```yaml
environment:
  FORWARD_URL: http://node-red:1880/delivery-note
```

## Data

`webhook_sink_data` volume, `/data/received.jsonl`, one JSON object per line:

```json
{"id":1,"ts":"...","path":"/webhook/delivery-note","headers":{},
 "body":{"name":"DN-TEST-0001"},"forwarded_status":null}
```

## Not a replacement for

- Shopify → ERPNext (that still needs a real store token or the replay tool)
- Signature verification: the sink records `X-Shopify-Hmac-Sha256` but does not
  validate it, because the demo's shared secret is not configured anywhere.
