import React from "react";
import ReactDOM from "react-dom/client";
import { BrowserRouter } from "react-router-dom";
import App from "./App";
import "./index.css";

const HEALTH_URL = "http://localhost:8000/health";
const RETRIES = 60;
const RETRY_DELAY_MS = 300;

const startupStrings = {
  "zh-CN": {
    starting: "正在启动 VeriIDE 后端…",
    failed: "后端未能启动（127.0.0.1:8000 无响应）。请检查 FastAPI 侧车后重新启动 VeriIDE。",
  },
  en: {
    starting: "Starting VeriIDE backend…",
    failed: "Backend failed to start (127.0.0.1:8000 not responding). Please check the FastAPI sidecar and restart VeriIDE.",
  },
};

function getStartupLocale() {
  const stored = window.localStorage.getItem("veride.locale");
  return stored === "en" ? "en" : "zh-CN";
}

async function backendIsUp(): Promise<boolean> {
  try {
    return (await fetch(HEALTH_URL)).ok;
  } catch {
    return false;
  }
}

function Notice({ text }: { text: string }) {
  return (
    <div
      style={{
        display: "flex",
        height: "100vh",
        alignItems: "center",
        justifyContent: "center",
        color: "#9ca3af",
        font: "14px/1.6 system-ui, sans-serif",
      }}
    >
      {text}
    </div>
  );
}

// The backend is a separate process started by the desktop shell, and the window
// can load before its port listens, so nothing mounts until /health answers.
async function main() {
  const root = ReactDOM.createRoot(document.getElementById("root")!);
  const lang = getStartupLocale();
  const strings = startupStrings[lang];
  root.render(<Notice text={strings.starting} />);
  for (let attempt = 0; attempt < RETRIES; attempt++) {
    if (await backendIsUp()) {
      root.render(
        <React.StrictMode>
          <BrowserRouter>
            <App />
          </BrowserRouter>
        </React.StrictMode>,
      );
      return;
    }
    await new Promise((resolve) => setTimeout(resolve, RETRY_DELAY_MS));
  }
  root.render(<Notice text={strings.failed} />);
}

void main();
