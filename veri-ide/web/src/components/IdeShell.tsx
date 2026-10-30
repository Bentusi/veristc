import { Outlet, useLocation, useNavigate } from "react-router-dom";
import { ActivityBar } from "./ActivityBar";
import { StatusBar } from "./StatusBar";

const NAV_ITEMS = [
  { id: "home", path: "/", icon: "M10 20v-6h4v6h5v-8h3L12 3 2 12h3v8z", label: "首页" },
  { id: "graph", path: "/graph", icon: "M3 3h8v8H3V3zm0 10h8v8H3v-8zm10-10h8v8h-8V3zm0 10h8v8h-8v-8z", label: "图形组态" },
  { id: "device", path: "/device", icon: "M9 4h6v16H9zM4 7h5v2H4zM4 15h5v2H4zM15 7h5v2h-5zM15 15h5v2h-5z", label: "设备组态" },
  { id: "library", path: "/library", icon: "M19.428 15.428a2 2 0 00-1.022-.547l-2.387-.477a6 6 0 00-3.86.517l-.318.158a6 6 0 01-3.86.517L6.05 15.21a2 2 0 00-1.022.547L3 17.5h2m14.428-2.072a2 2 0 011.022.547l2.387.477a6 6 0 003.86-.517l.318-.158a6 6 0 013.86-.517l1.95-1.592a2 2 0 011.022-.547H21", label: "算法库" },
  { id: "monitor", path: "/monitor", icon: "M9 19v-6a2 2 0 00-2-2H5a2 2 0 00-2 2v6a2 2 0 002 2h2a2 2 0 002-2zm0 0V9a2 2 0 012-2h2a2 2 0 012 2v10m-6 0a2 2 0 002 2h2a2 2 0 002-2m0 0V5a2 2 0 012-2h2a2 2 0 012 2v14a2 2 0 01-2 2h-2a2 2 0 01-2-2z", label: "在线监视" },
  { id: "simulation", path: "/simulation", icon: "M3.5 18.49l6-6.01 4 4L22 6.92l-1.41-1.41-7.09 7.97-4-4L2 16.99z", label: "仿真验证" },
  { id: "download", path: "/download", icon: "M19 9h-4V3H9v6H5l7 7 7-7zM5 18v2h14v-2H5z", label: "下装运行" },
];

export function IdeShell() {
  const location = useLocation();
  const navigate = useNavigate();

  // Derived from the URL so a deep link or browser back keeps the shell in sync.
  const activeView = NAV_ITEMS.find((n) => n.path === location.pathname)?.id ?? "home";

  return (
    <div className="flex flex-col h-screen w-screen overflow-hidden">
      {/* Title bar */}
      <div className="h-8 bg-ide-activity flex items-center px-3 select-none border-b border-ide-border">
        <span className="text-xs text-ide-textDim">VeriIDE</span>
        <span className="text-xs text-ide-textDim ml-2">— 工程站</span>
      </div>

      <div className="flex flex-1 overflow-hidden">
        {/* Activity bar: the only global navigation. Every stage page owns its
            own columns, so the shell adds no sidebar of its own. */}
        <ActivityBar
          items={NAV_ITEMS}
          activeId={activeView}
          onSelect={(id) => {
            const item = NAV_ITEMS.find((n) => n.id === id);
            if (item) navigate(item.path);
          }}
        />

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
