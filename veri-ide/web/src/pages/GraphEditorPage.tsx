import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useProject } from "../project/ProjectProvider";
import { useI18n } from "../lib/i18n";
import { Sheet } from "../components/graph/Sheet";
import { PageTabs } from "../components/graph/PageTabs";
import { CheckerPanel, type PanelTab } from "../components/graph/CheckerPanel";
import { SimTimeline } from "../components/graph/SimPanel";
import { Inspector } from "../components/graph/Inspector";
import { toast } from "../components/ui";
import { eventBus } from "../lib/eventBus";
import { useEditShortcuts } from "../lib/shortcuts";
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
  type SystemVarRow,
  type Scope,
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

/** Where a palette row puts its port, and how the port is declared. */
interface PortSeed {
  name?: string;
  type?: string;
  scope?: Scope;
  bind?: { station: string; variable: string };
  unit?: string;
}

/** One palette group: the variables of one kind and what a drop onto the sheet makes. */
interface PaletteGroup {
  title: string;
  note?: string;
  /** What the group says when it has no rows -- where the engineer has to go instead. */
  empty: string;
  create?: { label: string; seed: PortSeed; title: string };
  rows: {
    key: string;
    name: string;
    type: string;
    title: string;
    badge?: string;
    seed: PortSeed;
    /** The pins this variable can supply on a sheet; a station point has one. */
    actions: { label: string; direction: PortDirection; title: string }[];
  }[];
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
  const [systemVars, setSystemVars] = useState<SystemVarRow[]>([]);
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
  const [busy, setBusy] = useState(false);
  const [zoom, setZoom] = useState(0.62);
  const [focus, setFocus] = useState<Position | null>(null);
  const [filter, setFilter] = useState("");
  const { current: project } = useProject();
  const { t } = useI18n();
  const dirty = useRef(false);
  const rev = useRef(0);

  useEditShortcuts({
    onSave: async () => {
      if (!project) {
        toast.warning(t("common.noProject"), t("common.noProjectDesc"));
        return;
      }
      try {
        await call("/graph/save", json({}));
        toast.success(t("graph.pageSaved"), `${t("graph.pageSavedMsg")} ${project.path}/logic`);
      } catch (error) {
        fail(error);
      }
    },
  });

  const fail = useCallback((error: unknown) => {
    toast.error(t("common.error"), error instanceof Error ? error.message : String(error));
  }, [t]);

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
        const [rows, blocks, stationRows, systemRows] = await Promise.all([
          call<PageRow[]>("/graph/pages"),
          call<LibraryBlock[]>("/library/blocks"),
          call<{ station_id: string }[]>("/device/stations"),
          call<SystemVarRow[]>("/graph/system-variables"),
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
        setSystemVars(systemRows);
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
  }, [fail, loadPage, project?.path]);

  useEffect(() => {
    if (!station) {
      setExternal([]);
      return;
    }
    call<ExternalVarRow[]>(`/device/stations/${station}/external-variables`)
      .then(setExternal)
      .catch(() => setExternal([]));
  }, [station]);

  // Listen for binding changes from DevicePage and refresh external variables
  useEffect(() => {
    const handler = () => {
      if (!station) return;
      call<ExternalVarRow[]>(`/device/stations/${station}/external-variables`)
        .then((vars) => {
          setExternal(vars);
          toast.info(t("graph.varListRefreshed"), t("graph.varListRefreshedMsg"));
        })
        .catch(() => {});
    };
    eventBus.on("bindings:changed", handler);
    return () => eventBus.off("bindings:changed", handler);
  }, [station, t]);

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

  // Auto-run analysis 500ms after edits for real-time feedback
  useEffect(() => {
    if (!analysisStale || !page) return;
    const timer = window.setTimeout(() => {
      runAnalysis(false);
    }, 500);
    return () => window.clearTimeout(timer);
  }, [analysisStale, page, runAnalysis]);

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
        // The preview is taken for the station on the toolbar, so CYCLE_MS shows
        // the cycle that run will actually use.
        setStText(await call<string>(`/graph/st?station=${encodeURIComponent(station)}`));
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

  /** Where a palette row would put its port, and with what declaration. */
  const addPort = (direction: PortDirection, seed: PortSeed = {}) => {
    if (!page) return;
    let name = seed.name ?? "";
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
        type: seed.type ?? "REAL",
        scope: seed.scope ?? "external",
        ...(seed.bind ? { bind: seed.bind } : {}),
        unit: seed.unit ?? "",
        position,
      };
      return { ...current, interface: { ...current.interface, [direction]: [...current.interface[direction], port] } };
    });
    setSelected({ kind: "port", direction, name });
  };

  /** The direction a name is already declared in on this sheet, if any. */
  const portDirectionOnPage = (name: string): PortDirection | undefined => {
    if (!page) return undefined;
    return (["input", "in_out", "output"] as PortDirection[]).find((direction) =>
      page.interface[direction].some((port) => port.name === name)
    );
  };

  const focusPort = (name: string) => {
    const direction = portDirectionOnPage(name);
    if (!direction || !page) return;
    const port = page.interface[direction].find((item) => item.name === name);
    setSelected({ kind: "port", direction, name });
    if (port?.position) setFocus({ ...port.position });
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
      const label = window.prompt(t("graph.pageName"), `PAGE${pages.length + 1}`) ?? `PAGE${pages.length + 1}`;
      const created = await call<{ page: { id: string } }>("/graph/pages", json({ label, sheet: "A3" }));
      await refreshPages();
      dirty.current = false;
      await loadPage(created.page.id);
    } catch (error) {
      fail(error);
    }
  };

  const closePage = async (id: string) => {
    if (!window.confirm(`${t("graph.confirmDeletePage")} ${id}？`)) return;
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

  const filteredPalette = palette.filter(
    (block) =>
      !filter ||
      `${block.name} ${block.id} ${block.category} ${block.description}`.toLowerCase().includes(filter.toLowerCase())
  );

  /** Every port declared on the sheet being drawn, with the direction it sits in. */
  const pagePorts = useMemo(
    () =>
      page
        ? (["input", "in_out", "output"] as PortDirection[]).flatMap((direction) =>
            page.interface[direction].map((port) => ({ ...port, direction }))
          )
        : [],
    [page]
  );

  /**
   * The variable palette, cut the way a sheet is read: what comes in, what goes
   * out, what crosses over to another page, what belongs to this page alone, and
   * what the runtime hands over every cycle.
   *
   * A station point offers one pin only, because the module kind decided its
   * direction when the point was created -- offering the other one would ask the
   * engineer to contradict the hardware. A page variable offers both, because the
   * page it lands on decides that, and a name already on this sheet offers
   * nothing: it is declared once and the wires go from there.
   */
  const groups = useMemo<PaletteGroup[]>(() => {
    const onSheet = new Set(pagePorts.map((port) => port.name));
    const pinsFor = (
      name: string,
      actions: { label: string; direction: PortDirection; title: string }[]
    ) => (onSheet.has(name) ? [] : actions);

    const read = { label: "IN", direction: "input" as PortDirection, title: t("graph.readHere") };
    const write = { label: "OUT", direction: "output" as PortDirection, title: t("graph.writeHere") };

    const points = (direction: "input" | "output") =>
      external
        .filter((row) => row.direction === direction && row.enabled !== false)
        .map((row) => ({
          key: row.name,
          name: row.name,
          type: row.st_type,
          title: `${row.name} · ${row.description || t("graph.noPointName")}${row.mapped ? "" : ` · ${t("graph.noChannel")}`}`,
          seed: {
            name: row.name,
            type: row.st_type,
            scope: "external" as const,
            bind: { station, variable: row.name },
            unit: row.unit ?? "",
          },
          actions: pinsFor(row.name, direction === "input" ? [read] : [write]),
        }));

    const intermediate = new Map<string, { name: string; type: string; pages: string[] }>();
    crossPage
      .filter((row) => row.scope === "intermediate")
      .forEach((row) => intermediate.set(row.name, { name: row.name, type: row.type, pages: row.pages }));
    pagePorts
      .filter((port) => port.scope === "intermediate")
      .forEach((port) =>
        intermediate.set(port.name, {
          name: port.name,
          type: port.type,
          pages: intermediate.get(port.name)?.pages ?? [],
        })
      );

    // Device points arrive in channel order and stay that way: re-sorting by
    // name would read `1_CH1, 1_CH10, 1_CH2`. Only the page-local groups, which
    // have no channel, are name-sorted.
    const sort = <T extends { name: string }>(rows: T[]): T[] => rows.sort((a, b) => a.name.localeCompare(b.name));

    return [
      {
        title: t("graph.inputVars"),
        note:
          external.filter((row) => row.direction === "input" && row.enabled === false).length > 0
            ? t("graph.inputVarsNote")
            : undefined,
        empty: t("graph.noInputVars"),
        rows: points("input"),
      },
      {
        title: t("graph.outputVars"),
        empty: t("graph.noOutputVars"),
        rows: points("output"),
      },
      {
        title: t("graph.middleVars"),
        create: { label: t("graph.newMiddle"), seed: { scope: "intermediate" as const }, title: t("graph.newMiddleHint") },
        empty: t("graph.noMiddleVars"),
        rows: sort(
          [...intermediate.values()].map((row) => ({
            key: row.name,
            name: row.name,
            type: row.type,
            title: `${row.name} · ${t("graph.connectPage")} ${row.pages.join("、") || t("graph.thisPage")}`,
            seed: { name: row.name, type: row.type, scope: "intermediate" as const },
            actions: pinsFor(row.name, [read, write]),
          }))
        ),
      },
      {
        title: t("graph.privateVars"),
        create: { label: t("graph.newPrivate"), seed: { scope: "local" as const }, title: t("graph.newPrivateHint") },
        empty: t("graph.noPrivateVars"),
        rows: sort(
          pagePorts
            .filter((port) => port.scope === "local")
            .map((port) => ({
              key: `local${port.name}`,
              name: port.name,
              type: port.type,
              title: `${port.name} · ${t("graph.privateHint")}`,
              seed: { name: port.name, type: port.type, scope: "local" as const },
              actions: [] as { label: string; direction: PortDirection; title: string }[],
            }))
        ),
      },
      {
        title: t("graph.systemVars"),
        note: t("graph.systemVarsNote"),
        empty: t("graph.noSystemVars"),
        rows: systemVars.map((row) => ({
          key: row.name,
          name: row.name,
          type: row.st_type,
          title: `${row.name} · ${row.description}`,
          badge: t("graph.readonly"),
          seed: { name: row.name, type: row.st_type, scope: "external" as const },
          actions: pinsFor(row.name, [read]),
        })),
      },
    ];
  }, [external, pagePorts, crossPage, systemVars, station, t]);

  // No neutral background here on purpose: a variant that adds `bg-ide-accent`
  // would otherwise lose to this rule, since Tailwind orders background-color
  // utilities by config key order (accent comes before hover).
  const button = "px-2.5 py-1 rounded text-xs hover:bg-ide-hover border border-ide-border";

  return (
    <div className="h-full flex flex-col bg-ide-bg">
      <div className="h-9 flex items-center gap-2 px-3 bg-ide-sidebar border-b border-ide-border text-xs">
        <span className="text-ide-textDim">{t("graph.program")}</span>
        <span className="font-mono text-ide-text">{page?.name ?? "MAIN"}</span>
        <span className="w-px h-4 bg-ide-border mx-1" />
        <span className="text-ide-textDim">{t("graph.station")}</span>
        <select
          value={station}
          onChange={(event) => setStation(event.target.value)}
          className="bg-ide-bg border border-ide-border rounded px-1.5 py-0.5"
        >
          {stations.length === 0 && <option value="">{t("graph.noStation")}</option>}
          {stations.map((id) => (
            <option key={id} value={id}>
              {id}
            </option>
          ))}
        </select>
        <div className="w-px h-4 bg-ide-border mx-1" />
        <button onClick={runCheck} disabled={busy} className={`${button} bg-ide-accent text-white hover:bg-blue-600 disabled:opacity-50`}>
          {t("graph.checker")}
        </button>
        <span className="text-ide-textDim">{t("graph.cycles")}</span>
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
          title={t("graph.simHint")}
        >
          {simBusy ? t("graph.simulating") : t("graph.sim")}
        </button>
        <button onClick={removeSelection} disabled={!selected} className={`${button} disabled:opacity-40`} title={t("graph.deleteSelected")}>
          {t("graph.delete")}
        </button>
        <button onClick={addConstant} className={button}>
          {t("graph.addConstant")}
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
        <span
          data-testid="graph-project"
          className="px-2 py-1 rounded bg-ide-bg border border-ide-border text-ide-textDim text-[11px] max-w-[34ch] truncate"
          title={project?.path ?? ""}
        >
          {project ? `${project.name} · logic/` : t("title.unnamed")}
        </span>
      </div>

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
              placeholder={t("graph.searchPlaceholder")}
              className="w-full bg-ide-bg border border-ide-border rounded px-2 py-1 text-xs"
            />
          </div>
          <div className="flex-1 overflow-y-auto">
            <div className="px-2 py-1 text-[10px] uppercase tracking-wide text-ide-textDim">{t("graph.library")}</div>
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
                title={`${block.description}\n${t("graph.input")} ${block.inputs.length} / ${t("graph.output")} ${block.outputs.length}`}
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

            {groups.map((group) => {
              const rows = group.rows.filter(
                (row) => !filter || `${row.name} ${row.title}`.toLowerCase().includes(filter.toLowerCase())
              );
              const create = group.create;
              return (
                <div key={group.title}>
                  <div className="px-2 py-1 mt-2 text-[10px] uppercase tracking-wide text-ide-textDim border-t border-ide-border flex items-center gap-1.5">
                    <span className="flex-1">
                      {group.title} · {rows.length}
                    </span>
                    {create && (
                      <button
                        onClick={() => addPort("input", create.seed)}
                        className="text-ide-status hover:underline"
                        title={create.title}
                        data-testid={`palette-create-${group.title}`}
                      >
                        {create.label}
                      </button>
                    )}
                  </div>
                  {rows.map((row) => (
                    <div
                      key={row.key}
                      data-testid={`palette-${row.name}`}
                      className="mx-2 mb-0.5 px-2 py-1 rounded hover:bg-ide-hover text-[11px] flex items-center gap-1.5"
                    >
                      <span
                        className="w-1.5 h-1.5 rounded-full shrink-0"
                        style={{ background: typeColor(row.type) }}
                      />
                      <button
                        onClick={() => focusPort(row.name)}
                        className="flex-1 truncate font-mono text-left"
                        title={row.title}
                      >
                        {row.name}
                      </button>
                      {row.badge && <span className="text-orange-400 text-[9px]">{row.badge}</span>}
                      <span className="text-ide-textDim">{row.type}</span>
                      {row.actions.length === 0 ? (
                        <button
                          onClick={() => focusPort(row.name)}
                          className="text-ide-textDim hover:underline"
                          title={t("graph.onPageHint")}
                        >
                          {t("graph.onPage")}
                        </button>
                      ) : (
                        row.actions.map((action) => (
                          <button
                            key={action.label}
                            onClick={() => addPort(action.direction, row.seed)}
                            className="text-ide-status hover:underline"
                            title={action.title}
                          >
                            {action.label}
                          </button>
                        ))
                      )}
                    </div>
                  ))}
                  {!rows.length && <p className="px-3 py-1 text-[10px] text-ide-textDim">{group.empty}</p>}
                  {group.note && <p className="px-3 pb-1 text-[10px] text-ide-textDim">{group.note}</p>}
                </div>
              );
            })}
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
                {t("graph.loading")}
              </div>
            )}
          </div>
          {sim?.ok && sim.timeline?.length ? (
            <SimTimeline run={sim} cycle={cycleIndex} stale={simStale} onCycle={setCycleIndex} />
          ) : null}
          {Object.keys(forcedPins).length > 0 && (
            <div className="shrink-0 px-3 py-1 bg-orange-700/30 border-t border-orange-600 text-[11px] text-orange-300 font-mono">
              {t("graph.forcedPins")} {Object.keys(forcedPins).length} {t("graph.forcedPinsMsg")}
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
            {t("graph.tabs.properties")}
          </div>
          {page && (
            <Inspector
              page={page}
              library={library}
              selected={selected}
              external={external}
              system={systemVars}
              station={station}
              onPage={patch}
              onDelete={removeSelection}
            />
          )}
          <div className="px-3 py-2 border-t border-ide-border text-[10px] uppercase tracking-wide text-ide-textDim">
            {t("graph.tabs.variables")}
          </div>
          {page && (
            <div className="px-2 pb-2 space-y-1">
              {(["input", "in_out", "output"] as PortDirection[]).map((direction) => (
                <div key={direction}>
                  <div className="flex items-center justify-between text-[10px] text-ide-textDim px-1">
                    <span>{direction === "input" ? t("graph.direction.input") : direction === "output" ? t("graph.direction.output") : t("graph.direction.inout")}</span>
                    <button onClick={() => addPort(direction)} className="hover:text-ide-text" title={t("graph.newVarPin")}>
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
                      {port.scope === "intermediate" && <span className="text-yellow-500">{t("graph.cross")}</span>}
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
