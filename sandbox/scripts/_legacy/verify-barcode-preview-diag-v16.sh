#!/usr/bin/env bash
# Diagnose the on-form Preview sections: they render client-side with JsBarcode
# from the jsdelivr CDN. Check whether that can work in frappe v16 (jQuery
# version, CSP, $.getScript availability).
set -uo pipefail
cd /home/frappe/frappe-bench || exit 1
SITE=frontend
B=http://localhost:8000
F=apps/frappe/frappe

echo "== jQuery version shipped by frappe v16 =="
grep -rho "jQuery JavaScript Library v[0-9.]*" "$F/public/js/lib/jquery/jquery.min.js" 2>/dev/null | head -1 | sed 's/^/  /'
find "$F/public" -iname 'jquery*.js' 2>/dev/null | sed 's/^/  /'

echo
echo "== is \$.getScript still present in the bundled jQuery? =="
for f in $(find "$F/public" -iname 'jquery*.min.js' 2>/dev/null | head -3); do
  echo "  $f: getScript=$(grep -c 'getScript' "$f" 2>/dev/null)"
done

echo
echo "== Content-Security-Policy in v16? =="
grep -rn "Content-Security-Policy\|content_security_policy\|csp" "$F/../frappe" --include=*.py 2>/dev/null | grep -iv test | head -10 | sed 's/^/  /'

echo
echo "== CSP nonce / header middleware =="
grep -rln "Content-Security-Policy" "$F" --include=*.py 2>/dev/null | head | sed 's/^/  /'

echo
echo "== current form-preview JS (CDN calls) =="
grep -n "getScript\|cdn.jsdelivr\|JsBarcode(" apps/barcode_shrdc/barcode_shrdc/barcode_shrdc/doctype/barcode_printing/barcode_printing.js | sed 's/^/  /'

echo
echo "== does the desk page set a CSP meta? (check a served desk html) =="
curl -s -H "Host: $SITE" "$B/desk" -o /tmp/desk.html -w "  /desk http=%{http_code}\n"
grep -io 'content-security-policy[^>]*' /tmp/desk.html | head -2 | sed 's/^/  /' || echo "  no CSP meta in desk html"

echo
echo "== response headers for /api/method/ping =="
curl -s -D - -o /dev/null -H "Host: $SITE" "$B/api/method/ping" | grep -iE 'content-security|^HTTP' | sed 's/^/  /'
