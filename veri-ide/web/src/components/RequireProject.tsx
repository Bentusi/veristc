import { useNavigate } from "react-router-dom";
import { useProject } from "../project/ProjectProvider";
import { useI18n } from "../lib/i18n";
import type { ReactNode } from "react";

/**
 * Route guard: renders children only when a project is open.
 * Otherwise shows a placeholder prompting the user to create or open one.
 */
export function RequireProject({ children }: { children: ReactNode }) {
  const { current } = useProject();
  const navigate = useNavigate();
  const { t } = useI18n();

  if (current) return <>{children}</>;

  return (
    <div className="h-full flex items-center justify-center bg-ide-bg">
      <div className="text-center max-w-md px-6">
        <div className="w-16 h-16 mx-auto mb-6 rounded-full bg-ide-sidebar flex items-center justify-center">
          <svg viewBox="0 0 24 24" className="w-8 h-8 text-ide-textDim" fill="currentColor">
            <path d="M10 4H4c-1.1 0-2 .9-2 2v12c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2h-8l-2-2z" />
          </svg>
        </div>
        <h2 className="text-lg font-semibold text-ide-strong mb-2">{t("requireProject.title")}</h2>
        <p className="text-sm text-ide-textDim mb-6">{t("requireProject.desc")}</p>
        <button
          onClick={() => navigate("/")}
          className="px-4 py-2 bg-ide-accent text-white text-sm rounded hover:bg-blue-600 transition-colors"
        >
          {t("requireProject.goHome")}
        </button>
      </div>
    </div>
  );
}
