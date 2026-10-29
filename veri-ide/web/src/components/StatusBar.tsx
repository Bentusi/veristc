export function StatusBar() {
  return (
    <div className="h-6 bg-ide-status flex items-center px-3 text-white text-xs select-none">
      <span className="flex items-center gap-1">
        <svg viewBox="0 0 24 24" className="w-3.5 h-3.5" fill="currentColor">
          <path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-2 15l-5-5 1.41-1.41L10 14.17l7.59-7.59L19 8l-9 9z" />
        </svg>
        就绪
      </span>

      <div className="flex-1" />

      <span className="mr-3">UTF-8</span>
      <span className="mr-3">IEC 61131-3</span>
      <span>VeriIDE v0.1.0</span>
    </div>
  );
}
