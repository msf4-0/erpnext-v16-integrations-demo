#!/usr/bin/env bash
# Sanity-check the shopify.yaml recipe parses and the v12 entry says what we
# expect (local-fork source, Shopify Access verify doctype, no extra_pip).
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1

env/bin/python - <<'PYEOF'
import yaml
d = yaml.safe_load(open('/tmp/recipes/shopify.yaml'))
v = d['versions']['12']
print("app:", d['app'])
print("v12 branch:", v['branch'])
print("v12 verify_doctype:", v['verify_doctype'])
print("v12 extra_pip:", v.get('extra_pip'))
print("v12 notes mention FORK:", 'FORK' in v['notes'])
print("v12 notes mention 710e5d7:", '710e5d7' in v['notes'])
print("all versions:", sorted(d['versions'].keys()))
PYEOF
