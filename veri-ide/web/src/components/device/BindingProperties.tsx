import { useEffect, useState } from "react";
import {
  HOLD_LABELS,
  KIND_COLOR,
  type BindingPayload,
  type MappingRow,
  type ValidationIssue,
} from "./types";

interface BindingPropertiesProps {
  row: MappingRow | null;
  issues: ValidationIssue[];
  onSave: (binding: BindingPayload) => void;
}

interface FormState {
  channel: string;
  scale: string;
  bias: string;
  safetyMin: string;
  safetyMax: string;
  pointName: string;
  unit: string;
  hasQuality: boolean;
  faultHold: string;
  presetValue: string;
}

const EMPTY: FormState = {
  channel: "",
  scale: "1",
  bias: "0",
  safetyMin: "",
  safetyMax: "",
  pointName: "",
  unit: "",
  hasQuality: false,
  faultHold: "",
  presetValue: "",
};

function fromRow(row: MappingRow): FormState {
  return {
    channel: String(row.channel),
    scale: String(row.scale),
    bias: String(row.bias),
    safetyMin: row.safety_min === null ? "" : String(row.safety_min),
    safetyMax: row.safety_max === null ? "" : String(row.safety_max),
    pointName: row.point_name ?? "",
    unit: row.unit ?? "",
    hasQuality: row.has_quality ?? false,
    faultHold: row.fault_hold ?? "",
    presetValue: row.preset_value === null ? "" : String(row.preset_value),
  };
}

function toNumberOrNull(value: string): number | null {
  if (value.trim() === "") return null;
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}

export function BindingProperties({ row, issues, onSave }: BindingPropertiesProps) {
  const [form, setForm] = useState<FormState>(row ? fromRow(row) : EMPTY);

  useEffect(() => {
    setForm(row ? fromRow(row) : EMPTY);
  }, [row]);

  const related = row ? issues.filter((i) => i.var_name === row.var_name) : [];

  return (
    <div className="w-72 bg-ide-sidebar border-l border-ide-border flex flex-col overflow-hidden">
      <div className="px-3 py-2 border-b border-ide-border">
        <div className="text-xs font-semibold uppercase text-ide-textDim">绑定属性</div>
      </div>

      {row ? (
        <div className="p-3 space-y-3 overflow-y-auto">
          <div>
            <div className="text-[10px] uppercase text-ide-textDim mb-1">组态 I/O 口</div>
            <div className="text-sm font-mono bg-ide-bg border border-ide-border rounded px-2 py-1">
              {row.var_name}
            </div>
            <div className="text-[10px] text-ide-textDim mt-1">
              {row.direction} {row.st_type} → 推导 {row.derived_kind}
              <span
                className="ml-1 px-1 rounded font-mono"
                style={{ color: KIND_COLOR[row.module_kind ?? ""] ?? "#9ca3af" }}
              >
                {row.module_id ?? "—"} {row.module_kind ?? ""}
              </span>
            </div>
          </div>

          <div>
            <label className="text-[10px] uppercase text-ide-textDim block mb-1">硬件通道</label>
            <input
              type="number"
              min={0}
              max={63}
              value={form.channel}
              onChange={(e) => setForm({ ...form, channel: e.target.value })}
              className="w-full bg-ide-bg border border-ide-border rounded px-2 py-1 text-xs font-mono"
            />
          </div>

          <div className="grid grid-cols-2 gap-2">
            <div>
              <label className="text-[10px] uppercase text-ide-textDim block mb-1">量程系数</label>
              <input
                value={form.scale}
                onChange={(e) => setForm({ ...form, scale: e.target.value })}
                className="w-full bg-ide-bg border border-ide-border rounded px-2 py-1 text-xs font-mono"
              />
            </div>
            <div>
              <label className="text-[10px] uppercase text-ide-textDim block mb-1">偏置</label>
              <input
                value={form.bias}
                onChange={(e) => setForm({ ...form, bias: e.target.value })}
                className="w-full bg-ide-bg border border-ide-border rounded px-2 py-1 text-xs font-mono"
              />
            </div>
          </div>

          <div className="grid grid-cols-2 gap-2">
            <div>
              <label className="text-[10px] uppercase text-ide-textDim block mb-1">安全下限</label>
              <input
                type="number"
                value={form.safetyMin}
                placeholder="不限"
                onChange={(e) => setForm({ ...form, safetyMin: e.target.value })}
                className="w-full bg-ide-bg border border-ide-border rounded px-2 py-1 text-xs font-mono"
              />
            </div>
            <div>
              <label className="text-[10px] uppercase text-ide-textDim block mb-1">安全上限</label>
              <input
                type="number"
                value={form.safetyMax}
                placeholder="不限"
                onChange={(e) => setForm({ ...form, safetyMax: e.target.value })}
                className="w-full bg-ide-bg border border-ide-border rounded px-2 py-1 text-xs font-mono"
              />
            </div>
          </div>

          <div className="grid grid-cols-2 gap-2">
            <div>
              <label className="text-[10px] uppercase text-ide-textDim block mb-1">点名称</label>
              <input
                value={form.pointName}
                placeholder="PV-001"
                onChange={(e) => setForm({ ...form, pointName: e.target.value })}
                className="w-full bg-ide-bg border border-ide-border rounded px-2 py-1 text-xs font-mono"
              />
            </div>
            <div>
              <label className="text-[10px] uppercase text-ide-textDim block mb-1">工程单位</label>
              <input
                value={form.unit}
                placeholder="%"
                onChange={(e) => setForm({ ...form, unit: e.target.value })}
                className="w-full bg-ide-bg border border-ide-border rounded px-2 py-1 text-xs font-mono"
              />
            </div>
          </div>

          <div>
            <label className="text-[10px] uppercase text-ide-textDim block mb-1">异常后保持</label>
            <div className="flex gap-1.5">
              <select
                value={form.faultHold}
                onChange={(e) => setForm({ ...form, faultHold: e.target.value })}
                className="flex-1 bg-ide-bg border border-ide-border rounded px-2 py-1 text-xs"
              >
                {Object.entries(HOLD_LABELS).map(([value, title]) => (
                  <option key={value} value={value}>
                    {title}
                  </option>
                ))}
              </select>
              <input
                type="number"
                value={form.presetValue}
                disabled={form.faultHold !== "preset"}
                placeholder="预设值"
                onChange={(e) => setForm({ ...form, presetValue: e.target.value })}
                className="w-20 bg-ide-bg border border-ide-border rounded px-2 py-1 text-xs font-mono disabled:opacity-40"
              />
            </div>
          </div>

          <label className="flex items-center gap-2 text-xs cursor-pointer">
            <input
              type="checkbox"
              checked={form.hasQuality}
              onChange={(e) => setForm({ ...form, hasQuality: e.target.checked })}
              className="accent-ide-accent"
            />
            <span>通道含质量位</span>
          </label>

          <button
            onClick={() =>
              onSave({
                var_name: row.var_name,
                channel: Number(form.channel),
                scale: Number(form.scale),
                bias: Number(form.bias),
                safety_min: toNumberOrNull(form.safetyMin),
                safety_max: toNumberOrNull(form.safetyMax),
                point_name: form.pointName,
                unit: form.unit,
                has_quality: form.hasQuality,
                fault_hold: form.faultHold,
                preset_value: toNumberOrNull(form.presetValue),
              })
            }
            className="w-full px-3 py-1.5 bg-ide-accent text-white text-xs rounded hover:bg-blue-600 transition-colors"
          >
            保存绑定
          </button>

          <div className="text-[10px] leading-relaxed text-ide-textDim border-t border-ide-border pt-2">
            量程/偏置/单位/质量位/异常保持随 <code>iomap/&lt;站&gt;.toml</code> 存档，供仿真与在线监视使用；
            段 3 只有通道、方向、类型、位宽与幅值限制，量程当前发射恒等值 1.0 / 0.0，质量位与异常保持
            <span className="text-yellow-400">没有字节级承载</span>（见 <code>spec/safeasm-spec.md</code> §4.4 悬空项）。
          </div>

          {related.length > 0 && (
            <div className="border-t border-ide-border pt-2 space-y-1">
              {related.map((issue, idx) => (
                <div
                  key={idx}
                  className={`text-[10px] leading-snug ${
                    issue.severity === "error" ? "text-red-400" : "text-yellow-400"
                  }`}
                >
                  [{issue.code}] {issue.message}
                </div>
              ))}
            </div>
          )}
        </div>
      ) : (
        <div className="flex-1 flex items-center justify-center text-ide-textDim text-xs px-4 text-center">
          选择映射行以查看和编辑绑定属性
        </div>
      )}

      <div className="border-t border-ide-border">
        <div className="px-3 py-2 text-xs font-semibold uppercase text-ide-textDim">校验结果</div>
        <div className="max-h-40 overflow-y-auto px-3 pb-3 space-y-1">
          {issues.length === 0 && (
            <div className="text-[10px] text-green-400">全部通过，可生成 IOMAP 段</div>
          )}
          {issues.map((issue, idx) => (
            <div
              key={idx}
              className={`text-[10px] leading-snug ${
                issue.severity === "error" ? "text-red-400" : "text-yellow-400"
              }`}
            >
              <span className="font-mono opacity-70">{issue.severity}</span> [{issue.code}]{" "}
              {issue.message}
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}
