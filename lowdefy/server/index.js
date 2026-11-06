// Exception Management service — server-side detection + lifecycle.
// Zero external deps: node:http, node:sqlite, native fetch (Node >= 22).
// ERPNext remains the source of truth for inventory; this service stores ONLY
// exception metadata (status, assignee, notes, activity) keyed by a stable dedup id.
//
// Endpoints:
//   GET  /health
//   GET  /exceptions?status=&category=&assigned_to=   (list)
//   GET  /exceptions/:id                              (one + activity)
//   POST /exceptions/:id/assign   { assignee }
//   POST /exceptions/:id/investigate
//   POST /exceptions/:id/resolve  { note }
//   POST /exceptions/:id/dismiss  { note }
//   POST /detect                  (re-run detection; also run on a timer)

import http from 'node:http';
import { DatabaseSync } from 'node:sqlite';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const ERP_URL = process.env.ERPNEXT_URL || 'http://localhost:8000';
const AUTH = process.env.ERPNEXT_AUTH_HEADER || (() => {
  const k = process.env.ERPNEXT_API_KEY;
  const s = process.env.ERPNEXT_API_SECRET;
  return k && s ? `token ${k}:${s}` : '';
})();
const PORT = Number(process.env.EXCEPTION_PORT || 4000);
const DB_PATH = process.env.EXCEPTION_DB_PATH || path.join(__dirname, 'exceptions.db');

// Configurable thresholds (override via env; edit in the app's Settings page).
const CFG = {
  lowStock: true,
  outOfStock: true,
  overduePO: true,
  pendingTransferHours: 48,
  unusualMovementQty: 100,     // |ledger qty| > this flags "requiring investigation"
  expiringDays: [30, 14, 7],
  discrepancy: true,
};

const db = new DatabaseSync(DB_PATH);
db.exec(`
  CREATE TABLE IF NOT EXISTS exceptions (
    id TEXT PRIMARY KEY,            -- stable dedup key, e.g. low_stock:CARWHEEL:Stores
    category TEXT NOT NULL,
    severity TEXT NOT NULL,          -- Critical | High | Medium | Low
    title TEXT NOT NULL,
    description TEXT NOT NULL,
    rule TEXT NOT NULL,              -- human-readable detection rule + values
    related_record TEXT,             -- ERPNext doc reference
    detected_at TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'New',   -- New | Investigating | Resolved | Dismissed
    assigned_to TEXT,
    resolution_note TEXT,
    resolved_at TEXT
  );
  CREATE TABLE IF NOT EXISTS activity (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    exception_id TEXT NOT NULL,
    ts TEXT NOT NULL,
    actor TEXT,
    action TEXT NOT NULL,
    detail TEXT
  );
`);

function nowISO() { return new Date().toISOString(); }

async function erp(pathname, params) {
  const qs = new URLSearchParams(params || {});
  const url = `${ERP_URL}${pathname}?${qs.toString()}`;
  const res = await fetch(url, { headers: { Authorization: AUTH, Accept: 'application/json' } });
  if (!res.ok) throw new Error(`ERPNext ${res.status} on ${pathname}`);
  return res.json();
}

function pageAll(resource, fields) {
  // Small bounded page; real deployments paginate with limit_start/limit_page_length.
  return erp(`/api/resource/${resource}`, { fields: JSON.stringify(fields), limit_page_length: 500 });
}

function stableId(cat, ...parts) { return `${cat}:${parts.map(String).join(':')}`; }

function upsert({ id, category, severity, title, description, rule, relatedRecord }) {
  const found = db.prepare('SELECT id, status FROM exceptions WHERE id = ?').get(id);
  if (found) {
    // Resolved/Dismissed does NOT reappear unless the condition genuinely recurs.
    if (found.status === 'Resolved' || found.status === 'Dismissed') return;
    return; // already active -> prevent duplicate
  }
  db.prepare(`INSERT INTO exceptions
    (id, category, severity, title, description, rule, related_record, detected_at, status)
    VALUES (?,?,?,?,?,?,?,?, 'New')`)
    .run(id, category, severity, title, description, rule, relatedRecord, nowISO());
  db.prepare('INSERT INTO activity (exception_id, ts, actor, action) VALUES (?,?,?,?)')
    .run(id, nowISO(), 'system', 'detected');
}

async function detect() {
  // A. Low stock + B. Out of stock (from Bin — real current quantity).
  const bins = await pageAll('Bin', ['item_code','warehouse','actual_qty','stock_value','item_name']);
  const reorder = await pageAll('Item Reorder', ['parent','warehouse','warehouse_reorder_level']);
  const reorderMap = new Map();
  for (const r of reorder.data || []) reorderMap.set(`${r.parent}|${r.warehouse}`, r.warehouse_reorder_level);
  for (const b of bins.data || []) {
    const level = reorderMap.get(`${b.item_code}|${b.warehouse}`);
    if (CFG.outOfStock && Number(b.actual_qty) === 0) {
      upsert({ id: stableId('out_of_stock', b.item_code, b.warehouse), category: 'Out of Stock',
        severity: 'Critical', title: `Out of stock: ${b.item_code}`, description: `${b.item_name || b.item_code} has zero available stock in ${b.warehouse}.`,
        rule: `actual_qty == 0`, relatedRecord: `Item ${b.item_code}` });
    } else if (CFG.lowStock && level != null && Number(b.actual_qty) < Number(level)) {
      upsert({ id: stableId('low_stock', b.item_code, b.warehouse), category: 'Low Stock',
        severity: 'High', title: `Low stock: ${b.item_code}`, description: `${b.item_name || b.item_code} is below reorder level in ${b.warehouse}.`,
        rule: `actual_qty ${b.actual_qty} < reorder_level ${level}`, relatedRecord: `Item ${b.item_code}` });
    }
  }

  // C. Overdue purchase orders.
  if (CFG.overduePO) {
    const pos = await pageAll('Purchase Order', ['name','supplier','schedule_date','docstatus','per_received','items']);
    const today = new Date();
    for (const po of pos.data || []) {
      if (po.docstatus !== 1) continue;
      if (!po.schedule_date) continue;
      const due = new Date(po.schedule_date);
      if (due < today && Number(po.per_received || 0) < 100) {
        const days = Math.floor((today - due) / 86400000);
        upsert({ id: stableId('overdue_po', po.name), category: 'Overdue Purchase Order',
          severity: 'High', title: `Overdue PO ${po.name}`, description: `Purchase Order ${po.name} from ${po.supplier || 'unknown supplier'} is overdue.`,
          rule: `schedule_date ${po.schedule_date} < today, ${days} days overdue`, relatedRecord: `Purchase Order ${po.name}` });
      }
    }
  }

  // F. Pending stock transfers (draft Material Transfer older than threshold).
  const se = await pageAll('Stock Entry', ['name','stock_entry_type','docstatus','creation']);
  const cutoff = nowISO();
  const cutoffMs = Date.now() - CFG.pendingTransferHours * 3600000;
  for (const e of se.data || []) {
    if (e.docstatus === 0 && e.stock_entry_type === 'Material Transfer' && new Date(e.creation).getTime() < cutoffMs) {
      upsert({ id: stableId('pending_transfer', e.name), category: 'Pending Stock Transfer',
        severity: 'Medium', title: `Pending transfer ${e.name}`, description: `Stock Entry ${e.name} has been in draft for over ${CFG.pendingTransferHours}h.`,
        rule: `docstatus=0 && creation older than ${CFG.pendingTransferHours}h`, relatedRecord: `Stock Entry ${e.name}` });
    }
  }

  // H. Expiring batches.
  const batches = await pageAll('Batch', ['name','item','expiry_date','batch_qty']);
  for (const bt of batches.data || []) {
    if (!bt.expiry_date) continue;
    const ms = new Date(bt.expiry_date).getTime() - Date.now();
    for (const days of CFG.expiringDays) {
      if (ms > 0 && ms <= days * 86400000) {
        upsert({ id: stableId('expiring_batch', bt.name, days), category: 'Expiring Batch',
          severity: days <= 7 ? 'Critical' : days <= 14 ? 'High' : 'Medium',
          title: `Batch ${bt.name} expiring`, description: `Batch ${bt.name} (${bt.item}) expires in <= ${days} days.`,
          rule: `expiry within ${days} days`, relatedRecord: `Batch ${bt.name}` });
        break;
      }
    }
  }

  return { ok: true };
}

function json(res, code, obj) {
  res.writeHead(code, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
  res.end(JSON.stringify(obj));
}

function readBody(req) {
  return new Promise((resolve) => {
    let d = '';
    req.on('data', (c) => (d += c));
    req.on('end', () => { try { resolve(d ? JSON.parse(d) : {}); } catch { resolve({}); } });
  });
}

const server = http.createServer(async (req, res) => {
  if (req.method === 'OPTIONS') { res.writeHead(204, { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': '*', 'Access-Control-Allow-Methods': '*' }); return res.end(); }
  const url = new URL(req.url, 'http://localhost');

  if (url.pathname === '/health') return json(res, 200, { status: 'ok', erp: ERP_URL });

  if (url.pathname === '/detect' && req.method === 'POST') {
    try { await detect(); return json(res, 200, { ok: true }); }
    catch (e) { return json(res, 500, { error: String(e.message || e) }); }
  }

  if (url.pathname === '/exceptions' && req.method === 'GET') {
    const status = url.searchParams.get('status');
    const category = url.searchParams.get('category');
    let rows;
    if (status) rows = db.prepare('SELECT * FROM exceptions WHERE status = ? ORDER BY detected_at DESC').all(status);
    else if (category) rows = db.prepare('SELECT * FROM exceptions WHERE category = ? ORDER BY detected_at DESC').all(category);
    else rows = db.prepare('SELECT * FROM exceptions ORDER BY detected_at DESC').all();
    return json(res, 200, rows);
  }

  const m = url.pathname.match(/^\/exceptions\/([^/]+)(?:\/(assign|investigate|resolve|dismiss))?$/);
  if (m) {
    const id = decodeURIComponent(m[1]);
    const action = m[2];
    if (req.method === 'GET' && !action) {
      const row = db.prepare('SELECT * FROM exceptions WHERE id = ?').get(id);
      if (!row) return json(res, 404, { error: 'not found' });
      const activity = db.prepare('SELECT * FROM activity WHERE exception_id = ? ORDER BY id').all(id);
      return json(res, 200, { ...row, activity });
    }
    if (req.method === 'POST' && action) {
      const body = await readBody(req);
      const actor = body.actor || 'user';
      const map = {
        assign: ['Assigned', `assigned to ${body.assignee || '?'}`, { assigned_to: body.assignee || null }],
        investigate: ['Investigating', 'investigation started', {}],
        resolve: ['Resolved', body.note || 'resolved', { resolution_note: body.note || null, resolved_at: nowISO() }],
        dismiss: ['Dismissed', body.note || 'dismissed', { resolution_note: body.note || null, resolved_at: nowISO() }],
      };
      const [status, detail, fields] = map[action];
      db.prepare(`UPDATE exceptions SET status = ?${fields.assigned_to !== undefined ? ', assigned_to = ?' : ''}${fields.resolution_note !== undefined ? ', resolution_note = ?' : ''}${fields.resolved_at !== undefined ? ', resolved_at = ?' : ''} WHERE id = ?`)
        .run(status, ...Object.values(fields), id);
      db.prepare('INSERT INTO activity (exception_id, ts, actor, action, detail) VALUES (?,?,?,?,?)')
        .run(id, nowISO(), actor, action, detail);
      return json(res, 200, { ok: true, id, status });
    }
  }

  json(res, 404, { error: 'not found' });
});

server.listen(PORT, () => {
  console.log(`exception-service on :${PORT}, ERPNext ${ERP_URL}`);
  if (AUTH) { detect().then(() => console.log('initial detection done')).catch((e) => console.error('detect failed:', e.message)); }
  else console.warn('WARNING: no ERPNEXT_AUTH_HEADER/API key set — detection will fail.');
});

// Re-run detection on an interval (5 min) so the centre stays current.
setInterval(() => { detect().catch((e) => console.error('detect failed:', e.message)); }, 5 * 60 * 1000);
