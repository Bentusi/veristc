import { useEffect, useRef, useState } from "react";
import type { Finding, PinRow, SimRun } from "./types";
import { pinKey } from "./types";

/** A run that was refused says which gate refused it; only the checker speaks in findings. */
function refusalErrors(run: SimRun): string[] {
  const errors = run.errors ?? [];
  return errors.map((row) => (typeof row === "string" ? row : (row as Finding).message));
}

interface TimelineProps {
  run: SimRun;
  cycle: number;
  stale: boolean;
  onCycle: (index: number) => void;
}

/**
 * The scan-cycle scrubber. Every value on the sheet is the value the frame of
 * this cycle reported, so the cycle being shown has always to be stated.
 */
export function SimTimeline({ run, cycle, stale, onCycle }: TimelineProps) {
  const [playing, setPlaying] = useState(false);
  const count = run.timeline?.length ?? 0;

  // The interval is created once per play session, so it reads the cycle through a ref.
  const onCycleRef = useRef(onCycle);
  const cycleRef = useRef(cycle);
  onCycleRef.current = onCycle;
  cycleRef.current = cycle;

  useEffect(() => {
    if (!playing || count < 2) return;
    const timer = window.setInterval(() => onCycleRef.current((cycleRef.current + 1) % count), 250);
    return () => window.clearInterval(timer);
  }, [playing, count]);

  if (!count) return null;
  const row = run.timeline?.[Math.min(cycle, count - 1)];
  const step = (index: number) => onCycle(Math.max(0, Math.min(count - 1, index)));
  const button = "px-1.5 rounded border border-ide-border hover:bg-ide-hover disabled:opacity-40";

  return (
    <div className="h-8 shrink-0 flex items-center gap-2 px-3 bg-ide-sidebar border-t border-ide-border text-[11px]">
      <button className={button} onClick={() => step(0)} disabled={cycle === 0} title="首个周期">
        ⏮
      </button>
      <button className={button} onClick={() => step(cycle - 1)} disabled={cycle === 0} title="上一周期">
        ‹
      </button>
      <button
        className={button}
        onClick={() => setPlaying((value) => !value)}
        title={playing ? "暂停" : "回放"}
      >
        {playing ? "⏸" : "▶"}
      </button>
      <button className={button} onClick={() => step(cycle + 1)} disabled={cycle >= count - 1} title="下一周期">
        ›
      </button>
      <button className={button} onClick={() => step(count - 1)} disabled={cycle >= count - 1} title="末个周期">
        ⏭
      </button>
      <input
        type="range"
        min={1}
        max={count}
        value={Math.min(cycle + 1, count)}
        onChange={(event) => onCycle(Number(event.target.value) - 1)}
        className="flex-1 accent-teal-400"
      />
      <span className="font-mono text-ide-text w-28">
        周期 {cycle + 1}/{count}
      </span>
      <span className="font-mono text-ide-textDim w-24">t = {row?.t_ms ?? 0} ms</span>
      <span className={`font-mono ${(row?.violations ?? 0) > 0 ? "text-red-400" : "text-green-400"}`}>
        违例 {row?.violations ?? 0}
      </span>
      <span className="font-mono text-ide-textDim">状态 {row?.status ?? 0}</span>
      {stale && <span className="text-yellow-400">图已改动，结果属于改动前</span>}
      <span className="text-ide-textDim">
        {run.symbols?.length ?? 0} 符号 · {(run.runs ?? 1) > 1 ? `${run.runs} 次运行合并` : "单次运行"}
      </span>
    </div>
  );
}

/** How many symbols the frames reported as overridden at the cycle being shown. */
function forcedCount(run: SimRun, cycle: number): number {
  return (run.symbols ?? []).filter((row) => row.forced?.[cycle] === true).length;
}

interface SimPanelProps {
  run: SimRun | null;
  error: string | null;
  busy: boolean;
  cycle: number;
  onRun: () => void;
  onJump: (target: { page: string; block: string; port: string }) => void;
  /** Put this symbol on the force list, starting from the value the frame reported. */
  onForce: (name: string, value: string) => void;
}

/** The simulator's answer: what the object table was, and what every frame reported. */
export function SimPanel({ run, error, busy, cycle, onRun, onJump, onForce }: SimPanelProps) {
  const pinsFor = (symbol: string): PinRow[] =>
    (run?.pins ?? []).filter((pin) => pin.symbol === symbol);

  return (
    <div className="flex-1 overflow-auto text-xs">
      <div className="sticky top-0 px-3 py-1.5 bg-ide-sidebar border-b border-ide-border flex items-center gap-3">
        <button onClick={onRun} disabled={busy} className="px-2 py-0.5 rounded bg-ide-accent text-white hover:bg-blue-600 disabled:opacity-50">
          {busy ? "仿真中…" : "运行仿真"}
        </button>
        {run?.ok && run.done && (
          <span className="text-green-400 font-mono">
            {run.done.cycles} 周期 · {run.cycle_ms} ms · 读错 {run.done.read_errors} · 写错 {run.done.write_errors}
          </span>
        )}
        {run?.ok && run.plant && <span className="text-ide-textDim font-mono">对象表 {run.plant.name}</span>}
        {run?.ok && run.station && <span className="text-ide-textDim font-mono">站 {run.station.station_id}</span>}
        {run?.ok && (
          <span
            className={
              forcedCount(run, cycle) ? "text-orange-400 font-mono" : "text-ide-textDim font-mono"
            }
          >
            {forcedCount(run, cycle) ? `${forcedCount(run, cycle)} 个值被强制` : "无强制值"}
          </span>
        )}
      </div>

      {error && <pre className="p-3 text-red-400 font-mono whitespace-pre-wrap">{error}</pre>}

      {run && !run.ok && (
        <div className="p-3 space-y-1">
          <div className="text-red-400">
            仿真被拒绝：{run.stage ?? "未知阶段"}
          </div>
          {refusalErrors(run).map((message, index) => (
            <div key={index} className="font-mono text-red-300">
              {message}
            </div>
          ))}
          {(run.diagnostics ?? []).map((row, index) => (
            <div key={index} className="font-mono text-red-300">
              {row.loc ? `${row.loc} ` : ""}
              {row.message}
            </div>
          ))}
          {(run.warnings ?? []).map((finding, index) => (
            <div key={index} className="font-mono text-yellow-400">
              {finding.message}
            </div>
          ))}
        </div>
      )}

      {run?.ok && (
        <table className="w-full border-collapse">
          <thead>
            <tr className="text-ide-textDim text-[10px] uppercase">
              <th className="text-left px-3 py-1">符号</th>
              <th className="text-left px-2 py-1">类型</th>
              <th className="text-right px-2 py-1">地址</th>
              <th className="text-right px-2 py-1">通道</th>
              <th className="text-right px-2 py-1">当前值</th>
              <th className="text-left px-2 py-1">显示在</th>
              <th className="text-left px-2 py-1">强制</th>
            </tr>
          </thead>
          <tbody className="font-mono">
            {(run.symbols ?? []).map((row) => {
              const shown = pinsFor(row.name);
              const index = Math.min(cycle, row.values.length - 1);
              const value = row.values[index] ?? null;
              const isForced = row.forced?.[index] === true;
              return (
                <tr
                  key={row.name}
                  className={`border-t border-ide-bg hover:bg-ide-hover ${
                    isForced ? "bg-orange-700/20 text-orange-300" : ""
                  }`}
                >
                  <td className="px-3 py-0.5 text-ide-text">{row.name}</td>
                  <td className="px-2 py-0.5 text-ide-textDim">{row.type}</td>
                  <td className="px-2 py-0.5 text-right">{row.addr}</td>
                  <td className="px-2 py-0.5 text-right">{row.channel ?? "—"}</td>
                  <td
                    className={`px-2 py-0.5 text-right ${
                      isForced ? "text-orange-400 font-bold" : "text-teal-300"
                    }`}
                    title={isForced ? "本周期该值由激励覆盖，不是程序算出的" : "本周期该值由程序算出"}
                  >
                    {isForced ? "F " : ""}
                    {value === null ? "—" : String(value)}
                  </td>
                  <td className="px-2 py-0.5">
                    {shown.length ? (
                      shown.map((pin) => (
                        <button
                          key={pinKey({ block: pin.element, port: pin.port })}
                          onClick={() => onJump({ page: pin.page, block: pin.element, port: pin.port })}
                          className="mr-1 text-ide-status hover:underline"
                        >
                          {pin.element === "__interface__" ? pin.port : `${pin.element}.${pin.port}`}
                        </button>
                      ))
                    ) : (
                      <span className="text-ide-textDim">—</span>
                    )}
                  </td>
                  <td className="px-2 py-0.5">
                    <button
                      onClick={() => onForce(row.name, value === null ? "" : String(value))}
                      className="text-ide-textDim hover:text-orange-400"
                      title="加入强制列表并转到激励页"
                    >
                      {isForced ? "已强制" : "强制…"}
                    </button>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      )}

      {!run && !error && !busy && (
        <div className="p-4 text-ide-textDim">
          尚未仿真。运行时检查器先通过，再按设备组态生成被控对象表，逐周期取回 watch 帧；引脚上的数字来自帧，不来自图。
        </div>
      )}
    </div>
  );
}
