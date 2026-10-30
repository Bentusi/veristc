import { useMemo, useState } from "react";
import { KIND_COLOR, type IoVariable, type MappingRow } from "./types";

interface MappingTableProps {
  rows: MappingRow[];
  variables: IoVariable[];
  freeByKind: Record<string, number[]>;
  errorByVar: Record<string, string>;
  selectedVar: string | null;
  onSelectVar: (varName: string | null) => void;
  onBind: (varName: string, channel: number) => void;
  onUnbind: (varName: string) => void;
}

export function MappingTable({
  rows,
  variables,
  freeByKind,
  errorByVar,
  selectedVar,
  onSelectVar,
  onBind,
  onUnbind,
}: MappingTableProps) {
  const boundNames = new Set(rows.map((r) => r.var_name));
  const unbound = variables.filter((v) => !boundNames.has(v.name));

  const [pendingVar, setPendingVar] = useState<string>("");
  const [pendingChannel, setPendingChannel] = useState<string>("");

  const target = useMemo(
    () => unbound.find((v) => v.name === pendingVar) ?? null,
    [unbound, pendingVar],
  );
  const candidates = target ? freeByKind[target.io_kind] ?? [] : [];

  const canBind = target !== null && candidates.length > 0;

  const submit = () => {
    if (!canBind) return;
    onBind(target.name, Number(pendingChannel));
    setPendingVar("");
    setPendingChannel("");
  };

  return (
    <div className="flex-1 flex flex-col overflow-hidden bg-ide-bg">
      {/* New binding row */}
      <div className="px-4 py-3 border-b border-ide-border bg-ide-sidebar flex items-end gap-3">
        <div className="flex flex-col gap-1">
          <label className="text-[10px] uppercase text-ide-textDim">组态 I/O 口（未绑定）</label>
          <select
            value={pendingVar}
            onChange={(e) => {
              setPendingVar(e.target.value);
              setPendingChannel("");
            }}
            className="bg-ide-bg border border-ide-border rounded px-2 py-1.5 text-xs min-w-44"
          >
            <option value="">选择输入/输出口…</option>
            {unbound.map((v) => (
              <option key={v.name} value={v.name}>
                {v.name} · {v.direction} {v.st_type} → {v.io_kind}
              </option>
            ))}
          </select>
        </div>

        <div className="flex flex-col gap-1">
          <label className="text-[10px] uppercase text-ide-textDim">硬件通道</label>
          <select
            value={pendingChannel}
            onChange={(e) => setPendingChannel(e.target.value)}
            disabled={candidates.length === 0}
            className="bg-ide-bg border border-ide-border rounded px-2 py-1.5 text-xs min-w-32 disabled:opacity-40"
          >
            <option value="">{candidates.length === 0 ? "无空闲同类通道" : "选择通道…"}</option>
            {candidates.map((c) => (
              <option key={c} value={c}>
                CH{c}
              </option>
            ))}
          </select>
        </div>

        <button
          onClick={submit}
          disabled={!canBind || pendingChannel === ""}
          className="px-3 py-1.5 bg-ide-accent text-white text-xs rounded hover:bg-blue-600 transition-colors disabled:opacity-40 disabled:cursor-not-allowed"
        >
          建立映射
        </button>

        <div className="flex-1" />
        <div className="text-[10px] text-ide-textDim max-w-56 text-right">
          模块类型由方向 + 数据类型推导，只列出同类通道
        </div>
      </div>

      {/* Binding table */}
      <div className="flex-1 overflow-y-auto">
        <table className="w-full text-xs">
          <thead className="sticky top-0 bg-ide-sidebar text-ide-textDim">
            <tr className="text-left">
              <th className="px-4 py-2 font-medium">组态 I/O 口</th>
              <th className="px-2 py-2 font-medium">方向</th>
              <th className="px-2 py-2 font-medium">类型</th>
              <th className="px-2 py-2 font-medium">推导</th>
              <th className="px-2 py-2 font-medium">硬件通道</th>
              <th className="px-2 py-2 font-medium">模块</th>
              <th className="px-2 py-2 font-medium">量程 / 偏置</th>
              <th className="px-2 py-2 font-medium">状态</th>
              <th className="px-2 py-2" />
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => (
              <tr
                key={row.var_name}
                onClick={() => onSelectVar(row.var_name)}
                className={`border-t border-ide-border cursor-pointer ${
                  selectedVar === row.var_name ? "bg-ide-selected" : "hover:bg-ide-hover"
                }`}
              >
                <td className="px-4 py-2 font-mono">{row.var_name}</td>
                <td className="px-2 py-2 text-ide-textDim">{row.direction ?? "?"}</td>
                <td className="px-2 py-2 font-mono text-ide-textDim">{row.st_type ?? "?"}</td>
                <td className="px-2 py-2">
                  <span
                    className="px-1.5 py-0.5 rounded text-[10px] font-mono"
                    style={{
                      color: KIND_COLOR[row.derived_kind ?? ""] ?? "#9ca3af",
                      border: `1px solid ${KIND_COLOR[row.derived_kind ?? ""] ?? "#9ca3af"}`,
                    }}
                  >
                    {row.derived_kind ?? "?"}
                  </span>
                </td>
                <td className="px-2 py-2 font-mono">CH{row.channel}</td>
                <td className="px-2 py-2">
                  <span className="text-ide-textDim">
                    {row.module_id ?? "无模块"}
                    {row.module_kind ? ` (${row.module_kind})` : ""}
                  </span>
                </td>
                <td className="px-2 py-2 font-mono text-ide-textDim">
                  {row.scale} / {row.bias}
                </td>
                <td className="px-2 py-2">
                  {errorByVar[row.var_name] ? (
                    <span className="text-red-400">错误</span>
                  ) : row.kind_match ? (
                    <span className="text-green-400">匹配</span>
                  ) : (
                    <span className="text-yellow-400">未校验</span>
                  )}
                </td>
                <td className="px-2 py-2 text-right">
                  <button
                    onClick={(e) => {
                      e.stopPropagation();
                      onUnbind(row.var_name);
                    }}
                    className="text-ide-textDim hover:text-red-400 transition-colors"
                    title="解除映射"
                  >
                    解绑
                  </button>
                </td>
              </tr>
            ))}
            {rows.length === 0 && (
              <tr>
                <td colSpan={9} className="px-4 py-8 text-center text-ide-textDim">
                  尚无通道映射，请在上方选择组态 I/O 口与硬件通道
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}
