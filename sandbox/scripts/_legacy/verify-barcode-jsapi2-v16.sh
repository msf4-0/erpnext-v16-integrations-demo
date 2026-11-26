#!/usr/bin/env bash
set -uo pipefail
E=/home/frappe/frappe-bench/apps/erpnext/erpnext
bench --site frontend console < /tmp/_wl.py > /tmp/wl.out 2>&1
echo "---- wl.out ----"
cat /tmp/wl.out
echo "---- end ----"
echo
echo "== select_batch_and_serial_no definition (where?) =="
grep -rn "select_batch_and_serial_no *=" "$E/public/js" 2>/dev/null | head
echo
echo "== get_serial_no in get_item_details.py =="
sed -n '1890,1915p' "$E/stock/get_item_details.py"
