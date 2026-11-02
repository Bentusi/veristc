import { useEffect, useState } from 'react';

export type ToastType = 'success' | 'error' | 'warning' | 'info';

export interface Toast {
  id: string;
  type: ToastType;
  title: string;
  message?: string;
  duration?: number;
}

let globalAddToast: ((toast: Omit<Toast, 'id'>) => void) | null = null;

export const toast = {
  success: (title: string, message?: string, duration = 3000) => {
    globalAddToast?.({ type: 'success', title, message, duration });
  },
  error: (title: string, message?: string, duration = 5000) => {
    globalAddToast?.({ type: 'error', title, message, duration });
  },
  warning: (title: string, message?: string, duration = 4000) => {
    globalAddToast?.({ type: 'warning', title, message, duration });
  },
  info: (title: string, message?: string, duration = 3000) => {
    globalAddToast?.({ type: 'info', title, message, duration });
  },
};

export function ToastProvider({ children }: { children: React.ReactNode }) {
  const [toasts, setToasts] = useState<Toast[]>([]);

  useEffect(() => {
    globalAddToast = (toast) => {
      const id = `${Date.now()}-${Math.random()}`;
      setToasts((prev) => [...prev, { ...toast, id }]);
    };
    return () => {
      globalAddToast = null;
    };
  }, []);

  const removeToast = (id: string) => {
    setToasts((prev) => prev.filter((t) => t.id !== id));
  };

  return (
    <>
      {children}
      <ToastContainer toasts={toasts} onRemove={removeToast} />
    </>
  );
}

function ToastContainer({
  toasts,
  onRemove,
}: {
  toasts: Toast[];
  onRemove: (id: string) => void;
}) {
  return (
    <div className="fixed top-4 right-4 z-50 flex flex-col gap-2 pointer-events-none">
      {toasts.map((toast) => (
        <ToastItem key={toast.id} toast={toast} onRemove={onRemove} />
      ))}
    </div>
  );
}

function ToastItem({ toast, onRemove }: { toast: Toast; onRemove: (id: string) => void }) {
  useEffect(() => {
    const timer = setTimeout(() => {
      onRemove(toast.id);
    }, toast.duration ?? 3000);
    return () => clearTimeout(timer);
  }, [toast.id, toast.duration, onRemove]);

  const bgColor = {
    success: 'bg-green-600/90 border-green-500',
    error: 'bg-red-600/90 border-red-500',
    warning: 'bg-yellow-600/90 border-yellow-500',
    info: 'bg-blue-600/90 border-blue-500',
  }[toast.type];

  const icon = {
    success: '✓',
    error: '✕',
    warning: '⚠',
    info: 'ℹ',
  }[toast.type];

  return (
    <div
      className={`pointer-events-auto px-4 py-3 rounded-lg border ${bgColor} text-white shadow-lg min-w-72 max-w-96`}
    >
      <div className="flex items-start gap-3">
        <span className="text-lg font-bold mt-0.5">{icon}</span>
        <div className="flex-1">
          <div className="font-semibold text-sm">{toast.title}</div>
          {toast.message && <div className="text-xs mt-1 opacity-90">{toast.message}</div>}
        </div>
        <button
          onClick={() => onRemove(toast.id)}
          className="text-white/70 hover:text-white text-lg leading-none"
        >
          ×
        </button>
      </div>
    </div>
  );
}
