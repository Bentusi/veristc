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

interface WatchEntry {
  id: string;
  variable_name: string;
  alias: string | null;
  display_format: string;
  enabled: boolean;
  last_value: any;
  last_update: string | null;
}

interface WatchTableProps {
  entries: WatchEntry[];
  variables: Variable[];
  onRemove: (entryId: string) => void;
  onRefresh: () => void;
}

export function WatchTable({ entries, variables, onRemove, onRefresh }: WatchTableProps) {
  const [editingAlias, setEditingAlias] = useState<string | null>(null);
  const [newAlias, setNewAlias] = useState("");

  const getVariableData = (varName: string): Variable | undefined => {
    return variables.find((v) => v.name === varName);
  };

  const formatValue = (value: any, format: string, dataType: string): string => {
    if (value === null || value === undefined) return "-";
    
    if (format === "hex" && typeof value === "number") {
      return "0x" + value.toString(16).toUpperCase();
    }
    if (format === "binary" && typeof value === "number") {
      return "0b" + value.toString(2);
    }
    
    if (dataType === "BOOL") {
      return value ? "TRUE" : "FALSE";
    }
    
    return String(value);
  };

  const handleAliasSave = () => {
    // TODO: Call API to update alias
    setEditingAlias(null);
    setNewAlias("");
  };

  if (entries.length === 0) {
    return (
      <div className="h-full flex items-center justify-center">
        <div className="text-center">
          <svg viewBox="0 0 24 24" className="w-16 h-16 text-ide-textDim mx-auto mb-4" fill="none" stroke="currentColor" strokeWidth="1.5">
            <path d="M9 5H7a2 2 0 00-2 2v12a2 2 0 002 2h10a2 2 0 002-2V7a2 2 0 00-2-2h-2M9 5a2 2 0 002 2h2a2 2 0 002-2M9 5a2 2 0 012-2h2a2 2 0 012 2" />
          </svg>
          <p className="text-ide-textDim mb-2">监视表为空</p>
          <p className="text-sm text-ide-textDim">从变量浏览器中添加变量到监视表</p>
        </div>
      </div>
    );
  }

  return (
    <div className="h-full flex flex-col">
      {/* Toolbar */}
      <div className="flex items-center gap-2 mb-4">
        <button
          onClick={onRefresh}
          className="flex items-center gap-2 px-3 py-1.5 bg-ide-sidebar border border-ide-border rounded text-sm text-ide-text hover:bg-ide-hover transition-colors"
        >
          <svg viewBox="0 0 24 24" className="w-4 h-4" fill="none" stroke="currentColor" strokeWidth="2">
            <path d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15" />
          </svg>
          刷新
        </button>
        <button
          onClick={() => {
            if (confirm("确定要清空监视表吗？")) {
              entries.forEach((e) => onRemove(e.id));
            }
          }}
          className="flex items-center gap-2 px-3 py-1.5 bg-ide-sidebar border border-ide-border rounded text-sm text-ide-text hover:bg-red-600/20 hover:border-red-500/50 transition-colors"
        >
          <svg viewBox="0 0 24 24" className="w-4 h-4" fill="none" stroke="currentColor" strokeWidth="2">
            <path d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16" />
          </svg>
          清空
        </button>
        <div className="flex-1" />
        <span className="text-sm text-ide-textDim">{entries.length} 个变量</span>
      </div>

      {/* Table */}
      <div className="flex-1 overflow-auto rounded-lg border border-ide-border">
        <table className="w-full">
          <thead className="bg-ide-sidebar sticky top-0">
            <tr>
              <th className="px-4 py-2 text-left text-xs font-semibold text-ide-textDim uppercase tracking-wider">变量名</th>
              <th className="px-4 py-2 text-left text-xs font-semibold text-ide-textDim uppercase tracking-wider">别名</th>
              <th className="px-4 py-2 text-left text-xs font-semibold text-ide-textDim uppercase tracking-wider">当前值</th>
              <th className="px-4 py-2 text-left text-xs font-semibold text-ide-textDim uppercase tracking-wider">强制值</th>
              <th className="px-4 py-2 text-left text-xs font-semibold text-ide-textDim uppercase tracking-wider">类型</th>
              <th className="px-4 py-2 text-left text-xs font-semibold text-ide-textDim uppercase tracking-wider">状态</th>
              <th className="px-4 py-2 text-left text-xs font-semibold text-ide-textDim uppercase tracking-wider">更新时间</th>
              <th className="px-4 py-2 text-right text-xs font-semibold text-ide-textDim uppercase tracking-wider">操作</th>
            </tr>
          </thead>
          <tbody className="bg-ide-bg divide-y divide-ide-border">
            {entries.map((entry) => {
              const varData = getVariableData(entry.variable_name);
              if (!varData) return null;

              return (
                <tr key={entry.id} className="hover:bg-ide-hover/50 transition-colors">
                  <td className="px-4 py-3 text-sm text-white font-mono">{entry.variable_name}</td>
                  <td className="px-4 py-3 text-sm text-ide-text">
                    {editingAlias === entry.id ? (
                      <input
                        type="text"
                        value={newAlias}
                        onChange={(e) => setNewAlias(e.target.value)}
                        onBlur={handleAliasSave}
                        onKeyDown={(e) => e.key === "Enter" && handleAliasSave()}
                        className="w-full px-2 py-1 bg-ide-sidebar border border-ide-accent rounded text-sm text-white focus:outline-none"
                        autoFocus
                      />
                    ) : (
                      <span
                        onClick={() => {
                          setEditingAlias(entry.id);
                          setNewAlias(entry.alias || "");
                        }}
                        className="cursor-pointer hover:text-ide-accent"
                      >
                        {entry.alias || "-"}
                      </span>
                    )}
                  </td>
                  <td className="px-4 py-3 text-sm text-white font-mono">
                    {formatValue(varData.current_value, entry.display_format, varData.data_type)}
                  </td>
                  <td className="px-4 py-3 text-sm font-mono">
                    {varData.forced_value !== null ? (
                      <span className="text-orange-400">
                        {formatValue(varData.forced_value, entry.display_format, varData.data_type)}
                      </span>
                    ) : (
                      <span className="text-ide-textDim">-</span>
                    )}
                  </td>
                  <td className="px-4 py-3 text-sm text-ide-text">{varData.data_type}</td>
                  <td className="px-4 py-3">
                    <span className={`inline-flex items-center px-2 py-0.5 rounded text-xs font-medium ${
                      varData.force_status === "forced"
                        ? "bg-orange-500/20 text-orange-400"
                        : varData.quality === "good"
                        ? "bg-green-500/20 text-green-400"
                        : "bg-red-500/20 text-red-400"
                    }`}>
                      {varData.force_status === "forced" ? "已强制" : varData.quality === "good" ? "正常" : "异常"}
                    </span>
                  </td>
                  <td className="px-4 py-3 text-sm text-ide-textDim">
                    {new Date(varData.last_updated).toLocaleTimeString()}
                  </td>
                  <td className="px-4 py-3 text-right">
                    <button
                      onClick={() => onRemove(entry.id)}
                      className="text-ide-textDim hover:text-red-400 transition-colors"
                      title="移除"
                    >
                      <svg viewBox="0 0 24 24" className="w-4 h-4" fill="none" stroke="currentColor" strokeWidth="2">
                        <path d="M6 18L18 6M6 6l12 12" />
                      </svg>
                    </button>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </div>
  );
}
