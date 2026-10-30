import { useCallback, useEffect, useMemo, useState } from "react";
import { HardwareTree } from "../components/device/HardwareTree";
import { MappingTable } from "../components/device/MappingTable";
import { BindingProperties } from "../components/device/BindingProperties";
import { ExternalVarTable } from "../components/device/ExternalVarTable";
import { StationBar, type StationDraft } from "../components/device/StationBar";
import type {
  BindingPayload,
  ExternalVarRow,
  IoVariable,
  MappingRow,
  ModuleView,
  StationRow,
  ValidationIssue,
} from "../components/device/types";

const API = "http://localhost:8000/device";

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

export function DevicePage() {
  const [stations, setStations] = useState<StationRow[]>([]);
  const [stationId, setStationId] = useState("");
  const [modules, setModules] = useState<ModuleView[]>([]);
  const [rows, setRows] = useState<MappingRow[]>([]);
  const [variables, setVariables] = useState<IoVariable[]>([]);
  const [external, setExternal] = useState<ExternalVarRow[]>([]);
  const [issues, setIssues] = useState<ValidationIssue[]>([]);
  const [stPreview, setStPreview] = useState("");
  const [bottomTab, setBottomTab] = useState<"vars" | "st">("vars");
  const [selectedVar, setSelectedVar] = useState<string | null>(null);
  const [selectedChannel, setSelectedChannel] = useState<number | null>(null);
  const [collapsed, setCollapsed] = useState<Record<string, boolean>>({});
  const [notice, setNotice] = useState<string | null>(null);
  const [offline, setOffline] = useState(false);
  const [projectPath, setProjectPath] = useState("");
  const [newModule, setNewModule] = useState({
    module_id: "",
    kind: "AI",
    first_channel: "0",
    channel_count: "8",
  });

  const station = stations.find((s) => s.station_id === stationId);

  const refresh = useCallback(
    async (id: string) => {
      if (!id) return;
      try {
        const list = await call<StationRow[]>("/stations");
        const active = list.some((s) => s.station_id === id) ? id : list[0]?.station_id ?? "";
        const hardware = await call<{ modules: ModuleView[] }>(`/stations/${active}/hardware`);
        const mapping = await call<MappingRow[]>(`/stations/${active}/mappings`);
        const vars = await call<IoVariable[]>(`/stations/${active}/variables`);
        const externalRows = await call<ExternalVarRow[]>(
          `/stations/${active}/external-variables`,
        );
        const check = await call<{ errors: ValidationIssue[]; warnings: ValidationIssue[] }>(
          `/stations/${active}/validate`,
          { method: "POST" },
        );
        const st = await fetch(`${API}/stations/${active}/iomap.st`).then((r) => r.text());

        setStations(list);
        setStationId(active);
        setModules(hardware.modules);
        setRows(mapping);
        setVariables(vars);
        setExternal(externalRows);
        setIssues([...check.errors, ...check.warnings]);
        setStPreview(st);
        setOffline(false);
      } catch (error) {
        setOffline(true);
        setNotice(`后端未就绪：${(error as Error).message}`);
      }
    },
    [],
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
        setNotice(`后端未就绪：${(error as Error).message}`);
      });
  }, []);

  const freeByKind = useMemo(() => {
    const grouped: Record<string, number[]> = { AI: [], AO: [], DI: [], DO: [] };
    for (const module of modules) {
      for (const channel of module.channel_list) {
        if (!channel.bound) grouped[module.kind]?.push(channel.channel);
      }
    }
    return grouped;
  }, [modules]);

  const errorByVar = useMemo(() => {
    const map: Record<string, string> = {};
    for (const issue of issues) {
      if (issue.severity === "error" && issue.var_name) map[issue.var_name] = issue.message;
    }
    return map;
  }, [issues]);

  const selectedRow = rows.find((r) => r.var_name === selectedVar) ?? null;
  const scoped = (path: string) => `/stations/${stationId}${path}`;

  const mutate = async (action: () => Promise<unknown>) => {
    try {
      await action();
      await refresh(stationId);
    } catch (error) {
      setNotice((error as Error).message);
    }
  };

  const onBind = (varName: string, channel: number) => {
    // keep the point attributes already configured for this variable
    const previous = external.find((row) => row.name === varName);
    const payload: BindingPayload = {
      var_name: varName,
      channel,
      scale: previous?.scale ?? 1,
      bias: previous?.bias ?? 0,
      safety_min: previous?.safety_min ?? null,
      safety_max: previous?.safety_max ?? null,
      point_name: previous?.point_name ?? "",
      unit: previous?.unit ?? "",
      has_quality: previous?.has_quality ?? false,
      fault_hold: previous?.fault_hold ?? "",
      preset_value: previous?.preset_value ?? null,
    };
    return mutate(() => call(scoped("/mapping"), { ...json(payload), method: "PUT" })).then(() =>
      setSelectedVar(varName),
    );
  };

  const onUnbind = (varName: string) =>
    mutate(() => call(scoped(`/mapping/${encodeURIComponent(varName)}`), { method: "DELETE" }));

  const onSaveBinding = (binding: BindingPayload) =>
    mutate(() => call(scoped("/mapping"), { ...json(binding), method: "PUT" }));

  const onSelectChannel = (channel: number) => {
    setSelectedChannel(channel);
    const owner = modules.flatMap((m) => m.channel_list).find((c) => c.channel === channel);
    if (owner?.var_name) setSelectedVar(owner.var_name);
  };

  const onAddModule = () => {
    if (!newModule.module_id) {
      setNotice("请填写模块 ID");
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
    ).then(() => setNewModule({ ...newModule, module_id: "" }));
  };

  const onCreateStation = (draft: StationDraft) =>
    mutate(() => call("/stations", json(draft))).then(() => setStationId(draft.station_id));

  const onSaveStation = (stationKey: string, draft: StationDraft) =>
    mutate(() =>
      call(`/stations/${stationKey}`, { ...json(draft), method: "PUT" }),
    ).then(() => setNotice(`站 ${draft.station_id} 参数已保存`));

  const onRemoveStation = (id: string) => {
    if (!window.confirm(`删除站 ${id}？其通道映射与点配置将一并移除。`)) return;
    mutate(() => call(`/stations/${id}`, { method: "DELETE" }));
  };

  const saveToDevice = () =>
    projectPath
      ? mutate(() => call("/save", json({ project_path: projectPath }))).then(() =>
          setNotice(`已写入 ${projectPath}/device/stations.toml 与各站 iomap`),
        )
      : setNotice("请先填写工程目录");

  const loadFromDevice = () =>
    projectPath
      ? mutate(() => call("/load", json({ project_path: projectPath }))).then(() =>
          setNotice(`已从 ${projectPath} 读取站与映射`),
        )
      : setNotice("请先填写工程目录");

  const errorCount = issues.filter((i) => i.severity === "error").length;
  const warningCount = issues.length - errorCount;

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
        <h1 className="text-lg font-semibold text-white">设备组态</h1>
        <span className="text-xs text-ide-textDim">站 / 硬件通道点 / 外部变量表</span>

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
            ? `${errorCount} 项错误`
            : warningCount > 0
              ? `${warningCount} 项提醒`
              : "校验通过"}
        </span>

        <input
          value={projectPath}
          onChange={(e) => setProjectPath(e.target.value)}
          placeholder="工程目录，用于读写站配置与映射"
          className="w-64 bg-ide-bg border border-ide-border rounded px-2 py-1.5 text-xs"
        />
        <button
          onClick={saveToDevice}
          className="px-3 py-1.5 bg-ide-hover text-ide-text text-xs rounded hover:bg-ide-selected"
        >
          写入工程
        </button>
        <button
          onClick={loadFromDevice}
          className="px-3 py-1.5 bg-ide-hover text-ide-text text-xs rounded hover:bg-ide-selected"
        >
          从工程载入
        </button>
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
          {station ? `${station.station_id} 硬件模块` : "硬件模块"}
        </span>
        <input
          value={newModule.module_id}
          onChange={(e) => setNewModule({ ...newModule, module_id: e.target.value })}
          placeholder="模块 ID"
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
          placeholder="起始通道"
          className="w-20 bg-ide-bg border border-ide-border rounded px-2 py-1 font-mono"
        />
        <input
          value={newModule.channel_count}
          onChange={(e) => setNewModule({ ...newModule, channel_count: e.target.value })}
          placeholder="通道数"
          className="w-20 bg-ide-bg border border-ide-border rounded px-2 py-1 font-mono"
        />
        <button
          onClick={onAddModule}
          className="px-2.5 py-1 bg-ide-accent text-white rounded hover:bg-blue-600"
        >
          添加
        </button>
        <span className="text-[10px] text-ide-textDim">通道空间每站独立，0–63</span>
        {notice && (
          <span className="text-[10px] text-ide-textDim truncate max-w-96 ml-2">{notice}</span>
        )}
      </div>

      <div className="flex-1 flex overflow-hidden">
        <HardwareTree
          modules={modules}
          selectedChannel={selectedChannel}
          onSelectChannel={onSelectChannel}
          collapsed={collapsed}
          onToggle={(id) => setCollapsed({ ...collapsed, [id]: !collapsed[id] })}
        />

        <MappingTable
          rows={rows}
          variables={variables}
          freeByKind={freeByKind}
          errorByVar={errorByVar}
          selectedVar={selectedVar}
          onSelectVar={setSelectedVar}
          onBind={onBind}
          onUnbind={onUnbind}
        />

        <BindingProperties row={selectedRow} issues={issues} onSave={onSaveBinding} />
      </div>

      {/* Bottom panel: external variable table or generated ST */}
      <div className="border-t border-ide-border bg-ide-sidebar">
        <div className="px-4 py-2 flex items-center gap-3">
          <button
            onClick={() => setBottomTab("vars")}
            className={`text-xs font-semibold uppercase ${
              bottomTab === "vars" ? "text-white" : "text-ide-textDim hover:text-ide-text"
            }`}
          >
            设备外部变量表
          </button>
          <button
            onClick={() => setBottomTab("st")}
            className={`text-xs font-semibold uppercase ${
              bottomTab === "st" ? "text-white" : "text-ide-textDim hover:text-ide-text"
            }`}
          >
            生成的 ST 段（VAR_GLOBAL + IOMAP）
          </button>
          <div className="flex-1" />
          {bottomTab === "st" ? (
            <>
              <span className="text-[10px] text-ide-textDim">
                编译后成为 .sasm 段 3，名称必须是 VAR_GLOBAL（GATE-7）
              </span>
              <button
                onClick={() => navigator.clipboard?.writeText(stPreview)}
                className="text-[10px] text-ide-accent hover:underline"
              >
                复制
              </button>
            </>
          ) : (
            <span className="text-[10px] text-ide-textDim">
              共 {external.length} 个变量 · 未映射 {external.filter((r) => !r.mapped).length}
            </span>
          )}
          {offline && <span className="text-[10px] text-red-400">后端离线</span>}
        </div>
        {bottomTab === "vars" ? (
          <ExternalVarTable rows={external} onSelectVar={setSelectedVar} />
        ) : (
          <pre className="px-4 pb-3 text-xs font-mono text-ide-text overflow-auto max-h-40 leading-relaxed whitespace-pre">
            {stPreview || "// 尚无有效绑定"}
          </pre>
        )}
      </div>
    </div>
  );
}
