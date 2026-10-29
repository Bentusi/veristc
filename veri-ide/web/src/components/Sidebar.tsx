interface SidebarProps {
  activeView: string;
  onClose: () => void;
}

const SIDEBAR_CONTENT: Record<string, { title: string; items: string[] }> = {
  home: {
    title: "欢迎",
    items: ["项目概览", "最近打开", "快速开始"],
  },
  graph: {
    title: "图形组态",
    items: ["功能块库", "当前画布", "变量列表", "连接关系"],
  },
  simulation: {
    title: "仿真验证",
    items: ["被控对象", "仿真参数", "波形数据", "统计结果"],
  },
  download: {
    title: "下装运行",
    items: ["目标配置", "密钥管理", "下装历史", "审计日志"],
  },
};

export function Sidebar({ activeView, onClose }: SidebarProps) {
  const content = SIDEBAR_CONTENT[activeView] || SIDEBAR_CONTENT.home;

  return (
    <div className="w-60 bg-ide-sidebar border-r border-ide-border flex flex-col">
      <div className="h-9 flex items-center justify-between px-4 border-b border-ide-border">
        <span className="text-xs font-semibold uppercase tracking-wider text-ide-textDim">
          {content.title}
        </span>
        <button
          onClick={onClose}
          className="text-ide-textDim hover:text-ide-text transition-colors"
        >
          <svg viewBox="0 0 24 24" className="w-4 h-4" fill="currentColor">
            <path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z" />
          </svg>
        </button>
      </div>

      <div className="flex-1 overflow-y-auto py-2">
        {content.items.map((item, idx) => (
          <div
            key={idx}
            className="px-4 py-1.5 text-sm text-ide-text hover:bg-ide-hover cursor-pointer flex items-center gap-2"
          >
            <svg viewBox="0 0 24 24" className="w-4 h-4 text-ide-textDim" fill="currentColor">
              <path d="M10 17l5-5-5-5v10z" />
            </svg>
            {item}
          </div>
        ))}
      </div>
    </div>
  );
}
