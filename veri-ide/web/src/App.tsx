import { Routes, Route } from "react-router-dom";
import { IdeShell } from "./components/IdeShell";
import { ProjectProvider } from "./project/ProjectProvider";
import { ToastProvider } from "./components/ui";
import { I18nProvider } from "./lib/i18n";
import { RequireProject } from "./components/RequireProject";
import { HomePage } from "./pages/HomePage";
import { GraphEditorPage } from "./pages/GraphEditorPage";
import { DevicePage } from "./pages/DevicePage";
import { WaveformPage } from "./pages/WaveformPage";
import { DownloadPage } from "./pages/DownloadPage";
import { MonitorPage } from "./pages/MonitorPage";
import { LibraryPage } from "./pages/LibraryPage";

function App() {
  const handleContextMenu = (e: React.MouseEvent) => {
    const target = e.target as HTMLElement;
    if (target.tagName === "INPUT" || target.tagName === "TEXTAREA") {
      return;
    }
    e.preventDefault();
  };

  return (
    <I18nProvider>
      <ProjectProvider>
        <ToastProvider>
          <div className="h-screen w-screen flex flex-col bg-ide-bg text-ide-text" onContextMenu={handleContextMenu}>
            <Routes>
              <Route path="/" element={<IdeShell />}>
                <Route index element={<HomePage />} />
                <Route path="graph" element={<RequireProject><GraphEditorPage /></RequireProject>} />
                <Route path="device" element={<RequireProject><DevicePage /></RequireProject>} />
                <Route path="monitor" element={<RequireProject><MonitorPage /></RequireProject>} />
                <Route path="library" element={<RequireProject><LibraryPage /></RequireProject>} />
                <Route path="simulation" element={<RequireProject><WaveformPage /></RequireProject>} />
                <Route path="download" element={<RequireProject><DownloadPage /></RequireProject>} />
              </Route>
            </Routes>
          </div>
        </ToastProvider>
      </ProjectProvider>
    </I18nProvider>
  );
}

export default App;
