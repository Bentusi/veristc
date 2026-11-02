import { useState } from "react";
import { useI18n } from "../../lib/i18n";

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

interface VariableInspectorProps {
  variables: Variable[];
  selectedVariable: string | null;
  onSelect: (name: string) => void;
  onAddToWatch: (name: string) => void;
  onForce: (name: string, value: any, dataType: string) => void;
  onRelease: (name: string) => void;
}

export function VariableInspector({
  variables,
  selectedVariable,
  onSelect,
  onAddToWatch,
  onForce,
  onRelease,
}: VariableInspectorProps) {
  const { t } = useI18n();
  const [filterText, setFilterText] = useState("");
  const [filterType, setFilterType] = useState<string>("all");
  const [showForceDialog, setShowForceDialog] = useState<string | null>(null);
  const [forceValue, setForceValue] = useState("");

  const filteredVariables = variables.filter((v) => {
    const matchesText = v.name.toLowerCase().includes(filterText.toLowerCase());
    const matchesType = filterType === "all" || v.var_type === filterType;
    return matchesText && matchesType;
  });

  const handleForce = (varName: string, dataType: string) => {
    let value: any = forceValue;
    
    if (dataType === "BOOL") {
      value = forceValue.toLowerCase() === "true" || forceValue === "1";
    } else if (dataType === "INT" || dataType === "DINT") {
      value = parseInt(forceValue, 10);
    } else if (dataType === "REAL") {
      value = parseFloat(forceValue);
    }
    
    onForce(varName, value, dataType);
    setShowForceDialog(null);
    setForceValue("");
  };

  const varTypeColors: Record<string, string> = {
    INPUT: "bg-blue-500/20 text-blue-400",
    OUTPUT: "bg-green-500/20 text-green-400",
    IN_OUT: "bg-purple-500/20 text-purple-400",
    LOCAL: "bg-gray-500/20 text-ide-textDim",
    GLOBAL: "bg-orange-500/20 text-orange-400",
  };

  return (
    <div className="h-full flex flex-col">
      {/* Filters */}
      <div className="flex items-center gap-3 mb-4">
        <div className="flex-1">
          <input
            type="text"
            placeholder={t("varInspector.searchPlaceholder")}
            value={filterText}
            onChange={(e) => setFilterText(e.target.value)}
            className="w-full px-3 py-2 bg-ide-sidebar border border-ide-border rounded text-sm text-ide-strong placeholder-ide-textDim focus:outline-none focus:border-ide-accent"
          />
        </div>
        <select
          value={filterType}
          onChange={(e) => setFilterType(e.target.value)}
          className="px-3 py-2 bg-ide-sidebar border border-ide-border rounded text-sm text-ide-strong focus:outline-none focus:border-ide-accent"
        >
          <option value="all">{t("varInspector.allTypes")}</option>
          <option value="INPUT">{t("monitor.input")}</option>
          <option value="OUTPUT">{t("monitor.output")}</option>
          <option value="IN_OUT">{t("varInspector.inputOutput")}</option>
          <option value="LOCAL">{t("varInspector.local")}</option>
          <option value="GLOBAL">{t("varInspector.global")}</option>
        </select>
        <span className="text-sm text-ide-textDim">{filteredVariables.length} / {variables.length}</span>
      </div>

      {/* Variable List */}
      <div className="flex-1 overflow-auto rounded-lg border border-ide-border">
        <table className="w-full">
          <thead className="bg-ide-sidebar sticky top-0">
            <tr>
              <th className="px-4 py-2 text-left text-xs font-semibold text-ide-textDim uppercase tracking-wider">{t("varInspector.varName")}</th>
              <th className="px-4 py-2 text-left text-xs font-semibold text-ide-textDim uppercase tracking-wider">{t("varInspector.address")}</th>
              <th className="px-4 py-2 text-left text-xs font-semibold text-ide-textDim uppercase tracking-wider">{t("varInspector.currentValue")}</th>
              <th className="px-4 py-2 text-left text-xs font-semibold text-ide-textDim uppercase tracking-wider">{t("varInspector.type")}</th>
              <th className="px-4 py-2 text-left text-xs font-semibold text-ide-textDim uppercase tracking-wider">{t("varInspector.dataType")}</th>
              <th className="px-4 py-2 text-left text-xs font-semibold text-ide-textDim uppercase tracking-wider">{t("varInspector.status")}</th>
              <th className="px-4 py-2 text-right text-xs font-semibold text-ide-textDim uppercase tracking-wider">{t("varInspector.operations")}</th>
            </tr>
          </thead>
          <tbody className="bg-ide-bg divide-y divide-ide-border">
            {filteredVariables.map((variable) => (
              <tr
                key={variable.name}
                onClick={() => onSelect(variable.name)}
                className={`cursor-pointer transition-colors ${
                  selectedVariable === variable.name
                    ? "bg-ide-accent/10"
                    : "hover:bg-ide-hover/50"
                }`}
              >
                <td className="px-4 py-3 text-sm text-ide-strong font-mono">{variable.name}</td>
                <td className="px-4 py-3 text-sm text-ide-textDim font-mono">
                  0x{variable.address.toString(16).toUpperCase()}
                </td>
                <td className="px-4 py-3 text-sm text-ide-strong font-mono">
                  {variable.data_type === "BOOL"
                    ? variable.current_value
                      ? "TRUE"
                      : "FALSE"
                    : String(variable.current_value)}
                </td>
                <td className="px-4 py-3">
                  <span className={`inline-flex items-center px-2 py-0.5 rounded text-xs font-medium ${varTypeColors[variable.var_type] || "bg-gray-500/20 text-ide-textDim"}`}>
                    {variable.var_type}
                  </span>
                </td>
                <td className="px-4 py-3 text-sm text-ide-text">{variable.data_type}</td>
                <td className="px-4 py-3">
                  <span className={`inline-flex items-center px-2 py-0.5 rounded text-xs font-medium ${
                    variable.force_status === "forced"
                      ? "bg-orange-500/20 text-orange-400"
                      : variable.quality === "good"
                      ? "bg-green-500/20 text-green-400"
                      : "bg-red-500/20 text-red-400"
                  }`}>
                    {variable.force_status === "forced" ? t("monitor.forcedStatus") : variable.quality === "good" ? t("watchTable.normal") : t("monitor.abnormal")}
                  </span>
                </td>
                <td className="px-4 py-3 text-right" onClick={(e) => e.stopPropagation()}>
                  <div className="flex items-center justify-end gap-1">
                    <button
                      onClick={() => onAddToWatch(variable.name)}
                      className="p-1 text-ide-textDim hover:text-ide-accent transition-colors"
                      title={t("varInspector.addToWatch")}
                    >
                      <svg viewBox="0 0 24 24" className="w-4 h-4" fill="none" stroke="currentColor" strokeWidth="2">
                        <path d="M12 4v16m8-8H4" />
                      </svg>
                    </button>
                    {variable.force_status === "forced" ? (
                      <button
                        onClick={() => onRelease(variable.name)}
                        className="p-1 text-orange-400 hover:text-orange-300 transition-colors"
                        title={t("varInspector.releaseForce")}
                      >
                        <svg viewBox="0 0 24 24" className="w-4 h-4" fill="none" stroke="currentColor" strokeWidth="2">
                          <path d="M6 18L18 6M6 6l12 12" />
                        </svg>
                      </button>
                    ) : (
                      <button
                        onClick={() => {
                          setShowForceDialog(variable.name);
                          setForceValue(String(variable.current_value));
                        }}
                        className="p-1 text-ide-textDim hover:text-orange-400 transition-colors"
                        title={t("varInspector.forceValue")}
                      >
                        <svg viewBox="0 0 24 24" className="w-4 h-4" fill="none" stroke="currentColor" strokeWidth="2">
                          <path d="M13 10V3L4 14h7v7l9-11h-7z" />
                        </svg>
                      </button>
                    )}
                  </div>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {/* Force Dialog */}
      {showForceDialog && (
        <div className="fixed inset-0 bg-black/50 flex items-center justify-center z-50" onClick={() => setShowForceDialog(null)}>
          <div className="bg-ide-sidebar border border-ide-border rounded-lg p-6 w-96" onClick={(e) => e.stopPropagation()}>
            <h3 className="text-lg font-semibold text-ide-strong mb-4">{t("varInspector.forceValueTitle")}</h3>
            <div className="mb-4">
              <label className="block text-sm text-ide-textDim mb-2">{t("varInspector.varName")}</label>
              <div className="px-3 py-2 bg-ide-bg border border-ide-border rounded text-sm text-ide-strong font-mono">
                {showForceDialog}
              </div>
            </div>
            <div className="mb-6">
              <label className="block text-sm text-ide-textDim mb-2">{t("varInspector.forceValue")}</label>
              <input
                type="text"
                value={forceValue}
                onChange={(e) => setForceValue(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === "Enter") {
                    const variable = variables.find((v) => v.name === showForceDialog);
                    if (variable) {
                      handleForce(showForceDialog, variable.data_type);
                    }
                  }
                }}
                className="w-full px-3 py-2 bg-ide-bg border border-ide-border rounded text-sm text-ide-strong focus:outline-none focus:border-ide-accent"
                autoFocus
              />
            </div>
            <div className="flex gap-2">
              <button
                onClick={() => setShowForceDialog(null)}
                className="flex-1 px-4 py-2 bg-ide-bg border border-ide-border rounded text-sm text-ide-text hover:bg-ide-hover transition-colors"
              >
                {t("common.cancel")}
              </button>
              <button
                onClick={() => {
                  const variable = variables.find((v) => v.name === showForceDialog);
                  if (variable) {
                    handleForce(showForceDialog, variable.data_type);
                  }
                }}
                className="flex-1 px-4 py-2 bg-orange-600 hover:bg-orange-700 rounded text-sm text-white transition-colors"
              >
                {t("varInspector.force")}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
