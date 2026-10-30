import { useEffect, useState } from "react";
import { COMM_INTERFACES, DEVICE_TYPES, type StationRow } from "./types";

export interface StationDraft {
  station_id: string;
  label: string;
  device_type: string;
  cycle_ms: number;
  comm_interface: string;
  comm_address: string;
}

interface StationBarProps {
  stations: StationRow[];
  selectedId: string;
  onSelect: (stationId: string) => void;
  onCreate: (draft: StationDraft) => void;
  onSave: (stationId: string, draft: StationDraft) => void;
  onRemove: (stationId: string) => void;
}

const BLANK: StationDraft = {
  station_id: "",
  label: "",
  device_type: "DCU",
  cycle_ms: 100,
  comm_interface: "backplane",
  comm_address: "",
};

function toDraft(station: StationRow): StationDraft {
  return {
    station_id: station.station_id,
    label: station.label,
    device_type: station.device_type,
    cycle_ms: station.cycle_ms,
    comm_interface: station.comm_interface,
    comm_address: station.comm_address,
  };
}

export function StationBar({
  stations,
  selectedId,
  onSelect,
  onCreate,
  onSave,
  onRemove,
}: StationBarProps) {
  const [creating, setCreating] = useState(false);
  const [newStation, setNewStation] = useState<StationDraft>(BLANK);
  const current = stations.find((s) => s.station_id === selectedId);
  const [draft, setDraft] = useState<StationDraft>(current ? toDraft(current) : BLANK);

  useEffect(() => {
    setDraft(current ? toDraft(current) : BLANK);
  }, [current]);

  const submitCreate = () => {
    if (!newStation.station_id) return;
    onCreate(newStation);
    setNewStation(BLANK);
    setCreating(false);
  };

  const changed = current !== undefined && JSON.stringify(draft) !== JSON.stringify(toDraft(current));

  return (
    <div className="bg-ide-activity border-b border-ide-border px-3 py-1.5 text-xs">
      {/* station tabs */}
      <div className="flex items-center gap-2 flex-wrap">
        {stations.map((station) => {
          const active = station.station_id === selectedId;
          return (
            <button
              key={station.station_id}
              onClick={() => onSelect(station.station_id)}
              className={`px-2.5 py-1 rounded-t border-b-2 flex items-center gap-1.5 ${
                active
                  ? "bg-ide-sidebar border-ide-accent text-white"
                  : "border-transparent text-ide-textDim hover:text-ide-text"
              }`}
            >
              <span className="font-mono">{station.station_id}</span>
              {station.label && <span className="opacity-80">{station.label}</span>}
              <span className="opacity-60">{station.cycle_ms}ms</span>
              {station.errors > 0 && (
                <span className="px-1 rounded bg-red-500/30 text-red-300">{station.errors}</span>
              )}
              {station.errors === 0 && station.warnings > 0 && (
                <span className="px-1 rounded bg-yellow-500/25 text-yellow-300">
                  {station.warnings}
                </span>
              )}
            </button>
          );
        })}

        {creating ? (
          <span className="flex items-center gap-1.5">
            <input
              autoFocus
              value={newStation.station_id}
              onChange={(e) => setNewStation({ ...newStation, station_id: e.target.value })}
              placeholder="站 ID"
              className="w-20 bg-ide-bg border border-ide-border rounded px-2 py-1 font-mono"
            />
            <input
              value={newStation.label}
              onChange={(e) => setNewStation({ ...newStation, label: e.target.value })}
              placeholder="站名称"
              className="w-24 bg-ide-bg border border-ide-border rounded px-2 py-1"
            />
            <button
              onClick={submitCreate}
              className="px-2 py-1 bg-ide-accent text-white rounded hover:bg-blue-600"
            >
              创建
            </button>
            <button
              onClick={() => {
                setCreating(false);
                setNewStation(BLANK);
              }}
              className="px-2 py-1 text-ide-textDim hover:text-ide-text"
            >
              取消
            </button>
          </span>
        ) : (
          <button
            onClick={() => setCreating(true)}
            className="px-2 py-1 text-ide-accent hover:bg-ide-hover rounded"
            title="新建站"
          >
            + 新建站
          </button>
        )}

        <div className="flex-1" />

        {current && (
          <button
            onClick={() => onRemove(current.station_id)}
            disabled={stations.length <= 1}
            className="px-2 py-1 text-red-400 hover:bg-ide-hover rounded disabled:opacity-40"
            title={stations.length <= 1 ? "至少保留一个站" : "删除本站"}
          >
            删除站
          </button>
        )}
      </div>

      {/* selected station parameters */}
      {current && (
        <div className="mt-1.5 flex items-center gap-2 flex-wrap border-t border-ide-border pt-1.5">
          <span className="text-[10px] uppercase text-ide-textDim w-14">{current.station_id}</span>

          <label className="text-[10px] text-ide-textDim">名称</label>
          <input
            value={draft.label}
            onChange={(e) => setDraft({ ...draft, label: e.target.value })}
            className="w-24 bg-ide-bg border border-ide-border rounded px-1.5 py-1"
          />

          <label className="text-[10px] text-ide-textDim">设备类型</label>
          <input
            list="veri-ide-device-types"
            value={draft.device_type}
            onChange={(e) => setDraft({ ...draft, device_type: e.target.value })}
            className="w-20 bg-ide-bg border border-ide-border rounded px-1.5 py-1 font-mono"
          />
          <datalist id="veri-ide-device-types">
            {DEVICE_TYPES.map((t) => (
              <option key={t} value={t} />
            ))}
          </datalist>

          <label className="text-[10px] text-ide-textDim">运行周期</label>
          <input
            type="number"
            min={1}
            max={60000}
            value={draft.cycle_ms}
            onChange={(e) => setDraft({ ...draft, cycle_ms: Number(e.target.value) })}
            className="w-16 bg-ide-bg border border-ide-border rounded px-1.5 py-1 font-mono"
          />
          <span className="text-[10px] text-ide-textDim">ms</span>

          <label className="text-[10px] text-ide-textDim">通信接口</label>
          <select
            value={draft.comm_interface}
            onChange={(e) => setDraft({ ...draft, comm_interface: e.target.value })}
            className="bg-ide-bg border border-ide-border rounded px-1.5 py-1"
          >
            {COMM_INTERFACES.map((c) => (
              <option key={c} value={c}>
                {c}
              </option>
            ))}
          </select>
          <input
            value={draft.comm_address}
            onChange={(e) => setDraft({ ...draft, comm_address: e.target.value })}
            placeholder="通信地址"
            className="w-28 bg-ide-bg border border-ide-border rounded px-1.5 py-1 font-mono"
          />

          <button
            onClick={() => onSave(current.station_id, draft)}
            disabled={!changed}
            className="px-2.5 py-1 bg-ide-accent text-white rounded hover:bg-blue-600 disabled:opacity-40"
          >
            保存站参数
          </button>
          <span className="text-[10px] text-ide-textDim">
            模块 {current.modules} · 变量 {current.variables} · 已映射 {current.mapped}
          </span>
        </div>
      )}
    </div>
  );
}
