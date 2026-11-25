import React, { useEffect, useRef, useState } from 'react';
import { SurfaceView, type SurfaceAction } from './SurfaceView';
import type { A2UISurface } from './surface';

interface AppProps {
  user: string;
  company: string;
}

type Column = [string, string];

interface ChatTable {
  columns: Column[];
  rows: Array<Record<string, any>>;
}

interface ChatAction {
  label: string;
  action: string;
  args?: Record<string, any>;
  token?: string;
  style?: string;
}

interface ChatMessage {
  sender: 'user' | 'assistant';
  text: string;
  table?: ChatTable;
  actions?: ChatAction[];
  ui?: A2UISurface | null;
}

const DEFAULT_COLUMNS: Column[] = [
  ['item_code', 'Item'],
  ['item_name', 'Name'],
  ['warehouse', 'Warehouse'],
  ['actual_qty', 'Qty'],
  ['stock_uom', 'UOM'],
];

function extractError(json: any): string | null {
  if (!json) return null;
  if (json.exc_type || json.exception) {
    return [json.exc_type, json.exception].filter(Boolean).join(': ');
  }
  if (json._server_messages) {
    try {
      const parsed = JSON.parse(json._server_messages);
      const text = parsed
        .map((m: any) => {
          try {
            return JSON.parse(m).message;
          } catch {
            return m;
          }
        })
        .filter(Boolean)
        .join(' ');
      if (text) return text;
    } catch {
      return String(json._server_messages);
    }
  }
  return null;
}

function formatCell(key: string, value: any) {
  if (value === null || value === undefined || value === '') return '';
  if (key === 'actual_qty' || key === 'qty') {
    const num = Number(value);
    if (!Number.isNaN(num)) {
      return num.toLocaleString(undefined, { maximumFractionDigits: 3 });
    }
  }
  return String(value);
}

function isSurface(value: any): value is A2UISurface {
  return Boolean(value && typeof value === 'object' && Array.isArray(value.components));
}

export const App: React.FC<AppProps> = ({ user, company }) => {
  const [input, setInput] = useState('');
  const [messages, setMessages] = useState<ChatMessage[]>([
    { sender: 'assistant', text: 'Chat interface is ready. Type a prompt to test the dsh bridge backend.' }
  ]);
  const [loading, setLoading] = useState(false);

  const messagesEndRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    messagesEndRef.current?.scrollIntoView({ behavior: 'smooth' });
  }, [messages, loading]);

  const sendRequest = async (path: string, body: any) => {
    const response = await fetch(path, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-Frappe-CSRF-Token': (window as any).frappe?.csrf_token || '',
      },
      body: JSON.stringify(body),
    });
    return response.json().catch(() => null);
  };

  const appendResult = (json: any) => {
    const result = json?.message ?? json ?? {};
    const error = extractError(json) || (result.status === 'error' ? result.reply : null);
    if (error) {
      setMessages(prev => [...prev, { sender: 'assistant', text: `Error: ${error}` }]);
      return;
    }

    const isInventory = result.card_type === 'inventory_table' && Array.isArray(result.data);
    setMessages(prev => [
      ...prev,
      {
        sender: 'assistant',
        text: result.reply || 'Received an empty response from the backend.',
        ui: isSurface(result.ui) ? result.ui : undefined,
        table: isInventory
          ? {
              columns:
                Array.isArray(result.columns) && result.columns.length
                  ? result.columns
                  : DEFAULT_COLUMNS,
              rows: result.data,
            }
          : undefined,
        actions: Array.isArray(result.actions) ? result.actions : undefined,
      },
    ]);
  };

  const handleSend = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!input.trim() || loading) return;

    const userMessage = input;
    setInput('');
    setMessages(prev => [...prev, { sender: 'user', text: userMessage }]);
    setLoading(true);

    try {
      const json = await sendRequest('/api/method/dsh_bridge.api.handle_chat', {
        prompt: userMessage,
        company,
      });
      appendResult(json);
    } catch (err) {
      setMessages(prev => [
        ...prev,
        { sender: 'assistant', text: 'Error communicating with backend bridge.' },
      ]);
    } finally {
      setLoading(false);
    }
  };

  const runAction = async (chatAction: ChatAction) => {
    if (loading) return;
    setLoading(true);
    // buttons are single-use: drop them so a double click cannot re-fire
    setMessages(prev => prev.map(m => ({ ...m, actions: undefined })));

    try {
      const json = await sendRequest('/api/method/dsh_bridge.api.execute_action', {
        action: chatAction.action,
        args: chatAction.args,
        confirm_token: chatAction.token,
      });
      appendResult(json);
    } catch (err) {
      setMessages(prev => [
        ...prev,
        { sender: 'assistant', text: 'Error communicating with backend bridge.' },
      ]);
    } finally {
      setLoading(false);
    }
  };

  const runSurfaceAction = async (action: SurfaceAction) => {
    // A tokenised action is one-shot: the server holds the arguments, the page
    // only carries the token, so a replayed click cannot create a second doc.
    const body = action.token
      ? { confirm_token: action.token }
      : { action: action.name, args: action.args };

    const json = await sendRequest('/api/method/dsh_bridge.api.execute_action', body);
    appendResult(json);
  };

  const cancelAction = () => {
    setMessages(prev => [
      ...prev.map(m => ({ ...m, actions: undefined })),
      { sender: 'assistant', text: 'Cancelled. Nothing was created.' },
    ]);
  };

  const renderTable = (table: ChatTable) => (
    <table
      style={{
        width: '100%',
        borderCollapse: 'collapse',
        marginTop: '8px',
        fontSize: '13px',
        background: '#fff',
      }}
    >
      <thead>
        <tr>
          {table.columns.map(([key, label]) => (
            <th
              key={key}
              style={{
                textAlign: key === 'actual_qty' ? 'right' : 'left',
                borderBottom: '1px solid #ced4da',
                padding: '6px 8px',
                fontWeight: 600,
              }}
            >
              {label}
            </th>
          ))}
        </tr>
      </thead>
      <tbody>
        {table.rows.map((row, rowIdx) => (
          <tr key={rowIdx}>
            {table.columns.map(([key]) => (
              <td
                key={key}
                style={{
                  borderBottom: '1px solid #f1f3f5',
                  padding: '6px 8px',
                  textAlign: key === 'actual_qty' ? 'right' : 'left',
                  fontVariantNumeric: 'tabular-nums',
                }}
              >
                {formatCell(key, row[key])}
              </td>
            ))}
          </tr>
        ))}
      </tbody>
    </table>
  );

 return (
    <div
      style={{
        padding: '16px 24px',
        fontFamily: 'sans-serif',
        width: '100%',
        height: '100%',
        boxSizing: 'border-box',
        display: 'flex',
        flexDirection: 'column',
      }}
    >
      <div style={{ flexShrink: 0 }}>
        <h2 style={{ margin: '0 0 4px 0' }}>DSH Assistant Active Workspace</h2>
        <p style={{ margin: 0 }}>
          <strong>Logged in User:</strong> {user} | <strong>Active Company:</strong> {company}
        </p>
      </div>

      <div
        style={{
          flex: 1,
          minHeight: 0,
          marginTop: '16px',
          border: '1px solid #dee2e6',
          borderRadius: '8px',
          padding: '16px',
          background: '#fff',
          display: 'flex',
          flexDirection: 'column',
          justifyContent: 'space-between',
        }}
      >
        <div
          style={{
            flex: 1,
            minHeight: 0,
            overflowY: 'auto',
            marginBottom: '16px',
            whiteSpace: 'pre-wrap',
          }}
        >
          {messages.map((msg, idx) => (
            <div
              key={idx}
              style={{
                margin: '8px 0',
                padding: '10px 14px',
                borderRadius: '6px',
                background: msg.sender === 'user' ? '#e9ecef' : '#f1f3f5',
              }}
            >
              <strong>{msg.sender === 'user' ? 'You' : 'DSH Assistant'}:</strong> {msg.text}
              {msg.ui && <SurfaceView surface={msg.ui} onAction={runSurfaceAction} />}
              {!msg.ui && msg.table && renderTable(msg.table)}
              {!msg.ui && msg.actions && msg.actions.length > 0 && (
                <div style={{ display: 'flex', gap: '8px', marginTop: '12px', whiteSpace: 'normal' }}>
                  {msg.actions.map((action, actionIdx) => (
                    <button
                      key={actionIdx}
                      type="button"
                      disabled={loading}
                      onClick={() => runAction(action)}
                      style={{
                        padding: '8px 14px',
                        borderRadius: '4px',
                        border: '1px solid #007bff',
                        background: '#007bff',
                        color: '#fff',
                        cursor: loading ? 'default' : 'pointer',
                        opacity: loading ? 0.6 : 1,
                      }}
                    >
                      {action.label}
                    </button>
                  ))}
                  <button
                    type="button"
                    disabled={loading}
                    onClick={cancelAction}
                    style={{
                      padding: '8px 14px',
                      borderRadius: '4px',
                      border: '1px solid #ced4da',
                      background: '#fff',
                      cursor: loading ? 'default' : 'pointer',
                    }}
                  >
                    Cancel
                  </button>
                </div>
              )}
            </div>
          ))}
          {loading && (
            <div style={{ color: '#6c757d', fontStyle: 'italic' }}>Processing workflow...</div>
          )}
          <div ref={messagesEndRef} />
        </div>

        <form onSubmit={handleSend} style={{ display: 'flex', gap: '8px', flexShrink: 0 }}>
          <input
            type="text"
            value={input}
            onChange={e => setInput(e.target.value)}
            placeholder="Type a workflow prompt..."
            style={{ flex: 1, padding: '10px', borderRadius: '4px', border: '1px solid #ced4da' }}
          />
          <button
            type="submit"
            disabled={loading}
            style={{
              padding: '10px 20px',
              background: '#007bff',
              color: '#fff',
              border: 'none',
              borderRadius: '4px',
              cursor: 'pointer',
            }}
          >
            Send
          </button>
        </form>
      </div>
    </div>
  );
};
