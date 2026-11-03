/* Item list view — bulk "Create Tracked Units" action.
 * Select one or more Items in the list, then one click mass-creates tracked
 * units (one barcode/QR per physical unit) for all of them at once — instead of
 * opening each Item form and prompting repeatedly.
 */
frappe.listview_settings['Item'] = {
	onload: function (listview) {
		listview.page.add_action_item(__('Create Tracked Units'), function () {
			const selected = listview.get_checked_items();
			if (!selected.length) {
				frappe.msgprint({
					title: __('No items selected'),
					indicator: 'orange',
					message: __('Select one or more items in the list first.')
				});
				return;
			}

			const rows = selected.map(function (d) {
				return { item_code: d.name, qty: 1 };
			});

			frappe.prompt([
				{
					fieldname: 'qty',
					fieldtype: 'Int',
					label: __('Units per item'),
					reqd: 1,
					default: 1,
					description: __('One tracked unit = one barcode/QR label.')
				},
				{
					fieldname: 'warehouse',
					fieldtype: 'Link',
					options: 'Warehouse',
					label: __('Warehouse')
				}
			], function (values) {
				const payload = rows.map(function (r) {
					return {
						item_code: r.item_code,
						qty: values.qty,
						warehouse: values.warehouse || null
					};
				});
				frappe.call({
					method: 'item_tracking.item_tracking.doctype.tracked_item.tracked_item.bulk_transfer_tracked_items',
					args: { rows: payload },
					freeze: true,
					freeze_message: __('Creating tracked units…'),
					callback: function (r) {
						if (r.exc) {
							frappe.msgprint({
								title: __('Bulk creation failed'),
								indicator: 'red',
								message: r.exc
							});
							return;
						}
						const count = (r.message && r.message.created) || 0;
						frappe.msgprint({
							title: __('Tracked units created'),
							indicator: 'green',
							message: __('Created {0} tracked unit(s) across {1} item(s). ' +
								'You can print their labels from Barcode Printing → Load Tracked Items.',
								[count, rows.length])
						});
					}
				});
			}, __('Create Tracked Units'), __('Create'));
		});
	}
};
