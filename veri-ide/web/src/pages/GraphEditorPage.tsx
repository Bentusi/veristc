import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Sheet } from "../components/graph/Sheet";
import { PageTabs } from "../components/graph/PageTabs";
import { CheckerPanel, type PanelTab } from "../components/graph/CheckerPanel";
import { SimTimeline } from "../components/graph/SimPanel";
import { Inspector } from "../components/graph/Inspector";
import {
  INTERFACE,
  SHEETS,
  type AnalysisReport,
  type BlockNode,
  type CheckReport,
  type CrossPageRow,
  type ExternalVarRow,
  type Finding,
  type ForceRow,
  type LibraryBlock,
  type PageDoc,
  type PageRow,
  type PortDirection,
  type Position,
  type ScriptRow,
  type Selection,
  type SimRun,
  deleteSelection,
  pinForced,
  pinValues,
  simRunBody,
  typeColor,
} from "../components/graph/types";

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

const json = (body: unknown, method = "POST"): RequestInit => ({
  method,
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify(body),
});

/** The ST type name a library entry is written as, mirroring the server. */
function stTypeOf(block: LibraryBlock): string {
  const match = /(?:FUNCTION_BLOCK|FUNCTION)\s+([A-Za-z_][A-Za-z0-9_]*)/.exec(block.st_template ?? "");
  return match ? match[1] : block.name;
}

function uniqueId(taken: string[], stem: string): string {
  const base = stem.toLowerCase().replace(/[^a-z0-9_]/g, "");
  for (let index = 1; ; index += 1) {
    const candidate = `${base}${index}`;
    if (!taken.includes(candidate)) return candidate;
  }
}

export function GraphEditorPage() {
  const [pages, setPages] = useState<PageRow[]>([]);
  const [pageId, setPageId] = useState("");
  const [page, setPage] = useState<PageDoc | null>(null);
  const [library, setLibrary] = useState<Record<string, LibraryBlock>>({});
  const [palette, setPalette] = useState<LibraryBlock[]>([]);
  const [stations, setStations] = useState<string[]>([]);
  const [station, setStation] = useState("");
  const [external, setExternal] = useState<ExternalVarRow[]>([]);
  const [selected, setSelected] = useState<Selection>(null);
  const [report, setReport] = useState<CheckReport | null>(null);
  const [crossPage, setCrossPage] = useState<CrossPageRow[]>([]);
  const [stText, setStText] = useState("");
  const [stError, setStError] = useState<string | null>(null);
  const [analysis, setAnalysis] = useState<AnalysisReport | null>(null);
  const [analysisError, setAnalysisError] = useState<string | null>(null);
  const [analysisBusy, setAnalysisBusy] = useState(false);
  const [analysisStale, setAnalysisStale] = useState(false);
  const [sim, setSim] = useState<SimRun | null>(null);
  const [simError, setSimError] = useState<string | null>(null);
  const [simBusy, setSimBusy] = useState(false);
  const [simStale, setSimStale] = useState(false);
  const [simCycles, setSimCycles] = useState(20);
  const [cycleIndex, setCycleIndex] = useState(0);
  const [forces, setForces] = useState<ForceRow[]>([]);
  const [script, setScript] = useState<ScriptRow[]>([]);
  const [panel, setPanel] = useState<PanelTab>("check");
  const [notice, setNotice] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [zoom, setZoom] = useState(0.62);
  const [focus, setFocus] = useState<Position | null>(null);
  const [filter, setFilter] = useState("");
  const [projectPath, setProjectPath] = useState("");
  const dirty = useRef(false);
  const rev = useRef(0);

  const fail = useCallback((error: unknown) => {
    setNotice(error instanceof Error ? error.message : String(error));
  }, []);

  const refreshPages = useCallback(async () => {
    const rows = await call<PageRow[]>("/graph/pages");
    setPages(rows);
    return rows;
  }, []);

  const loadPage = useCallback(
    async (id: string) => {
      const doc = await call<PageDoc>(`/graph/pages/${id}`);
      setPage(doc);
      setPageId(id);
      setSelected(null);
    },
    []
  );

  useEffect(() => {
    (async () => {
      try {
        const [rows, blocks, stationRows] = await Promise.all([
          call<PageRow[]>("/graph/pages"),
          call<LibraryBlock[]>("/library/blocks"),
          call<{ station_id: string }[]>("/device/stations"),
        ]);
        const index: Record<string, LibraryBlock> = {};
        blocks.forEach((block) => {
          // The canvas and the checker look a block up by id, ST type or display name.
          const typed: LibraryBlock = { ...block, type: stTypeOf(block) };
          index[typed.id] = typed;
          index[stTypeOf(typed)] = typed;
          index[typed.name] = typed;
        });
        setLibrary(index);
        setPalette([...blocks].sort((a, b) => a.category.localeCompare(b.category) || a.name.localeCompare(b.name)));
        const ids = stationRows.map((row) => row.station_id);
        setStations(ids);
        setStation((current) => current || ids[0] || "");
        setPages(rows);
        if (rows[0]) await loadPage(rows[0].id);
        const jumps = await call<CrossPageRow[]>("/graph/cross-page");
        setCrossPage(jumps);
      } catch (error) {
        fail(error);
      }
    })();
  }, [fail, loadPage]);

  useEffect(() => {
    if (!station) {
      setExternal([]);
      return;
    }
    call<ExternalVarRow[]>(`/device/stations/${station}/external-variables`)
      .then(setExternal)
      .catch(() => setExternal([]));
  }, [station]);

  // Push the edited sheet to the sidecar; the schema decides whether it holds.
  // The local document stays authoritative: a slow response must not roll back
  // edits made while it was in flight.
  useEffect(() => {
    if (!page || !dirty.current) return;
    const doc = page;
    const target = rev.current;
    const timer = window.setTimeout(async () => {
      try {
        await call<PageDoc>(`/graph/pages/${doc.page.id}`, json(doc, "PUT"));
        if (rev.current === target) dirty.current = false;
        setPages(await refreshPages());
        setNotice(null);
      } catch (error) {
        fail(error);
      }
    }, 350);
    return () => window.clearTimeout(timer);
  }, [page, refreshPages, fail]);

  const patch = useCallback((mutate: (page: PageDoc) => PageDoc) => {
    dirty.current = true;
    rev.current += 1;
    // Anything the compiler measured belongs to the chart before this edit.
    setAnalysisStale(true);
    setSimStale(true);
    setPage((current) => (current ? mutate(current) : current));
  }, []);

  const marks = useMemo(() => {
    const table: Record<string, Finding[]> = {};
    if (!report || !page) return table;
    const sheet = page.page.id;
    [...report.errors, ...report.warnings, ...report.infos].forEach((finding) => {
      if (finding.page && finding.page !== sheet) return;
      const key = `${finding.block}.${finding.port}`;
      if (!finding.block) return;
      (table[key] ??= []).push(finding);
    });
    return table;
  }, [report, page]);

  const runAnalysis = useCallback(
    async (switchPanel = true) => {
      setAnalysisBusy(true);
      setAnalysisError(null);
      try {
        const result = await call<AnalysisReport>("/graph/analysis", json({ station: station || null }));
        setAnalysis(result);
        setAnalysisStale(false);
        if (switchPanel) setPanel("analysis");
      } catch (error) {
        setAnalysisError(error instanceof Error ? error.message : String(error));
      } finally {
        setAnalysisBusy(false);
      }
    },
    [station]
  );

  /** A pin's text comes from a frame, never from the chart; an edit retires the run. */
  const values = useMemo(
    () => (simStale ? {} : pinValues(sim, page?.page.id ?? "", cycleIndex)),
    [sim, simStale, page, cycleIndex]
  );

  /** Which of those pins a frame reported as overridden: the sheet marks them, and no one else. */
  const forcedPins = useMemo(
    () => (simStale ? {} : pinForced(sim, page?.page.id ?? "", cycleIndex)),
    [sim, simStale, page, cycleIndex]
  );

  const runSim = useCallback(async () => {
    setSimBusy(true);
    setSimError(null);
    try {
      const result = await call<SimRun>(
        "/sim/run",
        json(simRunBody(station, simCycles, forces, script))
      );
      setSim(result);
      setCycleIndex(0);
      setSimStale(false);
      setPanel("sim");
    } catch (error) {
      setSimError(error instanceof Error ? error.message : String(error));
      setSim(null);
    } finally {
      setSimBusy(false);
    }
  }, [station, simCycles, forces, script]);

  const runCheck = useCallback(async () => {
    setBusy(true);
    try {
      const result = await call<CheckReport>("/graph/check", json({ station: station || null }));
      setReport(result);
      setCrossPage(result.cross_page);
      setPages(result.pages);
      setPanel("check");
      setStError(null);
      try {
        setStText(await call<string>("/graph/st"));
      } catch (error) {
        // A chart with a loop has no execution order, so there is no text to show.
        setStError(error instanceof Error ? error.message : String(error));
      }
      // A clean chart goes straight to measurement: this is the gate into simulation.
      if (result.ok) await runAnalysis(false);
    } catch (error) {
      fail(error);
    } finally {
      setBusy(false);
    }
  }, [station, fail, runAnalysis]);

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Delete" || event.key === "Backspace") {
        const target = event.target as HTMLElement;
        if (target.tagName === "INPUT" || target.tagName === "SELECT" || target.tagName === "TEXTAREA") return;
        if (selected && page) removeSelection();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  });

  const removeSelection = () => {
    if (!page || !selected) return;
    patch((current) => deleteSelection(current, selected));
    setSelected(null);
  };

  const dropBlock = (payload: { library_id: string; type: string }, at: Position) => {
    if (!page) return;
    const def = library[payload.library_id] ?? library[payload.type];
    if (!def) return;
    let created = "";
    patch((current) => {
      const type = stTypeOf(def);
      const block: BlockNode = {
        id: uniqueId(
          [...current.blocks.map((item) => item.id), ...current.constants.map((item) => item.id)],
          type
        ),
        type,
        library_id: def.id,
        position: at,
        parameters: {},
      };
      created = block.id;
      return { ...current, blocks: [...current.blocks, block] };
    });
    setSelected({ kind: "block", id: created });
  };

  const addConstant = () => {
    if (!page) return;
    let created = "";
    patch((current) => {
      const id = uniqueId([...current.blocks.map((b) => b.id), ...current.constants.map((c) => c.id)], "K");
      created = id;
      const y = 140 + current.constants.length * 60;
      return { ...current, constants: [...current.constants, { id, type: "REAL", value: 0, position: { x: 320, y } }] };
    });
    setSelected({ kind: "constant", id: created });
  };

  const addPort = (direction: PortDirection, row?: ExternalVarRow) => {
    if (!page) return;
    let name = row?.name ?? "";
    patch((current) => {
      const taken = (["input", "output", "in_out"] as PortDirection[]).flatMap((key) => current.interface[key].map((port) => port.name));
      if (!name) name = uniqueId(taken, "VAR");
      const sheet = SHEETS[current.page.sheet ?? "A3"] ?? SHEETS.A3;
      const index = current.interface[direction].length;
      const position =
        direction === "output"
          ? { x: sheet.w - 24 - 40 - 150, y: 120 + index * 40 }
          : { x: 64, y: 120 + index * 40 };
      const port: PageDoc["interface"][PortDirection][number] = {
        name,
        type: row?.st_type ?? "REAL",
        scope: "external",
        ...(row ? { bind: { station, variable: row.name }, unit: row.unit ?? "" } : {}),
        position,
      };
      return { ...current, interface: { ...current.interface, [direction]: [...current.interface[direction], port] } };
    });
    setSelected({ kind: "port", direction, name });
  };

  const jumpTo = async (target: { page: string; block: string; port: string }) => {
    if (!target.page) return;
    const doc = target.page === pageId && page ? page : await call<PageDoc>(`/graph/pages/${target.page}`);
    if (target.page !== pageId) {
      dirty.current = false;
      await loadPage(target.page);
    }
    if (target.block === INTERFACE) {
      const direction = (["input", "output", "in_out"] as PortDirection[]).find((key) =>
        doc.interface[key].some((port) => port.name === target.port)
      );
      if (direction) {
        setSelected({ kind: "port", direction, name: target.port });
        const at = doc.interface[direction].find((port) => port.name === target.port)?.position;
        if (at) setFocus({ ...at });
      }
      return;
    }
    if (doc.constants.some((item) => item.id === target.block)) {
      setSelected({ kind: "constant", id: target.block });
      const at = doc.constants.find((item) => item.id === target.block)?.position;
      if (at) setFocus({ ...at });
      return;
    }
    const block = doc.blocks.find((item) => item.id === target.block);
    if (block) {
      setSelected({ kind: "block", id: block.id });
      setFocus({ x: block.position.x, y: block.position.y });
    }
  };

  const newPage = async () => {
    try {
      const label = window.prompt("图页名称", `PAGE${pages.length + 1}`) ?? `PAGE${pages.length + 1}`;
      const created = await call<{ page: { id: string } }>("/graph/pages", json({ label, sheet: "A3" }));
      await refreshPages();
      dirty.current = false;
      await loadPage(created.page.id);
    } catch (error) {
      fail(error);
    }
  };

  const closePage = async (id: string) => {
    if (!window.confirm(`删除图页 ${id}？`)) return;
    try {
      await call(`/graph/pages/${id}`, { method: "DELETE" });
      const rows = await refreshPages();
      dirty.current = false;
      if (id === pageId) await loadPage(rows[0]?.id ?? "");
    } catch (error) {
      fail(error);
    }
  };

  const renamePage = async (id: string, label: string) => {
    try {
      const doc = await call<PageDoc>(`/graph/pages/${id}`);
      await call<PageDoc>(`/graph/pages/${id}`, json({ ...doc, page: { ...doc.page, label } }, "PUT"));
      dirty.current = false;
      await refreshPages();
      if (id === pageId) await loadPage(id);
    } catch (error) {
      fail(error);
    }
  };

  const save = async () => {
    if (!projectPath) {
      setNotice("请先填写工程目录");
      return;
    }
    try {
      await call("/graph/save", json({ project_path: projectPath }));
      setNotice(`已保存到 ${projectPath}/graph`);
    } catch (error) {
      fail(error);
    }
  };

  const load = async () => {
    if (!projectPath) {
      setNotice("请先填写工程目录");
      return;
    }
    try {
      const rows = await call<PageRow[]>("/graph/load", json({ project_path: projectPath }));
      setPages(rows);
      dirty.current = false;
      if (rows[0]) await loadPage(rows[0].id);
      setNotice(null);
    } catch (error) {
      fail(error);
    }
  };

  const filteredPalette = palette.filter(
    (block) =>
      !filter ||
      `${block.name} ${block.id} ${block.category} ${block.description}`.toLowerCase().includes(filter.toLowerCase())
  );

  const button = "px-2.5 py-1 rounded text-xs bg-ide-hover hover:bg-ide-selected border border-ide-border";

  return (
    <div className="h-full flex flex-col" style={{ background: "#1e1e1e" }}>
      <div className="h-9 flex items-center gap-2 px-3 bg-ide-sidebar border-b border-ide-border text-xs">
        <span className="text-ide-textDim">程序</span>
        <span className="font-mono text-ide-text">{page?.name ?? "MAIN"}</span>
        <span className="w-px h-4 bg-ide-border mx-1" />
        <span className="text-ide-textDim">站点</span>
        <select
          value={station}
          onChange={(event) => setStation(event.target.value)}
          className="bg-ide-bg border border-ide-border rounded px-1.5 py-0.5"
        >
          {stations.length === 0 && <option value="">无站</option>}
          {stations.map((id) => (
            <option key={id} value={id}>
              {id}
            </option>
          ))}
        </select>
        <div className="w-px h-4 bg-ide-border mx-1" />
        <button onClick={runCheck} disabled={busy} className={`${button} bg-ide-accent text-white hover:bg-blue-600 disabled:opacity-50`}>
          检查器
        </button>
        <span className="text-ide-textDim">周期数</span>
        <input
          type="number"
          min={1}
          max={100000}
          value={simCycles}
          onChange={(event) => setSimCycles(Number(event.target.value) || 1)}
          className="w-16 bg-ide-bg border border-ide-border rounded px-1.5 py-0.5 font-mono"
        />
        <button
          onClick={() => void runSim()}
          disabled={busy || simBusy}
          className={`${button} bg-teal-700 text-white hover:bg-teal-600 disabled:opacity-50`}
          title="按设备组态生成被控对象表并运行 sim"
        >
          {simBusy ? "仿真中…" : "仿真"}
        </button>
        <button onClick={removeSelection} disabled={!selected} className={`${button} disabled:opacity-40`} title="删除所选（Delete）">
          删除
        </button>
        <button onClick={addConstant} className={button}>
          + 常量
        </button>
        <div className="flex-1" />
        <button onClick={() => setZoom((value) => Math.max(0.3, Math.round((value - 0.1) * 100) / 100))} className={button}>
          −
        </button>
        <span className="text-ide-textDim w-10 text-center">{Math.round(zoom * 100)}%</span>
        <button onClick={() => setZoom((value) => Math.min(1.6, Math.round((value + 0.1) * 100) / 100))} className={button}>
          +
        </button>
        <div className="w-px h-4 bg-ide-border mx-1" />
        <input
          value={projectPath}
          onChange={(event) => setProjectPath(event.target.value)}
          placeholder="工程目录"
          className="w-44 bg-ide-bg border border-ide-border rounded px-2 py-1 font-mono text-[11px]"
        />
        <button onClick={save} className={button}>
          保存
        </button>
        <button onClick={load} className={button}>
          载入
        </button>
      </div>

      {notice && (
        <div className="px-3 py-1.5 bg-red-900/40 border-b border-red-700 text-xs text-red-200 font-mono">{notice}</div>
      )}

      <PageTabs
        pages={pages}
        active={pageId}
        crossPage={crossPage}
        dirty={dirty.current}
        onSelect={async (id) => {
          dirty.current = false;
          await loadPage(id);
        }}
        onAdd={newPage}
        onClose={(id) => void closePage(id)}
        onRename={(id, label) => void renamePage(id, label)}
        onJump={(id, name) => void jumpTo({ page: id, block: INTERFACE, port: name })}
      />

      <div className="flex-1 flex overflow-hidden">
        <div className="w-60 shrink-0 bg-ide-sidebar border-r border-ide-border flex flex-col overflow-hidden">
          <div className="p-2 border-b border-ide-border">
            <input
              value={filter}
              onChange={(event) => setFilter(event.target.value)}
              placeholder="搜索算法块"
              className="w-full bg-ide-bg border border-ide-border rounded px-2 py-1 text-xs"
            />
          </div>
          <div className="flex-1 overflow-y-auto">
            <div className="px-2 py-1 text-[10px] uppercase tracking-wide text-ide-textDim">算法库</div>
            {filteredPalette.map((block) => (
              <div
                key={block.id}
                draggable
                onDragStart={(event) =>
                  event.dataTransfer.setData(
                    "application/x-veri-block",
                    JSON.stringify({ library_id: block.id, type: stTypeOf(block) })
                  )
                }
                onDoubleClick={() => dropBlock({ library_id: block.id, type: stTypeOf(block) }, { x: 300, y: 200 })}
                title={`${block.description}\n输入 ${block.inputs.length} / 输出 ${block.outputs.length}`}
                className="mx-2 mb-1 px-2 py-1.5 rounded hover:bg-ide-hover cursor-grab flex items-center gap-2"
              >
                <span
                  className="px-1 rounded text-[9px] font-mono"
                  style={{
                    background: block.block_kind === "FUN" ? "#3c5a3c" : "#3c4a6a",
                    color: "#dcdcdc",
                  }}
                >
                  {block.block_kind === "FUN" ? "FUN" : "FB"}
                </span>
                <span className="flex-1 truncate">{block.name}</span>
                <span className="text-[10px] text-ide-textDim font-mono">
                  {block.inputs.length}→{block.outputs.length}
                </span>
              </div>
            ))}

            <div className="px-2 py-1 mt-2 text-[10px] uppercase tracking-wide text-ide-textDim border-t border-ide-border">
              外部变量表 · {external.length}
            </div>
            {external.map((row) => (
              <div key={row.name} className="mx-2 mb-0.5 px-2 py-1 rounded hover:bg-ide-hover text-[11px] flex items-center gap-1.5">
                <span className="w-1.5 h-1.5 rounded-full shrink-0" style={{ background: typeColor(row.st_type) }} />
                <span className="flex-1 truncate font-mono" title={`${row.name} · ${row.description ?? ""}`}>
                  {row.name}
                </span>
                <span className="text-ide-textDim">{row.st_type}</span>
                <button onClick={() => addPort("input", row)} className="text-ide-status hover:underline" title="添加为输入引脚">
                  IN
                </button>
                <button onClick={() => addPort("output", row)} className="text-ide-status hover:underline" title="添加为输出引脚">
                  OUT
                </button>
              </div>
            ))}
            {external.length === 0 && (
              <p className="px-3 py-2 text-[10px] text-ide-textDim">该站暂无外部变量，请先在设备组态配置通道并生成变量表。</p>
            )}
          </div>
        </div>

        <div className="flex-1 flex flex-col overflow-hidden">
          <div className="flex-1 overflow-hidden">
            {page ? (
              <Sheet
                page={page}
                library={library}
                marks={marks}
                values={values}
                forced={forcedPins}
                selected={selected}
                zoom={zoom}
                focus={focus}
                onSelect={setSelected}
                onPage={patch}
                onDropBlock={dropBlock}
              />
            ) : (
              <div className="h-full flex items-center justify-center text-ide-textDim text-sm">
                正在载入图页…（若长时间无响应，请确认后端已启动）
              </div>
            )}
          </div>
          {sim?.ok && sim.timeline?.length ? (
            <SimTimeline run={sim} cycle={cycleIndex} stale={simStale} onCycle={setCycleIndex} />
          ) : null}
          {Object.keys(forcedPins).length > 0 && (
            <div className="shrink-0 px-3 py-1 bg-orange-700/30 border-t border-orange-600 text-[11px] text-orange-300 font-mono">
              本周期有 {Object.keys(forcedPins).length} 个引脚显示的是强制值（F 标记），不是程序算出来的结果
            </div>
          )}
          <div className="h-56 shrink-0">
            <CheckerPanel
              report={report}
              stText={stText}
              stError={stError}
              analysis={analysis}
              analysisError={analysisError}
              analysisBusy={analysisBusy}
              analysisStale={analysisStale}
              sim={sim}
              simError={simError}
              simBusy={simBusy}
              cycle={cycleIndex}
              busy={busy}
              tab={panel}
              pages={pages.map((row) => row.id)}
              forces={forces}
              script={script}
              simCycles={simCycles}
              onTab={setPanel}
              onJump={(target) => void jumpTo(target)}
              onRunAnalysis={() => void runAnalysis()}
              onRunSim={() => void runSim()}
              onForces={setForces}
              onScript={setScript}
            />
          </div>
        </div>

        <div className="w-72 shrink-0 bg-ide-sidebar border-l border-ide-border overflow-y-auto">
          <div className="px-3 py-2 text-[10px] uppercase tracking-wide text-ide-textDim border-b border-ide-border">
            属性
          </div>
          {page && (
            <Inspector
              page={page}
              library={library}
              selected={selected}
              external={external}
              station={station}
              onPage={patch}
              onDelete={removeSelection}
            />
          )}
          <div className="px-3 py-2 border-t border-ide-border text-[10px] uppercase tracking-wide text-ide-textDim">
            图页变量
          </div>
          {page && (
            <div className="px-2 pb-2 space-y-1">
              {(["input", "in_out", "output"] as PortDirection[]).map((direction) => (
                <div key={direction}>
                  <div className="flex items-center justify-between text-[10px] text-ide-textDim px-1">
                    <span>{direction === "input" ? "输入" : direction === "output" ? "输出" : "读写"}</span>
                    <button onClick={() => addPort(direction)} className="hover:text-ide-text" title="新建变量引脚">
                      +
                    </button>
                  </div>
                  {page.interface[direction].map((port) => (
                    <button
                      key={`${direction}${port.name}`}
                      onClick={() => setSelected({ kind: "port", direction, name: port.name })}
                      className={`w-full text-left px-2 py-0.5 rounded text-[11px] flex items-center gap-1.5 ${
                        selected?.kind === "port" && selected.name === port.name && selected.direction === direction
                          ? "bg-ide-selected"
                          : "hover:bg-ide-hover"
                      }`}
                    >
                      <span className="w-1.5 h-1.5 rounded-full" style={{ background: typeColor(port.type) }} />
                      <span className="flex-1 truncate font-mono">{port.name}</span>
                      {port.bind?.variable && <span className="text-green-500">⚙</span>}
                      {port.scope === "intermediate" && <span className="text-yellow-500">跨</span>}
                      <span className="text-ide-textDim">{port.type}</span>
                    </button>
                  ))}
                </div>
              ))}
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
