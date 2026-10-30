import { useState } from "react";
import type { ForceRow, ScriptRow } from "./types";
import { makeForceRow, makeScriptRow } from "./types";

/**
 * Stimulus: what the engineer overrides, and when.
 *
 * Two shapes, exactly as protocol section 5 states them -- an override that
 * holds for the whole run, and records that land on a given scan cycle and hold
 * until the next record for the same symbol takes over. Nothing is applied
 * here: the lists go into the run request and `sim` decides, refusing at
 * startup rather than coercing a value.
 */

const input =
  "bg-ide-bg border border-ide-border rounded px-1.5 py-0.5 font-mono w-full focus:outline-none focus:border-ide-accent";
const button = "px-2 py-0.5 rounded border border-ide-border hover:bg-ide-hover disabled:opacity-40";

interface StimulusPanelProps {
  forces: ForceRow[];
  script: ScriptRow[];
  /** The symbols the last run reported: names to choose from, not names to be limited to. */
  symbols: { name: string; type: string }[];
  cycles: number;
  busy: boolean;
  onForces: (rows: ForceRow[]) => void;
  onScript: (rows: ScriptRow[]) => void;
  onRun: () => void;
}

export function StimulusPanel({
  forces,
  script,
  symbols,
  cycles,
  busy,
  onForces,
  onScript,
  onRun,
}: StimulusPanelProps) {
  const [preset, setPreset] = useState("");

  const names = symbols.map((row) => row.name);
  const typeOf = new Map(symbols.map((row) => [row.name, row.type]));

  const patchForce = (id: string, patch: Partial<ForceRow>) =>
    onForces(forces.map((row) => (row.id === id ? { ...row, ...patch } : row)));
  const patchScript = (id: string, patch: Partial<ScriptRow>) =>
    onScript(script.map((row) => (row.id === id ? { ...row, ...patch } : row)));

  const addForce = (name: string) => onForces([...forces, makeForceRow(name, "")]);
  const addRecord = (name: string) =>
    onScript([...script, makeScriptRow(name, (script[script.length - 1]?.cycle ?? 0) + 1, "")]);

  return (
    <div className="flex-1 overflow-auto text-xs">
      <datalist id="stimulus-symbols">
        {names.map((name) => (
          <option key={name} value={name} />
        ))}
      </datalist>

      <div className="sticky top-0 z-10 px-3 py-1.5 bg-ide-sidebar border-b border-ide-border flex items-center gap-2 flex-wrap">
        <button onClick={() => addForce(preset || names[0] || "")} className={button}>
          + 强制项
        </button>
        <button onClick={() => addRecord(preset || names[0] || "")} className={button}>
          + 脚本记录
        </button>
        <select
          value={preset}
          onChange={(event) => setPreset(event.target.value)}
          className="bg-ide-bg border border-ide-border rounded px-1.5 py-0.5 font-mono max-w-48"
          title="先选一个上次仿真报告过的符号，再按上面的按钮加行"
        >
          <option value="">（先选符号）</option>
          {names.map((name) => (
            <option key={name} value={name}>
              {name} · {typeOf.get(name)}
            </option>
          ))}
        </select>
        <div className="flex-1" />
        <span className="text-ide-textDim font-mono">
          {forces.filter((row) => row.on).length} 强制 · {script.filter((row) => row.on).length} 记录
        </span>
        <button
          onClick={() => void onRun()}
          disabled={busy}
          className="px-2 py-0.5 rounded bg-teal-700 text-white hover:bg-teal-600 disabled:opacity-50"
        >
          {busy ? "仿真中…" : "带激励运行"}
        </button>
      </div>

      <div className="grid grid-cols-2 gap-3 p-3">
        <section>
          <h3 className="text-[10px] uppercase tracking-wide text-ide-textDim mb-1">
            强制（整场运行保持）
          </h3>
          <table className="w-full border-collapse">
            <thead>
              <tr className="text-[10px] text-ide-textDim">
                <th className="text-left px-1 py-0.5">用</th>
                <th className="text-left px-1 py-0.5 w-2/5">符号</th>
                <th className="text-left px-1 py-0.5">值</th>
                <th className="w-6" />
              </tr>
            </thead>
            <tbody>
              {forces.map((row) => (
                <ForceCells
                  key={row.id}
                  row={row}
                  onRow={(patch) => patchForce(row.id, patch)}
                  onRemove={() => onForces(forces.filter((item) => item.id !== row.id))}
                />
              ))}
              {!forces.length && (
                <tr>
                  <td colSpan={4} className="px-1 py-2 text-ide-textDim">
                    无强制项。
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </section>

        <section>
          <h3 className="text-[10px] uppercase tracking-wide text-ide-textDim mb-1">
            测试脚本（按周期设定）
          </h3>
          <table className="w-full border-collapse">
            <thead>
              <tr className="text-[10px] text-ide-textDim">
                <th className="text-left px-1 py-0.5">用</th>
                <th className="text-left px-1 py-0.5 w-14">周期</th>
                <th className="text-left px-1 py-0.5 w-2/5">符号</th>
                <th className="text-left px-1 py-0.5">值</th>
                <th className="w-6" />
              </tr>
            </thead>
            <tbody>
              {script.map((row) => (
                <ScriptCells
                  key={row.id}
                  row={row}
                  cycles={cycles}
                  onRow={(patch) => patchScript(row.id, patch)}
                  onRemove={() => onScript(script.filter((item) => item.id !== row.id))}
                />
              ))}
              {!script.length && (
                <tr>
                  <td colSpan={5} className="px-1 py-2 text-ide-textDim">
                    无脚本记录。
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </section>
      </div>

      <div className="px-3 pb-3 text-[11px] text-ide-textDim leading-relaxed">
        值写整数或 <span className="font-mono">TRUE/FALSE</span>；REAL 符号可写小数，由仿真器按类型判定。
        落点由符号决定：输入通道的符号<b className="text-ide-text">注入被控对象</b>
        ，程序本周期真的读到它；其余符号在程序算完之后
        <b className="text-ide-text">覆盖全局槽位</b>
        ，所以引脚显示强制值，而同周期内已从这个引脚取数的下游仍是程序算出的值。脚本记录从它的周期起保持，直到同名下一条记录接管。被覆盖的值在时间轴、表格与引脚上都带
        <span className="text-orange-400 font-bold">F</span> 标记，绝不当成程序算出的结果。
        <span className="text-yellow-400">
          {" "}
          已知缺口：绑在输入通道上的 REAL 点，强制值是按通道原始计数落进槽位的，槽位仍按浮点解码，所以显示成极小值（任务
          #73 的通道数值链）。整数点与页内变量不受影响。
        </span>
      </div>
    </div>
  );
}

interface CellsProps<T> {
  row: T;
  onRow: (patch: Partial<T>) => void;
  onRemove: () => void;
}

function Toggle({ on, onRow }: { on: boolean; onRow: (patch: { on: boolean }) => void }) {
  return (
    <td className="px-1 py-0.5">
      <input
        type="checkbox"
        checked={on}
        onChange={(event) => onRow({ on: event.target.checked })}
        className="accent-teal-400"
        title="勾掉即保留此行但不送进下一次运行"
      />
    </td>
  );
}

function NameCell({ name, onRow }: { name: string; onRow: (patch: { name: string }) => void }) {
  return (
    <td className="px-1 py-0.5">
      <input list="stimulus-symbols" value={name} onChange={(event) => onRow({ name: event.target.value })} className={input} />
    </td>
  );
}

function ValueCell({ value, onRow }: { value: string; onRow: (patch: { value: string }) => void }) {
  return (
    <td className="px-1 py-0.5">
      <input
        value={value}
        onChange={(event) => onRow({ value: event.target.value })}
        placeholder="1 / TRUE"
        className={input}
      />
    </td>
  );
}

function RemoveCell({ onRemove }: { onRemove: () => void }) {
  return (
    <td className="px-1 py-0.5">
      <button onClick={onRemove} className="text-ide-textDim hover:text-red-400" title="删除此行">
        ✕
      </button>
    </td>
  );
}

function ForceCells({ row, onRow, onRemove }: CellsProps<ForceRow>) {
  return (
    <tr className="border-t border-ide-bg">
      <Toggle on={row.on} onRow={onRow} />
      <NameCell name={row.name} onRow={onRow} />
      <ValueCell value={row.value} onRow={onRow} />
      <RemoveCell onRemove={onRemove} />
    </tr>
  );
}

function ScriptCells({
  row,
  cycles,
  onRow,
  onRemove,
}: CellsProps<ScriptRow> & { cycles: number }) {
  const beyond = row.cycle > cycles;
  return (
    <tr className="border-t border-ide-bg">
      <Toggle on={row.on} onRow={onRow} />
      <td className="px-1 py-0.5">
        <input
          type="number"
          min={1}
          value={row.cycle}
          onChange={(event) => onRow({ cycle: Number(event.target.value) || 1 })}
          className={`${input} w-14 ${beyond ? "border-red-500" : ""}`}
          title={beyond ? `本次运行只有 ${cycles} 个周期，这条记录永远不会生效` : "生效周期，从 1 起"}
        />
      </td>
      <NameCell name={row.name} onRow={onRow} />
      <ValueCell value={row.value} onRow={onRow} />
      <RemoveCell onRemove={onRemove} />
    </tr>
  );
}
