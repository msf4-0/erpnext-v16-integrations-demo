frappe.pages['dsh-assistant'].on_page_load = function(wrapper) {
    var page = frappe.ui.make_app_page({
        parent: wrapper,
        title: 'DSH Assistant',
        single_column: true
    });

    // 1. Expand Frappe's centered container to full width & remove default padding
    $(wrapper).find('.layout-main-section-wrapper').css({
        'padding': '0',
        'margin': '0'
    });
    $(wrapper).find('.container.page-body').css({
        'max-width': '100%',
        'width': '100%',
        'padding': '0',
        'margin': '0'
    });
    $(wrapper).find('.page-head').hide(); // Optional: hides the top title bar for more vertical space

    // 2. Make the root container fill the viewport height and use flex layout
    let $container = $(page.body).html(`
        <div id="dsh-assistant-root" style="
            width: 100%;
            height: calc(100vh - 48px); /* Adjust 48px if your top navbar height differs */
            display: flex;
            flex-direction: column;
            padding: 16px;
            box-sizing: border-box;
        ">Waiting for renderer bundle...</div>
    `);

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
