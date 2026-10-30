import { useState } from "react";

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

interface ForceControlPanelProps {
  variables: Variable[];
  onRelease: (name: string) => void;
  onBatchForce: (requests: Array<{ variable_name: string; force_value: any; data_type: string }>) => void;
  onBatchRelease: (names: string[]) => void;
}

export function ForceControlPanel({
  variables,
  onRelease,
  onBatchForce,
  onBatchRelease,
}: ForceControlPanelProps) {
  const [selectedVariables, setSelectedVariables] = useState<Set<string>>(new Set());
  const [batchForceValues, setBatchForceValues] = useState<Record<string, string>>({});
  const [showBatchDialog, setShowBatchDialog] = useState(false);

  const forcedVariables = variables.filter((v) => v.force_status === "forced");
  const availableVariables = variables.filter((v) => v.force_status !== "forced");

  const toggleSelection = (name: string) => {
    const newSelection = new Set(selectedVariables);
    if (newSelection.has(name)) {
      newSelection.delete(name);
    } else {
      newSelection.add(name);
    }
    setSelectedVariables(newSelection);
  };

  const selectAll = () => {
    setSelectedVariables(new Set(variables.map((v) => v.name)));
  };

  const deselectAll = () => {
    setSelectedVariables(new Set());
  };

  const handleBatchForce = () => {
    const requests = Array.from(selectedVariables).map((name) => {
      const variable = variables.find((v) => v.name === name);
      const valueStr = batchForceValues[name] || String(variable?.current_value || "");
      
      let value: any = valueStr;
      if (variable?.data_type === "BOOL") {
        value = valueStr.toLowerCase() === "true" || valueStr === "1";
      } else if (variable?.data_type === "INT" || variable?.data_type === "DINT") {
        value = parseInt(valueStr, 10);
      } else if (variable?.data_type === "REAL") {
        value = parseFloat(valueStr);
      }
      
      return {
        variable_name: name,
        force_value: value,
        data_type: variable?.data_type || "REAL",
      };
    });
    
    onBatchForce(requests);
    setSelectedVariables(new Set());
    setBatchForceValues({});
  };

  const handleBatchRelease = () => {
    const names = Array.from(selectedVariables);
    onBatchRelease(names);
    setSelectedVariables(new Set());
  };

  return (
    <div className="h-full flex flex-col">
      {/* Header */}
      <div className="mb-6">
        <h2 className="text-lg font-semibold text-white mb-2">变量强制控制</h2>
        <p className="text-sm text-ide-textDim">
          强制变量到指定值或释放强制。支持单个和批量操作。
        </p>
      </div>

      {/* Action Bar */}
      <div className="flex items-center gap-3 mb-4">
        <button
          onClick={selectAll}
          className="px-3 py-1.5 bg-ide-sidebar border border-ide-border rounded text-sm text-ide-text hover:bg-ide-hover transition-colors"
        >
          全选
        </button>
        <button
          onClick={deselectAll}
          className="px-3 py-1.5 bg-ide-sidebar border border-ide-border rounded text-sm text-ide-text hover:bg-ide-hover transition-colors"
        >
          取消全选
        </button>
        <div className="flex-1" />
        {selectedVariables.size > 0 && (
          <>
            <button
              onClick={() => setShowBatchDialog(true)}
              className="flex items-center gap-2 px-4 py-1.5 bg-orange-600 hover:bg-orange-700 rounded text-sm text-white transition-colors"
            >
              <svg viewBox="0 0 24 24" className="w-4 h-4" fill="none" stroke="currentColor" strokeWidth="2">
                <path d="M13 10V3L4 14h7v7l9-11h-7z" />
              </svg>
              批量强制 ({selectedVariables.size})
            </button>
            <button
              onClick={handleBatchRelease}
              className="flex items-center gap-2 px-4 py-1.5 bg-ide-sidebar border border-ide-border rounded text-sm text-ide-text hover:bg-red-600/20 hover:border-red-500/50 transition-colors"
            >
              <svg viewBox="0 0 24 24" className="w-4 h-4" fill="none" stroke="currentColor" strokeWidth="2">
                <path d="M6 18L18 6M6 6l12 12" />
              </svg>
              批量释放 ({selectedVariables.size})
            </button>
          </>
        )}
      </div>

      {/* Content */}
      <div className="flex-1 grid grid-cols-2 gap-4 overflow-hidden">
        {/* Available Variables */}
        <div className="flex flex-col overflow-hidden">
          <h3 className="text-sm font-semibold text-white mb-2 flex items-center gap-2">
            <span className="w-2 h-2 rounded-full bg-green-400"></span>
            可用变量 ({availableVariables.length})
          </h3>
          <div className="flex-1 overflow-auto rounded-lg border border-ide-border">
            <table className="w-full">
              <thead className="bg-ide-sidebar sticky top-0">
                <tr>
                  <th className="px-3 py-2 text-left">
                    <input
                      type="checkbox"
                      checked={selectedVariables.size === availableVariables.length && availableVariables.length > 0}
                      onChange={(e) => {
                        if (e.target.checked) {
                          setSelectedVariables(new Set(availableVariables.map((v) => v.name)));
                        } else {
                          deselectAll();
                        }
                      }}
                      className="w-4 h-4 rounded border-ide-border bg-ide-bg text-ide-accent focus:ring-ide-accent"
                    />
                  </th>
                  <th className="px-3 py-2 text-left text-xs font-semibold text-ide-textDim uppercase">变量名</th>
                  <th className="px-3 py-2 text-left text-xs font-semibold text-ide-textDim uppercase">当前值</th>
                  <th className="px-3 py-2 text-left text-xs font-semibold text-ide-textDim uppercase">类型</th>
                </tr>
              </thead>
              <tbody className="bg-ide-bg divide-y divide-ide-border">
                {availableVariables.map((variable) => (
                  <tr
                    key={variable.name}
                    className={`transition-colors ${
                      selectedVariables.has(variable.name) ? "bg-ide-accent/10" : "hover:bg-ide-hover/50"
                    }`}
                  >
                    <td className="px-3 py-2">
                      <input
                        type="checkbox"
                        checked={selectedVariables.has(variable.name)}
                        onChange={() => toggleSelection(variable.name)}
                        className="w-4 h-4 rounded border-ide-border bg-ide-bg text-ide-accent focus:ring-ide-accent"
                      />
                    </td>
                    <td className="px-3 py-2 text-sm text-white font-mono">{variable.name}</td>
                    <td className="px-3 py-2 text-sm text-ide-text font-mono">
                      {variable.data_type === "BOOL"
                        ? variable.current_value
                          ? "TRUE"
                          : "FALSE"
                        : String(variable.current_value)}
                    </td>
                    <td className="px-3 py-2 text-sm text-ide-textDim">{variable.data_type}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>

        {/* Forced Variables */}
        <div className="flex flex-col overflow-hidden">
          <h3 className="text-sm font-semibold text-white mb-2 flex items-center gap-2">
            <span className="w-2 h-2 rounded-full bg-orange-400"></span>
            已强制变量 ({forcedVariables.length})
          </h3>
          <div className="flex-1 overflow-auto rounded-lg border border-ide-border">
            <table className="w-full">
              <thead className="bg-ide-sidebar sticky top-0">
                <tr>
                  <th className="px-3 py-2 text-left text-xs font-semibold text-ide-textDim uppercase">变量名</th>
                  <th className="px-3 py-2 text-left text-xs font-semibold text-ide-textDim uppercase">强制值</th>
                  <th className="px-3 py-2 text-left text-xs font-semibold text-ide-textDim uppercase">当前值</th>
                  <th className="px-3 py-2 text-right text-xs font-semibold text-ide-textDim uppercase">操作</th>
                </tr>
              </thead>
              <tbody className="bg-ide-bg divide-y divide-ide-border">
                {forcedVariables.map((variable) => (
                  <tr key={variable.name} className="hover:bg-ide-hover/50 transition-colors">
                    <td className="px-3 py-2 text-sm text-white font-mono">{variable.name}</td>
                    <td className="px-3 py-2 text-sm text-orange-400 font-mono">
                      {variable.forced_value !== null ? String(variable.forced_value) : "-"}
                    </td>
                    <td className="px-3 py-2 text-sm text-ide-text font-mono">
                      {variable.data_type === "BOOL"
                        ? variable.current_value
                          ? "TRUE"
                          : "FALSE"
                        : String(variable.current_value)}
                    </td>
                    <td className="px-3 py-2 text-right">
                      <button
                        onClick={() => onRelease(variable.name)}
                        className="px-2 py-1 bg-red-600/20 hover:bg-red-600/30 border border-red-500/30 rounded text-xs text-red-400 transition-colors"
                      >
                        释放
                      </button>
                    </td>
                  </tr>
                ))}
                {forcedVariables.length === 0 && (
                  <tr>
                    <td colSpan={4} className="px-3 py-8 text-center text-sm text-ide-textDim">
                      暂无已强制的变量
                    </td>
                  </tr>
                )}
              </tbody>
            </table>
          </div>
        </div>
      </div>

      {/* Batch Force Dialog */}
      {showBatchDialog && (
        <div className="fixed inset-0 bg-black/50 flex items-center justify-center z-50" onClick={() => setShowBatchDialog(false)}>
          <div className="bg-ide-sidebar border border-ide-border rounded-lg p-6 w-[600px] max-h-[80vh] overflow-auto" onClick={(e) => e.stopPropagation()}>
            <h3 className="text-lg font-semibold text-white mb-4">批量强制变量</h3>
            <p className="text-sm text-ide-textDim mb-4">
              将为以下 {selectedVariables.size} 个变量设置强制值：
            </p>
            
            <div className="space-y-3 mb-6">
              {Array.from(selectedVariables).map((name) => {
                const variable = variables.find((v) => v.name === name);
                if (!variable) return null;
                
                return (
                  <div key={name} className="flex items-center gap-3">
                    <div className="w-32 text-sm text-white font-mono">{name}</div>
                    <div className="w-20 text-xs text-ide-textDim">{variable.data_type}</div>
                    <input
                      type="text"
                      value={batchForceValues[name] || String(variable.current_value)}
                      onChange={(e) => setBatchForceValues({ ...batchForceValues, [name]: e.target.value })}
                      className="flex-1 px-3 py-1.5 bg-ide-bg border border-ide-border rounded text-sm text-white focus:outline-none focus:border-ide-accent"
                      placeholder="强制值"
                    />
                  </div>
                );
              })}
            </div>
            
            <div className="flex gap-2">
              <button
                onClick={() => setShowBatchDialog(false)}
                className="flex-1 px-4 py-2 bg-ide-bg border border-ide-border rounded text-sm text-ide-text hover:bg-ide-hover transition-colors"
              >
                取消
              </button>
              <button
                onClick={() => {
                  handleBatchForce();
                  setShowBatchDialog(false);
                }}
                className="flex-1 px-4 py-2 bg-orange-600 hover:bg-orange-700 rounded text-sm text-white transition-colors"
              >
                确认强制
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
