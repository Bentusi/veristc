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

interface ParameterEditorProps {
  variables: Variable[];
  onModify: (blockId: string, paramName: string, newValue: any, dataType: string) => void;
  onBatchModify: (modifications: Array<{ block_id: string; parameter_name: string; new_value: any; data_type: string }>) => void;
}

interface ParameterGroup {
  blockId: string;
  parameters: Variable[];
}

export function ParameterEditor({ variables, onModify, onBatchModify }: ParameterEditorProps) {
  const [editingParams, setEditingParams] = useState<Set<string>>(new Set());
  const [paramValues, setParamValues] = useState<Record<string, string>>({});
  const [selectedForBatch, setSelectedForBatch] = useState<Set<string>>(new Set());
  const [showBatchDialog, setShowBatchDialog] = useState(false);

  // Group variables by block (simplified: group by prefix before underscore)
  const parameterGroups: ParameterGroup[] = [];
  const groupMap = new Map<string, Variable[]>();

  variables.forEach((v) => {
    if (v.var_type === "LOCAL" || v.var_type === "GLOBAL") {
      const parts = v.name.split("_");
      const blockId = parts.length > 1 ? parts[0] : "MAIN";
      
      if (!groupMap.has(blockId)) {
        groupMap.set(blockId, []);
      }
      groupMap.get(blockId)!.push(v);
    }
  });

  groupMap.forEach((params, blockId) => {
    parameterGroups.push({ blockId, parameters: params });
  });

  const startEditing = (paramName: string, currentValue: any) => {
    setEditingParams(new Set([...editingParams, paramName]));
    setParamValues({ ...paramValues, [paramName]: String(currentValue) });
  };

  const cancelEditing = (paramName: string) => {
    const newEditing = new Set(editingParams);
    newEditing.delete(paramName);
    setEditingParams(newEditing);
    
    const newValues = { ...paramValues };
    delete newValues[paramName];
    setParamValues(newValues);
  };

  const saveEditing = (paramName: string, dataType: string) => {
    const parts = paramName.split("_");
    const blockId = parts.length > 1 ? parts[0] : "MAIN";
    const paramNameOnly = parts.length > 1 ? parts.slice(1).join("_") : paramName;
    
    let value: any = paramValues[paramName];
    if (dataType === "BOOL") {
      value = value.toLowerCase() === "true" || value === "1";
    } else if (dataType === "INT" || dataType === "DINT") {
      value = parseInt(value, 10);
    } else if (dataType === "REAL") {
      value = parseFloat(value);
    }
    
    onModify(blockId, paramNameOnly, value, dataType);
    cancelEditing(paramName);
  };

  const toggleBatchSelection = (paramName: string) => {
    const newSelection = new Set(selectedForBatch);
    if (newSelection.has(paramName)) {
      newSelection.delete(paramName);
    } else {
      newSelection.add(paramName);
    }
    setSelectedForBatch(newSelection);
  };

  const handleBatchModify = () => {
    const modifications = Array.from(selectedForBatch).map((paramName) => {
      const parts = paramName.split("_");
      const blockId = parts.length > 1 ? parts[0] : "MAIN";
      const paramNameOnly = parts.length > 1 ? parts.slice(1).join("_") : paramName;
      
      const variable = variables.find((v) => v.name === paramName);
      const valueStr = paramValues[paramName] || String(variable?.current_value || "");
      
      let value: any = valueStr;
      if (variable?.data_type === "BOOL") {
        value = valueStr.toLowerCase() === "true" || valueStr === "1";
      } else if (variable?.data_type === "INT" || variable?.data_type === "DINT") {
        value = parseInt(valueStr, 10);
      } else if (variable?.data_type === "REAL") {
        value = parseFloat(valueStr);
      }
      
      return {
        block_id: blockId,
        parameter_name: paramNameOnly,
        new_value: value,
        data_type: variable?.data_type || "REAL",
      };
    });
    
    onBatchModify(modifications);
    setSelectedForBatch(new Set());
    setShowBatchDialog(false);
  };

  return (
    <div className="h-full flex flex-col">
      {/* Header */}
      <div className="mb-6">
        <h2 className="text-lg font-semibold text-white mb-2">参数在线修改</h2>
        <p className="text-sm text-ide-textDim">
          修改功能块参数值，支持单个编辑和批量修改。修改将在下一个周期生效。
        </p>
      </div>

      {/* Action Bar */}
      <div className="flex items-center gap-3 mb-4">
        {selectedForBatch.size > 0 && (
          <button
            onClick={() => setShowBatchDialog(true)}
            className="flex items-center gap-2 px-4 py-1.5 bg-ide-accent hover:bg-blue-600 rounded text-sm text-white transition-colors"
          >
            <svg viewBox="0 0 24 24" className="w-4 h-4" fill="none" stroke="currentColor" strokeWidth="2">
              <path d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z" />
            </svg>
            批量修改 ({selectedForBatch.size})
          </button>
        )}
        <div className="flex-1" />
        <span className="text-sm text-ide-textDim">
          {parameterGroups.length} 个功能块，{variables.filter((v) => v.var_type === "LOCAL" || v.var_type === "GLOBAL").length} 个参数
        </span>
      </div>

      {/* Parameter Groups */}
      <div className="flex-1 overflow-auto space-y-4">
        {parameterGroups.map((group) => (
          <div key={group.blockId} className="rounded-lg border border-ide-border overflow-hidden">
            {/* Group Header */}
            <div className="bg-ide-sidebar px-4 py-2 border-b border-ide-border">
              <h3 className="text-sm font-semibold text-white flex items-center gap-2">
                <svg viewBox="0 0 24 24" className="w-4 h-4 text-ide-accent" fill="none" stroke="currentColor" strokeWidth="2">
                  <path d="M19.428 15.428a2 2 0 00-1.022-.547l-2.387-.477a6 6 0 00-3.86.517l-.318.158a6 6 0 01-3.86.517L6.05 15.21a2 2 0 00-1.022.547L3 17.5h2m14.428-2.072a2 2 0 011.022.547l2.387.477a6 6 0 013.86-.517l.318-.158a6 6 0 003.86-.517l1.95-1.592a2 2 0 011.022-.547H21m-14.428-2.072a2 2 0 00-1.022-.547l-2.387-.477a6 6 0 00-3.86.517l-.318.158a6 6 0 01-3.86.517L3 7.5h2m14.428 2.072a2 2 0 011.022.547l2.387.477a6 6 0 003.86-.517l.318-.158a6 6 0 013.86-.517l1.95-1.592a2 2 0 001.022-.547H21" />
                </svg>
                功能块: {group.blockId}
                <span className="text-xs text-ide-textDim font-normal">({group.parameters.length} 个参数)</span>
              </h3>
            </div>

            {/* Parameters Table */}
            <table className="w-full">
              <thead className="bg-ide-sidebar/50">
                <tr>
                  <th className="px-4 py-2 text-left">
                    <input
                      type="checkbox"
                      checked={group.parameters.every((p) => selectedForBatch.has(p.name))}
                      onChange={(e) => {
                        if (e.target.checked) {
                          const newSelection = new Set(selectedForBatch);
                          group.parameters.forEach((p) => newSelection.add(p.name));
                          setSelectedForBatch(newSelection);
                        } else {
                          const newSelection = new Set(selectedForBatch);
                          group.parameters.forEach((p) => newSelection.delete(p.name));
                          setSelectedForBatch(newSelection);
                        }
                      }}
                      className="w-4 h-4 rounded border-ide-border bg-ide-bg text-ide-accent focus:ring-ide-accent"
                    />
                  </th>
                  <th className="px-4 py-2 text-left text-xs font-semibold text-ide-textDim uppercase">参数名</th>
                  <th className="px-4 py-2 text-left text-xs font-semibold text-ide-textDim uppercase">数据类型</th>
                  <th className="px-4 py-2 text-left text-xs font-semibold text-ide-textDim uppercase">当前值</th>
                  <th className="px-4 py-2 text-left text-xs font-semibold text-ide-textDim uppercase">修改值</th>
                  <th className="px-4 py-2 text-right text-xs font-semibold text-ide-textDim uppercase">操作</th>
                </tr>
              </thead>
              <tbody className="bg-ide-bg divide-y divide-ide-border">
                {group.parameters.map((param) => {
                  const isEditing = editingParams.has(param.name);
                  const isSelected = selectedForBatch.has(param.name);
                  
                  return (
                    <tr
                      key={param.name}
                      className={`transition-colors ${isSelected ? "bg-ide-accent/10" : "hover:bg-ide-hover/50"}`}
                    >
                      <td className="px-4 py-3">
                        <input
                          type="checkbox"
                          checked={isSelected}
                          onChange={() => toggleBatchSelection(param.name)}
                          className="w-4 h-4 rounded border-ide-border bg-ide-bg text-ide-accent focus:ring-ide-accent"
                        />
                      </td>
                      <td className="px-4 py-3 text-sm text-white font-mono">{param.name}</td>
                      <td className="px-4 py-3 text-sm text-ide-text">{param.data_type}</td>
                      <td className="px-4 py-3 text-sm text-ide-text font-mono">
                        {param.data_type === "BOOL"
                          ? param.current_value
                            ? "TRUE"
                            : "FALSE"
                          : String(param.current_value)}
                      </td>
                      <td className="px-4 py-3">
                        {isEditing ? (
                          <input
                            type="text"
                            value={paramValues[param.name] || ""}
                            onChange={(e) => setParamValues({ ...paramValues, [param.name]: e.target.value })}
                            onKeyDown={(e) => {
                              if (e.key === "Enter") saveEditing(param.name, param.data_type);
                              if (e.key === "Escape") cancelEditing(param.name);
                            }}
                            className="w-full px-2 py-1 bg-ide-sidebar border border-ide-accent rounded text-sm text-white focus:outline-none"
                            autoFocus
                          />
                        ) : (
                          <span className="text-sm text-ide-textDim">-</span>
                        )}
                      </td>
                      <td className="px-4 py-3 text-right">
                        {isEditing ? (
                          <div className="flex items-center justify-end gap-1">
                            <button
                              onClick={() => saveEditing(param.name, param.data_type)}
                              className="p-1 text-green-400 hover:text-green-300 transition-colors"
                              title="保存"
                            >
                              <svg viewBox="0 0 24 24" className="w-4 h-4" fill="none" stroke="currentColor" strokeWidth="2">
                                <path d="M5 13l4 4L19 7" />
                              </svg>
                            </button>
                            <button
                              onClick={() => cancelEditing(param.name)}
                              className="p-1 text-red-400 hover:text-red-300 transition-colors"
                              title="取消"
                            >
                              <svg viewBox="0 0 24 24" className="w-4 h-4" fill="none" stroke="currentColor" strokeWidth="2">
                                <path d="M6 18L18 6M6 6l12 12" />
                              </svg>
                            </button>
                          </div>
                        ) : (
                          <button
                            onClick={() => startEditing(param.name, param.current_value)}
                            className="p-1 text-ide-textDim hover:text-ide-accent transition-colors"
                            title="编辑"
                          >
                            <svg viewBox="0 0 24 24" className="w-4 h-4" fill="none" stroke="currentColor" strokeWidth="2">
                              <path d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z" />
                            </svg>
                          </button>
                        )}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        ))}

        {parameterGroups.length === 0 && (
          <div className="h-full flex items-center justify-center">
            <div className="text-center">
              <svg viewBox="0 0 24 24" className="w-16 h-16 text-ide-textDim mx-auto mb-4" fill="none" stroke="currentColor" strokeWidth="1.5">
                <path d="M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 001.065 2.572c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 00-2.572 1.065c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 00-1.065-2.572c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z" />
                <path d="M15 12a3 3 0 11-6 0 3 3 0 016 0z" />
              </svg>
              <p className="text-ide-textDim mb-2">暂无可修改的参数</p>
              <p className="text-sm text-ide-textDim">参数将在加载程序后显示</p>
            </div>
          </div>
        )}
      </div>

      {/* Batch Modify Dialog */}
      {showBatchDialog && (
        <div className="fixed inset-0 bg-black/50 flex items-center justify-center z-50" onClick={() => setShowBatchDialog(false)}>
          <div className="bg-ide-sidebar border border-ide-border rounded-lg p-6 w-[600px] max-h-[80vh] overflow-auto" onClick={(e) => e.stopPropagation()}>
            <h3 className="text-lg font-semibold text-white mb-4">批量修改参数</h3>
            <p className="text-sm text-ide-textDim mb-4">
              将修改以下 {selectedForBatch.size} 个参数的值：
            </p>
            
            <div className="space-y-3 mb-6">
              {Array.from(selectedForBatch).map((paramName) => {
                const variable = variables.find((v) => v.name === paramName);
                if (!variable) return null;
                
                return (
                  <div key={paramName} className="flex items-center gap-3">
                    <div className="w-40 text-sm text-white font-mono">{paramName}</div>
                    <div className="w-20 text-xs text-ide-textDim">{variable.data_type}</div>
                    <input
                      type="text"
                      value={paramValues[paramName] || String(variable.current_value)}
                      onChange={(e) => setParamValues({ ...paramValues, [paramName]: e.target.value })}
                      className="flex-1 px-3 py-1.5 bg-ide-bg border border-ide-border rounded text-sm text-white focus:outline-none focus:border-ide-accent"
                      placeholder="新值"
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
                onClick={handleBatchModify}
                className="flex-1 px-4 py-2 bg-ide-accent hover:bg-blue-600 rounded text-sm text-white transition-colors"
              >
                确认修改
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
