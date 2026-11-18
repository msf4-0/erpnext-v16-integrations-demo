import React from 'react';

interface AppProps {
  user: string;
  company: string;
}

export const App: React.FC<AppProps> = ({ user, company }) => {
  return (
    <div style={{ padding: '24px', fontFamily: 'sans-serif' }}>
      <h2>DSH Assistant Active Workspace</h2>
      <p><strong>Logged in User:</strong> {user}</p>
      <p><strong>Active Company:</strong> {company}</p>
      <div style={{ marginTop: '20px', padding: '16px', background: '#f8f9fa', border: '1px solid #dee2e6', borderRadius: '6px' }}>
        <p>Chat interface is ready to mount workflows here.</p>
      </div>
    </div>
  );
};
