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
  const refused = report && !report.ok;

  return (
    <div className="flex-1 overflow-auto">
      <div className="px-3 py-2 flex items-center gap-2 border-b border-ide-border">
        <button
          onClick={onRun}
          disabled={busy || blocked}
          title={blocked ? "检查器仍有错误" : "用编译器度量 WCET、内存与同步区"}
          className="px-2.5 py-1 bg-ide-accent text-white rounded text-xs disabled:opacity-40"
        >
          {busy ? "分析中…" : "重新分析"}
        </button>
        {blocked && !report && (
          <span className="text-ide-textDim">先让检查器通过，编译器才会被调用。</span>
        )}
        {report?.station && (
          <span className="ml-auto text-[10px] text-ide-textDim">
            站 {report.station.station_id} · 周期 {report.station.cycle_ms} ms
          </span>
        )}
      </div>

      {stale && report?.ok && (
        <div className="px-3 py-1.5 text-[11px] text-yellow-400 border-b border-ide-border bg-yellow-500/10">
          组态已改动，下面的数值来自改动前的那一次分析。
        </div>
      )}

      {error && <pre className="p-3 text-red-400 font-mono whitespace-pre-wrap">{error}</pre>}

      {refused && (
        <div className="p-3">
          <div className="text-red-400 mb-2">
            {report?.stage === "checker"
              ? "检查器仍有错误，编译器未调用。"
              : `编译器拒绝该组态文本${report?.exit_code !== undefined ? `（退出码 ${report.exit_code}）` : ""}。`}
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
            title="最坏执行时间"
            hint={`制品 ${report.image_bytes} 字节`}
            rows={[
              ["指令周期数（段 6 WCET）", `${report.wcet?.total_cycles ?? "—"}`],
              [
                "时间（编译器折算）",
                `${report.wcet?.total_ns ?? "—"} ns（${((report.wcet?.total_ns ?? 0) / 1e6).toFixed(6)} ms）`,
              ],
              [
                `占 ${report.wcet?.station_cycle_ms ?? "—"} ms 周期`,
                `${report.wcet?.used_percent ?? 0} %`,
                report.wcet?.fits_cycle === false,
              ],
              [
                "每周期指令上限（段 5）",
                `${report.wcet?.cycle_limit_instructions ?? "—"}${
                  report.wcet?.within_instruction_limit === false ? " 超限" : ""
                }`,
                report.wcet?.within_instruction_limit === false,
              ],
              ["静态栈深度", `${report.analysis?.stack_depth ?? "—"}`],
              ["递归调用", report.analysis?.recursive_calls ? "有" : "无", report.analysis?.recursive_calls],
              ["循环有界", report.analysis?.loops_bounded ? "是" : "否", !report.analysis?.loops_bounded],
            ]}
          />

          <Card
            title="内存与变量占用"
            hint={`代码 ${report.memory?.code_bytes} 字节`}
            rows={[
              ["线性内存（段 2 声明）", bytes(report.memory?.linear_memory_bytes)],
              ...Object.entries(report.memory?.by_kind ?? {}).map(
                ([kind, row]): CardRow => [
                  `　${kind} 区`,
                  `${bytes(row.bytes)}，${row.count} 段，基址 0x${row.start.toString(16)}`,
                ]
              ),
              ["符号条数（段 7）", `${report.memory?.symbols ?? "—"}`],
              ["全局变量 / 实例字段", `${report.memory?.global_slots} / ${report.memory?.fb_fields}`],
              ["I/O 通道映射（段 3）", `${report.memory?.io_channels ?? "—"}`],
            ]}
          />

          <Card
            title="热备同步区"
            hint={`页 ${report.sync_region?.page_size} B`}
            rows={[
              ["每周期强制同步页", `${report.sync_region?.mandatory_page_count ?? "—"} 页`],
              ["每周期同步数据量", bytes(report.sync_region?.bytes_per_cycle)],
              ["快照包头", bytes(report.sync_region?.snapshot_header_bytes)],
              [
                "最坏单帧快照",
                bytes(report.sync_region?.worst_case_bytes),
                report.sync_region?.within_page_limit === false,
              ],
              [
                `跟踪页上限 ${report.sync_region?.page_limit}`,
                `${report.sync_region?.tracked_pages} 已用`,
              ],
            ]}
          />
          {report.sync_region?.note && (
            <div className="text-[10px] text-ide-textDim mt-2">
              数值栈与帧栈由运行站快照模型（hotstandby/snapshot.c）另行计入。
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
          尚未分析。分析把设备组态的 VAR_GLOBAL/IOMAP 段与图页生成的 PROGRAM 文本一并交给
          veristc，读回制品里的 WCET、内存与符号段，并按热备快照规则算出同步区大小。
        </div>
      )}
    </div>
  );
}
