/**
 * Renders one A2UI surface as React, using a whitelist of components.
 *
 * Everything unknown returns null instead of throwing, so a server-side card
 * experiment can never take the chat pane down. Buttons carry the confirm token
 * inside the `x-erpnext` extension; the view never computes arguments itself.
 */
import React, { useState } from 'react';
import { atom, surfaceToNode, type A2UINode, type A2UISurface } from './surface';

export interface SurfaceAction {
  name: string;
  args?: Record<string, unknown>;
  token?: string;
  confirmRequired?: boolean;
}

interface SurfaceViewProps {
  surface: A2UISurface | null | undefined;
  onAction?: (action: SurfaceAction) => Promise<void> | void;
}

const dataOf = (surface: A2UISurface | null | undefined) => surface?.dataModel ?? {};

export const SurfaceView: React.FC<SurfaceViewProps> = ({ surface, onAction }) => {
  const root = surfaceToNode(surface);
  if (!root) return null;
  return <>{renderNode(root, dataOf(surface), onAction)}</>;
};

function renderNode(
  node: A2UINode,
  dataModel: Record<string, unknown>,
  onAction?: (action: SurfaceAction) => Promise<void> | void,
): React.ReactNode {
  switch (node.type) {
    case 'Card':
      return (
        <div
          key={node.id}
          style={{
            border: '1px solid #dee2e6',
            borderRadius: '8px',
            padding: '16px',
            background: '#fff',
            marginTop: '10px',
          }}
        >
          {renderChildren(node, dataModel, onAction)}
        </div>
      );

    case 'Column':
      return (
        <div key={node.id} style={{ display: 'flex', flexDirection: 'column', gap: '10px' }}>
          {renderChildren(node, dataModel, onAction)}
        </div>
      );

    case 'Row':
      return (
        <div key={node.id} style={{ display: 'flex', flexDirection: 'row', gap: '8px', flexWrap: 'wrap' }}>
          {renderChildren(node, dataModel, onAction)}
        </div>
      );

    case 'Text': {
      const value = atom(node.props.text, dataModel);
      const text = value === null || value === undefined ? '' : String(value);
      const hint = typeof node.props.usageHint === 'string' ? node.props.usageHint : '';
      if (hint === 'h3') return <h3 key={node.id} style={{ margin: 0 }}>{text}</h3>;
      if (hint === 'caption') return <small key={node.id} style={{ color: '#6c757d' }}>{text}</small>;
      return <div key={node.id}>{text}</div>;
    }

    case 'Badge':
      return (
        <span
          key={node.id}
          style={{
            display: 'inline-block',
            padding: '2px 8px',
            borderRadius: '999px',
            fontSize: '12px',
            background: node.props.tone === 'danger' ? '#f8d7da' : '#e7f5ff',
            color: node.props.tone === 'danger' ? '#842029' : '#0b4a6f',
          }}
        >
          {String(atom(node.props.text, dataModel) ?? '')}
        </span>
      );

    case 'Divider':
      return <hr key={node.id} style={{ border: 0, borderTop: '1px solid #f1f3f5' }} />;

    case 'Link': {
      const text = String(atom(node.props.text, dataModel) ?? '');
      const href = String(atom(node.props.href, dataModel) ?? '');
      // A surface is server-supplied JSON: only same-origin paths, never an
      // absolute URL or javascript:.
      if (!href.startsWith('/')) return null;
      return (
        <a key={node.id} href={href} style={{ color: '#0d6efd', fontWeight: 600, textDecoration: 'none' }}>
          {text || href}
        </a>
      );
    }
    
    case 'Table':
      return renderTable(node, dataModel);

    case 'Button': {
      const label = labelOf(node, dataModel);
      return (
        <SurfaceButton
          key={node.id}
          label={label}
          action={readAction(node, dataModel)}
          onAction={onAction}
        />
      );
    }

    default:
      return null;
  }
}

function renderChildren(
  node: A2UINode,
  dataModel: Record<string, unknown>,
  onAction?: (action: SurfaceAction) => Promise<void> | void,
): React.ReactNode[] {
  return node.children.map((child) => renderNode(child, dataModel, onAction));
}

function labelOf(node: A2UINode, dataModel: Record<string, unknown>): string {
  const first = node.children[0];
  if (!first) return 'Continue';
  const value = atom(first.props.text, dataModel);
  return value ? String(value) : 'Continue';
}

function readAction(node: A2UINode, dataModel: Record<string, unknown>): SurfaceAction | null {
  const action = node.props.action as Record<string, unknown> | undefined;
  if (!action || typeof action.name !== 'string') return null;
  const ext = (action['x-erpnext'] ?? {}) as Record<string, unknown>;
  const args = ext.args as Record<string, unknown> | undefined;
  return {
    name: action.name,
    args: args && typeof args === 'object' ? args : undefined,
    token: typeof ext.token === 'string' ? ext.token : undefined,
    confirmRequired: Boolean(ext.confirm_required),
  };
}

function renderTable(node: A2UINode, dataModel: Record<string, unknown>): React.ReactNode {
  const columns = Array.isArray(node.props.columns)
    ? (node.props.columns as Array<{ key: string; label: string; align?: string }>)
    : [];
  const value = atom(node.props.rows, dataModel);
  const rows = Array.isArray(value) ? (value as Array<Record<string, unknown>>) : [];

  const align = (column: { align?: string; key: string }) =>
    column.align === 'right' || column.key === 'actual_qty' ? 'right' : 'left';

  return (
    <table key={node.id} style={{ width: '100%', borderCollapse: 'collapse', fontSize: '13px', background: '#fff' }}>
      <thead>
        <tr>
          {columns.map((column) => (
            <th
              key={column.key}
              style={{
                textAlign: align(column) as 'left' | 'right',
                borderBottom: '1px solid #ced4da',
                padding: '6px 8px',
                fontWeight: 600,
              }}
            >
              {column.label}
            </th>
          ))}
        </tr>
      </thead>
      <tbody>
        {rows.map((row, index) => (
          <tr key={index}>
            {columns.map((column) => (
              <td
                key={column.key}
                style={{
                  borderBottom: '1px solid #f1f3f5',
                  padding: '6px 8px',
                  textAlign: align(column) as 'left' | 'right',
                  fontVariantNumeric: 'tabular-nums',
                }}
              >
                {formatCell(column.key, row[column.key])}
              </td>
            ))}
          </tr>
        ))}
      </tbody>
    </table>
  );
}

function formatCell(key: string, value: unknown): string {
  if (value === null || value === undefined || value === '') return '';
  if (key === 'actual_qty' || key === 'qty' || key === 'rate') {
    const number = Number(value);
    if (!Number.isNaN(number)) return number.toLocaleString(undefined, { maximumFractionDigits: 3 });
  }
  return String(value);
}

const SurfaceButton: React.FC<{
  label: string;
  action: SurfaceAction | null;
  onAction?: (action: SurfaceAction) => Promise<void> | void;
}> = ({ label, action, onAction }) => {
  const [state, setState] = useState<'idle' | 'pending' | 'done'>('idle');

  const fire = async () => {
    if (!action || !onAction || state !== 'idle') return;
    setState('pending');
    try {
      await onAction(action);
      setState('done');
    } catch {
      setState('idle');
    }
  };

  if (!action) return <span style={{ color: '#adb5bd' }}>{label}</span>;

  return (
    <button
      type="button"
      onClick={fire}
      disabled={state !== 'idle'}
      style={{
        alignSelf: 'flex-start',
        padding: '8px 14px',
        borderRadius: '4px',
        border: '1px solid #007bff',
        background: '#007bff',
        color: '#fff',
        opacity: state === 'idle' ? 1 : 0.6,
        cursor: state === 'idle' ? 'pointer' : 'default',
      }}
    >
      {state === 'pending' ? 'Working…' : state === 'done' ? `${label} ✓` : label}
    </button>
  );
};
