import { HOLD_LABELS, KIND_COLOR, type ExternalVarRow } from "./types";

interface ExternalVarTableProps {
  rows: ExternalVarRow[];
  onSelectVar: (name: string) => void;
}

function range(row: ExternalVarRow): string {
  if (row.safety_min === null && row.safety_max === null) return "—";
  const fmt = (value: number | null) => (value === null ? "−∞" : String(value));
  return `${fmt(row.safety_min)} … ${fmt(row.safety_max)}`;
}

export function ExternalVarTable({ rows, onSelectVar }: ExternalVarTableProps) {
  const columns = [
    "变量名",
    "方向",
    "数据类型",
    "模块",
    "通道",
    "点名称",
    "单位",
    "质量位",
    "幅值限制",
    "异常后保持",
  ];

  return (
    <div className="overflow-auto max-h-44">
      <table className="w-full text-[11px]">
        <thead>
          <tr className="text-left text-ide-textDim border-b border-ide-border">
            {columns.map((title) => (
              <th key={title} className="px-3 py-1 font-medium uppercase text-[10px]">
                {title}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.length === 0 && (
            <tr>
              <td colSpan={columns.length} className="px-3 py-3 text-ide-textDim">
                本站尚未定义外部变量；它们来自图形组态的输入/输出口
              </td>
            </tr>
          )}
          {rows.map((row) => (
            <tr
              key={row.name}
              onClick={() => onSelectVar(row.name)}
              className="border-b border-ide-border/50 hover:bg-ide-hover cursor-pointer"
            >
              <td className="px-3 py-1 font-mono text-ide-text">{row.name}</td>
              <td className="px-3 py-1">{row.direction === "input" ? "输入" : "输出"}</td>
              <td className="px-3 py-1 font-mono">
                {row.st_type}
                {row.has_quality && <span className="ml-1 text-yellow-400">+Q</span>}
              </td>
              <td className="px-3 py-1">
                <span
                  className="px-1 rounded font-mono"
                  style={{ color: KIND_COLOR[row.io_kind] ?? "#9ca3af" }}
                >
                  {row.io_kind}
                </span>
                <span className="ml-1 text-ide-textDim">{row.module_id ?? ""}</span>
              </td>
              <td className="px-3 py-1 font-mono">
                {row.mapped ? row.channel : <span className="text-yellow-400">未映射</span>}
              </td>
              <td className="px-3 py-1 font-mono text-ide-textDim">{row.point_name || "—"}</td>
              <td className="px-3 py-1 text-ide-textDim">{row.unit || "—"}</td>
              <td className="px-3 py-1">{row.has_quality ? "是" : "否"}</td>
              <td className="px-3 py-1 font-mono">{range(row)}</td>
              <td className="px-3 py-1">
                {HOLD_LABELS[row.fault_hold] ?? "未配置"}
                {row.fault_hold === "preset" && (
                  <span className="ml-1 font-mono text-ide-textDim">= {row.preset_value}</span>
                )}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
