import { useEffect, useState } from "react";
import { eventBus } from "../lib/eventBus";
import { toast } from "../components/ui";
import { useI18n } from "../lib/i18n";

const BASE = "http://localhost:8000";

async function call<T>(path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(`${BASE}${path}`, init);
  const text = await response.text();
  if (!response.ok) {
    let detail = text;
    try {
      detail = JSON.parse(text).detail ?? text;
    } catch {
      /* keep the raw body */
    }
    throw new Error(typeof detail === "string" ? detail : JSON.stringify(detail));
  }
  if (!text) return {} as T;
  if (!text.startsWith("{") && !text.startsWith("[")) return text as T;
  return JSON.parse(text) as T;
}

interface PlantChannel {
  id: string;
  name: string;
  type: "CONST" | "LAG" | "RAMP" | "ACTUATOR";
  value: number;
  min: number;
  max: number;
}

interface WaveformData {
  name: string;
  values: number[];
  color: string;
}

interface BindingRow {
  var_name: string;
  channel: number;
  io_kind: string;
}

export function WaveformPage() {
  const { t } = useI18n();
  const [showPlant, setShowPlant] = useState(false);
  const [cycles, setCycles] = useState(100);
  const [period, setPeriod] = useState(100);
  const [running, setRunning] = useState(false);
  const [channels, setChannels] = useState<PlantChannel[]>([
    { id: "1", name: "SP", type: "CONST", value: 100, min: 0, max: 200 },
    { id: "2", name: "PV", type: "LAG", value: 0, min: 0, max: 200 },
  ]);
  const [waveforms, setWaveforms] = useState<WaveformData[]>([]);
  const [station, setStation] = useState("");

  // Load stations on mount
  useEffect(() => {
    call<{ station_id: string }[]>("/device/stations")
      .then((rows) => {
        const ids = rows.map((r) => r.station_id);
        setStation(ids[0] || "");
      })
      .catch(() => {});
  }, []);

  // Auto-derive plant channels from device bindings
  useEffect(() => {
    if (!station) return;
    call<BindingRow[]>(`/device/stations/${station}/mappings`)
      .then((bindings) => {
        if (bindings.length === 0) return;
        // Auto-derive plant channels from bindings
        const derived: PlantChannel[] = bindings.map((b, idx) => ({
          id: `${idx + 1}`,
          name: b.var_name,
          type: b.io_kind === "AI" ? "LAG" : b.io_kind === "AO" ? "ACTUATOR" : "CONST",
          value: 0,
          min: 0,
          max: 100,
        }));
        setChannels(derived);
        toast.info(t("waveform.configDerived"), `${t("waveform.configDerivedMsg")} ${bindings.length} ${t("waveform.configDerivedMsg2")}`);
      })
      .catch(() => {});
  }, [station]);

  // Listen for binding changes
  useEffect(() => {
    const handler = () => {
      if (!station) return;
      call<BindingRow[]>(`/device/stations/${station}/mappings`)
        .then((bindings) => {
          const derived: PlantChannel[] = bindings.map((b, idx) => ({
            id: `${idx + 1}`,
            name: b.var_name,
            type: b.io_kind === "AI" ? "LAG" : b.io_kind === "AO" ? "ACTUATOR" : "CONST",
            value: 0,
            min: 0,
            max: 100,
          }));
          setChannels(derived);
          toast.info(t("waveform.configUpdated"), t("waveform.configUpdatedMsg"));
        })
        .catch(() => {});
    };
    eventBus.on("bindings:changed", handler);
    return () => eventBus.off("bindings:changed", handler);
  }, [station]);

  const addChannel = () => {
    const newChannel: PlantChannel = {
      id: Date.now().toString(),
      name: `CH_${channels.length + 1}`,
      type: "CONST",
      value: 0,
      min: 0,
      max: 100,
    };
    setChannels([...channels, newChannel]);
  };

  const removeChannel = (id: string) => {
    setChannels(channels.filter((c) => c.id !== id));
  };

  const runSimulation = () => {
    setRunning(true);
    // Simulate waveform data
    const colors = ["#4ec9b0", "#569cd6", "#c586c0", "#dcdcaa", "#ce9178"];
    const newWaveforms: WaveformData[] = channels.map((ch, idx) => ({
      name: ch.name,
      values: Array.from({ length: cycles }, (_, i) => {
        if (ch.type === "CONST") return ch.value;
        if (ch.type === "RAMP") return (i / cycles) * ch.value;
        return ch.value * (1 - Math.exp(-i / 10));
      }),
      color: colors[idx % colors.length],
    }));
    setWaveforms(newWaveforms);
    setTimeout(() => setRunning(false), 1000);
  };

  return (
    <div className="h-full flex flex-col">
      {/* Toolbar */}
      <div className="h-10 bg-ide-sidebar border-b border-ide-border flex items-center px-4 gap-2">
        <button
          onClick={() => setShowPlant(!showPlant)}
          className="px-3 py-1 bg-ide-accent text-white text-xs rounded hover:bg-blue-600"
        >

          {showPlant ? t("waveform.hidePlant") : t("waveform.configPlant")}{t("waveform.plant")}
        </button>
        <div className="w-px h-5 bg-ide-border mx-2" />
        <label className="text-xs text-ide-textDim">{t("waveform.cycles")}</label>
        <input
          type="number"
          value={cycles}
          onChange={(e) => setCycles(Number(e.target.value))}
          className="w-16 px-2 py-1 bg-ide-bg border border-ide-border rounded text-xs"
        />
        <label className="text-xs text-ide-textDim ml-2">{t("waveform.period")}</label>
        <input
          type="number"
          value={period}
          onChange={(e) => setPeriod(Number(e.target.value))}
          className="w-16 px-2 py-1 bg-ide-bg border border-ide-border rounded text-xs"
        />
        <div className="flex-1" />
        <button
          onClick={runSimulation}
          disabled={running}
          className="px-4 py-1 bg-green-600 text-white text-xs rounded hover:bg-green-700 disabled:opacity-50"
        >
          {running ? t("waveform.running") : t("waveform.runSim")}
        </button>
      </div>

      {/* Plant Configuration Panel */}
      {showPlant && (
        <div className="bg-ide-sidebar border-b border-ide-border p-4">
          <h3 className="text-sm font-semibold text-ide-accent mb-3">{t("waveform.plantConfig")}</h3>
          <div className="space-y-2 max-h-48 overflow-y-auto">
            {channels.map((ch) => (
              <div key={ch.id} className="flex items-center gap-2 text-xs">
                <input
                  value={ch.name}
                  onChange={(e) =>
                    setChannels(channels.map((c) => (c.id === ch.id ? { ...c, name: e.target.value } : c)))
                  }
                  className="w-20 px-2 py-1 bg-ide-bg border border-ide-border rounded"
                />
                <select
                  value={ch.type}
                  onChange={(e) =>
                    setChannels(channels.map((c) => (c.id === ch.id ? { ...c, type: e.target.value as PlantChannel["type"] } : c)))
                  }
                  className="w-24 px-2 py-1 bg-ide-bg border border-ide-border rounded"
                >
                  <option value="CONST">CONST</option>
                  <option value="LAG">LAG</option>
                  <option value="RAMP">RAMP</option>
                  <option value="ACTUATOR">ACTUATOR</option>
                </select>
                <input
                  type="number"
                  value={ch.value}
                  onChange={(e) =>
                    setChannels(channels.map((c) => (c.id === ch.id ? { ...c, value: Number(e.target.value) } : c)))
                  }
                  className="w-20 px-2 py-1 bg-ide-bg border border-ide-border rounded"
                />
                <button
                  onClick={() => removeChannel(ch.id)}
                  className="px-2 py-1 bg-red-600 text-white rounded hover:bg-red-700"
                >
                  {t("waveform.delete")}
                </button>
              </div>
            ))}
          </div>
          <button
            onClick={addChannel}
            className="mt-3 px-3 py-1 bg-ide-hover text-ide-text text-xs rounded hover:bg-ide-selected"
          >
            {t("waveform.addChannel")}
          </button>
        </div>
      )}

      {/* Waveform Display */}
      <div className="flex-1 overflow-auto p-4">
        {waveforms.length === 0 ? (
          <div className="h-full flex items-center justify-center text-ide-textDim">
            <div className="text-center">
              <svg viewBox="0 0 24 24" className="w-16 h-16 mx-auto mb-4 opacity-30" fill="currentColor">
                <path d="M3.5 18.49l6-6.01 4 4L22 6.92l-1.41-1.41-7.09 7.97-4-4L2 16.99z" />
              </svg>
              <p className="text-lg">{t("waveform.viewer")}</p>
              <p className="text-sm mt-2">{t("waveform.viewerDesc")}</p>
            </div>
          </div>
        ) : (
          <div className="space-y-4">
            {waveforms.map((wf) => (
              <div key={wf.name} className="bg-ide-sidebar border border-ide-border rounded p-4">
                <div className="flex justify-between items-center mb-3">
                  <div className="flex items-center gap-2">
                    <div className="w-3 h-3 rounded" style={{ backgroundColor: wf.color }} />
                    <span className="font-semibold text-sm">{wf.name}</span>
                  </div>
                  <div className="text-xs text-ide-textDim">
                    {t("waveform.mean")} {wf.values.reduce((a, b) => a + b, 0) / wf.values.length}
                  </div>
                </div>
                <div className="h-32 flex items-end gap-px">
                  {wf.values.map((v, i) => {
                    const maxVal = Math.max(...wf.values);
                    const height = maxVal > 0 ? (v / maxVal) * 100 : 0;
                    return (
                      <div
                        key={i}
                        className="flex-1 rounded-t"
                        style={{
                          height: `${height}%`,
                          backgroundColor: wf.color,
                          opacity: 0.7,
                        }}
                      />
                    );
                  })}
                </div>
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}
