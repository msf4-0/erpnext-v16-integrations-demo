/**
 * Runnable check: `node src/surface.check.ts` (Node 24 strips types directly).
 * Uses the exact surface shape that dsh_bridge/a2ui.py emits.
 */
import assert from 'node:assert/strict';
import { atom, getPath, surfaceToNode, surfaceToNodes } from './surface.ts';

const inventory = {
  surfaceId: 'a2ui-test',
  protocol: 'a2ui/0.9',
  components: [
    { id: 'root', component: { Card: { child: 'col' } } },
    { id: 'col', component: { Column: { children: { explicitList: ['title', 'table', 'count'] } } } },
    { id: 'title', component: { Text: { text: { literalString: 'Inventory: Stores - SD' }, usageHint: 'h3' } } },
    {
      id: 'table',
      component: {
        Table: {
          columns: [
            { key: 'item_code', label: 'Item' },
            { key: 'qty', label: 'Qty', align: 'right' },
          ],
          rows: { path: '/rows' },
        },
      },
    },
    { id: 'count', component: { Text: { text: { literalString: '2 row(s)' } } } },
  ],
  dataModel: {
    rows: [
      { item_code: 'SKU007', qty: 190 },
      { item_code: 'SKU008', qty: 4 },
    ],
  },
};

const root = surfaceToNode(inventory);
assert.equal(root?.type, 'Card');
assert.equal(root?.children[0].type, 'Column');
assert.deepEqual(root?.children[0].children.map((n) => n.type), ['Text', 'Table', 'Text']);

// Values are resolved from the dataModel, not baked into the layout.
const rows = atom((root!.children[0].children[1].props as any).rows, inventory.dataModel);
assert.deepEqual(rows, inventory.dataModel.rows);
assert.equal(atom({ literalString: 'x' }), 'x');
assert.equal(getPath(inventory.dataModel, 'rows'), inventory.dataModel.rows);

// Missing child ids and cycles are skipped, never thrown.
const broken = {
  surfaceId: 'a2ui-broken',
  components: [
    { id: 'root', component: { Card: { child: 'ghost' } } },
    { id: 'ghost', component: { Column: { children: { explicitList: ['root'] } } } },
  ],
};
assert.equal(surfaceToNode(broken), null); // every component is referenced: no root

const multi = { surfaceId: 'a2ui-multi', components: [
  { id: 'a', component: { Text: { text: { literalString: 'a' } } } },
  { id: 'b', component: { Text: { text: { literalString: 'b' } } } },
] };
assert.deepEqual(surfaceToNodes(multi).map((n) => n.id), ['a', 'b']);

assert.equal(surfaceToNode(null), null);
assert.deepEqual(surfaceToNodes({ surfaceId: 'x' }), []);

console.log('surface ok');
console.log('  root:', root?.type, '→', root?.children[0].children.map((n) => n.type).join(', '));
console.log('  rows resolved from dataModel:', (rows as unknown[]).length);
