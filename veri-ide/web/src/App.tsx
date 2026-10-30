import { Routes, Route } from "react-router-dom";
import { IdeShell } from "./components/IdeShell";
import { HomePage } from "./pages/HomePage";
import { GraphEditorPage } from "./pages/GraphEditorPage";
import { DevicePage } from "./pages/DevicePage";
import { WaveformPage } from "./pages/WaveformPage";
import { DownloadPage } from "./pages/DownloadPage";
import { MonitorPage } from "./pages/MonitorPage";
import { LibraryPage } from "./pages/LibraryPage";

function App() {
  return (
    <div className="h-screen w-screen flex flex-col bg-ide-bg text-ide-text">
      <Routes>
        <Route path="/" element={<IdeShell />}>
          <Route index element={<HomePage />} />
          <Route path="graph" element={<GraphEditorPage />} />
          <Route path="device" element={<DevicePage />} />
          <Route path="monitor" element={<MonitorPage />} />
          <Route path="library" element={<LibraryPage />} />
          <Route path="simulation" element={<WaveformPage />} />
          <Route path="download" element={<DownloadPage />} />
        </Route>
      </Routes>
    </div>
  );
}

export default App;
