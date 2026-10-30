/**
 * The FC protocol as the editor sees it, plus the geometry that turns a pin of
 * a protocol element into a point on the sheet. Every wire end is computed
 * here so the canvas, the draft line and the hit-test cannot disagree.
 */

export type Scope = "external" | "intermediate" | "local";

export interface Position {
  x: number;
  y: number;
}

export interface Port {
  name: string;
  type: string;
  scope?: Scope;
  bind?: { station?: string; variable?: string };
  unit?: string;
  position?: Position;
}

export interface InterfaceDoc {
  input: Port[];
  output: Port[];
  in_out: Port[];
}

export interface ConstantNode {
  id: string;
  type: string;
  value: string | number | boolean;
  position: Position;
}

export interface BlockNode {
  id: string;
  type: string;
  library_id?: string;
  position: Position;
  parameters?: Record<string, string | number | boolean>;
}

export interface Endpoint {
  block: string;
  port: string;
}

export interface Connection {
  from: Endpoint;
  to: Endpoint;
}

export interface PageDoc {
  version: string;
  type: "FC";
  name: string;
  page: { id: string; label?: string; index?: number; sheet?: string };
  interface: InterfaceDoc;
  constants: ConstantNode[];
  blocks: BlockNode[];
  connections: Connection[];
}

export interface LibraryPin {
  name: string;
  type: string;
  default_value?: string | number | boolean | null;
}

export interface LibraryBlock {
  id: string;
  name: string;
  type?: string;
  category: string;
  version: string;
  description: string;
  block_kind?: string;
  time_based?: boolean;
  st_template?: string;
  icon_svg?: string;
  tags?: string[];
  sha256?: string;
  author?: string;
  created_at?: string;
  updated_at?: string;
  inputs: Record<string, unknown>[];
  outputs: Record<string, unknown>[];
  parameters: Record<string, unknown>[];
}

export interface Finding {
  severity: "error" | "warning" | "info";
  code: string;
  message: string;
  page: string;
  block: string;
  port: string;
}

export interface PageRow {
  id: string;
  index: number;
  label: string;
  sheet: string;
  name: string;
  blocks: number;
  constants: number;
  connections: number;
  ports: string[];
}

export interface CrossPageRow {
  name: string;
  type: string;
  scope: string;
  direction: string;
  pages: string[];
}

export interface CheckReport {
  ok: boolean;
  errors: Finding[];
  warnings: Finding[];
  infos: Finding[];
  pages: PageRow[];
  cross_page: CrossPageRow[];
  station?: string;
}

/** What the compiler measured for a chart that passed the checker. */
export interface AnalysisReport {
  ok: boolean;
  stage?: "checker" | "analysis" | "compile";
  exit_code?: number;
  errors?: Finding[];
  warnings?: Finding[];
  diagnostics?: DiagnosticRow[];
  image_bytes?: number;
  analysis?: {
    stack_depth: number;
    recursive_calls: boolean;
    estimated_wcet: number;
    loops_bounded: boolean;
  } | null;
  wcet?: {
    functions: { func_idx: number; cycles: number; ns: number }[];
    total_cycles: number;
    total_ns: number;
    cycle_limit_instructions?: number;
    station_cycle_ms?: number;
    budget_ns?: number;
    used_percent?: number;
    fits_cycle?: boolean;
    within_instruction_limit?: boolean;
  };
  memory?: {
    linear_memory_bytes: number;
    segments: { kind: string; start: number; bytes: number }[];
    by_kind: Record<string, { bytes: number; count: number; start: number }>;
    io_channels: number;
    symbols: number;
    global_slots: number;
    fb_fields: number;
    code_bytes: number;
    image_bytes: number;
  };
  sync_region?: {
    page_size: number;
    tracked_pages: number;
    page_limit: number;
    mandatory_pages: number[];
    mandatory_page_count: number;
    bytes_per_cycle: number;
    snapshot_header_bytes: number;
    worst_case_bytes: number;
    within_page_limit: boolean;
    note?: string;
  };
  safety?: { level: string; cycle_limit_instructions: number; loop_bounds: unknown[] };
  sections?: Record<string, number>;
  station?: { station_id: string; display_name?: string; cycle_ms: number };
}

export interface DiagnosticRow {
  severity: string;
  message: string;
  pou?: string | null;
  var?: string | null;
  kind?: string | null;
  loc?: string | null;
}

export interface ExternalVarRow {
  name: string;
  direction: string;
  st_type: string;
  io_kind?: string;
  unit?: string;
  description?: string;
  mapped?: boolean;
  has_quality?: boolean;
}

/** One watched symbol: the timeline the frames answered for it. */
export interface SymbolSeries {
  name: string;
  addr: number;
  type: string;
  size: number;
  channel: number | null;
  values: (number | null)[];
  raw: (number | string | null)[];
  /** Per cycle: the value was overridden from outside the program (protocol 4.3). */
  forced: boolean[];
}

/**
 * One immediate override as the engineer states it: the symbol pinned and the
 * value typed in. `on` keeps a row in the list without sending it, so a
 * stimulus can be set aside and brought back without retyping it.
 */
export interface ForceRow {
  id: string;
  name: string;
  value: string;
  on: boolean;
}

/** One test-script record: the cycle it lands on and what to set there. */
export interface ScriptRow {
  id: string;
  cycle: number;
  name: string;
  value: string;
  on: boolean;
}

export interface CycleRow {
  cycle: number;
  t_ms: number;
  status: number;
  violations: number;
}

/** Which symbol carries a pin's value; the backend names it, the editor only reads. */
export interface PinRow {
  page: string;
  element: string;
  port: string;
  direction: "input" | "output";
  type: string;
  block_kind?: string;
  kind: "symbol" | "constant" | "unconnected" | "unwatchable";
  symbol: string | null;
  literal: string | null;
}

/** What `POST /sim/run` answers: the frames, the object table they came from, the pins. */
export interface SimRun {
  ok: boolean;
  stage?: "checker" | "plant" | "compile" | "watch" | "simulate";
  errors?: string[] | Finding[];
  warnings?: Finding[];
  diagnostics?: DiagnosticRow[];
  cycles?: number;
  cycle_ms?: number;
  runs?: number;
  done?: { frame: string; cycles: number; t_ms: number; violations: number; read_errors: number; write_errors: number };
  timeline?: CycleRow[];
  symbols?: SymbolSeries[];
  pins?: PinRow[];
  plant?: { name: string; text: string };
  station?: { station_id: string; cycle_ms: number; display_name?: string };
}

export const INTERFACE = "__interface__";

/** A3 landscape at 96 dpi is the default drawing field. */
export const SHEETS: Record<string, { w: number; h: number; label: string }> = {
  A4: { w: 1169, h: 827, label: "A4 横向" },
  A3: { w: 1587, h: 1123, label: "A3 横向" },
  A2: { w: 2234, h: 1580, label: "A2 横向" },
};

export const NODE_W = 168;
export const HEAD_H = 26;
export const ROW_H = 22;
export const CONST_W = 118;
export const CONST_H = 34;
export const PORT_W = 150;
export const PORT_H = 26;
export const FRAME = 24;
export const PORT_GAP = 14;

export type PortDirection = "input" | "output" | "in_out";

/**
 * A port that was never moved sits in its declaration column: the page feeds
 * the drawing from the left edge and takes its results off the right edge,
 * which is how a signal-flow sheet is read.
 */
export function defaultPortPosition(
  sheet: string,
  direction: PortDirection,
  index: number
): Position {
  const y = FRAME + 96 + index * (PORT_H + PORT_GAP);
  const width = SHEETS[sheet]?.w ?? SHEETS.A3.w;
  if (direction === "output") {
    return { x: width - FRAME - 40 - PORT_W, y };
  }
  const offset = direction === "in_out" ? 100 : 0;
  return { x: FRAME + 40, y: y + offset };
}

export function portAt(page: PageDoc, direction: PortDirection, index: number): Port {
  return page.interface[direction][index];
}

export function portPosition(page: PageDoc, direction: PortDirection, index: number): Position {
  const port = portAt(page, direction, index);
  return port.position ?? defaultPortPosition(page.page.sheet ?? "A3", direction, index);
}

export const TYPE_COLORS: Record<string, string> = {
  BOOL: "#c586c0",
  QBOOL: "#b5cea8",
  BYTE: "#dcdcaa",
  WORD: "#dcdcaa",
  DWORD: "#dcdcaa",
  SINT: "#569cd6",
  INT: "#569cd6",
  DINT: "#4fc1ff",
  LINT: "#4fc1ff",
  REAL: "#4ec9b0",
  LREAL: "#3bc9b0",
  QREAL: "#89d185",
  QINT: "#9cdcfe",
  QDINT: "#9cdcfe",
  TIME: "#ce9178",
  STRING: "#ce9178",
};

export function typeColor(stType: string): string {
  return TYPE_COLORS[stType] ?? "#cccccc";
}

export interface Pins {
  inputs: LibraryPin[];
  outputs: LibraryPin[];
}

export function pinsOf(block: BlockNode, library: Record<string, LibraryBlock>): Pins {
  const def = library[block.library_id || block.type] || library[block.type];
  if (!def) return { inputs: [], outputs: [] };
  const map = (rows: Record<string, unknown>[]): LibraryPin[] =>
    rows.map((r) => ({
      name: String(r.name),
      type: String(r.data_type ?? r.type ?? "REAL"),
      default_value: (r.default_value ?? null) as string | number | boolean | null,
    }));
  return { inputs: map(def.inputs || []), outputs: map(def.outputs || []) };
}

export function blockHeight(pins: Pins): number {
  return HEAD_H + Math.max(1, pins.inputs.length, pins.outputs.length) * ROW_H + 8;
}

/** One entry per drawable thing that can carry a wire end. */
export type NodeKind = "block" | "constant" | "port";

export interface PinPoint extends Endpoint {
  x: number;
  y: number;
  kind: NodeKind;
  type: string;
  direction: "input" | "output";
}

/**
 * Every pin of every element on the page, in sheet coordinates.
 *
 * Interface ports are drawn as connector boxes: an input port exposes its pin
 * on the right (it feeds the page), an output port on the left (the page writes
 * it), an in_out port on both sides.
 */
export function pinMap(page: PageDoc, library: Record<string, LibraryBlock>): PinPoint[] {
  const points: PinPoint[] = [];

  page.blocks.forEach((block) => {
    const pins = pinsOf(block, library);
    const height = blockHeight(pins);
    pins.inputs.forEach((pin, i) =>
      points.push({
        block: block.id,
        port: pin.name,
        x: block.position.x,
        y: block.position.y + HEAD_H + i * ROW_H + ROW_H / 2,
        kind: "block",
        type: pin.type,
        direction: "input",
      })
    );
    pins.outputs.forEach((pin, i) =>
      points.push({
        block: block.id,
        port: pin.name,
        x: block.position.x + NODE_W,
        y: block.position.y + HEAD_H + i * ROW_H + ROW_H / 2,
        kind: "block",
        type: pin.type,
        direction: "output",
      })
    );
    if (!pins.inputs.length && !pins.outputs.length) {
      points.push({
        block: block.id,
        port: "IN",
        x: block.position.x,
        y: block.position.y + height / 2,
        kind: "block",
        type: "REAL",
        direction: "input",
      });
    }
  });

  page.constants.forEach((constant) => {
    points.push({
      block: constant.id,
      port: "OUT",
      x: constant.position.x + CONST_W,
      y: constant.position.y + CONST_H / 2,
      kind: "constant",
      type: constant.type,
      direction: "output",
    });
  });

  const interfaceRows = (
    ["input", "output", "in_out"] as PortDirection[]
  ).flatMap((direction) =>
    page.interface[direction].map((port, index) => ({
      port,
      direction,
      at: portPosition(page, direction, index),
    }))
  );
  interfaceRows.forEach(({ port, direction, at }) => {
    if (direction !== "output") {
      points.push({
        block: INTERFACE,
        port: port.name,
        x: at.x + PORT_W,
        y: at.y + PORT_H / 2,
        kind: "port",
        type: port.type,
        direction: "output",
      });
    }
    if (direction !== "input") {
      points.push({
        block: INTERFACE,
        port: port.name,
        x: at.x,
        y: at.y + PORT_H / 2,
        kind: "port",
        type: port.type,
        direction: "input",
      });
    }
  });

  return points;
}

export function pinKey(endpoint: Endpoint): string {
  return `${endpoint.block}.${endpoint.port}`;
}

/** A wire may only join an output to an input. */
export function connectable(a: PinPoint, b: PinPoint): boolean {
  if (a.block === b.block && a.port === b.port) return false;
  if (pinKey(a) === pinKey(b)) return false;
  return a.direction !== b.direction;
}

export function otherSide(a: PinPoint, b: PinPoint): [PinPoint, PinPoint] {
  return a.direction === "output" ? [a, b] : [b, a];
}

export function portPath(from: Position, to: Position): string {
  const dx = Math.max(40, Math.abs(to.x - from.x) / 2);
  return `M ${from.x} ${from.y} C ${from.x + dx} ${from.y}, ${to.x - dx} ${to.y}, ${to.x} ${to.y}`;
}

export function emptyPage(id: string, name = "MAIN", index = 0, sheet = "A3"): PageDoc {
  return {
    version: "1.1",
    type: "FC",
    name,
    page: { id, label: id, index, sheet },
    interface: { input: [], output: [], in_out: [] },
    constants: [],
    blocks: [],
    connections: [],
  };
}

export type Selection =
  | { kind: "block"; id: string }
  | { kind: "constant"; id: string }
  | { kind: "port"; direction: PortDirection; name: string }
  | { kind: "wire"; index: number }
  | null;

function sameEndpoint(a: Endpoint, b: Endpoint): boolean {
  return a.block === b.block && a.port === b.port;
}

/** Deleting an element also drops every wire that ended on it. */
export function deleteSelection(page: PageDoc, sel: Selection): PageDoc {
  if (!sel) return page;
  const gone = (endpoint: Endpoint): boolean => {
    if (sel.kind === "block" || sel.kind === "constant") return endpoint.block === sel.id;
    if (sel.kind === "wire") return false;
    return sel.kind === "port" && endpoint.block === INTERFACE && endpoint.port === sel.name;
  };

  const dropPort = (direction: PortDirection) =>
    sel.kind === "port" && sel.direction === direction
      ? page.interface[direction].filter((port) => port.name !== sel.name)
      : page.interface[direction];

  return {
    ...page,
    blocks: sel.kind === "block" ? page.blocks.filter((block) => block.id !== sel.id) : page.blocks,
    constants:
      sel.kind === "constant" ? page.constants.filter((c) => c.id !== sel.id) : page.constants,
    interface: {
      input: dropPort("input"),
      output: dropPort("output"),
      in_out: dropPort("in_out"),
    },
    connections:
      sel.kind === "wire"
        ? page.connections.filter((_, index) => index !== sel.index)
        : page.connections.filter((conn) => !gone(conn.from) && !gone(conn.to)),
  };
}

export function wiresOn(page: PageDoc, endpoint: Endpoint): number {
  return page.connections.filter((conn) => sameEndpoint(conn.from, endpoint) || sameEndpoint(conn.to, endpoint)).length;
}

/** An input pin already driven cannot take a second source. */
export function driverOn(page: PageDoc, input: Endpoint): boolean {
  return page.connections.some((conn) => sameEndpoint(conn.to, input));
}

export function sameConnection(a: Connection, from: Endpoint, to: Endpoint): boolean {
  return sameEndpoint(a.from, from) && sameEndpoint(a.to, to);
}

/** How a watched value reads on a pin: a level for a boolean, a number otherwise. */
export function formatValue(stType: string, value: number | string | null): string {
  if (value === null || value === undefined) return "—";
  if (typeof value === "string") return value;
  if (stType.includes("BOOL")) return value !== 0 ? "TRUE" : "FALSE";
  if (stType.includes("REAL")) {
    return Number(value)
      .toPrecision(6)
      .replace(/(\.\d*?)0+$/, "$1")
      .replace(/\.$/, "");
  }
  return String(value);
}

/**
 * The text each pin of one sheet shows at one cycle of a run.
 *
 * A pin is only ever labelled by the symbol the backend named for it; a pin
 * whose symbol no frame answered for stays blank rather than guessing.
 */
export function pinValues(run: SimRun | null, pageId: string, cycle: number): Record<string, string> {
  const table: Record<string, string> = {};
  if (!run?.pins || !run.symbols) return table;
  const series = new Map(run.symbols.map((row) => [row.name, row]));
  run.pins.forEach((pin) => {
    if (pin.page !== pageId) return;
    const key = pinKey({ block: pin.element, port: pin.port });
    if (pin.kind === "constant") {
      if (pin.literal !== null) table[key] = pin.literal;
      return;
    }
    const row = pin.kind === "symbol" ? series.get(pin.symbol ?? "") : undefined;
    if (row) table[key] = formatValue(row.type, row.values[cycle] ?? null);
  });
  return table;
}

/**
 * Which pins show a value that a frame marked as overridden at this cycle.
 *
 * The marking is the frame's own `forced` key, never a comparison with the
 * force list: a value only counts as forced where the runner says it was.
 */
export function pinForced(run: SimRun | null, pageId: string, cycle: number): Record<string, boolean> {
  const table: Record<string, boolean> = {};
  if (!run?.pins || !run.symbols) return table;
  const series = new Map(run.symbols.map((row) => [row.name, row]));
  run.pins.forEach((pin) => {
    if (pin.page !== pageId || pin.kind !== "symbol") return;
    const row = series.get(pin.symbol ?? "");
    if (row?.forced?.[cycle] === true) table[pinKey({ block: pin.element, port: pin.port })] = true;
  });
  return table;
}

/** A row is only sent when it names a symbol and carries a value. */
function usable(row: ForceRow | ScriptRow): boolean {
  return row.on && row.name.trim() !== "" && row.value.trim() !== "";
}

/** The two stimulus lists of a run request, in the shapes protocol 5 defines. */
export function stimulusPayload(forces: ForceRow[], script: ScriptRow[]) {
  return {
    forces: forces.filter(usable).map((row) => ({ name: row.name.trim(), value: row.value.trim() })),
    script: script
      .filter(usable)
      .map((row) => ({ cycle: row.cycle, name: row.name.trim(), value: row.value.trim() })),
  };
}

/** A run request body: the station, the scan count and whatever stimulus is switched on. */
export function simRunBody(
  station: string,
  cycles: number,
  forces: ForceRow[],
  script: ScriptRow[]
): Record<string, unknown> {
  return { station: station || null, cycles, ...stimulusPayload(forces, script) };
}

/** Rows are edited, not persisted, so a session-local key is all an id has to be. */
let stimulusSequence = 0;
export function newStimulusId(prefix: "force" | "script"): string {
  stimulusSequence += 1;
  return `${prefix}${stimulusSequence}`;
}

/** A force row for a symbol the engineer just saw on a pin, seeded with its value. */
export function makeForceRow(name: string, value: string): ForceRow {
  return { id: newStimulusId("force"), name, value, on: true };
}

/** A script record that lands after the last one, so a list reads as a sequence. */
export function makeScriptRow(name: string, cycle: number, value: string): ScriptRow {
  return { id: newStimulusId("script"), name, cycle: Math.max(1, cycle), value, on: true };
}
