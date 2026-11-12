/* Item form — Item Tracking actions.
 * Loaded on the Item form via the `doctype_js` hook so users reach the tracker
 * naturally from the product master, not a detached link. */
frappe.ui.form.on('Item', {
	refresh(frm) {
		if (frm.is_new()) { return; }

		frm.add_custom_button(__('Tracked Units'), function () {
			frappe.set_route('List', 'Tracked Item', { item_code: frm.doc.name });
		}, __('Item Tracking'));

		frm.add_custom_button(__('All Units (Grouped by Item)'), function () {
			window.location.href = '/tracked_units';
		}, __('Item Tracking'));

		frappe.db.count('Tracked Item', { filters: { item_code: frm.doc.name } }).then((n) => {
			if (n) { frm.dashboard.add_indicator(__('{0} tracked unit(s)', [n]), 'blue'); }
		});

		frm.add_custom_button(__('Create Tracked Units'), function () {
			frappe.prompt([
				{ fieldname: 'qty', fieldtype: 'Int', label: __('Quantity'), reqd: 1, default: 1 },
				{ fieldname: 'warehouse', fieldtype: 'Link', options: 'Warehouse', label: __('Warehouse') }
			], function (values) {
				frappe.call({
					method: 'item_tracking.item_tracking.doctype.tracked_item.tracked_item.bulk_create_tracked_items',
					args: {
						item_code: frm.doc.name,
						qty: values.qty,
						warehouse: values.warehouse || null
					},
					freeze: true,
					callback: function (r) {
						frappe.msgprint(__('Created {0} tracked unit(s)', [r.message.length]));
					}
				});
			}, __('Create Tracked Units'), __('Create'));
		}, __('Item Tracking'));
	}
});
