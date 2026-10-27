---
name: frappe-version-gotchas
description: Version-specific Frappe/ERPNext API changes and traps that break custom-app controller, doc_events, seed, or test code (v14/v15/v16). Use BEFORE writing or debugging any call into ERPNext core such as make_job_card, set_work_order_operations, frappe.defaults, or programmatic Work Order / Job Card creation.
---

# frappe-version-gotchas skill — API changes and traps

**Golden rule: before using an ERPNext/Frappe method whose signature or behaviour you are not 100% sure of, read the INSTALLED source in the container (read-only). Never trust memory across v14/v15/v16.**

```bash
docker compose -p test-sandbox -f ./sandbox/docker-compose.yml exec -T bench bash -lc \
  "grep -n 'def <method>' -A 40 /home/frappe/frappe-bench/apps/erpnext/erpnext/<path>.py"
```

## v16 (verified 2026-09-30; erpnext 16.36.0 / frappe 16.35.0)

- `frappe.defaults.get_default(key)` was **removed** → use `frappe.db.get_default(key)`, or `frappe.db.get_single_value("Global Defaults", "default_company")`. It is only a preference lookup: always add a fallback (e.g. first `Company`). Symptom: `AttributeError: module 'frappe.defaults' has no attribute 'get_default'`.
- `make_job_card(work_order, operations, parent_bom=None)` — the **2nd argument is the operations list/JSON**, NOT a `{"company": ...}` dict. The old idiom `make_job_card(wo, {"company": c})` raises `ValueError: dictionary update sequence element #0 ...`.
- **Do not call `make_job_card` to create Job Cards.** Submitting a Work Order already creates them via `WorkOrder.on_submit → create_job_card()`, which iterates `self.operations` (obeying `Manufacturing Settings.disable_capacity_planning` and `Operation.create_job_card_based_on_batch_size`).
- **`set_work_order_operations()` / `set_required_items()` run only from the whitelisted `get_items_and_operations_from_bom`**, which the Work Order *form* calls when the BOM is picked. A **programmatic** `frappe.get_doc({"doctype": "Work Order", ...}).insert()` therefore ends up with **no operations and no required_items → no Job Cards**. Fix: after setting `bom_no`, call `wo.get_items_and_operations_from_bom()` before `insert()`.
- A BOM keeps its operations only when **`with_operations = 1`**; otherwise the operations rows are dropped at save and no Job Card can be produced.
- A BOM with no `items` rows fails validate with **"Raw Materials cannot be blank."** — demo/seed BOMs need at least one raw-material line.
- Controllers must define `class <DocTypeName>(Document)`. A controller file with only bare functions makes `get_controller()` raise `ImportError`, and `remove_orphan_doctypes()` then **silently deletes the DocType** on the next `bench migrate` (install looked 100% fine).

## Testing traps

- `doc.validate()` calls only the controller method; **`doc_events` hooks fire only via `run_method("validate")` / `save()` / `submit()`**. Assert hook behaviour with `doc.run_method("validate")`, never bare `doc.validate()`.
- `bench run-tests` builds real documents: create master data defensively (Item **+ a raw Item** + submitted BOM **with `with_operations=1`** + Workstation + Operation) and `self.skipTest(...)` when the site lacks prerequisites, rather than failing the whole suite.
- Seeding left-over drafts: a failed `insert()` during `validate` leaves nothing, but a BOM whose `submit()` raised inside a `try/except` DOES leave a draft — prefer idempotent get-or-create that deactivates a stale active record before making a replacement.
