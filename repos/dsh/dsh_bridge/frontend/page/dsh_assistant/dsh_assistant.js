frappe.pages['dsh-assistant'].on_page_load = function(wrapper) {
  const page = frappe.ui.make_app_page({
    parent: wrapper,
    title: 'DSH Assistant',
    single_column: true
  });

  const user = frappe.session.user;
  const company = frappe.defaults.get_user_default('Company') || 'Not Set';

  // Isolated root container for the React/A2UI chat interface
  $(page.body).html(`
    <div id="dsh-assistant-root" style="min-height: calc(100vh - 140px); display: flex; flex-direction: column; padding: 20px;">
      <div class="alert alert-info">
        <strong>DSH Assistant Workspace Ready</strong><br>
        Logged in as: <code>${user}</code> | Active Company: <code>${company}</code><br>
        <small class="text-muted">Waiting for @shrdc/a2ui-renderer bundle...</small>
      </div>
    </div>
  `);

  // Once Phase 3 bundle is deployed, uncomment this to mount the UI:
  /*
  frappe.require('/assets/dsh_bridge/js/a2ui-renderer.js', () => {
    if (window.A2UIRenderer && typeof window.A2UIRenderer.mount === 'function') {
      window.A2UIRenderer.mount(document.getElementById('dsh-assistant-root'), {
        user,
        company
      });
    }
  });
  */
};