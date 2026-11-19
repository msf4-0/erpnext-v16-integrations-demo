import React, { useState } from 'react';

interface AppProps {
  user: string;
  company: string;
}

type Column = [string, string];

interface ChatTable {
  columns: Column[];
  rows: Array<Record<string, any>>;
}

interface ChatMessage {
  sender: 'user' | 'assistant';
  text: string;
  table?: ChatTable;
}

const DEFAULT_COLUMNS: Column[] = [
  ['item_code', 'Item'],
  ['item_name', 'Name'],
  ['warehouse', 'Warehouse'],
  ['actual_qty', 'Qty'],
  ['stock_uom', 'UOM'],
];

// Frappe returns errors as exc_type/exception (500) or _server_messages, not as
// message.reply. Surface them instead of falling back to a generic sentence.
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

export const App: React.FC<AppProps> = ({ user, company }) => {
  const [input, setInput] = useState('');
  const [messages, setMessages] = useState<ChatMessage[]>([
    { sender: 'assistant', text: 'Chat interface is ready. Type a prompt to test the dsh bridge backend.' }
  ]);
  const [loading, setLoading] = useState(false);

  const handleSend = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!input.trim() || loading) return;

    const userMessage = input;
    setInput('');
    setMessages(prev => [...prev, { sender: 'user', text: userMessage }]);
    setLoading(true);

    try {
      const response = await fetch('/api/method/dsh_bridge.api.handle_chat', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-Frappe-CSRF-Token': (window as any).frappe?.csrf_token || '',
        },
        body: JSON.stringify({ prompt: userMessage, company }),
      });

      const json = await response.json().catch(() => null);
      const result = json?.message ?? json ?? {};

      const backendError =
        extractError(json) || (result.status === 'error' ? result.reply : null);
      if (backendError) {
        setMessages(prev => [
          ...prev,
          { sender: 'assistant', text: `Error: ${backendError}` },
        ]);
        return;
      }

      const replyText: string =
        result.reply || 'Received an empty response from the backend.';

      const isInventory =
        result.card_type === 'inventory_table' && Array.isArray(result.data);

      setMessages(prev => [
        ...prev,
        {
          sender: 'assistant',
          text: replyText,
          table: isInventory
            ? {
                columns:
                  Array.isArray(result.columns) && result.columns.length
                    ? result.columns
                    : DEFAULT_COLUMNS,
                rows: result.data,
              }
            : undefined,
        },
      ]);
    } catch (err) {
      setMessages(prev => [
        ...prev,
        { sender: 'assistant', text: 'Error communicating with backend bridge.' },
      ]);
    } finally {
      setLoading(false);
    }
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
    <div style={{ padding: '24px', fontFamily: 'sans-serif', maxWidth: '800px', margin: '0 auto' }}>
      <h2>DSH Assistant Active Workspace</h2>
      <p><strong>Logged in User:</strong> {user} | <strong>Active Company:</strong> {company}</p>

      <div style={{ marginTop: '20px', border: '1px solid #dee2e6', borderRadius: '8px', padding: '16px', background: '#fff', minHeight: '300px', display: 'flex', flexDirection: 'column', justifyContent: 'space-between' }}>
        <div style={{ flex: 1, overflowY: 'auto', marginBottom: '16px', maxHeight: '400px', whiteSpace: 'pre-wrap' }}>
          {messages.map((msg, idx) => (
            <div key={idx} style={{ margin: '8px 0', padding: '10px 14px', borderRadius: '6px', background: msg.sender === 'user' ? '#e9ecef' : '#f1f3f5' }}>
              <strong>{msg.sender === 'user' ? 'You' : 'DSH Assistant'}:</strong> {msg.text}
              {msg.table && renderTable(msg.table)}
            </div>
          ))}
          {loading && <div style={{ color: '#6c757d', fontStyle: 'italic' }}>Processing workflow...</div>}
        </div>

        <form onSubmit={handleSend} style={{ display: 'flex', gap: '8px' }}>
          <input
            type="text"
            value={input}
            onChange={e => setInput(e.target.value)}
            placeholder="Type a workflow prompt..."
            style={{ flex: 1, padding: '10px', borderRadius: '4px', border: '1px solid #ced4da' }}
          />
          <button type="submit" disabled={loading} style={{ padding: '10px 20px', background: '#007bff', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer' }}>
            Send
          </button>
        </form>
      </div>
    </div>
  );
};