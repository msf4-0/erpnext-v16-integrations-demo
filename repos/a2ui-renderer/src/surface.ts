/**
 * A2UI surface → render tree.
 *
 * The server sends a *flat* list of components plus a dataModel:
 *
 *   { surfaceId,
 *     components: [{ id: 'root', component: { Card: { child: 'col' } } }, ...],
 *     dataModel: { rows: [...] } }
 *
 * Layout lives in the components, values live in the dataModel, and a value is
 * referenced as { path: '/rows' }. This module turns that into the tree a React
 * renderer walks — no JSX, no fetch, no side effects, so it runs under plain
 * `node src/surface.check.ts`.
 *
 * Deliberately unsupported (fail soft, render nothing):
 *   - data-bound child lists: children: { template: {...}, path: '/rows' }
 *   - unknown component types: this module reports the type; the caller decides.
 */

export interface A2UIComponent {
  id: string;
  component: Record<string, unknown>;
}

export interface A2UISurface {
  surfaceId: string;
  protocol?: string;
  components?: A2UIComponent[];
  dataModel?: Record<string, unknown>;
}

export interface A2UINode {
  id: string;
  /** Component name: "Card", "Column", "Text", "Table", "Button", ... */
  type: string;
  /** Props exactly as sent; pass values through atom(). */
  props: Record<string, unknown>;
  children: A2UINode[];
}

export type DataModel = Record<string, unknown>;

/** Read a {path} / {literalString} binding; return any other value unchanged. */
export function atom(value: unknown, dataModel: DataModel = {}): unknown {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) return value;
  const spec = value as Record<string, unknown>;
  if (typeof spec.path === 'string') return getPath(dataModel, spec.path);
  if ('literalString' in spec) return spec.literalString;
  if ('literalNumber' in spec) return spec.literalNumber;
  if ('literalBoolean' in spec) return spec.literalBoolean;
  return value;
}

/** Resolve a dataModel path such as "/rows" or "/a/b" (empty segments ignored). */
export function getPath(dataModel: DataModel, path: string): unknown {
  const segments = path.split('/').filter(Boolean);
  let current: unknown = dataModel;
  for (const segment of segments) {
    if (current === null || typeof current !== 'object') return undefined;
    current = (current as Record<string, unknown>)[segment];
  }
  return current;
}

/** Ids a component links to: `child` (one) or `children.explicitList` (many). */
export function childIds(props: Record<string, unknown>): string[] {
  if (typeof props.child === 'string') return [props.child];
  const children = props.children as { explicitList?: unknown } | undefined;
  if (children && Array.isArray(children.explicitList)) {
    return children.explicitList.filter((id): id is string => typeof id === 'string');
  }
  return [];
}

/**
 * Every root: components nothing else links to, in document order.
 * A surface may legitimately hold more than one card.
 */
export function surfaceToNodes(surface: A2UISurface | null | undefined): A2UINode[] {
  if (!surface || !Array.isArray(surface.components)) return [];

  const byId = new Map<string, A2UIComponent>();
  for (const component of surface.components) {
    if (component && typeof component.id === 'string' && component.component) {
      byId.set(component.id, component);
    }
  }

  const referenced = new Set<string>();
  for (const component of byId.values()) {
    for (const props of Object.values(component.component)) {
      for (const id of childIds((props ?? {}) as Record<string, unknown>)) referenced.add(id);
    }
  }

  return [...byId.values()]
    .filter((component) => !referenced.has(component.id))
    .map((component) => build(component, byId, new Set()));
}

/** The single card a chat message renders, or null when there is no root. */
export function surfaceToNode(surface: A2UISurface | null | undefined): A2UINode | null {
  return surfaceToNodes(surface)[0] ?? null;
}

function build(
  component: A2UIComponent,
  byId: Map<string, A2UIComponent>,
  seen: Set<string>,
): A2UINode {
  const [type, rawProps] = Object.entries(component.component)[0] ?? ['Unknown', {}];
  const props = (rawProps ?? {}) as Record<string, unknown>;
  seen.add(component.id);

  const children: A2UINode[] = [];
  for (const id of childIds(props)) {
    const child = byId.get(id);
    if (!child || seen.has(child.id)) continue; // missing id or cycle: skip, never throw
    children.push(build(child, byId, seen));
  }

  return { id: component.id, type, props, children };
}
