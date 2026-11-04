return (async function () {
  const ERP = process.env.ERPNEXT_INTERNAL_URL || 'http://bench:8000';
  const STORE = process.env.SHOPIFY_STORE || '4e1075.myshopify.com';
  const ERP_AUTH = 'token aaaaaaaaaaaaaaa:bbbbbbbbbbbbbbb';
  const SHOP_AUTH = 'shpat_aaaaaaaaaaaaaaaaaaaaaa';
  const fields = encodeURIComponent('["name","shopify_order_id","grand_total","status","docstatus"]');
  const get = async function (url, opts, ms) {
    const c = new AbortController();
    const t = setTimeout(function () { c.abort(); }, ms);
    try { return await fetch(url, Object.assign({}, opts, { signal: c.signal })); }
    finally { clearTimeout(t); }
  };
  const out = { erpnext: [], shopify: [] };
  try {
    const r = await get(ERP + '/api/resource/Sales%20Order?limit_page_length=1000&order_by=creation%20desc&fields=' + fields, { headers: { Authorization: ERP_AUTH } }, 9000);
    const j = await r.json();
    out.erpnext = j.data || [];
  } catch (e) { out.erpnext_error = String((e && e.message) || e); }
  try {
    const r = await get('https://' + STORE + '/admin/api/2026-04/orders.json?status=any&limit=250', { headers: { 'X-Shopify-Access-Token': SHOP_AUTH } }, 9000);
    const j = await r.json();
    out.shopify = j.orders || [];
  } catch (e) { out.shopify_error = String((e && e.message) || e); }
  const linked = new Set((out.erpnext || []).map(function (o) { return o.shopify_order_id; }).filter(Boolean).map(String));
  const missing = (out.shopify || []).filter(function (o) { return !linked.has(String(o.id)); });
  out.totals = { shopify: (out.shopify || []).length, erpnext: (out.erpnext || []).length, linked: linked.size, missing_in_erpnext: missing.length };
  out.missing_in_erpnext = missing.map(function (o) { return { id: String(o.id), name: o.name, total_price: o.total_price, financial_status: o.financial_status, created_at: o.created_at }; });
  msg.payload = out;
  return msg;
})().catch(function (e) { msg.payload = { error: String(e) }; return msg; });