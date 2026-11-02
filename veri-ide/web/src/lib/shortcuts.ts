import { useEffect } from "react";

export interface ShortcutBinding {
  key: string;
  ctrl?: boolean;
  shift?: boolean;
  alt?: boolean;
  /** Prevent default browser behavior (e.g. Ctrl+S save). */
  preventDefault?: boolean;
  /** Skip when focus is inside an input/select/textarea. */
  ignoreInInput?: boolean;
  handler: () => void;
}

/**
 * Register global keyboard shortcuts. Shortcuts are active only while the
 * component is mounted, so each page can own its own set without collisions.
 */
export function useShortcuts(bindings: ShortcutBinding[]) {
  useEffect(() => {
    const handler = (event: KeyboardEvent) => {
      const target = event.target as HTMLElement;
      const inInput =
        target.tagName === "INPUT" || target.tagName === "TEXTAREA" || target.tagName === "SELECT";

      for (const b of bindings) {
        if (b.ctrl !== undefined && event.ctrlKey !== b.ctrl) continue;
        if (b.shift !== undefined && event.shiftKey !== b.shift) continue;
        if (b.alt !== undefined && event.altKey !== b.alt) continue;
        if (event.key.toLowerCase() !== b.key.toLowerCase()) continue;
        if (b.ignoreInInput && inInput) continue;
        if (b.preventDefault) event.preventDefault();
        b.handler();
        return;
      }
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, [bindings]);
}

/** Common editing shortcuts shared by every stage page. */
export function useEditShortcuts(handlers: {
  onSave?: () => void;
  onUndo?: () => void;
  onRedo?: () => void;
  onCut?: () => void;
  onCopy?: () => void;
  onPaste?: () => void;
}) {
  useShortcuts([
    { key: "s", ctrl: true, preventDefault: true, ignoreInInput: true, handler: () => handlers.onSave?.() },
    { key: "z", ctrl: true, shift: false, handler: () => handlers.onUndo?.() },
    { key: "z", ctrl: true, shift: true, handler: () => handlers.onRedo?.() },
    { key: "y", ctrl: true, handler: () => handlers.onRedo?.() },
    { key: "x", ctrl: true, handler: () => handlers.onCut?.() },
    { key: "c", ctrl: true, handler: () => handlers.onCopy?.() },
    { key: "v", ctrl: true, handler: () => handlers.onPaste?.() },
  ]);
}
