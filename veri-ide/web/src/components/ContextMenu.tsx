import { useEffect, useRef, useState } from "react";
import { useI18n } from "../lib/i18n";

export interface ContextMenuField {
  key: string;
  label: string;
  placeholder?: string;
  /** Empty string is a valid choice, so a select can express "not configured". */
  options?: { label: string; value: string }[];
  value?: string;
}

export interface ContextMenuItem {
  label: string;
  onClick?: () => void;
  disabled?: boolean;
  separator?: boolean;
  /** Expands into an inline sub-form; the values go back through onSubmit. */
  fields?: ContextMenuField[];
  onSubmit?: (values: Record<string, string>) => void;
}

interface ContextMenuProps {
  x: number;
  y: number;
  items: ContextMenuItem[];
  onClose: () => void;
}

const input =
  "w-full bg-ide-bg border border-ide-border rounded px-1.5 py-1 text-[11px] font-mono focus:border-ide-accent outline-none";

function initialValues(fields: ContextMenuField[]): Record<string, string> {
  return Object.fromEntries(fields.map((field) => [field.key, field.value ?? ""]));
}

export function ContextMenu({ x, y, items, onClose }: ContextMenuProps) {
  const { t } = useI18n();
  const menuRef = useRef<HTMLDivElement>(null);
  const [openForm, setOpenForm] = useState<number | null>(null);
  const [values, setValues] = useState<Record<string, string>>({});

  useEffect(() => {
    const handleClickOutside = (event: globalThis.MouseEvent) => {
      if (menuRef.current && !menuRef.current.contains(event.target as Node)) {
        onClose();
      }
    };

    const handleEscape = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        onClose();
      }
    };

    document.addEventListener("mousedown", handleClickOutside);
    document.addEventListener("keydown", handleEscape);

    return () => {
      document.removeEventListener("mousedown", handleClickOutside);
      document.removeEventListener("keydown", handleEscape);
    };
  }, [onClose]);

  // Adjust position to keep menu within viewport
  const adjustedX = Math.min(x, window.innerWidth - 224);
  const adjustedY = Math.max(8, Math.min(y, window.innerHeight - items.length * 32 - 10));

  const submit = (item: ContextMenuItem) => {
    item.onSubmit?.(values);
    onClose();
  };

  return (
    <div
      ref={menuRef}
      data-testid="context-menu"
      className="fixed bg-ide-sidebar border border-ide-border rounded shadow-lg py-1 z-50 min-w-[160px] max-w-[240px] max-h-[80vh] overflow-y-auto"
      style={{ left: adjustedX, top: adjustedY }}
      onContextMenu={(e) => e.preventDefault()}
    >
      {items.map((item, index) => {
        if (item.separator) return <div key={index} className="border-t border-ide-border my-1" />;

        if (item.fields) {
          if (openForm !== index) {
            return (
              <button
                key={index}
                onClick={() => {
                  setValues(initialValues(item.fields!));
                  setOpenForm(index);
                }}
                className="w-full px-3 py-1.5 text-left text-xs hover:bg-ide-hover"
              >
                {item.label}
              </button>
            );
          }
          return (
            <div key={index} className="px-3 py-1.5 space-y-1.5 bg-ide-bg/40">
              <div className="text-[10px] uppercase text-ide-textDim">{item.label}</div>
              {item.fields.map((field) => (
                <label key={field.key} className="block space-y-0.5">
                  <span className="text-[10px] text-ide-textDim">{field.label}</span>
                  {field.options ? (
                    <select
                      value={values[field.key] ?? ""}
                      onChange={(e) => setValues({ ...values, [field.key]: e.target.value })}
                      className={input}
                      data-testid={`menu-field-${field.key}`}
                    >
                      {field.options.map((option) => (
                        <option key={option.value} value={option.value}>
                          {option.label}
                        </option>
                      ))}
                    </select>
                  ) : (
                    <input
                      autoFocus
                      value={values[field.key] ?? ""}
                      placeholder={field.placeholder}
                      onChange={(e) => setValues({ ...values, [field.key]: e.target.value })}
                      onKeyDown={(e) => {
                        if (e.key === "Enter") submit(item);
                      }}
                      className={input}
                      data-testid={`menu-field-${field.key}`}
                    />
                  )}
                </label>
              ))}
              <div className="flex gap-1.5 pt-0.5">
                <button
                  onClick={() => submit(item)}
                  className="flex-1 px-2 py-1 bg-ide-accent text-white text-[11px] rounded hover:bg-blue-600"
                  data-testid="menu-submit"
                >
                  {t("contextMenu.apply")}
                </button>
                <button
                  onClick={() => setOpenForm(null)}
                  className="px-2 py-1 border border-ide-border text-[11px] rounded hover:bg-ide-hover"
                >
                  {t("contextMenu.collapse")}
                </button>
              </div>
            </div>
          );
        }

        return (
          <button
            key={index}
            onClick={() => {
              item.onClick?.();
              onClose();
            }}
            disabled={item.disabled}
            className="w-full px-3 py-1.5 text-left text-xs hover:bg-ide-hover disabled:opacity-40 disabled:cursor-not-allowed"
          >
            {item.label}
          </button>
        );
      })}
    </div>
  );
}
