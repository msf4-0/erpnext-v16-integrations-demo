frappe.pages['dsh-assistant'].on_page_load = function(wrapper) {
    var page = frappe.ui.make_app_page({
        parent: wrapper,
        title: 'DSH Assistant',
        single_column: true
    });

    // Create root container for React
    let $container = $(page.body).html('<div id="dsh-assistant-root" style="padding: 15px;">Waiting for renderer bundle...</div>');

    // Load the compiled standalone React bundle
    frappe.require('/assets/dsh_bridge/js/a2ui-renderer.js', () => {
        if (window.A2UIRenderer && window.A2UIRenderer.mount) {
            window.A2UIRenderer.mount(document.getElementById('dsh-assistant-root'), {
                user: frappe.session.user,
                company: frappe.defaults.get_user_default("Company") || "Default Company"
            });
        } else {
            console.error("A2UIRenderer failed to attach to window.");
        }
    });
};