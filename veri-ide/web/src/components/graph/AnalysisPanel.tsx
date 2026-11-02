import { useI18n } from "../../lib/i18n";
import type { AnalysisReport } from "./types";

interface CardProps {
  title: string;
  hint?: string;
  rows: CardRow[];
}

type CardRow = [string, string] | [string, string, boolean | undefined];

function Card({ title, hint, rows }: CardProps) {
  return (
    <div className="border border-ide-border rounded bg-ide-bg/40 mb-2">
      <div className="px-2.5 py-1 border-b border-ide-border text-[10px] uppercase tracking-wide text-ide-textDim">
        {title}
        {hint && <span className="normal-case ml-2 opacity-70">{hint}</span>}
      </div>
      {rows.map(([label, value, warn]) => (
        <div key={label} className="flex items-baseline gap-2 px-2.5 py-1 text-xs">
          <span className="text-ide-textDim flex-1">{label}</span>
          <span className={`font-mono ${warn ? "text-red-400" : "text-ide-text"}`}>{value}</span>
        </div>
      ))}
    </div>
  );
}

function bytes(value?: number): string {
  if (value === undefined) return "—";
  return value >= 1024 ? `${(value / 1024).toFixed(2)} KiB (${value})` : `${value} B`;
}

/**
 * The compiler's own numbers, read back from the emitted image.
 *
 * This is the gate into simulation: an ill-formed chart never reaches it, and a
 * chart whose WCET exceeds the station cycle is reported, not hidden.
 */
export function AnalysisPanel({
  report,
  error,
  busy,
  stale,
  blocked,
  onRun,
}: {
  report: AnalysisReport | null;
  error: string | null;
  busy: boolean;
  stale: boolean;
  blocked: boolean;
  onRun: () => void;
}) {
  const { t } = useI18n();
  const refused = report && !report.ok;

  return (
    <div className="flex-1 overflow-auto">
      <div className="px-3 py-2 flex items-center gap-2 border-b border-ide-border">
        <button
          onClick={onRun}
          disabled={busy || blocked}
          title={blocked ? t("analysis.checkerErrors") : t("analysis.checkerErrorsHint")}
          className="px-2.5 py-1 bg-ide-accent text-white rounded text-xs disabled:opacity-40"
        >
          {busy ? t("analysis.analyzing") : t("analysis.reanalyze")}
        </button>
        {blocked && !report && (
          <span className="text-ide-textDim">{t("analysis.checkerFirst")}</span>
        )}
        {report?.station && (
          <span className="ml-auto text-[10px] text-ide-textDim">
            {t("sim.station")} {report.station.station_id} · {t("sim.cycle")} {report.station.cycle_ms} ms
          </span>
        )}
      </div>

      {stale && report?.ok && (
        <div className="px-3 py-1.5 text-[11px] text-yellow-400 border-b border-ide-border bg-yellow-500/10">
          {t("analysis.configChanged")}
        </div>
      )}

      {error && <pre className="p-3 text-red-400 font-mono whitespace-pre-wrap">{error}</pre>}

      {refused && (
        <div className="p-3">
          <div className="text-red-400 mb-2">
            {report?.stage === "checker"
              ? t("analysis.checkerStillErrors")
              : `${t("analysis.compilerRejected")}${report?.exit_code !== undefined ? `（${t("analysis.exitCode")} ${report.exit_code}）` : ""}。`}
          </div>
          {(report?.errors ?? []).map((finding, index) => (
            <div key={`c${index}`} className="text-xs py-0.5">
              <span className="text-red-400 mr-1">✕</span>
              {finding.message}
              <span className="block text-[10px] text-ide-textDim ml-4">
                {finding.page}
                {finding.block && finding.block !== "__interface__" ? ` · ${finding.block}` : ""}
                {finding.port ? ` · ${finding.port}` : ""}
              </span>
            </div>
          ))}
          {(report?.diagnostics ?? []).map((row, index) => (
            <div key={`d${index}`} className="text-xs py-0.5">
              <span className="text-red-400 mr-1">✕</span>
              {row.message}
              <span className="block text-[10px] text-ide-textDim ml-4 font-mono">
                {[row.pou, row.var, row.kind, row.loc].filter(Boolean).join(" · ")}
              </span>
            </div>
          ))}
        </div>
      )}

      {report?.ok && (
        <div className="p-3">
          <Card
            title={t("analysis.wcet")}
            hint={`${t("analysis.artifact")} ${report.image_bytes} ${t("analysis.bytes")}`}
            rows={[
              [t("analysis.instructionCycles"), `${report.wcet?.total_cycles ?? "—"}`],
              [
                t("analysis.time"),
                `${report.wcet?.total_ns ?? "—"} ns（${((report.wcet?.total_ns ?? 0) / 1e6).toFixed(6)} ms）`,
              ],
              [
                `${t("analysis.cycleBudget")} ${report.wcet?.station_cycle_ms ?? "—"} ${t("analysis.cycleBudget2")}`,
                `${report.wcet?.used_percent ?? 0} %`,
                report.wcet?.fits_cycle === false,
              ],
              [
                t("analysis.cycleLimit"),
                `${report.wcet?.cycle_limit_instructions ?? "—"}${
                  report.wcet?.within_instruction_limit === false ? ` ${t("analysis.exceeded")}` : ""
                }`,
                report.wcet?.within_instruction_limit === false,
              ],
              [t("analysis.stackDepth"), `${report.analysis?.stack_depth ?? "—"}`],
              [t("analysis.recursive"), report.analysis?.recursive_calls ? t("analysis.yes") : t("analysis.no"), report.analysis?.recursive_calls],
              [t("analysis.boundedLoop"), report.analysis?.loops_bounded ? t("common.yes") : t("common.no"), !report.analysis?.loops_bounded],
            ]}
          />

          <Card
            title={t("analysis.memoryUsage")}
            hint={`${t("analysis.code")} ${report.memory?.code_bytes} ${t("analysis.bytes")}`}
            rows={[
              [t("analysis.linearMemory"), bytes(report.memory?.linear_memory_bytes)],
              ...Object.entries(report.memory?.by_kind ?? {}).map(
                ([kind, row]): CardRow => [
                  ` ${kind} ${t("analysis.section")}`,
                  `${bytes(row.bytes)}，${row.count} ${t("analysis.section2")}，${t("analysis.baseAddr")} 0x${row.start.toString(16)}`,
                ]
              ),
              [t("analysis.symbolCount"), `${report.memory?.symbols ?? "—"}`],
              [t("analysis.globalVars"), `${report.memory?.global_slots} / ${report.memory?.fb_fields}`],
              [t("analysis.ioMapping"), `${report.memory?.io_channels ?? "—"}`],
            ]}
          />

          <Card
            title={t("analysis.hotstandby")}
            hint={`${t("analysis.page")} ${report.sync_region?.page_size} B`}
            rows={[
              [t("analysis.syncPages"), `${report.sync_region?.mandatory_page_count ?? "—"} ${t("analysis.page")}`],
              [t("analysis.syncDataSize"), bytes(report.sync_region?.bytes_per_cycle)],
              [t("analysis.snapshotHeader"), bytes(report.sync_region?.snapshot_header_bytes)],
              [
                t("analysis.worstSnapshot"),
                bytes(report.sync_region?.worst_case_bytes),
                report.sync_region?.within_page_limit === false,
              ],
              [
                `${t("analysis.tracePageLimit")} ${report.sync_region?.page_limit}`,
                `${report.sync_region?.tracked_pages} ${t("analysis.used")}`,
              ],
            ]}
          />
          {report.sync_region?.note && (
            <div className="text-[10px] text-ide-textDim mt-2">
              {t("analysis.stackNote")}
            </div>
          )}

          <div className="mt-3 text-[10px] text-ide-textDim font-mono">
            {Object.entries(report.sections ?? {})
              .map(([name, length]) => `${name}=${length}`)
              .join("  ")}
          </div>
        </div>
      )}

      {!report && !busy && !error && (
        <div className="p-4 text-ide-textDim">
          {t("analysis.notAnalyzed")}
        </div>
      )}
    </div>
  );
}
