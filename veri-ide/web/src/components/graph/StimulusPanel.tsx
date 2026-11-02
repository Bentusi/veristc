import { useState } from "react";
import { useI18n } from "../../lib/i18n";
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
  const { t } = useI18n();
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
          {t("stimulus.addForce")}
        </button>
        <button onClick={() => addRecord(preset || names[0] || "")} className={button}>
          {t("stimulus.addScript")}
        </button>
        <select
          value={preset}
          onChange={(event) => setPreset(event.target.value)}
          className="bg-ide-bg border border-ide-border rounded px-1.5 py-0.5 font-mono max-w-48"
          title={t("stimulus.selectSymbolFirst")}
        >
          <option value="">{t("stimulus.selectSymbolPlaceholder")}</option>
          {names.map((name) => (
            <option key={name} value={name}>
              {name} · {typeOf.get(name)}
            </option>
          ))}
        </select>
        <div className="flex-1" />
        <span className="text-ide-textDim font-mono">
          {forces.filter((row) => row.on).length} {t("stimulus.forceCount")} · {script.filter((row) => row.on).length} {t("stimulus.scriptCount")}
        </span>
        <button
          onClick={() => void onRun()}
          disabled={busy}
          className="px-2 py-0.5 rounded bg-teal-700 text-white hover:bg-teal-600 disabled:opacity-50"
        >
          {busy ? t("checker.running") : t("stimulus.runWithStimulus")}
        </button>
      </div>

      <div className="grid grid-cols-2 gap-3 p-3">
        <section>
          <h3 className="text-[10px] uppercase tracking-wide text-ide-textDim mb-1">
            {t("stimulus.forceSection")}
          </h3>
          <table className="w-full border-collapse">
            <thead>
              <tr className="text-[10px] text-ide-textDim">
                <th className="text-left px-1 py-0.5">{t("stimulus.using")}</th>
                <th className="text-left px-1 py-0.5 w-2/5">{t("stimulus.symbol")}</th>
                <th className="text-left px-1 py-0.5">{t("stimulus.value")}</th>
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
                    {t("stimulus.noForces")}
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </section>

        <section>
          <h3 className="text-[10px] uppercase tracking-wide text-ide-textDim mb-1">
            {t("stimulus.scriptSection")}
          </h3>
          <table className="w-full border-collapse">
            <thead>
              <tr className="text-[10px] text-ide-textDim">
                <th className="text-left px-1 py-0.5">{t("stimulus.using")}</th>
                <th className="text-left px-1 py-0.5 w-14">{t("stimulus.cycle")}</th>
                <th className="text-left px-1 py-0.5 w-2/5">{t("stimulus.symbol")}</th>
                <th className="text-left px-1 py-0.5">{t("stimulus.value")}</th>
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
                    {t("stimulus.noScripts")}
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </section>
      </div>

      <div className="px-3 pb-3 text-[11px] text-ide-textDim leading-relaxed">
        {t("stimulus.helpText")}
        <span className="text-yellow-400">
          {" "}
          {t("stimulus.knownGap")}
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
  const { t } = useI18n();
  return (
    <td className="px-1 py-0.5">
      <input
        type="checkbox"
        checked={on}
        onChange={(event) => onRow({ on: event.target.checked })}
        className="accent-teal-400"
        title={t("stimulus.keepRow")}
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
  const { t } = useI18n();
  return (
    <td className="px-1 py-0.5">
      <button onClick={onRemove} className="text-ide-textDim hover:text-red-400" title={t("stimulus.deleteRow")}>
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
  const { t } = useI18n();
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
          title={beyond ? `${t("stimulus.cycleOutOfRange")} ${cycles} ${t("stimulus.cycleOutOfRange2")}` : t("stimulus.effectiveCycle")}
        />
      </td>
      <NameCell name={row.name} onRow={onRow} />
      <ValueCell value={row.value} onRow={onRow} />
      <RemoveCell onRemove={onRemove} />
    </tr>
  );
}
