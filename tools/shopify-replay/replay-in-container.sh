#!/usr/bin/env bash
# Runs INSIDE the bench container: replay one recorded Shopify order through the
# real mapping code (shopify.retrieve_order.create_sales_order).
set -e
cd /home/frappe/frappe-bench
site="${1:-frontend}"
[ -f /tmp/shopify-order.json ] || { echo "replay: /tmp/shopify-order.json missing" >&2; exit 2; }
[ -f /tmp/shopify-replay.py ] || { echo "replay: /tmp/shopify-replay.py missing" >&2; exit 2; }
echo "replay: replaying on site '$site'"
# bench execute evaluates one Python expression; runpy executes the script file
# so the replay logic can keep normal imports and a try/except. `and None` keeps
# bench from trying to JSON-serialise runpy's module globals.
bench --site "$site" execute "__import__('runpy').run_path('/tmp/shopify-replay.py') and None"
