SELECT '-- myinvois custom fields --' AS info;
SELECT name, dt FROM `_35e1999d62da474b`.`tabCustom Field` WHERE name LIKE '%myinvois%';
SELECT '-- myinvois client scripts --' AS info;
SELECT name, dt FROM `_35e1999d62da474b`.`tabClient Script` WHERE name LIKE '%MyInvois%';
SELECT '-- item_tracking reference (should exist) --' AS info;
SELECT name, dt FROM `_35e1999d62da474b`.`tabCustom Field` WHERE name = 'Stock Entry-tracked_items';
