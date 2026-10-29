import { useState } from "react";
import { Outlet, useNavigate } from "react-router-dom";
import { ActivityBar } from "./ActivityBar";
import { Sidebar } from "./Sidebar";
import { StatusBar } from "./StatusBar";

const NAV_ITEMS = [
  { id: "home", path: "/", icon: "M10 20v-6h4v6h5v-8h3L12 3 2 12h3v8z", label: "首页" },
  { id: "graph", path: "/graph", icon: "M3 3h8v8H3V3zm0 10h8v8H3v-8zm10-10h8v8h-8V3zm0 10h8v8h-8v-8z", label: "图形组态" },
  { id: "simulation", path: "/simulation", icon: "M3.5 18.49l6-6.01 4 4L22 6.92l-1.41-1.41-7.09 7.97-4-4L2 16.99z", label: "仿真验证" },
  { id: "download", path: "/download", icon: "M19 9h-4V3H9v6H5l7 7 7-7zM5 18v2h14v-2H5z", label: "下装运行" },
];

export function IdeShell() {
  const [activeView, setActiveView] = useState("home");
  const [sidebarOpen, setSidebarOpen] = useState(true);
  const navigate = useNavigate();

  const handleNavigate = (path: string, viewId: string) => {
    navigate(path);
    setActiveView(viewId);
  };

  return (
    <div className="flex flex-col h-screen w-screen overflow-hidden">
      {/* Title bar */}
      <div className="h-8 bg-ide-activity flex items-center px-3 select-none border-b border-ide-border">
        <span className="text-xs text-ide-textDim">VeriIDE</span>
        <span className="text-xs text-ide-textDim ml-2">— 工程站</span>
      </div>

      <div className="flex flex-1 overflow-hidden">
        {/* Activity Bar */}
        <ActivityBar
          items={NAV_ITEMS}
          activeId={activeView}
          onSelect={(id) => {
            const item = NAV_ITEMS.find((n) => n.id === id);
            if (item) handleNavigate(item.path, id);
            setSidebarOpen(true);
          }}
        />

        {/* Sidebar */}
        {sidebarOpen && (
          <Sidebar
            activeView={activeView}
            onClose={() => setSidebarOpen(false)}
          />
        )}

        {/* Main Content */}
        <main className="flex-1 overflow-hidden bg-ide-bg">
          <Outlet />
        </main>
      </div>

      {/* Status Bar */}
      <StatusBar />
    </div>
  );
}
