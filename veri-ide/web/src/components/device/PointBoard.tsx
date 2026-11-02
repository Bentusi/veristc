import { useEffect, useMemo, useRef, useState, type MouseEvent } from "react";
import { ContextMenu, type ContextMenuItem } from "../ContextMenu";
import {
  HOLD_LABELS,
  IO_KIND_LABEL,
  KIND_COLOR,
  SIGNAL_TYPE_LABELS,
  SIGNAL_TYPES,
  type BindingPayload,
  type ExternalVarRow,
  type ModuleView,
} from "./types";
import { useI18n } from "../../lib/i18n";

export type BatchAction = "enable" | "disable" | "delete";
/** One point's worth of batch field edits, resolved to names before it is sent. */
export interface BatchEdit {
  name: string;
  patch: Partial<BindingPayload>;
}

interface PointBoardProps {
  modules: ModuleView[];
  /** Points keyed by variable name: a module channel owns at most one. */
  byName: Record<string, ExternalVarRow>;
  errorByVar: Record<string, string>;
  selectedVar: string | null;
  onSelectChannel: (channel: number) => void;
  onToggleEnabled: (name: string, enabled: boolean) => void;
  onCreatePoint: (moduleId: string, channel: number) => void;
  onDelete: (name: string) => void;
  /** Save one edited cell; the binding always goes back as a whole. */
  onEdit: (row: ExternalVarRow, patch: Partial<BindingPayload>) => void;
  selected: Set<string>;
  setSelected: (update: (prev: Set<string>) => Set<string>) => void;
  selectionMode: boolean;
  setSelectionMode: (on: boolean) => void;
  onBatch: (names: string[], action: BatchAction) => void;
  /** Field edits applied to every selected point at once. */
  onBatchEdit: (edits: BatchEdit[]) => void;
}

type EditableField = "point_name" | "unit";

type Cell = { kind: "point"; row: ExternalVarRow; channel: number } | { kind: "empty"; channel: number };

interface Lane {
  id: string;
  ioKind: string;
  label: string;
  range: string;
  cells: Cell[];
}

interface MenuState {
  x: number;
  y: number;
  items: ContextMenuItem[];
}

/** `-inf … 1000` reads as a range; nothing set reads as a gap to fill. */
function rangeOf(row: ExternalVarRow): string {
  if (row.safety_min === null && row.safety_max === null) return "";
  const low = row.safety_min === null ? "−∞" : String(row.safety_min);
  const high = row.safety_max === null ? "+∞" : String(row.safety_max);
  return `${low} … ${high}`;
}

/** A blank field means "no limit", so an unfinished input must not become NaN. */
function numberOrNull(value: string | undefined): number | null {
  const text = (value ?? "").trim();
  if (!text) return null;
  const parsed = Number(text);
  return Number.isFinite(parsed) ? parsed : null;
}

/** Hold still on a card to start picking -- the phone gesture this list borrows. */
const LONG_PRESS_MS = 500;

const chip = "px-1 rounded border border-ide-border text-[10px] text-ide-textDim";
const barBtn = "px-2 py-1 rounded border border-ide-border hover:bg-ide-hover disabled:opacity-40 disabled:cursor-not-allowed";

/**
 * Channel cards grouped by hardware module.
 *
 * The module already states direction, data type and channel range, so a card
 * only carries what a person still decides: whether the point is live, its tag
 * name, and which protections are configured. Everything else stays in the
 * properties panel on the right.
 */
export function PointBoard({
  modules,
  byName,
  errorByVar,
  selectedVar,
  onSelectChannel,
  onToggleEnabled,
  onCreatePoint,
  onDelete,
  onEdit,
  selected,
  setSelected,
  selectionMode,
  setSelectionMode,
  onBatch,
  onBatchEdit,
}: PointBoardProps) {
  const { t } = useI18n();
  const [editing, setEditing] = useState<{ name: string; field: EditableField } | null>(null);
  const [draft, setDraft] = useState("");
  const [menu, setMenu] = useState<MenuState | null>(null);
  const hold = useRef<{ timer?: number; fired: boolean }>({ fired: false });

  // A point no module channel points at would have nowhere to show, so it gets
  // its own lane -- nothing configured in the station may go invisible.
  const lanes = useMemo<Lane[]>(() => {
    const covered = new Set<string>();
    const built: Lane[] = modules
      .slice()
      .sort((a, b) => a.first_channel - b.first_channel)
      .map((module) => ({
        id: module.module_id,
        ioKind: module.kind,
        label: IO_KIND_LABEL[module.kind] ?? module.label,
        range: `CH${module.first_channel}–${module.last_channel}`,
        cells: module.channel_list.map((channel) => {
          const row = channel.var_name ? byName[channel.var_name] : undefined;
          if (row) covered.add(row.name);
          return row
            ? { kind: "point" as const, row, channel: channel.channel }
            : { kind: "empty" as const, channel: channel.channel };
        }),
      }));
    const orphans = Object.values(byName).filter((row) => !covered.has(row.name));
    if (orphans.length) {
      built.push({
        id: t("pointBoard.noChannel"),
        ioKind: orphans[0].io_kind ?? "",
        label: t("pointBoard.noChannelDesc"),
        range: `${orphans.length} ${t("pointBoard.point")}`,
        cells: orphans.map((row) => ({ kind: "point" as const, row, channel: row.channel ?? -1 })),
      });
    }
    return built;
  }, [modules, byName, t]);

  /** Lane order is the range-selection order: top-left to bottom-right. */
  const order = useMemo(
    () => lanes.flatMap((lane) => lane.cells.filter((cell) => cell.kind === "point").map((cell) => (cell as { row: ExternalVarRow }).row.name)),
    [lanes],
  );

  useEffect(() => {
    const onKey = (event: globalThis.KeyboardEvent) => {
      const tag = (event.target as HTMLElement | null)?.tagName;
      if (tag === "INPUT" || tag === "TEXTAREA") return;
      if (event.key === "Escape") {
        setSelectionMode(false);
        setSelected(() => new Set());
      }
      if (selectionMode && (event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "a") {
        event.preventDefault();
        setSelected(() => new Set(order));
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [order, selectionMode, setSelected, setSelectionMode]);

  const startEdit = (row: ExternalVarRow, field: EditableField) => {
    setEditing({ name: row.name, field });
    setDraft(String(row[field] ?? ""));
  };

  const commit = (row: ExternalVarRow, field: EditableField) => {
    setEditing(null);
    const next = draft.trim();
    if (next === String(row[field] ?? "")) return;
    onEdit(row, { [field]: next } as Partial<BindingPayload>);
  };

  const openMenu = (event: MouseEvent, row: ExternalVarRow | null, moduleId: string, channel: number) => {
    event.preventDefault();
    const targets = order.filter((name) => selected.has(name));

    // With a live selection the menu stops describing one card and starts
    // describing the group -- same verbs, applied to every picked point.
    if (selectionMode && targets.length > 0) {
      const edits = (build: (name: string, index: number) => Partial<BindingPayload>) =>
        onBatchEdit(targets.map((name, index) => ({ name, patch: build(name, index) })));
      const joinItem: ContextMenuItem[] =
        row && !selected.has(row.name)
          ? [
              {
                label: `${t("pointBoard.addToSelection")} ${row.name} ${t("pointBoard.addToSelection2")}`,
                onClick: () => setSelected((prev) => new Set(prev).add(row.name)),
              },
              { separator: true, label: "" },
            ]
          : [];
      const items: ContextMenuItem[] = [
        { label: `${t("pointBoard.applyToSelected")} ${targets.length} ${t("pointBoard.applyToSelected2")}`, disabled: true },
        ...joinItem,
        { label: t("pointBoard.batchEnable"), onClick: () => onBatch(targets, "enable") },
        { label: t("pointBoard.batchDisable"), onClick: () => onBatch(targets, "disable") },
        { separator: true, label: "" },
        {
          label: t("pointBoard.batchRename"),
          fields: [
            { key: "prefix", label: t("pointBoard.prefix"), placeholder: "PV-" },
            { key: "start", label: t("pointBoard.startIndex"), value: "1" },
          ],
          onSubmit: (values) => {
            const prefix = values.prefix.trim();
            if (!prefix) return;
            const start = Number(values.start) || 1;
            const width = Math.max(2, String(start + targets.length - 1).length);
            edits((_, index) => ({ point_name: `${prefix}${String(start + index).padStart(width, "0")}` }));
          },
        },
        {
          label: t("pointBoard.batchUnit"),
          fields: [{ key: "unit", label: t("binding.unit"), placeholder: "%", value: "" }],
          onSubmit: (values) => edits(() => ({ unit: values.unit.trim() })),
        },
        {
          label: t("pointBoard.batchRange"),
          fields: [
            { key: "low", label: t("pointBoard.safetyMin") },
            { key: "high", label: t("pointBoard.safetyMax") },
          ],
          onSubmit: (values) =>
            edits(() => ({ safety_min: numberOrNull(values.low), safety_max: numberOrNull(values.high) })),
        },
        {
          label: t("pointBoard.batchSignalType"),
          fields: [
            {
              key: "signal_type",
              label: t("binding.signalType"),
              options: SIGNAL_TYPES.map((type) => ({ label: SIGNAL_TYPE_LABELS[type] ?? type, value: type })),
            },
          ],
          onSubmit: (values) => edits(() => ({ signal_type: values.signal_type })),
        },
        {
          label: t("pointBoard.batchFaultHold"),
          fields: [
            {
              key: "fault_hold",
              label: t("binding.faultHold"),
              options: Object.entries(HOLD_LABELS).map(([value, title]) => ({ label: title, value })),
            },
            { key: "preset", label: t("pointBoard.presetValue") },
          ],
          onSubmit: (values) =>
            edits(() => ({
              fault_hold: values.fault_hold,
              preset_value: values.fault_hold === "preset" ? numberOrNull(values.preset) : null,
            })),
        },
        { separator: true, label: "" },
        { label: t("pointBoard.batchDelete"), onClick: () => onBatch(targets, "delete") },
        {
          label: t("pointBoard.deselect"),
          onClick: () => {
            setSelectionMode(false);
            setSelected(() => new Set());
          },
        },
      ];
      setMenu({ x: event.clientX, y: event.clientY, items });
      return;
    }

    const items: ContextMenuItem[] = row
      ? [
          { label: row.enabled ? t("pointBoard.clickDisable") : t("pointBoard.clickEnable"), onClick: () => onToggleEnabled(row.name, !row.enabled) },
          { label: t("pointBoard.editName"), onClick: () => startEdit(row, "point_name") },
          { label: t("common.delete"), onClick: () => onDelete(row.name) },
        ]
      : [{ label: t("pointBoard.createPoint"), onClick: () => onCreatePoint(moduleId, channel) }];
    setMenu({ x: event.clientX, y: event.clientY, items });
  };

  const pressStart = (name: string) => {
    hold.current.fired = false;
    window.clearTimeout(hold.current.timer);
    hold.current.timer = window.setTimeout(() => {
      hold.current.fired = true;
      setSelectionMode(true);
      setSelected((prev) => (prev.size ? new Set(prev).add(name) : new Set([name])));
    }, LONG_PRESS_MS);
  };

  const pressEnd = () => {
    window.clearTimeout(hold.current.timer);
  };

  const pickCard = (name: string, event: MouseEvent) => {
    if (hold.current.fired) {
      hold.current.fired = false;
      return;
    }
    if (!selectionMode) {
      return false; // the caller runs the normal single-select behaviour
    }
    if (event.shiftKey) {
      const last = [...selected].pop();
      const to = order.indexOf(name);
      const from = last ? order.indexOf(last) : to;
      const [start, end] = from <= to ? [from, to] : [to, from];
      setSelected((prev) => {
        const next = new Set(prev);
        order.slice(start, end + 1).forEach((item) => next.add(item));
        return next;
      });
    } else {
      setSelected((prev) => {
        const next = new Set(prev);
        if (next.has(name)) next.delete(name);
        else next.add(name);
        return next;
      });
    }
    return true;
  };

  const names = [...selected];
  const allOn = order.length > 0 && names.length === order.length;

  return (
    <div className="flex-1 flex flex-col min-h-0">
      <div className="px-3 pt-2 flex items-center gap-2 text-[10px] text-ide-textDim">
        {selectionMode ? (
          <span>{t("pointBoard.helpText")}</span>
        ) : (
          <span>{t("pointBoard.helpText2")}</span>
        )}
        <span className="flex-1" />
        {selectionMode ? (
          <button
            onClick={() => {
              setSelectionMode(false);
              setSelected(() => new Set());
            }}
            className="text-ide-textDim hover:text-ide-text"
            data-testid="point-select-exit"
          >
            {t("pointBoard.exitMulti")}
          </button>
        ) : (
          <button
            onClick={() => setSelectionMode(true)}
            className="text-ide-accent hover:underline"
            data-testid="point-select-enter"
          >
            {t("pointBoard.multiSelect")}
          </button>
        )}
      </div>

      <div className="flex-1 overflow-auto px-3 py-2" onContextMenu={(event) => event.preventDefault()}>
        {lanes.length === 0 && (
          <p className="text-xs text-ide-textDim py-6 text-center">
            {t("pointBoard.notConfigured")}
          </p>
        )}

        {lanes.map((lane) => {
          const live = lane.cells.filter((cell) => cell.kind === "point" && cell.row.enabled).length;
          const color = KIND_COLOR[lane.ioKind] ?? "rgb(var(--ide-text-dim))";
          return (
            <div key={lane.id} className="mb-4">
              <div className="flex items-center gap-2 mb-1.5 text-[10px] uppercase tracking-wide text-ide-textDim">
                <span className="px-1 rounded font-mono normal-case" style={{ color, border: `1px solid ${color}` }}>
                  {lane.ioKind || "—"}
                </span>
                <span className="font-mono text-ide-text normal-case">{lane.id}</span>
                <span className="normal-case">{lane.label}</span>
                <span>{lane.range}</span>
                <span>{t("extVar.enabled")} {live}/{lane.cells.length}</span>
                {lane.cells.some((cell) => cell.kind === "point") && (
                  <button
                    onClick={() => {
                      setSelectionMode(true);
                      setSelected((prev) => {
                        const next = new Set(prev);
                        lane.cells.forEach((cell) => (cell.kind === "point" ? next.add(cell.row.name) : null));
                        return next;
                      });
                    }}
                    className="normal-case text-ide-accent hover:underline"
                    title={t("pointBoard.selectAllHint")}
                    data-testid={`lane-all-${lane.id}`}
                  >
                    {t("pointBoard.selectAll")}
                  </button>
                )}
              </div>

              <div className="grid gap-1.5" style={{ gridTemplateColumns: "repeat(auto-fill, minmax(196px, 1fr))" }}>
                {lane.cells.map((cell) => {
                  if (cell.kind === "empty") {
                    return (
                      <button
                        key={cell.channel}
                        onClick={() => onCreatePoint(lane.id, cell.channel)}
                        onContextMenu={(event) => openMenu(event, null, lane.id, cell.channel)}
                        className="text-left px-2 py-1.5 rounded border border-dashed border-ide-border text-[11px] text-ide-textDim hover:border-ide-accent hover:text-ide-text"
                        title={`CH${cell.channel} ${t("pointBoard.idle")}`}
                        data-testid={`point-empty-${cell.channel}`}
                      >
                        CH{cell.channel} {t("pointBoard.idleLabel")}
                        <span className="block text-[10px] opacity-70">{t("pointBoard.createPointLabel")}</span>
                      </button>
                    );
                  }

                  const row = cell.row;
                  const isEditing = editing?.name === row.name;
                  const error = errorByVar[row.name];
                  const hold2 = row.fault_hold ? HOLD_LABELS[row.fault_hold] ?? row.fault_hold : "";
                  const range = rangeOf(row);
                  const picked = selected.has(row.name);

                  return (
                    <div
                      key={row.name}
                      role="button"
                      tabIndex={0}
                      onPointerDown={() => pressStart(row.name)}
                      onPointerUp={pressEnd}
                      onPointerLeave={pressEnd}
                      onPointerCancel={pressEnd}
                      onClick={(event) => {
                        if (pickCard(row.name, event)) return;
                        if (cell.channel >= 0) onSelectChannel(cell.channel);
                      }}
                      onKeyDown={(event) => {
                        if (event.key !== "Enter" && event.key !== " ") return;
                        if (pickCard(row.name, event as unknown as MouseEvent)) return;
                        onSelectChannel(cell.channel);
                      }}
                      onContextMenu={(event) => openMenu(event, row, lane.id, cell.channel)}
                      data-testid={`point-${row.name}`}
                      data-state={row.enabled ? "on" : "off"}
                      data-picked={picked ? "yes" : "no"}
                      className={`relative px-2 py-1.5 rounded border text-[11px] cursor-pointer select-none ${
                        picked
                          ? "border-ide-accent bg-ide-selected"
                          : row.name === selectedVar
                            ? "border-ide-accent bg-ide-selected"
                            : "border-ide-border bg-ide-sidebar hover:bg-ide-hover"
                      } ${row.enabled ? "" : "opacity-45"}`}
                    >
                      <div className="flex items-center gap-1.5">
                        {selectionMode ? (
                          <span
                            aria-hidden="true"
                            className={`w-2.5 h-2.5 shrink-0 rounded border ${
                              picked ? "bg-ide-accent border-ide-accent" : "border-ide-textDim"
                            }`}
                          />
                        ) : (
                          <span
                            role="checkbox"
                            aria-checked={row.enabled}
                            tabIndex={0}
                            title={row.enabled ? t("pointBoard.clickDisable") : t("pointBoard.clickEnable")}
                            onClick={(event) => {
                              event.stopPropagation();
                              onToggleEnabled(row.name, !row.enabled);
                            }}
                            onKeyDown={(event) => {
                              if (event.key !== "Enter" && event.key !== " ") return;
                              event.stopPropagation();
                              onToggleEnabled(row.name, !row.enabled);
                            }}
                            data-testid={`point-enabled-${row.name}`}
                            className={`w-2.5 h-2.5 shrink-0 rounded-full border cursor-pointer ${
                              row.enabled ? "bg-ide-accent border-ide-accent" : "border-ide-textDim"
                            }`}
                          />
                        )}
                        <span className="font-mono flex-1 min-w-0 truncate" title={`${row.name} · ${IO_KIND_LABEL[row.io_kind] ?? ""}`}>
                          {row.name}
                        </span>
                        {error && (
                          <span className="text-red-400 shrink-0" title={error} role="alert">
                            ⚠
                          </span>
                        )}
                        {!row.enabled && <span className={chip}>{t("extVar.disabled")}</span>}
                      </div>

                      {isEditing && editing ? (
                        <input
                          autoFocus
                          value={draft}
                          onChange={(event) => setDraft(event.target.value)}
                          onClick={(event) => event.stopPropagation()}
                          onBlur={() => commit(row, editing.field)}
                          onKeyDown={(event) => {
                            if (event.key === "Enter") commit(row, editing.field);
                            if (event.key === "Escape") setEditing(null);
                          }}
                          className="mt-1 w-full bg-ide-bg border border-ide-accent rounded px-1 py-0.5 text-[11px] font-mono"
                          data-testid={`point-edit-${editing.field}`}
                        />
                      ) : (
                        <div className="mt-0.5 flex items-center gap-1 text-ide-textDim min-w-0">
                          <span
                            className="truncate"
                            title={t("pointBoard.editName")}
                            onDoubleClick={(event) => {
                              event.stopPropagation();
                              startEdit(row, "point_name");
                            }}
                          >
                            {row.point_name || t("pointBoard.fillName")}
                          </span>
                          <span
                            className="shrink-0"
                            title={t("pointBoard.editUnit")}
                            onDoubleClick={(event) => {
                              event.stopPropagation();
                              startEdit(row, "unit");
                            }}
                          >
                            {row.unit || t("pointBoard.unitPlaceholder")}
                          </span>
                        </div>
                      )}

                      <div className="mt-1 flex flex-wrap gap-1">
                        {range ? <span className={chip}>{range}</span> : <span className={`${chip} opacity-60`}>{t("pointBoard.noScale")}</span>}
                        {row.has_quality && <span className={chip}>{t("pointBoard.qualityBadge")}</span>}
                        {hold2 && <span className={chip}>{t("pointBoard.faultBadge")}{hold2}</span>}
                        <span className={chip}>{row.st_type}</span>
                      </div>
                    </div>
                  );
                })}
              </div>
            </div>
          );
        })}

        {menu && <ContextMenu x={menu.x} y={menu.y} items={menu.items} onClose={() => setMenu(null)} />}
      </div>

      {selectionMode && (
        <div
          className="border-t border-ide-border bg-ide-sidebar px-3 py-2 flex items-center gap-1.5 text-[11px]"
          data-testid="point-batch-bar"
          role="toolbar"
          aria-live="polite"
        >
          <span className="text-ide-textDim">{t("pointBoard.selected")} {names.length} {t("pointBoard.point")}</span>
          <button className={barBtn} onClick={() => setSelected(() => new Set(allOn ? [] : order))} data-testid="batch-all">
            {allOn ? t("pointBoard.deselectAll") : t("pointBoard.selectAllBtn")}
          </button>
          <button
            className={barBtn}
            onClick={() =>
              setSelected((prev) => new Set(order.filter((name) => !prev.has(name))))
            }
            data-testid="batch-invert"
          >
            {t("pointBoard.invert")}
          </button>
          <span className="flex-1" />
          <button className={barBtn} disabled={!names.length} onClick={() => onBatch(names, "enable")} data-testid="batch-enable">
            {t("pointBoard.batchEnable")}
          </button>
          <button className={barBtn} disabled={!names.length} onClick={() => onBatch(names, "disable")} data-testid="batch-disable">
            {t("pointBoard.batchDisable")}
          </button>
          <button
            className={`${barBtn} text-red-400 disabled:opacity-40`}
            disabled={!names.length}
            onClick={() => onBatch(names, "delete")}
            data-testid="batch-delete"
          >
            {t("pointBoard.batchDelete")}
          </button>
        </div>
      )}
    </div>
  );
}
