import { useEffect, useState } from "react";
import {
  HOLD_LABELS,
  IO_KIND_LABEL,
  KIND_COLOR,
  SIGNAL_TYPE_LABELS,
  SIGNAL_TYPES,
  issueTitle,
  severityLabel,
  type BindingPayload,
  type ExternalVarRow,
  type ValidationIssue,
} from "./types";
import { useI18n } from "../../lib/i18n";

interface BindingPropertiesProps {
  row: ExternalVarRow | null;
  issues: ValidationIssue[];
  onSave: (binding: BindingPayload) => void;
}

interface FormState {
  scale: string;
  bias: string;
  safetyMin: string;
  safetyMax: string;
  pointName: string;
  unit: string;
  hasQuality: boolean;
  faultHold: string;
  presetValue: string;
  signalType: string;
}

const EMPTY: FormState = {
  scale: "1",
  bias: "0",
  safetyMin: "",
  safetyMax: "",
  pointName: "",
  unit: "",
  hasQuality: false,
  faultHold: "",
  presetValue: "",
  signalType: "",
};

function fromRow(row: ExternalVarRow): FormState {
  return {
    scale: String(row.scale),
    bias: String(row.bias),
    safetyMin: row.safety_min === null ? "" : String(row.safety_min),
    safetyMax: row.safety_max === null ? "" : String(row.safety_max),
    pointName: row.point_name ?? "",
    unit: row.unit ?? "",
    hasQuality: row.has_quality ?? false,
    faultHold: row.fault_hold ?? "",
    presetValue: row.preset_value === null ? "" : String(row.preset_value),
    signalType: row.signal_type ?? "",
  };
}

function toNumberOrNull(value: string): number | null {
  if (value.trim() === "") return null;
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}

export function BindingProperties({ row, issues, onSave }: BindingPropertiesProps) {
  const { t } = useI18n();
  const [form, setForm] = useState<FormState>(row ? fromRow(row) : EMPTY);

  useEffect(() => {
    setForm(row ? fromRow(row) : EMPTY);
  }, [row]);

  const related = row ? issues.filter((i) => i.var_name === row.name) : [];

  return (
    <div className="w-72 bg-ide-sidebar border-l border-ide-border flex flex-col overflow-hidden">
      <div className="px-3 py-2 border-b border-ide-border">
        <div className="text-xs font-semibold uppercase text-ide-textDim">{t("binding.title")}</div>
      </div>

      {row ? (
        <div className="p-3 space-y-3 overflow-y-auto">
          <div>
            <div className="text-[10px] uppercase text-ide-textDim mb-1">{t("binding.point")}</div>
            <div className="text-sm font-mono bg-ide-bg border border-ide-border rounded px-2 py-1">
              {row.name}
            </div>
            <div className="text-[10px] text-ide-textDim mt-1">
              <span
                className="px-1 rounded font-mono"
                style={{ color: KIND_COLOR[row.io_kind] ?? "rgb(var(--ide-text-dim))" }}
              >
                {row.module_id ?? "—"} {row.io_kind}
              </span>{" "}
              {IO_KIND_LABEL[row.io_kind] ?? ""} · CH{row.channel ?? "—"} · {row.st_type}
            </div>
          </div>

          <div>
            <label className="text-[10px] uppercase text-ide-textDim block mb-1">{t("binding.signalType")}</label>
            <select
              value={form.signalType}
              onChange={(e) => setForm({ ...form, signalType: e.target.value })}
              className="w-full bg-ide-bg border border-ide-border rounded px-2 py-1 text-xs"
            >
              {SIGNAL_TYPES.map((type) => (
                <option key={type} value={type}>
                  {SIGNAL_TYPE_LABELS[type] ?? type}
                </option>
              ))}
            </select>
          </div>

          <div className="grid grid-cols-2 gap-2">
            <div>
              <label className="text-[10px] uppercase text-ide-textDim block mb-1">{t("binding.scale")}</label>
              <input
                value={form.scale}
                onChange={(e) => setForm({ ...form, scale: e.target.value })}
                className="w-full bg-ide-bg border border-ide-border rounded px-2 py-1 text-xs font-mono"
              />
            </div>
            <div>
              <label className="text-[10px] uppercase text-ide-textDim block mb-1">{t("binding.bias")}</label>
              <input
                value={form.bias}
                onChange={(e) => setForm({ ...form, bias: e.target.value })}
                className="w-full bg-ide-bg border border-ide-border rounded px-2 py-1 text-xs font-mono"
              />
            </div>
          </div>

          <div className="grid grid-cols-2 gap-2">
            <div>
              <label className="text-[10px] uppercase text-ide-textDim block mb-1">{t("binding.safetyMin")}</label>
              <input
                type="number"
                value={form.safetyMin}
                placeholder={t("binding.unlimited")}
                onChange={(e) => setForm({ ...form, safetyMin: e.target.value })}
                className="w-full bg-ide-bg border border-ide-border rounded px-2 py-1 text-xs font-mono"
              />
            </div>
            <div>
              <label className="text-[10px] uppercase text-ide-textDim block mb-1">{t("binding.safetyMax")}</label>
              <input
                type="number"
                value={form.safetyMax}
                placeholder={t("binding.unlimited")}
                onChange={(e) => setForm({ ...form, safetyMax: e.target.value })}
                className="w-full bg-ide-bg border border-ide-border rounded px-2 py-1 text-xs font-mono"
              />
            </div>
          </div>

          <div className="grid grid-cols-2 gap-2">
            <div>
              <label className="text-[10px] uppercase text-ide-textDim block mb-1">{t("binding.pointName")}</label>
              <input
                value={form.pointName}
                placeholder="PV-001"
                onChange={(e) => setForm({ ...form, pointName: e.target.value })}
                className="w-full bg-ide-bg border border-ide-border rounded px-2 py-1 text-xs font-mono"
              />
            </div>
            <div>
              <label className="text-[10px] uppercase text-ide-textDim block mb-1">{t("binding.unit")}</label>
              <input
                value={form.unit}
                placeholder="%"
                onChange={(e) => setForm({ ...form, unit: e.target.value })}
                className="w-full bg-ide-bg border border-ide-border rounded px-2 py-1 text-xs font-mono"
              />
            </div>
          </div>

          <div>
            <label className="text-[10px] uppercase text-ide-textDim block mb-1">{t("binding.faultHold")}</label>
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
                placeholder={t("binding.preset")}
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
            <span>{t("binding.hasQuality")}</span>
          </label>

          <button
            onClick={() =>
              onSave({
                var_name: row.name,
                channel: row.channel ?? 0,
                scale: Number(form.scale),
                bias: Number(form.bias),
                safety_min: toNumberOrNull(form.safetyMin),
                safety_max: toNumberOrNull(form.safetyMax),
                point_name: form.pointName,
                unit: form.unit,
                has_quality: form.hasQuality,
                fault_hold: form.faultHold,
                preset_value: toNumberOrNull(form.presetValue),
                signal_type: form.signalType,
              })
            }
            data-testid="binding-save"
            className="w-full px-3 py-1.5 bg-ide-accent text-white text-xs rounded hover:bg-blue-600 transition-colors"
          >
            {t("binding.saveConfig")}
          </button>

          {related.length > 0 && (
            <div className="border-t border-ide-border pt-2 space-y-1">
              {related.map((issue, idx) => (
                <div
                  key={idx}
                  className={`text-[10px] leading-snug ${
                    issue.severity === "error" ? "text-red-400" : "text-yellow-400"
                  }`}
                >
                  {issueTitle(issue)}：{issue.message}
                </div>
              ))}
            </div>
          )}
        </div>
      ) : (
        <div className="flex-1 flex items-center justify-center text-ide-textDim text-xs px-4 text-center">
          {t("binding.selectPoint")}
        </div>
      )}

      <div className="border-t border-ide-border">
        <div className="px-3 py-2 text-xs font-semibold uppercase text-ide-textDim">{t("binding.validation")}</div>
        <div className="max-h-40 overflow-y-auto px-3 pb-3 space-y-1">
          {issues.length === 0 && (
            <div className="text-[10px] text-green-400">{t("binding.allPassed")}</div>
          )}
          {issues.map((issue, idx) => (
            <div
              key={idx}
              className={`text-[10px] leading-snug ${
                issue.severity === "error" ? "text-red-400" : "text-yellow-400"
              }`}
            >
              <span className="font-mono opacity-70">{severityLabel(issue.severity)}</span>{" "}
              {issueTitle(issue)}：{issue.message}
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}
