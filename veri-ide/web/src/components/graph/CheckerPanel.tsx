import { useState } from "react";
import { useI18n } from "../../lib/i18n";
import { AnalysisPanel } from "./AnalysisPanel";
import { SimPanel } from "./SimPanel";
import { StimulusPanel } from "./StimulusPanel";
import type {
  AnalysisReport,
  CheckReport,
  Finding,
  ForceRow,
  ScriptRow,
  SimRun,
} from "./types";
import { makeForceRow } from "./types";

export type PanelTab = "check" | "st" | "analysis" | "sim" | "stim";

export interface CheckerPanelProps {
  report: CheckReport | null;
  stText: string;
  stError: string | null;
  analysis: AnalysisReport | null;
  analysisError: string | null;
  analysisBusy: boolean;
  analysisStale: boolean;
  sim: SimRun | null;
  simError: string | null;
  simBusy: boolean;
  cycle: number;
  busy: boolean;
  tab: PanelTab;
  pages: string[];
  forces: ForceRow[];
  script: ScriptRow[];
  simCycles: number;
  onTab: (tab: PanelTab) => void;
  onJump: (target: { page: string; block: string; port: string }) => void;
  onRunAnalysis: () => void;
  onRunSim: () => void;
  onForces: (rows: ForceRow[]) => void;
  onScript: (rows: ScriptRow[]) => void;
}

function rows(findings: Finding[], filter: Record<string, boolean>): Finding[] {
  return findings.filter((finding) => filter[finding.severity] !== false);
}

/** The inspector results: every finding points at a sheet, an element and a pin. */
export function CheckerPanel({
  report,
  stText,
  stError,
  analysis,
  analysisError,
  analysisBusy,
  analysisStale,
  sim,
  simError,
  simBusy,
  cycle,
  busy,
  tab,
  pages,
  forces,
  script,
  simCycles,
  onTab,
  onJump,
  onRunAnalysis,
  onRunSim,
  onForces,
  onScript,
}: CheckerPanelProps) {
  const { t } = useI18n();
  const [filter, setFilter] = useState<Record<string, boolean>>({ error: true, warning: true, info: true });

  const TAB_LABELS: Record<PanelTab, string> = {
    check: t("checker.tabs.checker"),
    st: t("checker.tabs.st"),
    analysis: t("checker.tabs.analysis"),
    sim: t("checker.tabs.sim"),
    stim: t("checker.tabs.stimulus"),
  };

  const SEVERITY: Record<Finding["severity"], { color: string; glyph: string; label: string }> = {
    error: { color: "rgb(var(--ide-hue-red))", glyph: "✕", label: t("checker.error") },
    warning: { color: "rgb(var(--ide-hue-yellow))", glyph: "▲", label: t("checker.warning") },
    info: { color: "rgb(var(--ide-hue-blue))", glyph: "ℹ", label: t("checker.info") },
  };

  const errors = report?.errors ?? [];
  const warnings = report?.warnings ?? [];
  const infos = report?.infos ?? [];

  const group = (title: string, findings: Finding[]) => {
    const shown = rows(findings, filter);
    if (!findings.length) return null;
    return (
      <div className="mb-2">
        <div className="px-3 py-1 text-[10px] uppercase tracking-wide text-ide-textDim border-b border-ide-border">
          {title} · {findings.length}
        </div>
        {shown.map((finding, index) => (
          <button
            key={`${finding.code}-${finding.page}-${finding.block}-${finding.port}-${index}`}
            onClick={() => onJump({ page: finding.page, block: finding.block, port: finding.port })}
            disabled={!finding.page}
            className="w-full text-left px-3 py-1.5 text-xs hover:bg-ide-hover flex items-start gap-2 border-b border-ide-bg disabled:opacity-60"
          >
            <span style={{ color: SEVERITY[finding.severity].color }} className="mt-0.5">
              {SEVERITY[finding.severity].glyph}
            </span>
            <span className="flex-1">
              <span className="text-ide-text">{finding.message}</span>
              <span className="block text-[10px] text-ide-textDim">
                {finding.page || t("checker.unlocated")}
                {finding.block && finding.block !== "__interface__" ? ` · ${finding.block}` : ""}
                {finding.port ? ` · ${finding.port}` : ""}
                <span className="ml-2 font-mono opacity-70">{finding.code}</span>
              </span>
            </span>
          </button>
        ))}
      </div>
    );
  };

  return (
    <div className="flex flex-col h-full bg-ide-panel border-t border-ide-border text-xs">
      <div className="h-7 flex items-center gap-1 px-2 bg-ide-sidebar border-b border-ide-border">
        {(["check", "st", "analysis", "sim", "stim"] as PanelTab[]).map((key) => (
          <button
            key={key}
            onClick={() => onTab(key)}
            className={`px-2.5 py-0.5 rounded text-xs ${
              tab === key ? "bg-ide-bg text-ide-text" : "text-ide-textDim hover:bg-ide-hover"
            }`}
          >
            {TAB_LABELS[key]}
            {key === "check" && report && (
              <span className={`ml-1.5 ${errors.length ? "text-red-400" : "text-green-400"}`}>
                {errors.length ? `${errors.length} ${t("checker.fail")}` : t("checker.pass")}
              </span>
            )}
            {key === "analysis" && analysis && (
              <span
                className={`ml-1.5 ${
                  analysis.ok ? (analysisStale ? "text-yellow-400" : "text-green-400") : "text-red-400"
                }`}
              >
                {!analysis.ok ? t("checker.rejected") : analysisStale ? t("checker.modified") : t("checker.measured")}
              </span>
            )}
            {key === "sim" && sim && (
              <span className={`ml-1.5 ${sim.ok ? "text-green-400" : "text-red-400"}`}>
                {sim.ok ? `${sim.done?.cycles ?? 0} ${t("sim.cycle")}` : `${t("checker.rejected")}·${sim.stage ?? ""}`}
              </span>
            )}
            {key === "stim" && (forces.length || script.length) > 0 && (
              <span className="ml-1.5 text-orange-400">
                {forces.filter((row) => row.on).length + script.filter((row) => row.on).length}
              </span>
            )}
          </button>
        ))}

        <div className="flex-1" />

        {tab === "check" && (
          <div className="flex items-center gap-2 mr-2">
            {(["error", "warning", "info"] as const).map((severity) => (
              <button
                key={severity}
                onClick={() => setFilter((current) => ({ ...current, [severity]: current[severity] === false }))}
                className="flex items-center gap-1 opacity-90 hover:opacity-100"
                style={{ color: SEVERITY[severity].color, opacity: filter[severity] === false ? 0.35 : 1 }}
                title={SEVERITY[severity].label}
              >
                {SEVERITY[severity].glyph}
                {({ error: errors, warning: warnings, info: infos } as Record<string, Finding[]>)[severity].length}
              </button>
            ))}
          </div>
        )}
        {busy && <span className="text-ide-textDim animate-pulse">{t("checker.running")}</span>}
      </div>

      {tab === "check" ? (
        <div className="flex-1 overflow-y-auto">
          {!report && !busy && (
            <div className="p-4 text-ide-textDim">
              {t("checker.notChecked")}
            </div>
          )}
          {report?.ok && (
            <div className="p-3 text-green-400">
              {t("checker.passed")}{pages.length} {t("checker.passedPages")}{report.cross_page.length} {t("checker.passedCrossVars")}
            </div>
          )}
          {group(SEVERITY.error.label, errors)}
          {group(SEVERITY.warning.label, warnings)}
          {group(SEVERITY.info.label, infos)}
        </div>
      ) : tab === "st" ? (
        <div className="flex-1 overflow-auto">
          {stError && <pre className="p-3 text-red-400 font-mono whitespace-pre-wrap">{stError}</pre>}
          {!stError && <pre className="p-3 font-mono text-ide-text leading-relaxed whitespace-pre">{stText || t("checker.noContent")}</pre>}
        </div>
      ) : tab === "analysis" ? (
        <AnalysisPanel
          report={analysis}
          error={analysisError}
          busy={analysisBusy}
          stale={analysisStale}
          blocked={!report?.ok}
          onRun={onRunAnalysis}
        />
      ) : tab === "sim" ? (
        <SimPanel
          run={sim}
          error={simError}
          busy={simBusy}
          cycle={cycle}
          onRun={onRunSim}
          onJump={onJump}
          onForce={(name, value) => {
            onForces([...forces, makeForceRow(name, value)]);
            onTab("stim");
          }}
        />
      ) : (
        <StimulusPanel
          forces={forces}
          script={script}
          symbols={(sim?.symbols ?? []).map((row) => ({ name: row.name, type: row.type }))}
          cycles={simCycles}
          busy={simBusy}
          onForces={onForces}
          onScript={onScript}
          onRun={onRunSim}
        />
      )}
    </div>
  );
}
