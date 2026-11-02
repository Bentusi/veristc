import { useState, useRef, useEffect } from "react";

export interface MenuItem {
  id: string;
  label: string;
  shortcut?: string;
  disabled?: boolean;
  onClick?: () => void;
  children?: MenuItem[];
}

export interface MenuGroup {
  id: string;
  label: string;
  items: MenuItem[];
}

interface MenuBarProps {
  groups: MenuGroup[];
}

function MenuItemRow({ item, onClose }: { item: MenuItem; onClose: () => void }) {
  const [open, setOpen] = useState(false);

  if (item.children) {
    return (
      <div
        className="relative"
        onMouseEnter={() => setOpen(true)}
        onMouseLeave={() => setOpen(false)}
      >
        <button
          onClick={() => setOpen((v) => !v)}
          className={`w-full flex items-center justify-between px-3 py-1.5 text-xs hover:bg-ide-accent hover:text-white ${
            item.disabled ? "opacity-40 cursor-not-allowed" : ""
          }`}
          disabled={item.disabled}
        >
          <span>{item.label}</span>
          <span className="text-ide-textDim ml-4">▶</span>
        </button>
        {open && (
          <div className="absolute left-full top-0 bg-ide-sidebar border border-ide-border rounded shadow-lg min-w-[160px] z-50">
            {item.children.map((child) => (
              <MenuItemRow key={child.id} item={child} onClose={onClose} />
            ))}
          </div>
        )}
      </div>
    );
  }

  return (
    <button
      onClick={() => {
        if (!item.disabled) {
          item.onClick?.();
          onClose();
        }
      }}
      className={`w-full flex items-center justify-between px-3 py-1.5 text-xs hover:bg-ide-accent hover:text-white ${
        item.disabled ? "opacity-40 cursor-not-allowed" : ""
      }`}
      disabled={item.disabled}
    >
      <span>{item.label}</span>
      {item.shortcut && <span className="text-ide-textDim ml-4 font-mono text-[10px]">{item.shortcut}</span>}
    </button>
  );
}

function MenuDropdown({ group, onClose }: { group: MenuGroup; onClose: () => void }) {
  return (
    <div className="absolute top-full left-0 bg-ide-sidebar border border-ide-border rounded shadow-lg min-w-[160px] z-50 py-1">
      {group.items.map((item) => (
        <MenuItemRow key={item.id} item={item} onClose={onClose} />
      ))}
    </div>
  );
}

export function MenuBar({ groups }: MenuBarProps) {
  const [openId, setOpenId] = useState<string | null>(null);
  const barRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const handler = (e: MouseEvent) => {
      if (barRef.current && !barRef.current.contains(e.target as Node)) {
        setOpenId(null);
      }
    };
    document.addEventListener("mousedown", handler);
    return () => document.removeEventListener("mousedown", handler);
  }, []);

  return (
    <div ref={barRef} className="h-7 bg-ide-sidebar border-b border-ide-border flex items-center px-1 select-none">
      {groups.map((group) => (
        <div key={group.id} className="relative">
          <button
            onClick={() => setOpenId(openId === group.id ? null : group.id)}
            className={`px-2.5 py-0.5 text-xs rounded ${
              openId === group.id
                ? "bg-ide-accent text-white"
                : "text-ide-textDim hover:text-ide-text hover:bg-ide-hover"
            }`}
          >
            {group.label}
          </button>
          {openId === group.id && <MenuDropdown group={group} onClose={() => setOpenId(null)} />}
        </div>
      ))}
    </div>
  );
}
