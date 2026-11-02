import { useState } from "react";
import { toast } from "../components/ui";
import { useI18n } from "../lib/i18n";

export function DownloadPage() {
  const { t } = useI18n();
  const [currentStep, setCurrentStep] = useState(1);
  const [formData, setFormData] = useState({
    targetPath: "",
    backend: "pipe",
    agentBinary: "/usr/bin/veristc-agent",
    role: "primary",
    nodeId: 1,
    keyName: "",
    keyHex: "",
    cycles: 1000,
    periodMs: 100,
    downloadAt: 1,
    healthCycles: 3,
  });
  const [deploying, setDeploying] = useState(false);

  const STEPS = [
    { id: 1, title: t("download.step1.title"), desc: t("download.step1.desc") },
    { id: 2, title: t("download.step2.title"), desc: t("download.step2.desc") },
    { id: 3, title: t("download.step3.title"), desc: t("download.step3.desc") },
    { id: 4, title: t("download.step4.title"), desc: t("download.step4.desc") },
    { id: 5, title: t("download.step5.title"), desc: t("download.step5.desc") },
  ];

  const handleNext = () => {
    if (currentStep < 5) setCurrentStep(currentStep + 1);
  };

  const handlePrev = () => {
    if (currentStep > 1) setCurrentStep(currentStep - 1);
  };

  const handleDeploy = () => {
    setDeploying(true);
    // Simulate deployment
    setTimeout(() => {
      setDeploying(false);
      toast.success(t("download.completed"), t("download.completedMsg"));
      setCurrentStep(5);
    }, 2000);
  };

  return (
    <div className="h-full flex flex-col">
      {/* Toolbar */}
      <div className="h-10 bg-ide-sidebar border-b border-ide-border flex items-center px-4 gap-2">
        <span className="text-sm font-medium">{t("download.title")}</span>
        <div className="flex-1" />
        <button
          onClick={() => {
            setCurrentStep(1);
          }}
          className="px-3 py-1 bg-ide-hover text-ide-text text-xs rounded hover:bg-ide-selected"
        >
          {t("download.reset")}
        </button>
      </div>

      <div className="flex-1 flex overflow-hidden">
        {/* Left - Step Navigation */}
        <div className="w-64 bg-ide-sidebar border-r border-ide-border">
          <div className="p-4 border-b border-ide-border">
            <div className="text-xs font-semibold uppercase text-ide-textDim">{t("download.steps")}</div>
          </div>
          <div className="p-2">
            {STEPS.map((step) => (
              <button
                key={step.id}
                onClick={() => setCurrentStep(step.id)}
                className={`w-full text-left px-3 py-3 rounded mb-1 transition-colors ${
                  currentStep === step.id
                    ? "bg-blue-900/30 border-l-2 border-ide-accent"
                    : currentStep > step.id
                    ? "bg-green-900/20 border-l-2 border-green-500"
                    : "hover:bg-ide-hover"
                }`}
              >
                <div className="flex items-center gap-2">
                  <div
                    className={`w-6 h-6 rounded-full flex items-center justify-center text-xs font-semibold ${
                      currentStep > step.id
                        ? "bg-green-600 text-white"
                        : currentStep === step.id
                        ? "bg-ide-accent text-white"
                        : "bg-ide-border text-ide-textDim"
                    }`}
                  >
                    {currentStep > step.id ? "\u2713" : step.id}
                  </div>
                  <div>
                    <div className="text-sm font-medium">{step.title}</div>
                    <div className="text-xs text-ide-textDim">{step.desc}</div>
                  </div>
                </div>
              </button>
            ))}
          </div>
        </div>

        {/* Center - Step Content */}
        <div className="flex-1 p-6 overflow-y-auto">
          {currentStep === 1 && (
            <div className="max-w-2xl">
              <h2 className="text-xl font-semibold mb-6">{t("download.step1.title")}</h2>
              <div className="space-y-4">
                <div>
                  <label className="block text-xs text-ide-textDim mb-1">{t("download.targetPath")}</label>
                  <input
                    type="text"
                    value={formData.targetPath}
                    onChange={(e) => setFormData({ ...formData, targetPath: e.target.value })}
                    className="w-full px-3 py-2 bg-ide-bg border border-ide-border rounded text-sm"
                    placeholder="/path/to/target.sasm"
                  />
                </div>
                <div className="grid grid-cols-2 gap-4">
                  <div>
                    <label className="block text-xs text-ide-textDim mb-1">{t("download.backendType")}</label>
                    <select
                      value={formData.backend}
                      onChange={(e) => setFormData({ ...formData, backend: e.target.value })}
                      className="w-full px-3 py-2 bg-ide-bg border border-ide-border rounded text-sm"
                    >
                      <option value="pipe">{t("download.pipe")}</option>
                      <option value="file">{t("download.file")}</option>
                    </select>
                  </div>
                  <div>
                    <label className="block text-xs text-ide-textDim mb-1">{t("download.role")}</label>
                    <select
                      value={formData.role}
                      onChange={(e) => setFormData({ ...formData, role: e.target.value })}
                      className="w-full px-3 py-2 bg-ide-bg border border-ide-border rounded text-sm"
                    >
                      <option value="primary">{t("download.primary")}</option>
                      <option value="backup">{t("download.backup")}</option>
                    </select>
                  </div>
                </div>
                <div>
                  <label className="block text-xs text-ide-textDim mb-1">{t("download.nodeId")}</label>
                  <input
                    type="number"
                    value={formData.nodeId}
                    onChange={(e) => setFormData({ ...formData, nodeId: Number(e.target.value) })}
                    className="w-full px-3 py-2 bg-ide-bg border border-ide-border rounded text-sm"
                  />
                </div>
              </div>
            </div>
          )}

          {currentStep === 2 && (
            <div className="max-w-2xl">
              <h2 className="text-xl font-semibold mb-6">{t("download.step2.title")}</h2>
              <div className="space-y-4">
                <div>
                  <label className="block text-xs text-ide-textDim mb-1">{t("download.keyName")}</label>
                  <input
                    type="text"
                    value={formData.keyName}
                    onChange={(e) => setFormData({ ...formData, keyName: e.target.value })}
                    className="w-full px-3 py-2 bg-ide-bg border border-ide-border rounded text-sm"
                    placeholder={t("download.keyNamePlaceholder")}
                  />
                </div>
                <div>
                  <label className="block text-xs text-ide-textDim mb-1">{t("download.keyHex")}</label>
                  <input
                    type="text"
                    value={formData.keyHex}
                    onChange={(e) => setFormData({ ...formData, keyHex: e.target.value })}
                    className="w-full px-3 py-2 bg-ide-bg border border-ide-border rounded text-sm font-mono"
                    placeholder="0123456789abcdef..."
                  />
                </div>
              </div>
            </div>
          )}

          {currentStep === 3 && (
            <div className="max-w-2xl">
              <h2 className="text-xl font-semibold mb-6">{t("download.step3.title")}</h2>
              <div className="grid grid-cols-2 gap-4">
                <div>
                  <label className="block text-xs text-ide-textDim mb-1">{t("download.cycles")}</label>
                  <input
                    type="number"
                    value={formData.cycles}
                    onChange={(e) => setFormData({ ...formData, cycles: Number(e.target.value) })}
                    className="w-full px-3 py-2 bg-ide-bg border border-ide-border rounded text-sm"
                  />
                </div>
                <div>
                  <label className="block text-xs text-ide-textDim mb-1">{t("download.period")}</label>
                  <input
                    type="number"
                    value={formData.periodMs}
                    onChange={(e) => setFormData({ ...formData, periodMs: Number(e.target.value) })}
                    className="w-full px-3 py-2 bg-ide-bg border border-ide-border rounded text-sm"
                  />
                </div>
                <div>
                  <label className="block text-xs text-ide-textDim mb-1">{t("download.downloadAt")}</label>
                  <input
                    type="number"
                    value={formData.downloadAt}
                    onChange={(e) => setFormData({ ...formData, downloadAt: Number(e.target.value) })}
                    className="w-full px-3 py-2 bg-ide-bg border border-ide-border rounded text-sm"
                  />
                </div>
                <div>
                  <label className="block text-xs text-ide-textDim mb-1">{t("download.healthCycles")}</label>
                  <input
                    type="number"
                    value={formData.healthCycles}
                    onChange={(e) => setFormData({ ...formData, healthCycles: Number(e.target.value) })}
                    className="w-full px-3 py-2 bg-ide-bg border border-ide-border rounded text-sm"
                  />
                </div>
              </div>
            </div>
          )}

          {currentStep === 4 && (
            <div className="max-w-2xl">
              <h2 className="text-xl font-semibold mb-6">{t("download.step4.title")}</h2>
              <div className="bg-ide-sidebar border border-ide-border rounded p-6">
                <div className="space-y-3 text-sm mb-6">
                  <div className="flex justify-between">
                    <span className="text-ide-textDim">{t("download.targetPath")}:</span>
                    <span>{formData.targetPath || t("download.notSet")}</span>
                  </div>
                  <div className="flex justify-between">
                    <span className="text-ide-textDim">{t("download.keyHex")}:</span>
                    <span className="font-mono">{formData.keyHex ? formData.keyHex.slice(0, 16) + "..." : t("download.notSet")}</span>
                  </div>
                  <div className="flex justify-between">
                    <span className="text-ide-textDim">{t("download.cycles")}:</span>
                    <span>{formData.cycles}</span>
                  </div>
                  <div className="flex justify-between">
                    <span className="text-ide-textDim">{t("download.periodLabel")}</span>
                    <span>{formData.periodMs} ms</span>
                  </div>
                </div>
                <button
                  onClick={handleDeploy}
                  disabled={deploying}
                  className="w-full py-3 bg-ide-accent text-white rounded hover:bg-blue-600 disabled:opacity-50"
                >
                  {deploying ? t("download.deploying") : t("download.startDeploy")}
                </button>
              </div>
            </div>
          )}

          {currentStep === 5 && (
            <div className="max-w-2xl">
              <h2 className="text-xl font-semibold mb-6">{t("download.completed")}</h2>
              <div className="bg-green-900/20 border border-green-500 rounded p-6">
                <div className="flex items-center gap-3 mb-4">
                  <div className="w-12 h-12 rounded-full bg-green-600 flex items-center justify-center">
                    <span className="text-white text-xl">{"\u2713"}</span>
                  </div>
                  <div>
                    <div className="text-lg font-semibold text-green-400">{t("download.success")}</div>
                    <div className="text-sm text-ide-textDim">{t("download.completedMsg")}</div>
                  </div>
                </div>
              </div>
            </div>
          )}
        </div>

        {/* Right - Summary */}
        <div className="w-72 bg-ide-sidebar border-l border-ide-border p-4">
          <div className="text-xs font-semibold uppercase text-ide-textDim mb-3">{t("download.configSummary")}</div>
          <div className="space-y-2 text-xs">
            <div className="flex justify-between">
              <span className="text-ide-textDim">{t("download.currentStep")}</span>
              <span>{currentStep} / 5</span>
            </div>
            <div className="flex justify-between">
              <span className="text-ide-textDim">{t("download.target")}</span>
              <span className="truncate ml-2">{formData.targetPath || "-"}</span>
            </div>
            <div className="flex justify-between">
              <span className="text-ide-textDim">{t("download.periodLabel")}</span>
              <span>{formData.periodMs}ms {"\u00d7"} {formData.cycles}</span>
            </div>
          </div>

          <div className="mt-6 flex gap-2">
            <button
              onClick={handlePrev}
              disabled={currentStep === 1}
              className="flex-1 py-2 bg-ide-hover text-ide-text rounded text-xs hover:bg-ide-selected disabled:opacity-50"
            >
              {t("download.prev")}
            </button>
            {currentStep < 4 && (
              <button
                onClick={handleNext}
                className="flex-1 py-2 bg-ide-accent text-white rounded text-xs hover:bg-blue-600"
              >
                {t("download.next")}
              </button>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
