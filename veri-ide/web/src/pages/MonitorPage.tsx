import { useState, useEffect } from "react";
import { WatchTable } from "../components/monitor/WatchTable";
import { VariableInspector } from "../components/monitor/VariableInspector";
import { ForceControlPanel } from "../components/monitor/ForceControlPanel";
import { ParameterEditor } from "../components/monitor/ParameterEditor";

interface Variable {
  name: string;
  address: number;
  data_type: string;
  var_type: string;
  current_value: any;
  forced_value: any | null;
  force_status: string;
  last_updated: string;
  quality: string;
}

interface WatchEntry {
  id: string;
  variable_name: string;
  alias: string | null;
  display_format: string;
  enabled: boolean;
  last_value: any;
  last_update: string | null;
}

type MonitorTab = "watch" | "variables" | "force" | "parameters";

export function MonitorPage() {
  const [activeTab, setActiveTab] = useState<MonitorTab>("watch");
  const [variables, setVariables] = useState<Variable[]>([]);
  const [watchTable, setWatchTable] = useState<WatchEntry[]>([]);
  const [selectedVariable, setSelectedVariable] = useState<string | null>(null);
  const [refreshInterval, setRefreshInterval] = useState(1000);
  const [isAutoRefresh, setIsAutoRefresh] = useState(true);

  // Fetch variables from backend
  useEffect(() => {
    const fetchVariables = async () => {
      try {
        const response = await fetch("http://localhost:8000/monitor/variables");
        if (response.ok) {
          const data = await response.json();
          setVariables(data);
        }
      } catch (error) {
        console.error("Failed to fetch variables:", error);
      }
    };

    fetchVariables();
    
    if (isAutoRefresh) {
      const interval = setInterval(fetchVariables, refreshInterval);
      return () => clearInterval(interval);
    }
  }, [isAutoRefresh, refreshInterval]);

  // Fetch watch table
  useEffect(() => {
    const fetchWatchTable = async () => {
      try {
        const response = await fetch("http://localhost:8000/monitor/watch");
        if (response.ok) {
          const data = await response.json();
          setWatchTable(data);
        }
      } catch (error) {
        console.error("Failed to fetch watch table:", error);
      }
    };

    fetchWatchTable();
  }, []);

  const handleAddToWatch = async (variableName: string) => {
    try {
      const response = await fetch("http://localhost:8000/monitor/watch", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ variable_name: variableName }),
      });
      if (response.ok) {
        const entry = await response.json();
        setWatchTable([...watchTable, entry]);
      }
    } catch (error) {
      console.error("Failed to add to watch:", error);
    }
  };

  const handleRemoveFromWatch = async (entryId: string) => {
    try {
      const response = await fetch(`http://localhost:8000/monitor/watch/${entryId}`, {
        method: "DELETE",
      });
      if (response.ok) {
        setWatchTable(watchTable.filter((e) => e.id !== entryId));
      }
    } catch (error) {
      console.error("Failed to remove from watch:", error);
    }
  };

  const handleForceVariable = async (variableName: string, value: any, dataType: string) => {
    try {
      const response = await fetch("http://localhost:8000/monitor/force", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          variable_name: variableName,
          force_value: value,
          data_type: dataType,
          persistent: false,
        }),
      });
      if (response.ok) {
        // Refresh variables
        const varResponse = await fetch("http://localhost:8000/monitor/variables");
        if (varResponse.ok) {
          const data = await varResponse.json();
          setVariables(data);
        }
      }
    } catch (error) {
      console.error("Failed to force variable:", error);
    }
  };

  const handleReleaseVariable = async (variableName: string) => {
    try {
      const response = await fetch(`http://localhost:8000/monitor/release/${variableName}`, {
        method: "POST",
      });
      if (response.ok) {
        // Refresh variables
        const varResponse = await fetch("http://localhost:8000/monitor/variables");
        if (varResponse.ok) {
          const data = await varResponse.json();
          setVariables(data);
        }
      }
    } catch (error) {
      console.error("Failed to release variable:", error);
    }
  };

  const tabs = [
    { id: "watch" as MonitorTab, label: "监视表", icon: "M9 5H7a2 2 0 00-2 2v12a2 2 0 002 2h10a2 2 0 002-2V7a2 2 0 00-2-2h-2M9 5a2 2 0 002 2h2a2 2 0 002-2M9 5a2 2 0 012-2h2a2 2 0 012 2" },
    { id: "variables" as MonitorTab, label: "变量浏览器", icon: "M4 6h16M4 10h16M4 14h16M4 18h16" },
    { id: "force" as MonitorTab, label: "强制控制", icon: "M13 10V3L4 14h7v7l9-11h-7z" },
    { id: "parameters" as MonitorTab, label: "参数修改", icon: "M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 001.065 2.572c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 00-2.572 1.065c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 00-1.065-2.572c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z" },
  ];

  return (
    <div className="h-full flex flex-col">
      {/* Header */}
      <div className="h-12 bg-ide-sidebar border-b border-ide-border flex items-center px-4">
        <div className="flex items-center gap-2">
          <svg viewBox="0 0 24 24" className="w-5 h-5 text-ide-accent" fill="none" stroke="currentColor" strokeWidth="2">
            <path d="M9 19v-6a2 2 0 00-2-2H5a2 2 0 00-2 2v6a2 2 0 002 2h2a2 2 0 002-2zm0 0V9a2 2 0 012-2h2a2 2 0 012 2v10m-6 0a2 2 0 002 2h2a2 2 0 002-2m0 0V5a2 2 0 012-2h2a2 2 0 012 2v14a2 2 0 01-2 2h-2a2 2 0 01-2-2z" />
          </svg>
          <h1 className="text-lg font-semibold text-white">在线监视与调试</h1>
        </div>
        
        <div className="flex-1" />
        
        {/* Auto-refresh control */}
        <div className="flex items-center gap-3">
          <label className="flex items-center gap-2 text-sm text-ide-text">
            <input
              type="checkbox"
              checked={isAutoRefresh}
              onChange={(e) => setIsAutoRefresh(e.target.checked)}
              className="w-4 h-4 rounded border-ide-border bg-ide-bg text-ide-accent focus:ring-ide-accent"
            />
            自动刷新
          </label>
          <select
            value={refreshInterval}
            onChange={(e) => setRefreshInterval(Number(e.target.value))}
            className="px-2 py-1 bg-ide-bg border border-ide-border rounded text-sm text-ide-text"
          >
            <option value={500}>500ms</option>
            <option value={1000}>1s</option>
            <option value={2000}>2s</option>
            <option value={5000}>5s</option>
          </select>
        </div>
      </div>

      {/* Tab Navigation */}
      <div className="h-10 bg-ide-sidebar border-b border-ide-border flex items-center px-4 gap-1">
        {tabs.map((tab) => (
          <button
            key={tab.id}
            onClick={() => setActiveTab(tab.id)}
            className={`flex items-center gap-2 px-4 py-1.5 rounded-t text-sm font-medium transition-colors ${
              activeTab === tab.id
                ? "bg-ide-bg text-white border-b-2 border-ide-accent"
                : "text-ide-textDim hover:text-ide-text hover:bg-ide-hover"
            }`}
          >
            <svg viewBox="0 0 24 24" className="w-4 h-4" fill="none" stroke="currentColor" strokeWidth="2">
              <path d={tab.icon} />
            </svg>
            {tab.label}
          </button>
        ))}
      </div>

      {/* Content */}
      <div className="flex-1 flex overflow-hidden">
        {/* Main Content Area */}
        <div className="flex-1 overflow-auto bg-ide-bg p-4">
          {activeTab === "watch" && (
            <WatchTable
              entries={watchTable}
              variables={variables}
              onRemove={handleRemoveFromWatch}
              onRefresh={() => {}}
            />
          )}
          {activeTab === "variables" && (
            <VariableInspector
              variables={variables}
              selectedVariable={selectedVariable}
              onSelect={setSelectedVariable}
              onAddToWatch={handleAddToWatch}
              onForce={handleForceVariable}
              onRelease={handleReleaseVariable}
            />
          )}
          {activeTab === "force" && (
            <ForceControlPanel
              variables={variables}
              onRelease={handleReleaseVariable}
              onBatchForce={() => {}}
              onBatchRelease={() => {}}
            />
          )}
          {activeTab === "parameters" && (
            <ParameterEditor
              variables={variables}
              onModify={() => {}}
              onBatchModify={() => {}}
            />
          )}
        </div>

        {/* Right Panel - Variable Details */}
        {selectedVariable && activeTab === "variables" && (
          <div className="w-80 bg-ide-sidebar border-l border-ide-border overflow-y-auto">
            <div className="p-4">
              <h3 className="text-sm font-semibold text-white mb-3">变量详情</h3>
              {(() => {
                const variable = variables.find((v) => v.name === selectedVariable);
                if (!variable) return null;
                
                return (
                  <div className="space-y-3">
                    <div>
                      <div className="text-xs text-ide-textDim">名称</div>
                      <div className="text-sm text-white font-mono">{variable.name}</div>
                    </div>
                    <div>
                      <div className="text-xs text-ide-textDim">地址</div>
                      <div className="text-sm text-white font-mono">0x{variable.address.toString(16).toUpperCase()}</div>
                    </div>
                    <div>
                      <div className="text-xs text-ide-textDim">数据类型</div>
                      <div className="text-sm text-white">{variable.data_type}</div>
                    </div>
                    <div>
                      <div className="text-xs text-ide-textDim">变量类型</div>
                      <div className="text-sm text-white">{variable.var_type}</div>
                    </div>
                    <div>
                      <div className="text-xs text-ide-textDim">当前值</div>
                      <div className="text-sm text-white font-mono">{String(variable.current_value)}</div>
                    </div>
                    {variable.forced_value !== null && (
                      <div>
                        <div className="text-xs text-ide-textDim">强制值</div>
                        <div className="text-sm text-orange-400 font-mono">{String(variable.forced_value)}</div>
                      </div>
                    )}
                    <div>
                      <div className="text-xs text-ide-textDim">强制状态</div>
                      <div className={`text-sm ${
                        variable.force_status === "forced" ? "text-orange-400" : "text-green-400"
                      }`}>
                        {variable.force_status === "forced" ? "已强制" : "未强制"}
                      </div>
                    </div>
                    <div>
                      <div className="text-xs text-ide-textDim">质量</div>
                      <div className={`text-sm ${
                        variable.quality === "good" ? "text-green-400" : "text-red-400"
                      }`}>
                        {variable.quality === "good" ? "良好" : "异常"}
                      </div>
                    </div>
                    <div>
                      <div className="text-xs text-ide-textDim">最后更新</div>
                      <div className="text-sm text-white">{new Date(variable.last_updated).toLocaleTimeString()}</div>
                    </div>
                  </div>
                );
              })()}
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
