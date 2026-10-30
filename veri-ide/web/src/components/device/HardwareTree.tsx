import { KIND_COLOR, type ModuleView } from "./types";

interface HardwareTreeProps {
  modules: ModuleView[];
  selectedChannel: number | null;
  onSelectChannel: (channel: number) => void;
  collapsed: Record<string, boolean>;
  onToggle: (moduleId: string) => void;
}

export function HardwareTree({
  modules,
  selectedChannel,
  onSelectChannel,
  collapsed,
  onToggle,
}: HardwareTreeProps) {
  const boundCount = modules.reduce(
    (total, m) => total + m.channel_list.filter((c) => c.bound).length,
    0,
  );

  return (
    <div className="w-60 bg-ide-sidebar border-r border-ide-border flex flex-col overflow-hidden">
      <div className="px-3 py-2 border-b border-ide-border">
        <div className="text-xs font-semibold uppercase text-ide-textDim">硬件通道</div>
        <div className="text-[10px] text-ide-textDim mt-1">
          {modules.length} 个模块 · 已绑定 {boundCount} / 64 通道
        </div>
      </div>

      <div className="flex-1 overflow-y-auto py-1">
        {modules.map((module) => {
          const bound = module.channel_list.filter((c) => c.bound).length;
          const open = !collapsed[module.module_id];
          return (
            <div key={module.module_id}>
              <button
                onClick={() => onToggle(module.module_id)}
                className="w-full px-3 py-1.5 flex items-center gap-1.5 text-xs hover:bg-ide-hover"
              >
                <svg
                  viewBox="0 0 24 24"
                  className={`w-3 h-3 text-ide-textDim transition-transform ${open ? "rotate-90" : ""}`}
                  fill="currentColor"
                >
                  <path d="M10 17l5-5-5-5v10z" />
                </svg>
                <span
                  className="w-2 h-2 rounded-full shrink-0"
                  style={{ backgroundColor: KIND_COLOR[module.kind] }}
                />
                <span className="font-mono">{module.module_id}</span>
                <span className="text-ide-textDim">
                  {module.kind} {module.first_channel}–{module.last_channel}
                </span>
                <span className="flex-1" />
                <span
                  className={`text-[10px] ${bound === 0 ? "text-ide-textDim" : "text-ide-accent"}`}
                >
                  {bound}/{module.channel_count}
                </span>
              </button>

              {open && (
                <div className="pb-1">
                  {module.channel_list.map((channel) => (
                    <button
                      key={channel.channel}
                      onClick={() => onSelectChannel(channel.channel)}
                      className={`w-full pl-9 pr-3 py-1 flex items-center gap-2 text-xs ${
                        selectedChannel === channel.channel
                          ? "bg-ide-selected text-white"
                          : "hover:bg-ide-hover text-ide-text"
                      }`}
                    >
                      <span
                        className={`w-1.5 h-1.5 rounded-full ${
                          channel.bound ? "bg-green-500" : "bg-ide-border"
                        }`}
                      />
                      <span className="font-mono">CH{channel.channel}</span>
                      <span className="flex-1" />
                      {channel.var_name ? (
                        <span className="text-ide-accent truncate max-w-24">{channel.var_name}</span>
                      ) : (
                        <span className="text-ide-textDim">空闲</span>
                      )}
                    </button>
                  ))}
                </div>
              )}
            </div>
          );
        })}

        {modules.length === 0 && (
          <div className="px-3 py-4 text-xs text-ide-textDim">尚未配置硬件模块</div>
        )}
      </div>
    </div>
  );
}
