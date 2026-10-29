interface NavItem {
  id: string;
  icon: string;
  label: string;
}

interface ActivityBarProps {
  items: NavItem[];
  activeId: string;
  onSelect: (id: string) => void;
}

export function ActivityBar({ items, activeId, onSelect }: ActivityBarProps) {
  return (
    <div className="w-12 bg-ide-activity flex flex-col items-center py-2 border-r border-ide-border">
      {items.map((item) => (
        <button
          key={item.id}
          onClick={() => onSelect(item.id)}
          className={`w-10 h-10 flex items-center justify-center mb-1 rounded transition-colors ${
            activeId === item.id
              ? "text-white border-l-2 border-white bg-ide-hover"
              : "text-ide-textDim hover:text-ide-text"
          }`}
          title={item.label}
        >
          <svg viewBox="0 0 24 24" className="w-6 h-6" fill="currentColor">
            <path d={item.icon} />
          </svg>
        </button>
      ))}

      <div className="flex-1" />

      {/* Settings icon at bottom */}
      <button
        className="w-10 h-10 flex items-center justify-center text-ide-textDim hover:text-ide-text transition-colors"
        title="设置"
      >
        <svg viewBox="0 0 24 24" className="w-6 h-6" fill="currentColor">
          <path d="M19.14 12.94c.04-.3.06-.61.06-.94 0-.32-.02-.64-.07-.94l2.03-1.58a.49.49 0 00.12-.61l-1.92-3.32a.49.49 0 00-.59-.22l-2.39.96c-.5-.38-1.03-.7-1.62-.94l-.36-2.54a.484.484 0 00-.48-.41h-3.84c-.24 0-.43.17-.47.41l-.36 2.54c-.59.24-1.13.57-1.62.94l-2.39-.96a.49.49 0 00-.59.22L2.74 8.87c-.12.21-.08.47.12.61l2.03 1.58c-.05.3-.07.62-.07.94s.02.64.07.94l-2.03 1.58a.49.49 0 00-.12.61l1.92 3.32c.12.22.37.29.59.22l2.39-.96c.5.38 1.03.7 1.62.94l.36 2.54c.05.24.24.41.48.41h3.84c.24 0 .44-.17.47-.41l.36-2.54c.59-.24 1.13-.56 1.62-.94l2.39.96c.22.08.47 0 .59-.22l1.92-3.32c.12-.22.07-.47-.12-.61l-2.01-1.58zM12 15.6A3.6 3.6 0 1115.6 12 3.611 3.611 0 0112 15.6z" />
        </svg>
      </button>
    </div>
  );
}
