import { Routes, Route } from "react-router-dom";
import { IdeShell } from "./components/IdeShell";
import { HomePage } from "./pages/HomePage";
import { GraphEditorPage } from "./pages/GraphEditorPage";
import { WaveformPage } from "./pages/WaveformPage";
import { DownloadPage } from "./pages/DownloadPage";

function App() {
  return (
    <div className="h-screen w-screen flex flex-col bg-ide-bg text-ide-text">
      <Routes>
        <Route path="/" element={<IdeShell />}>
          <Route index element={<HomePage />} />
          <Route path="graph" element={<GraphEditorPage />} />
          <Route path="simulation" element={<WaveformPage />} />
          <Route path="download" element={<DownloadPage />} />
        </Route>
      </Routes>
    </div>
  );
}

export default App;
