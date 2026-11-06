import frappe

script = """
frappe.ui.form.on('Metabase Dashboard', {
    refresh: function(frm) {
        if (frm.is_new()) return;
        frappe.call({
            method: 'metabase_integration.metabase_integration.doctype.metabase_dashboard.get_url',
            args: { dashboard: frm.doc.name },
            callback: function(r) {
                if (r.message && r.message.iframeUrl) {
                    $('.metabase-embed').remove();
                    var $e = $('<div class="metabase-embed" style="width:100%;margin:0;">' +
                        '<iframe src="' + r.message.iframeUrl + '" frameborder="0" ' +
                        'style="width:100%;height:85vh;border:0;display:block;"></iframe></div>');
                    var $layout = frm.$wrapper.find('.layout-main-section-wrapper, .layout-main-section');
                    if ($layout.length) { $layout.after($e); } else { frm.$wrapper.append($e); }
                }
            }
        });
    }
});
"""

if frappe.db.exists("Client Script", {"dt": "Metabase Dashboard", "view": "Form"}):
    name = frappe.db.get_value("Client Script", {"dt": "Metabase Dashboard", "view": "Form"}, "name")
    cs = frappe.get_doc("Client Script", name)
    cs.script = script
    cs.enabled = 1
    cs.save(ignore_permissions=True)
    print("updated client script:", name)
else:
    cs = frappe.new_doc("Client Script")
    cs.name = "metabase-dashboard-embed"
    cs.dt = "Metabase Dashboard"
    cs.view = "Form"
    cs.script = script
    cs.enabled = 1
    cs.insert(ignore_permissions=True)
    print("created client script:", cs.name)

frappe.db.commit()
print("COMMITTED")
