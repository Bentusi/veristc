import { useState, useCallback, useMemo } from "react";
import { Outlet, useLocation, useNavigate } from "react-router-dom";
import { ActivityBar } from "./ActivityBar";
import { StatusBar } from "./StatusBar";
import { WorkflowProgress } from "./WorkflowProgress";
import { MenuBar, type MenuGroup } from "./MenuBar";
import { useProject } from "../project/ProjectProvider";
import { readTheme, writeTheme, type Theme } from "../lib/theme";
import { eventBus } from "../lib/eventBus";
import { toast } from "./ui";
import { useI18n } from "../lib/i18n";

export function IdeShell() {
  const location = useLocation();
  const navigate = useNavigate();
  const { current, save, close } = useProject();
  const [theme, setTheme] = useState<Theme>(() => readTheme());
  const { t, locale, setLocale } = useI18n();

  const toggleTheme = () => {
    const next: Theme = theme === "dark" ? "light" : "dark";
    writeTheme(next);
    setTheme(next);
  };

  const toggleLocale = () => {
    setLocale(locale === "zh-CN" ? "en" : "zh-CN");
  };

  const handleSave = useCallback(async () => {
    if (!current) {
      toast.warning(t("common.noProject"), t("common.noProjectDesc"));
      return;
    }
    try {
      await save();
      toast.success(t("common.saved"), current.path);
    } catch (error) {
      toast.error(t("common.saveFailed"), error instanceof Error ? error.message : String(error));
    }
  }, [current, save, t]);

  const handleClose = useCallback(async () => {
    if (!current) {
      toast.warning(t("common.noProject"), t("common.noProjectToClose"));
      return;
    }
    try {
      await close();
      navigate("/");
      toast.success(t("common.projectClosed"), current.name);
    } catch (error) {
      toast.error(t("common.closeFailed"), error instanceof Error ? error.message : String(error));
    }
  }, [current, close, navigate, t]);

  const handleProperties = useCallback(() => {
    if (!current) {
      toast.warning(t("common.noProject"), t("common.noProjectProps"));
      return;
    }
    toast.info(
      t("common.projectProps"),
      `${t("common.name")}: ${current.name}\n${t("common.path")}: ${current.path}\n${t("common.safetyLevel")}: ${current.safety_level}`,
    );
  }, [current, t, locale]);

  const menuGroups: MenuGroup[] = useMemo(
    () => [
      {
        id: "file",
        label: t("menu.file"),
        items: [
          {
            id: "new",
            label: t("menu.file.new"),
            shortcut: "Ctrl+N",
            onClick: () => {
              navigate("/");
              setTimeout(() => eventBus.emit("menu:openPanel", "new-project"), 50);
            },
          },
          {
            id: "open",
            label: t("menu.file.open"),
            shortcut: "Ctrl+O",
            onClick: () => {
              navigate("/");
              setTimeout(() => eventBus.emit("menu:openPanel", "open-project"), 50);
            },
          },
          { id: "sep1", label: "─────────", disabled: true },
          {
            id: "save",
            label: t("menu.file.save"),
            shortcut: "Ctrl+S",
            onClick: handleSave,
          },
          {
            id: "save-as",
            label: t("menu.file.saveAs"),
            shortcut: "Ctrl+Shift+S",
            onClick: () => toast.info(t("menu.file.saveAs"), t("menu.notImplemented")),
          },
          { id: "sep2", label: "─────────", disabled: true },
          {
            id: "properties",
            label: t("menu.file.properties"),
            onClick: handleProperties,
          },
          { id: "sep3", label: "─────────", disabled: true },
          {
            id: "close",
            label: t("menu.file.close"),
            onClick: handleClose,
          },
        ],
      },
      {
        id: "edit",
        label: t("menu.edit"),
        items: [
          { id: "undo", label: t("menu.edit.undo"), shortcut: "Ctrl+Z", disabled: true },
          { id: "redo", label: t("menu.edit.redo"), shortcut: "Ctrl+Y", disabled: true },
          { id: "sep4", label: "─────────", disabled: true },
          { id: "cut", label: t("menu.edit.cut"), shortcut: "Ctrl+X", disabled: true },
          { id: "copy", label: t("menu.edit.copy"), shortcut: "Ctrl+C", disabled: true },
          { id: "paste", label: t("menu.edit.paste"), shortcut: "Ctrl+V", disabled: true },
        ],
      },
    ],
    [t, handleSave, handleProperties, handleClose, navigate],
  );

  const navItems = useMemo(
    () => [
      { id: "home", path: "/", icon: "M10 20v-6h4v6h5v-8h3L12 3 2 12h3v8z", label: t("nav.home") },
      { id: "device", path: "/device", icon: "M9 4h6v16H9zM4 7h5v2H4zM4 15h5v2H4zM15 7h5v2h-5zM15 15h5v2h-5z", label: t("nav.device") },
      { id: "graph", path: "/graph", icon: "M3 3h8v8H3V3zm0 10h8v8H3v-8zm10-10h8v8h-8V3zm0 10h8v8h-8v-8z", label: t("nav.graph") },
      { id: "simulation", path: "/simulation", icon: "M3.5 18.49l6-6.01 4 4L22 6.92l-1.41-1.41-7.09 7.97-4-4L2 16.99z", label: t("nav.simulation") },
      { id: "download", path: "/download", icon: "M19 9h-4V3H9v6H5l7 7 7-7zM5 18v2h14v-2H5z", label: t("nav.download") },
      { id: "library", path: "/library", icon: "M19.428 15.428a2 2 0 00-1.022-.547l-2.387-.477a6 6 0 00-3.86.517l-.318.158a6 6 0 01-3.86.517L6.05 15.21a2 2 0 00-1.022.547L3 17.5h2m14.428-2.072a2 2 0 011.022.547l2.387.477a6 6 0 003.86-.517l.318-.158a6 6 0 013.86-.517l1.95-1.592a2 2 0 011.022-.547H21", label: t("nav.library") },
      { id: "monitor", path: "/monitor", icon: "M9 19v-6a2 2 0 00-2-2H5a2 2 0 00-2 2v6a2 2 0 002 2h2a2 2 0 002-2zm0 0V9a2 2 0 012-2h2a2 2 0 012 2v10m-6 0a2 2 0 002 2h2a2 2 0 002-2m0 0V5a2 2 0 012-2h2a2 2 0 012 2v14a2 2 0 01-2 2h-2a2 2 0 01-2-2z", label: t("nav.monitor") },
    ],
    [t],
  );

  // Derived from the URL so a deep link or browser back keeps the shell in sync.
  const activeView = navItems.find((n) => n.path === location.pathname)?.id ?? "home";

  return (
    <div className="flex flex-col h-screen w-screen overflow-hidden">
      {/* Title bar: which project folder the stage pages are reading and writing. */}
      <div className="h-8 bg-ide-activity flex items-center px-3 select-none border-b border-ide-border gap-2">
        <span className="text-xs text-ide-textDim">VeriIDE</span>
        {current ? (
          <button
            data-testid="titlebar-project"
            onClick={() => navigate("/")}
            className="text-xs text-ide-text hover:text-ide-strong truncate max-w-[60ch]"
            title={current.path}
          >
            {current.name}
            <span className="text-ide-textDim ml-2">{current.path}</span>
            <span className="text-ide-textDim ml-2">· {current.safety_level}</span>
          </button>
        ) : (
          <button
            data-testid="titlebar-project"
            onClick={() => navigate("/")}
            className="text-xs text-ide-textDim hover:text-ide-text"
          >
            {t("title.unnamed")}
          </button>
        )}
        <div className="ml-auto flex items-center gap-1">
          {/* Language toggle */}
          <button
            data-testid="lang-toggle"
            onClick={toggleLocale}
            title={locale === "zh-CN" ? t("title.lang.zh") : t("title.lang.en")}
            aria-label={locale === "zh-CN" ? t("title.lang.zh") : t("title.lang.en")}
            className="px-1.5 py-0.5 rounded text-[10px] font-medium text-ide-textDim hover:text-ide-text hover:bg-ide-hover border border-ide-border"
          >
            {locale === "zh-CN" ? "EN" : "中"}
          </button>
          {/* Theme toggle */}
          <button
            data-testid="theme-toggle"
            onClick={toggleTheme}
            title={theme === "dark" ? t("title.theme.dark") : t("title.theme.light")}
            aria-label={theme === "dark" ? t("title.theme.dark") : t("title.theme.light")}
            className="p-1.5 rounded text-ide-textDim hover:text-ide-text hover:bg-ide-hover"
          >
            <svg viewBox="0 0 24 24" className="w-4 h-4 fill-current" aria-hidden="true">
              <path
                d={
                  theme === "dark"
                    ? "M12 8a4 4 0 100 8 4 4 0 000-8zm-1-6h2v3h-2V2zm0 17h2v3h-2v-3zM2 11h3v2H2v-2zm17 0h3v2h-3v-2zM4.2 5.6l1.4-1.4 2.1 2.1-1.4 1.4-2.1-2.1zm11.9 11.9l1.4-1.4 2.1 2.1-1.4 1.4-2.1-2.1zm1.8-11.9l2.1 2.1-1.4 1.4-2.1-2.1 1.4-1.4zM6.3 15.6l2.1 2.1-1.4 1.4-2.1-2.1 1.4-1.4z"
                    : "M21 12.79A9 9 0 1111.21 3a7 7 0 009.79 9.79z"
                }
              />
            </svg>
          </button>
        </div>
      </div>

      <div className="flex flex-1 overflow-hidden">
        {/* Activity bar: the only global navigation. Every stage page owns its
            own columns, so the shell adds no sidebar of its own. */}
        <ActivityBar
          items={navItems}
          activeId={activeView}
          disabledIds={current ? [] : navItems.filter((n) => n.id !== "home").map((n) => n.id)}
          disabledTitle={t("nav.requireProject")}
          onSelect={(id) => {
            const item = navItems.find((n) => n.id === id);
            if (item) navigate(item.path);
          }}
        />

        {/* Main Content */}
        <div className="flex-1 flex flex-col overflow-hidden">
          {/* Menu Bar */}
          <MenuBar groups={menuGroups} />
          {/* Workflow Progress Bar */}
          {current && <WorkflowProgress />}
          <main className="flex-1 overflow-hidden bg-ide-bg">
            <Outlet />
          </main>
        </div>
      </div>

      {/* Status Bar */}
      <StatusBar />
    </div>
  );
}
