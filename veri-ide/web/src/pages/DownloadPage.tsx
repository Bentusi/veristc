import { useState } from "react";

const STEPS = [
  { id: 1, title: "目标配置", desc: "配置下装目标参数" },
  { id: 2, title: "密钥选择", desc: "选择或生成 HMAC 密钥" },
  { id: 3, title: "下装参数", desc: "配置下装时序参数" },
  { id: 4, title: "执行下装", desc: "发送帧流并监控" },
  { id: 5, title: "完成", desc: "下装结果确认" },
];

export function DownloadPage() {
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
  const [deployResult, setDeployResult] = useState<null | { success: boolean; message: string }>(null);

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
      setDeployResult({ success: true, message: "下装成功完成" });
      setCurrentStep(5);
    }, 2000);
  };

  return (
    <div className="h-full flex flex-col">
      {/* Toolbar */}
      <div className="h-10 bg-ide-sidebar border-b border-ide-border flex items-center px-4 gap-2">
        <span className="text-sm font-medium">下装向导</span>
        <div className="flex-1" />
        <button
          onClick={() => {
            setCurrentStep(1);
            setDeployResult(null);
          }}
          className="px-3 py-1 bg-ide-hover text-ide-text text-xs rounded hover:bg-ide-selected"
        >
          重置
        </button>
      </div>

      <div className="flex-1 flex overflow-hidden">
        {/* Left - Step Navigation */}
        <div className="w-64 bg-ide-sidebar border-r border-ide-border">
          <div className="p-4 border-b border-ide-border">
            <div className="text-xs font-semibold uppercase text-ide-textDim">下装步骤</div>
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
                    {currentStep > step.id ? "✓" : step.id}
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
              <h2 className="text-xl font-semibold mb-6">目标配置</h2>
              <div className="space-y-4">
                <div>
                  <label className="block text-xs text-ide-textDim mb-1">目标路径</label>
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
                    <label className="block text-xs text-ide-textDim mb-1">后端类型</label>
                    <select
                      value={formData.backend}
                      onChange={(e) => setFormData({ ...formData, backend: e.target.value })}
                      className="w-full px-3 py-2 bg-ide-bg border border-ide-border rounded text-sm"
                    >
                      <option value="pipe">管道</option>
                      <option value="file">文件</option>
                    </select>
                  </div>
                  <div>
                    <label className="block text-xs text-ide-textDim mb-1">角色</label>
                    <select
                      value={formData.role}
                      onChange={(e) => setFormData({ ...formData, role: e.target.value })}
                      className="w-full px-3 py-2 bg-ide-bg border border-ide-border rounded text-sm"
                    >
                      <option value="primary">主</option>
                      <option value="backup">备</option>
                    </select>
                  </div>
                </div>
                <div>
                  <label className="block text-xs text-ide-textDim mb-1">节点 ID</label>
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
              <h2 className="text-xl font-semibold mb-6">密钥选择</h2>
              <div className="space-y-4">
                <div>
                  <label className="block text-xs text-ide-textDim mb-1">密钥名称</label>
                  <input
                    type="text"
                    value={formData.keyName}
                    onChange={(e) => setFormData({ ...formData, keyName: e.target.value })}
                    className="w-full px-3 py-2 bg-ide-bg border border-ide-border rounded text-sm"
                    placeholder="输入密钥名称"
                  />
                </div>
                <div>
                  <label className="block text-xs text-ide-textDim mb-1">密钥 (Hex)</label>
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
              <h2 className="text-xl font-semibold mb-6">下装参数</h2>
              <div className="grid grid-cols-2 gap-4">
                <div>
                  <label className="block text-xs text-ide-textDim mb-1">周期数</label>
                  <input
                    type="number"
                    value={formData.cycles}
                    onChange={(e) => setFormData({ ...formData, cycles: Number(e.target.value) })}
                    className="w-full px-3 py-2 bg-ide-bg border border-ide-border rounded text-sm"
                  />
                </div>
                <div>
                  <label className="block text-xs text-ide-textDim mb-1">周期 (ms)</label>
                  <input
                    type="number"
                    value={formData.periodMs}
                    onChange={(e) => setFormData({ ...formData, periodMs: Number(e.target.value) })}
                    className="w-full px-3 py-2 bg-ide-bg border border-ide-border rounded text-sm"
                  />
                </div>
                <div>
                  <label className="block text-xs text-ide-textDim mb-1">下装时机</label>
                  <input
                    type="number"
                    value={formData.downloadAt}
                    onChange={(e) => setFormData({ ...formData, downloadAt: Number(e.target.value) })}
                    className="w-full px-3 py-2 bg-ide-bg border border-ide-border rounded text-sm"
                  />
                </div>
                <div>
                  <label className="block text-xs text-ide-textDim mb-1">健康检查周期数</label>
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
              <h2 className="text-xl font-semibold mb-6">执行下装</h2>
              <div className="bg-ide-sidebar border border-ide-border rounded p-6">
                <div className="space-y-3 text-sm mb-6">
                  <div className="flex justify-between">
                    <span className="text-ide-textDim">目标路径:</span>
                    <span>{formData.targetPath || "未设置"}</span>
                  </div>
                  <div className="flex justify-between">
                    <span className="text-ide-textDim">密钥:</span>
                    <span className="font-mono">{formData.keyHex ? formData.keyHex.slice(0, 16) + "..." : "未设置"}</span>
                  </div>
                  <div className="flex justify-between">
                    <span className="text-ide-textDim">周期数:</span>
                    <span>{formData.cycles}</span>
                  </div>
                  <div className="flex justify-between">
                    <span className="text-ide-textDim">周期:</span>
                    <span>{formData.periodMs} ms</span>
                  </div>
                </div>
                <button
                  onClick={handleDeploy}
                  disabled={deploying}
                  className="w-full py-3 bg-ide-accent text-white rounded hover:bg-blue-600 disabled:opacity-50"
                >
                  {deploying ? "下装中..." : "开始下装"}
                </button>
              </div>
            </div>
          )}

          {currentStep === 5 && (
            <div className="max-w-2xl">
              <h2 className="text-xl font-semibold mb-6">下装完成</h2>
              <div className={`border rounded p-6 ${deployResult?.success ? "bg-green-900/20 border-green-500" : "bg-red-900/20 border-red-500"}`}>
                <div className="flex items-center gap-3 mb-4">
                  <div className={`w-12 h-12 rounded-full flex items-center justify-center ${deployResult?.success ? "bg-green-600" : "bg-red-600"}`}>
                    {deployResult?.success ? "✓" : ""}
                  </div>
                  <div>
                    <div className="text-lg font-semibold">{deployResult?.message || "下装失败"}</div>
                    <div className="text-sm text-ide-textDim">所有帧已发送，目标已切换</div>
                  </div>
                </div>
              </div>
            </div>
          )}
        </div>

        {/* Right - Summary */}
        <div className="w-72 bg-ide-sidebar border-l border-ide-border p-4">
          <div className="text-xs font-semibold uppercase text-ide-textDim mb-3">配置摘要</div>
          <div className="space-y-2 text-xs">
            <div className="flex justify-between">
              <span className="text-ide-textDim">当前步骤:</span>
              <span>{currentStep} / 5</span>
            </div>
            <div className="flex justify-between">
              <span className="text-ide-textDim">目标:</span>
              <span className="truncate ml-2">{formData.targetPath || "-"}</span>
            </div>
            <div className="flex justify-between">
              <span className="text-ide-textDim">周期:</span>
              <span>{formData.periodMs}ms × {formData.cycles}</span>
            </div>
          </div>

          <div className="mt-6 flex gap-2">
            <button
              onClick={handlePrev}
              disabled={currentStep === 1}
              className="flex-1 py-2 bg-ide-hover text-ide-text rounded text-xs hover:bg-ide-selected disabled:opacity-50"
            >
              上一步
            </button>
            {currentStep < 4 && (
              <button
                onClick={handleNext}
                className="flex-1 py-2 bg-ide-accent text-white rounded text-xs hover:bg-blue-600"
              >
                下一步
              </button>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
