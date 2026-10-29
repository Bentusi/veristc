import { useNavigate } from "react-router-dom";
import { useState } from "react";
import { open, save } from "@tauri-apps/plugin-dialog";
import { message } from "@tauri-apps/plugin-dialog";

const FEATURES = [
  {
    path: "/graph",
    title: "图形组态",
    desc: "可视化功能图编辑器",
    sub: "拖拽式块连线 · 实时 ST 生成",
    icon: (
      <svg viewBox="0 0 24 24" className="w-10 h-10" fill="currentColor">
        <path d="M3 3h8v8H3V3zm0 10h8v8H3v-8zm10-10h8v8h-8V3zm0 10h8v8h-8v-8z" />
      </svg>
    ),
    color: "from-blue-500/20 to-blue-600/20 border-blue-500/30 hover:border-blue-400/50",
    iconBg: "bg-blue-500/20 text-blue-400",
  },
  {
    path: "/simulation",
    title: "仿真验证",
    desc: "闭环仿真 · 波形查看",
    sub: "孪生模式 · 统计分析",
    icon: (
      <svg viewBox="0 0 24 24" className="w-10 h-10" fill="currentColor">
        <path d="M3.5 18.49l6-6.01 4 4L22 6.92l-1.41-1.41-7.09 7.97-4-4L2 16.99z" />
      </svg>
    ),
    color: "from-green-500/20 to-green-600/20 border-green-500/30 hover:border-green-400/50",
    iconBg: "bg-green-500/20 text-green-400",
  },
  {
    path: "/download",
    title: "下装运行",
    desc: "帧流发送 · 周期边界切换",
    sub: "健康检查 · 回滚保护",
    icon: (
      <svg viewBox="0 0 24 24" className="w-10 h-10" fill="currentColor">
        <path d="M19 9h-4V3H9v6H5l7 7 7-7zM5 18v2h14v-2H5z" />
      </svg>
    ),
    color: "from-orange-500/20 to-orange-600/20 border-orange-500/30 hover:border-orange-400/50",
    iconBg: "bg-orange-500/20 text-orange-400",
  },
];

const QUICK_ACTIONS = [
  { label: "新建工程", icon: "M12 4v16m8-8H4" },
  { label: "打开工程", icon: "M3 7v10a2 2 0 002 2h14a2 2 0 002-2V9a2 2 0 00-2-2h-6l-2-2H5a2 2 0 00-2 2z" },
  { label: "最近项目", icon: "M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z" },
];

export function HomePage() {
  const navigate = useNavigate();
  const [hoveredIdx, setHoveredIdx] = useState<number | null>(null);

  const handleNewProject = async () => {
    const filePath = await save({
      title: "新建 VeriIDE 工程",
      defaultPath: "untitled.veriproj",
      filters: [{ name: "VeriIDE 工程", extensions: ["veriproj"] }],
    });
    if (filePath) {
      await message(`工程已创建：${filePath}`, { title: "新建工程", kind: "info" });
    }
  };

  const handleOpenProject = async () => {
    const selected = await open({
      title: "打开 VeriIDE 工程",
      multiple: false,
      filters: [{ name: "VeriIDE 工程", extensions: ["veriproj"] }],
      directory: false,
    });
    if (selected) {
      await message(`打开工程：${selected}`, { title: "打开工程", kind: "info" });
    }
  };

  const handleRecentProjects = async () => {
    await message("最近项目功能开发中...", { title: "最近项目", kind: "info" });
  };

  const handleQuickAction = (label: string) => {
    if (label === "新建工程") handleNewProject();
    else if (label === "打开工程") handleOpenProject();
    else if (label === "最近项目") handleRecentProjects();
  };

  return (
    <div className="h-full flex flex-col overflow-y-auto">
      {/* Hero Section */}
      <div className="flex-shrink-0 px-8 pt-12 pb-8">
        <div className="max-w-5xl mx-auto">
          <div className="flex items-center gap-3 mb-4">
            <div className="w-10 h-10 rounded-lg bg-ide-accent/20 flex items-center justify-center">
              <svg viewBox="0 0 24 24" className="w-6 h-6 text-ide-accent" fill="currentColor">
                <path d="M12 2L2 7l10 5 10-5-10-5zM2 17l10 5 10-5M2 12l10 5 10-5" />
              </svg>
            </div>
            <div>
              <h1 className="text-2xl font-semibold text-white">欢迎使用 VeriIDE</h1>
              <p className="text-sm text-ide-textDim">IEC 61131-3 ST → SafeASM 编译 · 仿真验证 · 下装运行</p>
            </div>
          </div>
        </div>
      </div>

      {/* Quick Actions */}
      <div className="flex-shrink-0 px-8 pb-6">
        <div className="max-w-5xl mx-auto">
          <div className="flex gap-3">
            {QUICK_ACTIONS.map((action) => (
              <button
                key={action.label}
                onClick={() => handleQuickAction(action.label)}
                className="flex items-center gap-2 px-4 py-2 bg-ide-sidebar border border-ide-border rounded-lg text-sm text-ide-text hover:bg-ide-hover hover:border-ide-textDim transition-all"
              >
                <svg viewBox="0 0 24 24" className="w-4 h-4" fill="none" stroke="currentColor" strokeWidth="2">
                  <path d={action.icon} />
                </svg>
                {action.label}
              </button>
            ))}
          </div>
        </div>
      </div>

      {/* Feature Cards */}
      <div className="flex-1 px-8 pb-8">
        <div className="max-w-5xl mx-auto">
          <h2 className="text-sm font-semibold uppercase tracking-wider text-ide-textDim mb-4">核心功能</h2>
          <div className="grid grid-cols-3 gap-4">
            {FEATURES.map((f, idx) => (
              <button
                key={f.path}
                onClick={() => navigate(f.path)}
                onMouseEnter={() => setHoveredIdx(idx)}
                onMouseLeave={() => setHoveredIdx(null)}
                className={`relative bg-gradient-to-br ${f.color} border rounded-xl p-6 text-left transition-all duration-200 ${
                  hoveredIdx === idx ? "scale-[1.02] shadow-lg" : ""
                }`}
              >
                <div className={`w-14 h-14 rounded-lg ${f.iconBg} flex items-center justify-center mb-4`}>
                  {f.icon}
                </div>
                <h3 className="text-base font-semibold text-white mb-1">{f.title}</h3>
                <p className="text-sm text-ide-text mb-2">{f.desc}</p>
                <p className="text-xs text-ide-textDim">{f.sub}</p>

                {/* Arrow indicator */}
                <div className="absolute top-6 right-6 opacity-0 group-hover:opacity-100 transition-opacity">
                  <svg viewBox="0 0 24 24" className="w-5 h-5 text-ide-textDim" fill="none" stroke="currentColor" strokeWidth="2">
                    <path d="M9 5l7 7-7 7" />
                  </svg>
                </div>
              </button>
            ))}
          </div>
        </div>
      </div>

      {/* Footer */}
      <div className="flex-shrink-0 px-8 py-4 border-t border-ide-border">
        <div className="max-w-5xl mx-auto flex justify-between items-center text-xs text-ide-textDim">
          <span>VeriIDE v0.1.0 · Phase 6</span>
          <div className="flex gap-4">
            <span>Tauri 2.x</span>
            <span>React 18</span>
            <span>FastAPI</span>
          </div>
        </div>
      </div>
    </div>
  );
}
