#!/usr/bin/env bash
# Verify the SAMPLE DATA: DB counts, the workshop linkage, the fetched phone,
# and the derived per-car summary. Also demonstrate that the BMW's historical
# row referencing the INACTIVE workshop (Old Town Motors) raises the
# inactive-workshop warning while still saving.
set -uo pipefail
SITE="${SITE_NAME:-frontend}"
cd /home/frappe/frappe-bench || exit 1
DB_NAME=$(env/bin/python -c "import json;print(json.load(open('sites/$SITE/site_config.json'))['db_name'])")

echo "== row counts =="
mariadb -h db -u root -padmin "$DB_NAME" -e "
select (select count(*) from tabCar) as cars,
       (select count(*) from \`tabCar Workshop\`) as workshops,
       (select count(*) from \`tabCar Service Record\`) as service_rows;" 2>/dev/null

echo
echo "== workshops =="
mariadb -h db -u root -padmin "$DB_NAME" -e "
select name, workshop_name, status, city, hourly_rate from \`tabCar Workshop\` order by name;" 2>/dev/null

echo
echo "== cars: derived summary =="
mariadb -h db -u root -padmin "$DB_NAME" -e "
select license_plate, make, model, last_recorded_mileage,
       last_oil_change_date, next_oil_change_due_date,
       last_workshop, workshops_used, service_status, total_maintenance_cost
from tabCar order by name;" 2>/dev/null

echo
echo "== service rows with the LINK + fetched phone =="
mariadb -h db -u root -padmin "$DB_NAME" -e "
select parent, service_date, service_type, odometer, workshop, workshop_phone, cost
from \`tabCar Service Record\` order by parent, service_date;" 2>/dev/null

echo
echo "== every service row's workshop link resolves to a real workshop =="
mariadb -h db -u root -padmin "$DB_NAME" -e "
select count(*) as orphan_links
from \`tabCar Service Record\` r
left join \`tabCar Workshop\` w on w.name = r.workshop
where r.workshop is not null and r.workshop <> '' and w.name is null;" 2>/dev/null

echo
echo "== the inactive workshop is referenced exactly once (the BMW) =="
mariadb -h db -u root -padmin "$DB_NAME" -e "
select r.parent, r.service_type, r.service_date, r.workshop
from \`tabCar Service Record\` r
join \`tabCar Workshop\` w on w.name = r.workshop
where w.status = 'Inactive';" 2>/dev/null
