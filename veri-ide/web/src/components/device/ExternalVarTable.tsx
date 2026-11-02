import { useState } from "react";
import { HOLD_LABELS, IO_KIND_LABEL, KIND_COLOR, type BindingPayload, type ExternalVarRow } from "./types";
import { useI18n } from "../../lib/i18n";

interface ExternalVarTableProps {
  rows: ExternalVarRow[];
  errorByVar: Record<string, string>;
  selectedVar: string | null;
  onSelectVar: (name: string) => void;
  /** Gray the row out and unselect the channel in the hardware tree. */
  onToggleEnabled?: (name: string, enabled: boolean) => void;
  onDelete?: (name: string) => void;
  /** Save one edited cell; the binding always goes back as a whole. */
  onEdit?: (row: ExternalVarRow, patch: Partial<BindingPayload>) => void;
}

type EditableField = "point_name" | "unit";

function range(row: ExternalVarRow): string {
  if (row.safety_min === null && row.safety_max === null) return "—";
  const fmt = (value: number | null) => (value === null ? "−∞" : String(value));
  return `${fmt(row.safety_min)} … ${fmt(row.safety_max)}`;
}

export function ExternalVarTable({
  rows,
  errorByVar,
  selectedVar,
  onSelectVar,
  onToggleEnabled,
  onDelete,
  onEdit,
}: ExternalVarTableProps) {
  const { t } = useI18n();
  const [editing, setEditing] = useState<{ name: string; field: EditableField } | null>(null);
  const [draft, setDraft] = useState("");

  const COLUMNS = [
    t("extVar.enabled"),
    t("extVar.pointName"),
    t("extVar.module"),
    t("extVar.channel"),
    t("extVar.directionType"),
    t("extVar.pointNameCol"),
    t("extVar.unit"),
    t("extVar.scaleBias"),
    t("extVar.quality"),
    t("extVar.range"),
    t("extVar.faultHold"),
    t("extVar.actions"),
  ];

  const commit = (row: ExternalVarRow, field: EditableField) => {
    onEdit?.(row, { [field]: draft.trim() });
    setEditing(null);
  };

  return (
    <div className="flex-1 overflow-auto">
      <table className="w-full text-[11px]">
        <thead className="sticky top-0 bg-ide-sidebar text-ide-textDim">
          <tr className="text-left">
            {COLUMNS.map((title) => (
              <th key={title} className="px-3 py-2 font-medium uppercase text-[10px]">
                {title}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.length === 0 && (
            <tr>
              <td colSpan={COLUMNS.length} className="px-3 py-8 text-center text-ide-textDim">
                {t("extVar.noPoints")}
              </td>
            </tr>
          )}
          {rows.map((row) => {
            const isEditing = editing?.name === row.name;
            return (
              <tr
                key={row.name}
                onClick={() => onSelectVar(row.name)}
                className={`border-t border-ide-border/60 cursor-pointer ${
                  selectedVar === row.name ? "bg-ide-selected" : "hover:bg-ide-hover"
                } ${row.enabled ? "" : "opacity-40"}`}
              >
                <td className="px-3 py-1.5">
                  <span
                    role="checkbox"
                    aria-checked={row.enabled}
                    aria-label={`${row.name} ${t("extVar.enabled")}`}
                    data-testid={`var-enabled-${row.name}`}
                    onClick={(event) => {
                      event.stopPropagation();
                      onToggleEnabled?.(row.name, !row.enabled);
                    }}
                    title={row.enabled ? t("extVar.disablePoint") : t("extVar.enablePoint")}
                    className={`inline-flex w-3 h-3 rounded-sm border items-center justify-center ${
                      onToggleEnabled ? "cursor-pointer" : "cursor-default"
                    } ${row.enabled ? "bg-emerald-500 border-emerald-500" : "border-ide-textDim"}`}
                  >
                    {row.enabled && (
                      <svg
                        viewBox="0 0 24 24"
                        className="w-2.5 h-2.5 text-white"
                        fill="none"
                        stroke="currentColor"
                        strokeWidth="3"
                      >
                        <path d="M5 13l4 4L19 7" />
                      </svg>
                    )}
                  </span>
                </td>
                <td className="px-3 py-1.5">
                  <span className="font-mono text-ide-text">{row.name}</span>
                  {errorByVar[row.name] && (
                    <span className="ml-1 text-red-400" title={errorByVar[row.name]}>
                      ⚠
                    </span>
                  )}
                </td>
                <td className="px-3 py-1.5">
                  <span
                    className="px-1 rounded font-mono"
                    style={{ color: KIND_COLOR[row.io_kind] ?? "rgb(var(--ide-text-dim))" }}
                    title={IO_KIND_LABEL[row.io_kind] ?? ""}
                  >
                    {row.module_id ?? row.io_kind}
                  </span>
                </td>
                <td className="px-3 py-1.5 font-mono">
                  {row.mapped ? `CH${row.channel}` : <span className="text-yellow-400">{t("extVar.emptyChannel")}</span>}
                </td>
                {/* Direction and data type are properties of the module, not of the point. */}
                <td className="px-3 py-1.5 text-ide-textDim">
                  {row.direction === "input" ? t("extVar.input") : t("extVar.output")}{" "}
                  <span className="font-mono">{row.st_type}</span>
                  {row.has_quality && <span className="ml-1 text-yellow-400">+Q</span>}
                </td>
                <td className="px-3 py-1.5 font-mono text-ide-textDim">
                  {isEditing && editing.field === "point_name" ? (
                    <input
                      value={draft}
                      autoFocus
                      onClick={(event) => event.stopPropagation()}
                      onChange={(event) => setDraft(event.target.value)}
                      onBlur={() => commit(row, "point_name")}
                      onKeyDown={(event) => {
                        if (event.key === "Enter") commit(row, "point_name");
                        if (event.key === "Escape") setEditing(null);
                      }}
                      data-testid={`point-name-${row.name}`}
                      className="w-24 bg-ide-bg border border-ide-border rounded px-1 py-0.5 font-mono min-w-0"
                    />
                  ) : (
                    <span
                      title={t("extVar.edit")}
                      onDoubleClick={(event) => {
                        event.stopPropagation();
                        setEditing({ name: row.name, field: "point_name" });
                        setDraft(row.point_name);
                      }}
                      className="cursor-text"
                    >
                      {row.point_name || "—"}
                    </span>
                  )}
                </td>
                <td className="px-3 py-1.5 text-ide-textDim">
                  {isEditing && editing.field === "unit" ? (
                    <input
                      value={draft}
                      autoFocus
                      onClick={(event) => event.stopPropagation()}
                      onChange={(event) => setDraft(event.target.value)}
                      onBlur={() => commit(row, "unit")}
                      onKeyDown={(event) => {
                        if (event.key === "Enter") commit(row, "unit");
                        if (event.key === "Escape") setEditing(null);
                      }}
                      data-testid={`point-unit-${row.name}`}
                      className="w-14 bg-ide-bg border border-ide-border rounded px-1 py-0.5 font-mono min-w-0"
                    />
                  ) : (
                    <span
                      title={t("extVar.edit")}
                      onDoubleClick={(event) => {
                        event.stopPropagation();
                        setEditing({ name: row.name, field: "unit" });
                        setDraft(row.unit);
                      }}
                      className="cursor-text"
                    >
                      {row.unit || "—"}
                    </span>
                  )}
                </td>
                <td className="px-3 py-1.5 font-mono text-ide-textDim">
                  {row.scale} / {row.bias}
                </td>
                <td className="px-3 py-1.5">{row.has_quality ? t("extVar.yes") : t("extVar.no")}</td>
                <td className="px-3 py-1.5 font-mono">{range(row)}</td>
                <td className="px-3 py-1.5">
                  {HOLD_LABELS[row.fault_hold] ?? t("extVar.notConfigured")}
                  {row.fault_hold === "preset" && (
                    <span className="ml-1 font-mono text-ide-textDim">= {row.preset_value}</span>
                  )}
                  {!row.enabled && <span className="ml-1 text-ide-textDim">{t("extVar.disabled")}</span>}
                </td>
                <td className="px-3 py-1.5">
                  <button
                    onClick={(event) => {
                      event.stopPropagation();
                      onDelete?.(row.name);
                    }}
                    data-testid={`var-delete-${row.name}`}
                    disabled={!onDelete}
                    className="text-[10px] text-red-300 hover:text-red-200 disabled:opacity-40"
                    title={t("extVar.deleteHint")}
                  >
                    {t("common.delete")}
                  </button>
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}
