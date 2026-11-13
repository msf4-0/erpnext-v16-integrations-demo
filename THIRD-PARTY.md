# Third-party and application licensing

This inventory records the app sources vendored under `repos/`. Preserve each
upstream license file with its source. A missing or conflicting license is not
permission to redistribute; confirm rights with the owner before distributing
those apps outside this project.

| App | Upstream / origin | License | Redistribution status |
|---|---|---|---|
| `barcode_shrdc` | [msf4-0/ERPNext-Barcode-Integration](https://github.com/msf4-0/ERPNext-Barcode-Integration), v16 fork | `license.txt` says MIT; the vendored README also says GPLv3 | License file is present, but the README conflicts. Resolve with the upstream rights holder before external redistribution. |
| `shopify` | [msf4-0/shopify-ERPnext](https://github.com/msf4-0/shopify-ERPnext) | MIT (`license.txt`) | License file is present; redistribution is subject to its terms. |
| `eu_einvoice` | [alyf-de/eu_einvoice](https://github.com/alyf-de/eu_einvoice), version-16 source | GPL-3.0-or-later | `license.txt` and source are present. Keep the corresponding source and license intact when redistributing; comply with GPL-3.0-or-later. |
| `item_tracking` | First-party source in this repository | Not declared | Do not redistribute externally until the rights holder and license are confirmed. |
| `metabase_integration` | First-party scaffold; upstream provenance has not been verified | Not declared | Do not redistribute externally until provenance, rights holder, and license are confirmed. |
| `my_invois` | First-party source in this repository | Not declared | Do not redistribute externally until the rights holder and license are confirmed. |

The three upstream license files currently present are the copies from the
corresponding provenance checkouts. The three first-party apps have no license
declaration or license file in this repository; no license has been inferred or
created for them.
