import React from 'react';
import { createRoot } from 'react-dom/client';
import { App } from './App';

export function mount(container: HTMLElement, context: { user: string; company: string }) {
  const root = createRoot(container);
  root.render(
    <React.StrictMode>
      <App user={context.user} company={context.company} />
    </React.StrictMode>
  );
}

// Expose globally for frappe.require()
if (typeof window !== 'undefined') {
  (window as any).A2UIRenderer = { mount };
}
