import { useCallback, useEffect, useMemo, useState } from "react";
import { useProject } from "../project/ProjectProvider";
import { HardwareTree } from "../components/device/HardwareTree";
import { BindingProperties } from "../components/device/BindingProperties";
import { ExternalVarTable } from "../components/device/ExternalVarTable";
import { PointBoard, type BatchAction, type BatchEdit } from "../components/device/PointBoard";
import { StationBar, type StationDraft } from "../components/device/StationBar";
import { toast } from "../components/ui";
import { eventBus } from "../lib/eventBus";
import { useEditShortcuts } from "../lib/shortcuts";
import { useI18n } from "../lib/i18n";
import {
  type BindingPayload,
  type ExternalVarRow,
  type ModuleView,
  type StationRow,
  type ValidationIssue,
} from "../components/device/types";

const API = "http://localhost:8000/device";

type PointView = "board" | "table";
const VIEW_KEY = "veride.device.point-view";

/** The board is the default; remembering the choice survives stage switches. */
function initialView(): PointView {
  return window.localStorage.getItem(VIEW_KEY) === "table" ? "table" : "board";
}

async function call<T>(path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(`${API}${path}`, init);
  const text = await response.text();
  if (!response.ok) {
    let detail = text;
    try {
      detail = JSON.parse(text).detail ?? text;
    } catch {
      /* keep the raw body */
    }
    throw new Error(detail || `HTTP ${response.status}`);
  }
  return text ? (JSON.parse(text) as T) : ({} as T);
}

const json = (body: unknown): RequestInit => ({
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify(body),
});

/** Names the graph configuration binds a page pin to -- device-side destructive
 * actions must not silently break those pins, so the page asks before acting. */
async function graphBoundNames(): Promise<Set<string>> {
  try {
    const response = await fetch("http://localhost:8000/graph/bound-variables");
    if (!response.ok) return new Set();
    const rows = (await response.json()) as { variable: string }[];
    return new Set(rows.map((row) => row.variable).filter(Boolean));
  } catch {
    return new Set();
  }
}

export function DevicePage() {
  const [stations, setStations] = useState<StationRow[]>([]);
  const [stationId, setStationId] = useState("");
  const [modules, setModules] = useState<ModuleView[]>([]);
  const [points, setPoints] = useState<ExternalVarRow[]>([]);
  const [issues, setIssues] = useState<ValidationIssue[]>([]);
  const [stPreview, setStPreview] = useState("");
  const [showSt, setShowSt] = useState(false);
  const [selectedVar, setSelectedVar] = useState<string | null>(null);
  const [selectedChannel, setSelectedChannel] = useState<number | null>(null);
  const [view, setView] = useState<PointView>(initialView);
  const [hideDisabled, setHideDisabled] = useState(true);
  const [selected, setSelected] = useState<Set<string>>(() => new Set());
  const [selectionMode, setSelectionMode] = useState(false);
  const [collapsed, setCollapsed] = useState<Record<string, boolean>>({});
  const [offline, setOffline] = useState(false);
  const { current, save: saveProject } = useProject();
  const { t } = useI18n();
  const [newModule, setNewModule] = useState({
    module_id: "",
    kind: "AI",
    first_channel: "0",
    channel_count: "16",
  });

  useEditShortcuts({
    onSave: () => {
      if (!current) {
        toast.warning(t("common.noProject"), t("common.noProjectDesc"));
        return;
      }
      mutate(() => saveProject()).then(() => toast.success(t("common.saved"), current.path));
    },
  });

  const station = stations.find((s) => s.station_id === stationId);

  const refresh = useCallback(
    async (id: string) => {
      if (!id) return;
      try {
        const list = await call<StationRow[]>("/stations");
        const active = list.some((s) => s.station_id === id) ? id : list[0]?.station_id ?? "";
        const hardware = await call<{ modules: ModuleView[] }>(`/stations/${active}/hardware`);
        const rows = await call<ExternalVarRow[]>(`/stations/${active}/external-variables`);
        const check = await call<{ errors: ValidationIssue[]; warnings: ValidationIssue[] }>(
          `/stations/${active}/validate`,
          { method: "POST" },
        );
        const st = await fetch(`${API}/stations/${active}/iomap.st`).then((r) => r.text());

        setStations(list);
        setStationId(active);
        setModules(hardware.modules);
        setPoints(rows);
        setIssues([...check.errors, ...check.warnings]);
        setStPreview(st);
        setOffline(false);
      } catch (error) {
        setOffline(true);
        toast.error(t("home.backendNotReady"), (error as Error).message);
      }
    },
    [t],
  );

  useEffect(() => {
    if (stationId) refresh(stationId);
  }, [stationId, refresh]);

  useEffect(() => {
    call<StationRow[]>("/stations")
      .then((list) => {
        setStations(list);
        if (list.length > 0) setStationId(list[0].station_id);
      })
      .catch((error) => {
        setOffline(true);
        toast.error(t("home.backendNotReady"), (error as Error).message);
      });
  }, [current?.path, t]);

  const suggestedFirstChannel = useMemo(() => {
    if (modules.length === 0) return 0;
    return Math.max(...modules.map((m) => m.last_channel)) + 1;
  }, [modules]);

  useEffect(() => {
    setNewModule((prev) => ({ ...prev, first_channel: String(suggestedFirstChannel) }));
  }, [suggestedFirstChannel]);

  const errorByVar = useMemo(() => {
    const map: Record<string, string> = {};
    for (const issue of issues) {
      if (issue.severity === "error" && issue.var_name) map[issue.var_name] = issue.message;
    }
    return map;
  }, [issues]);

  const pointsByName = useMemo(
    () => Object.fromEntries(points.map((row) => [row.name, row])) as Record<string, ExternalVarRow>,
    [points],
  );

  const visiblePoints = useMemo(
    () => (hideDisabled ? points.filter((r) => r.enabled) : points),
    [points, hideDisabled],
  );

  const visiblePointsByName = useMemo(
    () => Object.fromEntries(visiblePoints.map((row) => [row.name, row])),
    [visiblePoints],
  );

  /** A point that stops existing must not stay in a batch selection. */
  useEffect(() => {
    setSelected((prev) => {
      if (prev.size === 0) return prev;
      const live = new Set(points.map((row) => row.name));
      const next = new Set([...prev].filter((name) => live.has(name)));
      return next.size === prev.size ? prev : next;
    });
  }, [points]);

  const switchView = (next: PointView) => {
    setView(next);
    window.localStorage.setItem(VIEW_KEY, next);
    setSelectionMode(false);
    setSelected(() => new Set());
  };

  const selectedRow = points.find((r) => r.name === selectedVar) ?? null;
  const scoped = (path: string) => `/stations/${stationId}${path}`;
  // The demo station can fill the whole 0-63 space; then only deleting a module
  // makes room, so saying so beats a range error from the backend.
  const spaceFull = suggestedFirstChannel > 63;

  const mutate = async (action: () => Promise<unknown>) => {
    try {
      await action();
    } catch (error) {
      toast.error(t("device.operationFailed"), (error as Error).message);
    } finally {
      await refresh(stationId);
    }
  };

  /** The point table edits one field at a time; the binding always goes back whole. */
  const payloadFor = (row: ExternalVarRow, patch: Partial<BindingPayload>): BindingPayload => ({
    var_name: row.name,
    channel: row.channel ?? 0,
    scale: row.scale,
    bias: row.bias,
    safety_min: row.safety_min,
    safety_max: row.safety_max,
    point_name: row.point_name,
    unit: row.unit,
    has_quality: row.has_quality,
    fault_hold: row.fault_hold,
    preset_value: row.preset_value,
    signal_type: row.signal_type,
    ...patch,
  });

  const onSavePoint = (row: ExternalVarRow, patch: Partial<BindingPayload>) => {
    const payload = payloadFor(row, patch);
    return mutate(() => call(scoped("/mapping"), { ...json(payload), method: "PUT" })).then(() => {
      eventBus.emit("bindings:changed", [{ var_name: payload.var_name, channel: payload.channel }]);
    });
  };

  const onSaveBinding = (binding: BindingPayload) =>
    mutate(() => call(scoped("/mapping"), { ...json(binding), method: "PUT" })).then(() => {
      setSelectedVar(binding.var_name);
      eventBus.emit("bindings:changed", [{ var_name: binding.var_name, channel: binding.channel }]);
    });

  const onSelectChannel = (channel: number) => {
    setSelectedChannel(channel);
    const owner = modules.flatMap((m) => m.channel_list).find((c) => c.channel === channel);
    if (owner?.var_name) setSelectedVar(owner.var_name);
  };

  const onUpdateChannelName = async (moduleId: string, channel: number, name: string) => {
    try {
      await call(scoped(`/modules/${moduleId}/channels/${channel}`), {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ channel, name }),
      });
      await refresh(stationId);
    } catch (error) {
      toast.error(t("device.updateChannelFailed"), (error as Error).message);
    }
  };

  const onAddModuleByKind = async (kind: string) => {
    if (spaceFull) {
      toast.warning(t("device.spaceFull"), t("device.spaceFullMsg"));
      return;
    }
    const existingIds = modules.filter((m) => m.kind === kind).length;
    const moduleId = `${kind}${existingIds + 1}`;

    try {
      await call(scoped("/modules"), {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          module_id: moduleId,
          kind,
          first_channel: suggestedFirstChannel,
          channel_count: 16,
          label: `${kind} ${t("device.module")} ${existingIds + 1}`,
        }),
      });
      await refresh(stationId);
      toast.success(t("device.moduleAdded"), `${moduleId} · ${t("device.moduleAddedMsg")}`);
      eventBus.emit("module:added", { moduleId, kind });
      eventBus.emit("bindings:changed", []);
    } catch (error) {
      toast.error(t("device.addModuleFailed"), (error as Error).message);
    }
  };

  const onRemoveModule = async (moduleId: string) => {
    if (!window.confirm(`${t("device.confirmDeleteModule")} ${moduleId}？${t("device.confirmDeleteModuleMsg")}`)) return;

    try {
      await call(scoped(`/modules/${moduleId}`), { method: "DELETE" });
      await refresh(stationId);
      toast.success(t("device.moduleDeleted"), moduleId);
      eventBus.emit("module:removed", { moduleId });
      eventBus.emit("bindings:changed", []);
    } catch (error) {
      toast.error(t("device.deleteModuleFailed"), (error as Error).message);
    }
  };

  /** A channel only lacks a point when its point was deleted; restore both at once. */
  const onCreatePoint = (moduleId: string, channel: number) =>
    mutate(() =>
      call(scoped(`/modules/${moduleId}/channels/${channel}/point`), json({})),
    ).then(() => toast.success(t("device.pointCreated"), `${moduleId}_CH${channel}`));

  /** Reject a destructive point action when graph config still binds a pin to it. */
  const guardGraphBind = async (name: string, action: string): Promise<boolean> => {
    const bound = await graphBoundNames();
    if (!bound.has(name)) return true;
    toast.warning(
      `${name} ${t("device.boundByGraph")}`,
      `${t("device.unbindFirst")}${action}`,
    );
    return false;
  };

  const onTogglePoint = async (name: string, enabled: boolean) => {
    if (!enabled && !(await guardGraphBind(name, t("device.disable")))) return;
    await mutate(() =>
      call(scoped(`/variables/${encodeURIComponent(name)}/enabled`), {
        ...json({ enabled }),
        method: "PUT",
      }),
    );
    toast.success(enabled ? t("device.pointEnabled") : t("device.pointDisabled"), name);
  };

  const onDeletePoint = async (name: string) => {
    if (!(await guardGraphBind(name, t("device.delete")))) return;
    if (!window.confirm(`${t("device.confirmDeletePoint")} ${name}？${t("device.confirmDeletePointMsg")}`)) return;
    await mutate(() => call(scoped(`/variables/${encodeURIComponent(name)}`), { method: "DELETE" }));
    toast.success(t("device.pointDeleted"), name);
  };

  /** Batch actions work like the single ones, but the station is re-read only
   * once at the end and points still bound to the graph are skipped, not killed. */
  const runBatch = async (names: string[], action: BatchAction) => {
    if (names.length === 0) return;
    if (action === "delete" && !window.confirm(`${t("device.confirmBatchDelete")} ${names.length} ${t("device.confirmBatchDeleteMsg")}`)) return;

    const bound = action === "enable" ? new Set<string>() : await graphBoundNames();
    const targets = names.filter((name) => !bound.has(name));
    const skipped = names.filter((name) => bound.has(name));

    let failed = 0;
    for (const name of targets) {
      try {
        if (action === "delete") {
          await call(scoped(`/variables/${encodeURIComponent(name)}`), { method: "DELETE" });
        } else {
          await call(scoped(`/variables/${encodeURIComponent(name)}/enabled`), {
            ...json({ enabled: action === "enable" }),
            method: "PUT",
          });
        }
      } catch {
        failed += 1;
      }
    }

    await refresh(stationId);
    setSelectionMode(false);
    setSelected(() => new Set());
    eventBus.emit("bindings:changed", []);

    const done = targets.length - failed;
    const label = action === "delete" ? t("device.delete") : action === "enable" ? t("device.enable") : t("device.disable");
    if (done > 0) toast.success(`${t("device.batch")}${label}`, `${done} ${t("device.points")}`);
    if (failed > 0) toast.error(`${t("device.batch")}${label}`, `${failed} ${t("device.batchFailedMsg")}`);
    if (skipped.length > 0) {
      toast.warning(
        `${skipped.length} ${t("device.pointsBound")}`,
        `${t("device.skipUnbind")} ${skipped.slice(0, 3).join(", ")}${skipped.length > 3 ? "..." : ""}: ${t("device.skipUnbindMsg")}`,
      );
    }
  };

  /** Field edits from the multi-select menu: write every point, re-read once.
   * The selection survives so a second batch edit can follow the first. */
  const runBatchEdit = async (edits: BatchEdit[]) => {
    const changed: { var_name: string; channel: number }[] = [];
    let firstError = "";
    let failed = 0;
    for (const edit of edits) {
      const row = pointsByName[edit.name];
      if (!row) continue;
      const payload = payloadFor(row, edit.patch);
      try {
        await call(scoped("/mapping"), { ...json(payload), method: "PUT" });
        changed.push({ var_name: payload.var_name, channel: payload.channel });
      } catch (error) {
        failed += 1;
        if (!firstError) firstError = (error as Error).message;
      }
    }

    await refresh(stationId);
    eventBus.emit("bindings:changed", changed);
    if (changed.length > 0) toast.success(t("device.batchModified"), `${changed.length} ${t("device.batchModifiedMsg")}`);
    if (failed > 0) toast.error(t("device.batchModifyFailed"), `${failed} ${t("device.batchModifyFailedMsg")}: ${firstError}`);
  };

  const onCreateStation = (draft: StationDraft) =>
    mutate(() => call("/stations", json(draft))).then(() => setStationId(draft.station_id));

  const onSaveStation = (stationKey: string, draft: StationDraft) =>
    mutate(() =>
      call(`/stations/${stationKey}`, { ...json(draft), method: "PUT" }),
    ).then(() => {
      toast.success(t("device.stationSaved"), draft.station_id);
      eventBus.emit("station:saved", { station_id: draft.station_id });
    });

  const onRemoveStation = (id: string) => {
    if (!window.confirm(`${t("device.confirmDeleteStation")} ${id}？${t("device.confirmDeleteStationMsg")}`)) return;
    mutate(() => call(`/stations/${id}`, { method: "DELETE" }));
  };

  const addModule = () => {
    if (!newModule.module_id) {
      toast.warning(t("device.moduleIdRequired"));
      return;
    }
    if (spaceFull && Number(newModule.first_channel) > 63) {
      toast.warning(t("device.spaceFull"), t("device.spaceFullMsg"));
      return;
    }
    mutate(() =>
      call(
        scoped("/modules"),
        json({
          ...newModule,
          first_channel: Number(newModule.first_channel),
          channel_count: Number(newModule.channel_count),
        }),
      ),
    ).then(() => {
      toast.success(t("device.moduleAdded"), `${newModule.module_id} · ${t("device.moduleAddedMsg")}`);
      eventBus.emit("bindings:changed", []);
      setNewModule({ ...newModule, module_id: "" });
    });
  };

  const errorCount = issues.filter((i) => i.severity === "error").length;
  const warningCount = issues.length - errorCount;
  const disabledCount = points.filter((r) => !r.enabled).length;

  return (
    <div className="h-full flex flex-col">
      {/* Header */}
      <div className="h-12 bg-ide-sidebar border-b border-ide-border flex items-center px-4 gap-3">
        <svg
          viewBox="0 0 24 24"
          className="w-5 h-5 text-ide-accent"
          fill="none"
          stroke="currentColor"
          strokeWidth="2"
        >
          <path d="M6 3v12a3 3 0 003 3h9M6 21V9m0 0h4m-4 6h4m2-12h8v4h-8z" />
        </svg>
        <h1 className="text-lg font-semibold text-ide-strong">{t("device.title")}</h1>
        <span className="text-xs text-ide-textDim">{t("device.subtitle")}</span>

        <div className="flex-1" />

        <span
          className={`text-xs px-2 py-1 rounded ${
            errorCount > 0
              ? "bg-red-500/20 text-red-300"
              : warningCount > 0
                ? "bg-yellow-500/20 text-yellow-300"
                : "bg-green-500/20 text-green-300"
          }`}
        >
          {errorCount > 0
            ? `${errorCount} ${t("device.errors")}`
            : warningCount > 0
              ? `${warningCount} ${t("device.warnings")}`
              : t("device.passed")}
        </span>

        <span
          data-testid="device-project"
          className="text-xs px-2 py-1.5 rounded bg-ide-bg border border-ide-border text-ide-textDim max-w-[36ch] truncate"
          title={current?.path ?? ""}
        >
          {current ? `${current.name} · ${current.path}` : t("title.unnamed")}
        </span>
      </div>

      <StationBar
        stations={stations}
        selectedId={stationId}
        onSelect={setStationId}
        onCreate={onCreateStation}
        onSave={onSaveStation}
        onRemove={onRemoveStation}
      />

      {/* Hardware module row */}
      <div className="bg-ide-sidebar border-b border-ide-border px-4 py-2 flex items-center gap-2 text-xs">
        <span className="text-ide-textDim uppercase text-[10px]">
          {station ? `${station.station_id} ${t("device.hardwareModules")}` : t("device.hardwareModules")}
        </span>
        <input
          value={newModule.module_id}
          onChange={(e) => setNewModule({ ...newModule, module_id: e.target.value })}
          placeholder={t("device.moduleId")}
          className="w-20 bg-ide-bg border border-ide-border rounded px-2 py-1 font-mono"
        />
        <select
          value={newModule.kind}
          onChange={(e) => setNewModule({ ...newModule, kind: e.target.value })}
          className="bg-ide-bg border border-ide-border rounded px-2 py-1"
        >
          {["AI", "AO", "DI", "DO"].map((kind) => (
            <option key={kind} value={kind}>
              {kind}
            </option>
          ))}
        </select>
        <input
          value={newModule.first_channel}
          onChange={(e) => setNewModule({ ...newModule, first_channel: e.target.value })}
          placeholder={t("device.startChannel")}
          className="w-20 bg-ide-bg border border-ide-border rounded px-2 py-1 font-mono"
        />
        <input
          value={newModule.channel_count}
          onChange={(e) => setNewModule({ ...newModule, channel_count: e.target.value })}
          placeholder={t("device.channelCount")}
          className="w-20 bg-ide-bg border border-ide-border rounded px-2 py-1 font-mono"
        />
        <button
          onClick={addModule}
          disabled={spaceFull || !newModule.module_id}
          className="px-2.5 py-1 bg-ide-accent text-white rounded hover:bg-blue-600 disabled:opacity-40"
        >
          {t("device.add")}
        </button>
        <span className="text-[10px] text-ide-textDim">
          {spaceFull
            ? t("device.spaceFullAdd")
            : t("device.channelHint")}
        </span>
      </div>

      <div className="flex-1 flex overflow-hidden">
        <HardwareTree
          modules={modules}
          selectedChannel={selectedChannel}
          onSelectChannel={onSelectChannel}
          collapsed={collapsed}
          onToggle={(id) => setCollapsed({ ...collapsed, [id]: !collapsed[id] })}
          onUpdateChannelName={onUpdateChannelName}
          onAddModule={onAddModuleByKind}
          onRemoveModule={onRemoveModule}
          onCreatePoint={onCreatePoint}
          onDeletePoint={onDeletePoint}
          onToggleEnabled={onTogglePoint}
        />

        <div className="flex-1 flex flex-col overflow-hidden bg-ide-bg">
          <div className="px-4 py-2 border-b border-ide-border flex items-center gap-3">
            <span className="text-xs font-semibold uppercase text-ide-textDim">{t("device.devicePoints")}</span>
            <div className="flex rounded border border-ide-border overflow-hidden text-[10px]">
              {([
                ["board", t("device.cardView")],
                ["table", t("device.tableView")],
              ] as [PointView, string][]).map(([key, label]) => (
                <button
                  key={key}
                  onClick={() => switchView(key)}
                  data-testid={`point-view-${key}`}
                  aria-pressed={view === key}
                  className={`px-2 py-1 ${
                    view === key ? "bg-ide-selected text-ide-text" : "bg-ide-sidebar text-ide-textDim hover:bg-ide-hover"
                  }`}
                >
                  {label}
                </button>
              ))}
            </div>
            <label className="flex items-center gap-1.5 text-[10px] text-ide-textDim cursor-pointer select-none">
              <input
                type="checkbox"
                checked={hideDisabled}
                onChange={(e) => setHideDisabled(e.target.checked)}
                className="w-3 h-3 accent-ide-accent"
              />
              {t("device.hideDisabled")}
            </label>
            <span className="flex-1" />
            <span className="text-[10px] text-ide-textDim">
              {t("device.totalPoints")} {points.length} {t("device.points")} · {t("device.disabled")} {disabledCount} ·{" "}
              {view === "board" ? t("device.cardHint") : t("device.tableHint")}
            </span>
            <button
              onClick={() => navigator.clipboard?.writeText(stPreview)}
              className="text-[10px] text-ide-accent hover:underline"
            >
              {t("device.copySt")}
            </button>
            <button
              onClick={() => setShowSt(!showSt)}
              className="text-[10px] text-ide-textDim hover:text-ide-text"
            >
              {showSt ? t("device.collapseSt") : t("device.viewSt")}
            </button>
          </div>
          {view === "board" ? (
            <PointBoard
              modules={modules}
              byName={visiblePointsByName}
              errorByVar={errorByVar}
              selectedVar={selectedVar}
              onSelectChannel={onSelectChannel}
              onToggleEnabled={onTogglePoint}
              onCreatePoint={onCreatePoint}
              onDelete={onDeletePoint}
              onEdit={onSavePoint}
              selected={selected}
              setSelected={setSelected}
              selectionMode={selectionMode}
              setSelectionMode={setSelectionMode}
              onBatch={runBatch}
              onBatchEdit={runBatchEdit}
            />
          ) : (
            <ExternalVarTable
              rows={visiblePoints}
              errorByVar={errorByVar}
              onSelectVar={setSelectedVar}
              selectedVar={selectedVar}
              onToggleEnabled={onTogglePoint}
              onDelete={onDeletePoint}
              onEdit={(row, patch) => onSavePoint(row, patch)}
            />
          )}
          {showSt && (
            <pre className="border-t border-ide-border px-4 py-2 text-xs font-mono text-ide-text overflow-auto max-h-40 leading-relaxed whitespace-pre">
              {stPreview || t("device.noPoints")}
            </pre>
          )}
        </div>

        <BindingProperties row={selectedRow} issues={issues} onSave={onSaveBinding} />
      </div>

      <div className="border-t border-ide-border bg-ide-sidebar px-4 py-1 flex items-center gap-3 text-[10px] text-ide-textDim">
        <span>{offline ? t("device.backendOffline") : t("device.pointHint")}</span>
        <span className="flex-1" />
        <span>{t("device.disableHint")}</span>
      </div>
    </div>
  );
}
