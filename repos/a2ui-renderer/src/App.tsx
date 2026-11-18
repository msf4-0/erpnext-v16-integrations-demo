import React, { useState } from 'react';

interface AppProps {
  user: string;
  company: string;
}

export const App: React.FC<AppProps> = ({ user, company }) => {
  const [input, setInput] = useState('');
  const [messages, setMessages] = useState<Array<{ sender: string; text: string }>>([
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
      // Call your custom Frappe whitelist method in dsh_bridge.api
      const response = await fetch('/api/method/dsh_bridge.api.handle_chat', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-Frappe-CSRF-Token': (window as any).frappe?.csrf_token || '',
        },
        body: JSON.stringify({ prompt: userMessage, company }),
      });

      const json = await response.json();
      const result = json.message || json;
      
      let replyText = result.reply || 'Received response from backend orchestrator.';
      if (result.data) {
        replyText += `\n${JSON.stringify(result.data, null, 2)}`;
      }
      
      setMessages(prev => [...prev, { sender: 'assistant', text: replyText }]);
    } catch (err) {
      setMessages(prev => [...prev, { sender: 'assistant', text: 'Error communicating with backend bridge.' }]);
    } finally {
      setLoading(false);
    }
  };

  return (
    <div style={{ padding: '24px', fontFamily: 'sans-serif', maxWidth: '800px', margin: '0 auto' }}>
      <h2>DSH Assistant Active Workspace</h2>
      <p><strong>Logged in User:</strong> {user} | <strong>Active Company:</strong> {company}</p>
      
      <div style={{ marginTop: '20px', border: '1px solid #dee2e6', borderRadius: '8px', padding: '16px', background: '#fff', minHeight: '300px', display: 'flex', flexDirection: 'column', justifyContent: 'space-between' }}>
        <div style={{ flex: 1, overflowY: 'auto', marginBottom: '16px', maxHeight: '400px', whiteSpace: 'pre-wrap' }}>
          {messages.map((msg, idx) => (
            <div key={idx} style={{ margin: '8px 0', padding: '10px 14px', borderRadius: '6px', background: msg.sender === 'user' ? '#e9ecef' : '#f1f3f5' }}>
              <strong>{msg.sender === 'user' ? 'You' : 'DSH Assistant'}:</strong> {msg.text}
            </div>
          ))}
          {loading && <div style={{ color: '#6c757d', fontStyle: 'italic' }}>Processing workflow...</div>}
        </div>

        <form onSubmit={handleSend} style={{ display: 'flex', gap: '8px' }}>
          <input 
            type="text" 
            value={input} 
            onChange={e => setInput(e.target.value) } 
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