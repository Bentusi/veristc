import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  CONST_H,
  CONST_W,
  FRAME,
  HEAD_H,
  INTERFACE,
  NODE_W,
  PORT_H,
  PORT_W,
  ROW_H,
  SHEETS,
  type ConstantNode,
  type Finding,
  type LibraryBlock,
  type PageDoc,
  type PinPoint,
  type PortDirection,
  type Position,
  type Selection,
  blockHeight,
  connectable,
  driverOn,
  otherSide,
  pinKey,
  pinMap,
  pinsOf,
  portPath,
  portPosition,
  sameConnection,
  typeColor,
} from "./types";

const GRID = 10;
const HIT_RADIUS = 16;
const ZONE_STEP = 200;
const TITLE_BLOCK = { w: 300, h: 60 };

interface DragState {
  kind: "block" | "constant" | "port";
  id: string;
  direction?: PortDirection;
  index?: number;
  width: number;
  height: number;
  grab: Position;
  origin: Position;
}

interface DraftState {
  from: PinPoint;
  cur: Position;
  target: PinPoint | null;
}

export interface SheetProps {
  page: PageDoc;
  library: Record<string, LibraryBlock>;
  marks: Record<string, Finding[]>;
  values: Record<string, string>;
  /** Pins whose displayed value a frame reported as overridden at this cycle. */
  forced?: Record<string, boolean>;
  selected: Selection;
  zoom: number;
  focus?: Position | null;
  onSelect: (selection: Selection) => void;
  onPage: (mutate: (page: PageDoc) => PageDoc) => void;
  onDropBlock: (payload: { library_id: string; type: string }, at: Position) => void;
}

function grid(value: number): number {
  return Math.round(value / GRID) * GRID;
}

/** Keep the pointer with the element being dragged; a released pointer must not abort the gesture. */
function capture(event: React.PointerEvent) {
  try {
    (event.currentTarget as Element).setPointerCapture?.(event.pointerId);
  } catch {
    /* the pointer is already gone */
  }
}

function worstFinding(findings: Finding[] | undefined): Finding | undefined {
  if (!findings?.length) return undefined;
  return (
    findings.find((finding) => finding.severity === "error") ??
    findings.find((finding) => finding.severity === "warning")
  );
}

function markColor(findings: Finding[] | undefined): string | undefined {
  const worst = worstFinding(findings);
  if (!worst) return undefined;
  return worst.severity === "error" ? "#f14c4c" : "#cca700";
}

/** The border, the zone marks and the title block of an A-series drawing. */
function DrawingFrame({ page }: { page: PageDoc }) {
  const sheet = SHEETS[page.page.sheet ?? "A3"] ?? SHEETS.A3;
  const innerW = sheet.w - 2 * FRAME;
  const innerH = sheet.h - 2 * FRAME;
  const columns = Math.max(1, Math.floor(innerW / ZONE_STEP));
  const rows = Math.max(1, Math.floor(innerH / ZONE_STEP));
  const marks: React.ReactNode[] = [];

  for (let index = 1; index <= columns; index += 1) {
    const centre = FRAME + (innerW / columns) * (index - 0.5);
    marks.push(
      <g key={`column${index}`}>
        <line
          x1={centre - innerW / columns / 2}
          y1={sheet.h - FRAME}
          x2={centre + innerW / columns / 2}
          y2={sheet.h - FRAME}
          stroke="#3c3c3c"
        />
        <text x={centre} y={sheet.h - FRAME - 5} textAnchor="middle" fontSize="10" fill="#5b5b60">
          {index}
        </text>
      </g>
    );
  }
  for (let index = 1; index <= rows; index += 1) {
    const centre = FRAME + (innerH / rows) * (index - 0.5);
    marks.push(
      <text key={`row${index}`} x={FRAME + 6} y={centre + 3} fontSize="10" fill="#5b5b60">
        {"ABCDEFGH"[index - 1]}
      </text>
    );
  }

  return (
    <g pointerEvents="none">
      <rect x={FRAME - 6} y={FRAME - 6} width={innerW + 12} height={innerH + 12} fill="none" stroke="#3c3c3c" strokeWidth={2} />
      <rect x={FRAME} y={FRAME} width={innerW} height={innerH} fill="url(#sheet-grid)" stroke="#484852" />
      {marks}
      <g transform={`translate(${sheet.w - FRAME - TITLE_BLOCK.w}, ${sheet.h - FRAME - TITLE_BLOCK.h})`}>
        <rect width={TITLE_BLOCK.w} height={TITLE_BLOCK.h} fill="#1f1f21" stroke="#484852" />
        <line y1={22} x2={TITLE_BLOCK.w} y2={22} stroke="#3c3c3c" />
        <line x1={TITLE_BLOCK.w - 104} y1={22} x2={TITLE_BLOCK.w - 104} y2={TITLE_BLOCK.h} stroke="#3c3c3c" />
        <text x={8} y={15} fontSize="11" fill="#dcdcdc">
          {page.name}
        </text>
        <text x={8} y={38} fontSize="10" fill="#9a9a9a">
          图页 {page.page.label || page.page.id} · 第 {(page.page.index ?? 0) + 1} 页
        </text>
        <text x={8} y={52} fontSize="10" fill="#9a9a9a">
          {page.blocks.length} 块 · {page.connections.length} 线 · {page.interface.input.length + page.interface.output.length + page.interface.in_out.length} 变量
        </text>
        <text x={TITLE_BLOCK.w - 96} y={38} fontSize="10" fill="#9a9a9a">
          {page.page.sheet ?? "A3"} 横向
        </text>
        <text x={TITLE_BLOCK.w - 96} y={52} fontSize="10" fill="#6a9955">
          VeriIDE
        </text>
      </g>
    </g>
  );
}

function PinDot({ pin, findings, onGrab }: { pin: PinPoint; findings?: Finding[]; onGrab: (event: React.PointerEvent, pin: PinPoint) => void }) {
  const ring = markColor(findings);
  const worst = worstFinding(findings);
  return (
    <g>
      <circle
        cx={pin.x}
        cy={pin.y}
        r={5}
        fill={typeColor(pin.type)}
        stroke="#141414"
        strokeWidth={1}
        style={{ cursor: "crosshair" }}
        onPointerDown={(event) => onGrab(event, pin)}
      />
      {ring && (
        <circle cx={pin.x} cy={pin.y} r={10} fill="none" stroke={ring} strokeWidth={2} pointerEvents="none">
          {worst && <title>{`${worst.code}: ${worst.message}`}</title>}
        </circle>
      )}
    </g>
  );
}

/**
 * The value one pin showed at the cycle being replayed.
 *
 * A forced value is drawn in a different colour and prefixed with `F`: reading an
 * override as a computed result is the classic way to certify a chart that does
 * not behave. The mark comes from the frame's own `forced` key, never from the
 * editor's idea of what was overridden.
 */
function PinValue({ pin, text, forced }: { pin: PinPoint; text: string; forced: boolean }) {
  const outward = pin.direction === "input" ? -6 : 6;
  return (
    <text
      x={pin.x + outward}
      y={pin.y + 3.5}
      textAnchor={pin.direction === "input" ? "end" : "start"}
      fontSize="9.5"
      fontFamily="ui-monospace, monospace"
      fill={forced ? "#ff7a45" : "#3ddc97"}
      fontWeight={forced ? "bold" : "normal"}
      stroke="#141414"
      strokeWidth={2.5}
      paintOrder="stroke"
      pointerEvents="none"
    >
      {forced ? `F ${text}` : text}
    </text>
  );
}

export function Sheet({ page, library, marks, values, forced, selected, zoom, focus, onSelect, onPage, onDropBlock }: SheetProps) {
  const svgRef = useRef<SVGSVGElement>(null);
  const scrollRef = useRef<HTMLDivElement>(null);
  const [drag, setDrag] = useState<DragState | null>(null);
  const [draft, setDraft] = useState<DraftState | null>(null);
  const sheet = SHEETS[page.page.sheet ?? "A3"] ?? SHEETS.A3;

  useEffect(() => {
    const box = scrollRef.current;
    if (!box || !focus) return;
    box.scrollTo({
      left: Math.max(0, focus.x * zoom - box.clientWidth / 2),
      top: Math.max(0, focus.y * zoom - box.clientHeight / 2),
      behavior: "smooth",
    });
  }, [focus, zoom]);

  const pins = useMemo(() => pinMap(page, library), [page, library]);
  const pinAt = useMemo(() => {
    const index = new Map<string, PinPoint>();
    pins.forEach((pin) => index.set(pinKey(pin), pin));
    return index;
  }, [pins]);

  const toSheet = useCallback(
    (event: { clientX: number; clientY: number }): Position => {
      const rect = svgRef.current?.getBoundingClientRect();
      if (!rect) return { x: 0, y: 0 };
      return { x: (event.clientX - rect.left) / zoom, y: (event.clientY - rect.top) / zoom };
    },
    [zoom]
  );

  const grabElement = (event: React.PointerEvent, item: Omit<DragState, "grab" | "origin">, origin: Position) => {
    event.stopPropagation();
    capture(event);
    setDrag({ ...item, grab: toSheet(event), origin });
    onSelect(
      item.kind === "block"
        ? { kind: "block", id: item.id }
        : item.kind === "constant"
          ? { kind: "constant", id: item.id }
          : { kind: "port", direction: item.direction ?? "input", name: item.id }
    );
  };

  const grabPin = (event: React.PointerEvent, pin: PinPoint) => {
    event.stopPropagation();
    capture(event);
    onSelect(null);
    setDraft({ from: pin, cur: { x: pin.x, y: pin.y }, target: null });
  };

  const commitDraft = (start: PinPoint, target: PinPoint) => {
    const [from, to] = otherSide(start, target);
    const source = { block: from.block, port: from.port };
    const sink = { block: to.block, port: to.port };
    onPage((doc) => {
      if (doc.connections.some((conn) => sameConnection(conn, source, sink))) return doc;
      // An input that already had a source is re-wired rather than double-driven.
      const kept = driverOn(doc, sink)
        ? doc.connections.filter((conn) => !sameConnection(conn, conn.from, sink))
        : doc.connections;
      return { ...doc, connections: [...kept, { from: source, to: sink }] };
    });
  };

  const moveElement = (event: React.PointerEvent, current: DragState) => {
    const at = toSheet(event);
    const width = current.kind === "port" ? PORT_W : current.width;
    const height = current.kind === "port" ? PORT_H : current.height;
    const next = {
      x: Math.min(Math.max(grid(current.origin.x + (at.x - current.grab.x)), FRAME + GRID), sheet.w - FRAME - GRID - width),
      y: Math.min(Math.max(grid(current.origin.y + (at.y - current.grab.y)), FRAME + GRID), sheet.h - FRAME - GRID - height),
    };
    if (current.kind === "port" && current.direction && current.index !== undefined) {
      const { direction, index } = current;
      const position = next;
      onPage((doc) => ({
        ...doc,
        interface: {
          ...doc.interface,
          [direction]: doc.interface[direction].map((port, i) => (i === index ? { ...port, position } : port)),
        },
      }));
      return;
    }
    if (current.kind === "constant") {
      const id = current.id;
      onPage((doc) => ({ ...doc, constants: doc.constants.map((item) => (item.id === id ? { ...item, position: next } : item)) }));
      return;
    }
    const id = current.id;
    onPage((doc) => ({ ...doc, blocks: doc.blocks.map((item) => (item.id === id ? { ...item, position: next } : item)) }));
  };

  const moveDraft = (event: React.PointerEvent, current: DraftState) => {
    const at = toSheet(event);
    let target: PinPoint | null = null;
    let radius = HIT_RADIUS;
    pins.forEach((pin) => {
      if (!connectable(current.from, pin)) return;
      const distance = Math.hypot(pin.x - at.x, pin.y - at.y);
      if (distance < radius) {
        radius = distance;
        target = pin;
      }
    });
    setDraft({ ...current, cur: at, target });
  };

  const handleMove = (event: React.PointerEvent) => {
    if (draft) moveDraft(event, draft);
    else if (drag) moveElement(event, drag);
  };

  const handleUp = () => {
    if (draft?.target) commitDraft(draft.from, draft.target);
    setDraft(null);
    setDrag(null);
  };

  const handleDrop = (event: React.DragEvent) => {
    event.preventDefault();
    const payload = event.dataTransfer.getData("application/x-veri-block");
    if (!payload) return;
    const at = toSheet(event);
    try {
      onDropBlock(JSON.parse(payload) as { library_id: string; type: string }, { x: grid(at.x), y: grid(at.y) });
    } catch {
      /* a foreign drag payload is not ours to read */
    }
  };

  return (
    <div
      ref={scrollRef}
      className="overflow-auto"
      style={{ width: "100%", height: "100%", background: "#141414" }}
      onDragOver={(event) => event.preventDefault()}
      onDrop={handleDrop}
    >
      <svg
        ref={svgRef}
        width={sheet.w * zoom}
        height={sheet.h * zoom}
        viewBox={`0 0 ${sheet.w} ${sheet.h}`}
        style={{ display: "block", touchAction: "none", cursor: draft ? "crosshair" : "default" }}
        onPointerMove={handleMove}
        onPointerUp={handleUp}
        onPointerDown={() => {
          onSelect(null);
          setDraft(null);
          setDrag(null);
        }}
      >
        <defs>
          <pattern id="sheet-grid" width={GRID} height={GRID} patternUnits="userSpaceOnUse">
            <rect width={GRID} height={GRID} fill="#1b1b1c" />
            <path d={`M ${GRID} 0 L 0 0 0 ${GRID}`} fill="none" stroke="#232327" strokeWidth={0.6} />
          </pattern>
          <marker id="wire-head" viewBox="0 0 10 10" refX={8} refY={5} markerWidth={6} markerHeight={6} orient="auto-start-reverse">
            <path d="M 0 0 L 10 5 L 0 10 z" fill="#b4b4b4" />
          </marker>
        </defs>

        <DrawingFrame page={page} />

        {page.connections.map((conn, index) => {
          const from = pinAt.get(pinKey(conn.from));
          const to = pinAt.get(pinKey(conn.to));
          if (!from || !to) return null;
          const isSelected = selected?.kind === "wire" && selected.index === index;
          const path = portPath(from, to);
          return (
            <g key={`wire${index}`}>
              <path d={path} fill="none" stroke={isSelected ? "#007acc" : typeColor(from.type)} strokeWidth={isSelected ? 3 : 1.8} markerEnd="url(#wire-head)" />
              <path
                d={path}
                fill="none"
                stroke="#000000"
                strokeOpacity={0}
                strokeWidth={12}
                style={{ cursor: "pointer" }}
                onPointerDown={(event) => {
                  event.stopPropagation();
                  onSelect({ kind: "wire", index });
                }}
              />
            </g>
          );
        })}

        {(["input", "output", "in_out"] as PortDirection[]).flatMap((direction) =>
          page.interface[direction].map((port, index) => {
            const at = portPosition(page, direction, index);
            const isSelected =
              selected?.kind === "port" && selected.direction === direction && selected.name === port.name;
            const ring = markColor(marks[`${INTERFACE}.${port.name}`]);
            const scope = port.scope ?? "external";
            const accent = ring ?? (scope === "intermediate" ? "#cca700" : scope === "local" ? "#8f8f8f" : "#007acc");
            return (
              <g
                key={`port${direction}${port.name}${index}`}
                transform={`translate(${at.x}, ${at.y})`}
                style={{ cursor: "move" }}
                onPointerDown={(event) =>
                  grabElement(event, { kind: "port", id: port.name, direction, index, width: PORT_W, height: PORT_H }, at)
                }
              >
                <rect
                  width={PORT_W}
                  height={PORT_H}
                  rx={3}
                  fill={isSelected ? "#37373d" : "#252526"}
                  stroke={isSelected ? "#007acc" : accent}
                  strokeWidth={isSelected ? 2 : 1.2}
                  strokeDasharray={scope === "intermediate" ? "5 3" : undefined}
                />
                <text x={direction === "output" ? 8 : 12} y={PORT_H / 2 + 4} fontSize="10.5" fill="#dcdcaa" pointerEvents="none">
                  {port.name}
                </text>
                <text
                  x={direction === "output" ? PORT_W - 12 : PORT_W - 6}
                  y={PORT_H / 2 + 4}
                  textAnchor="end"
                  fontSize="9"
                  fill={typeColor(port.type)}
                  pointerEvents="none"
                >
                  {port.type}
                </text>
                {port.bind?.variable && (
                  <text x={0} y={PORT_H + 11} fontSize="8.5" fill="#6a9955" pointerEvents="none">
                    ⚙ {port.bind.variable}
                  </text>
                )}
              </g>
            );
          })
        )}

        {page.constants.map((constant: ConstantNode) => {
          const isSelected = selected?.kind === "constant" && selected.id === constant.id;
          const ring = markColor(marks[`${constant.id}.OUT`]);
          return (
            <g
              key={constant.id}
              transform={`translate(${constant.position.x}, ${constant.position.y})`}
              style={{ cursor: "move" }}
              onPointerDown={(event) =>
                grabElement(event, { kind: "constant", id: constant.id, width: CONST_W, height: CONST_H }, constant.position)
              }
            >
              <rect
                width={CONST_W}
                height={CONST_H}
                rx={3}
                fill={isSelected ? "#37373d" : "#252526"}
                stroke={isSelected ? "#007acc" : ring ?? typeColor(constant.type)}
                strokeWidth={isSelected ? 2 : 1.3}
              />
              <text x={8} y={CONST_H / 2 + 4} fontSize="11" fill={typeColor(constant.type)} fontFamily="ui-monospace, monospace" pointerEvents="none">
                {String(constant.value)}
              </text>
              <text x={CONST_W - 6} y={CONST_H / 2 + 4} textAnchor="end" fontSize="8.5" fill="#8f8f8f" pointerEvents="none">
                {constant.type}
              </text>
            </g>
          );
        })}

        {page.blocks.map((block) => {
          const def = library[block.library_id || block.type] ?? library[block.type];
          const table = pinsOf(block, library);
          const height = blockHeight(table);
          const isSelected = selected?.kind === "block" && selected.id === block.id;
          const accent = markColor(
            [...table.inputs, ...table.outputs].flatMap((pin) => marks[`${block.id}.${pin.name}`] ?? [])
          );
          return (
            <g
              key={block.id}
              transform={`translate(${block.position.x}, ${block.position.y})`}
              style={{ cursor: "move" }}
              onPointerDown={(event) =>
                grabElement(event, { kind: "block", id: block.id, width: NODE_W, height }, block.position)
              }
            >
              <rect width={NODE_W} height={height} rx={4} fill={isSelected ? "#2d2d31" : "#252526"} stroke={isSelected ? "#007acc" : accent ?? "#585b70"} strokeWidth={isSelected || accent ? 2 : 1.4} />
              <rect width={NODE_W} height={HEAD_H} rx={4} fill={isSelected ? "#007acc" : "#3c3c46"} opacity={0.35} />
              <text x={8} y={HEAD_H / 2 + 4} fontSize="11" fontWeight="600" fill="#e8e8e8" pointerEvents="none">
                {block.id}
              </text>
              <text x={NODE_W - 8} y={HEAD_H / 2 + 4} textAnchor="end" fontSize="9.5" fill="#b8b8c4" pointerEvents="none">
                {def?.name ?? block.type}
              </text>
              {table.inputs.map((pin, index) => (
                <text
                  key={pin.name}
                  x={13}
                  y={HEAD_H + index * ROW_H + ROW_H / 2 + 3.5}
                  fontSize="10"
                  fill={markColor(marks[`${block.id}.${pin.name}`]) ?? "#cfcfcf"}
                  pointerEvents="none"
                >
                  {pin.name}
                </text>
              ))}
              {table.outputs.map((pin, index) => (
                <text
                  key={pin.name}
                  x={NODE_W - 13}
                  y={HEAD_H + index * ROW_H + ROW_H / 2 + 3.5}
                  textAnchor="end"
                  fontSize="10"
                  fill={markColor(marks[`${block.id}.${pin.name}`]) ?? "#cfcfcf"}
                  pointerEvents="none"
                >
                  {pin.name}
                </text>
              ))}
              {!table.inputs.length && !table.outputs.length && (
                <text x={NODE_W / 2} y={HEAD_H + 16} textAnchor="middle" fontSize="9" fill="#8f8f8f" pointerEvents="none">
                  库中无引脚定义
                </text>
              )}
              {Object.keys(block.parameters ?? {}).length > 0 && (
                <text x={8} y={height - 5} fontSize="8.5" fill="#8f8f8f" pointerEvents="none">
                  {Object.entries(block.parameters ?? {})
                    .map(([key, value]) => `${key}=${value}`)
                    .join(" ")}
                </text>
              )}
            </g>
          );
        })}

        {pins.map((pin) => {
          const text = values[pinKey(pin)];
          return text ? (
            <PinValue
              key={`value${pinKey(pin)}${pin.direction}`}
              pin={pin}
              text={text}
              forced={forced?.[pinKey(pin)] === true}
            />
          ) : null;
        })}

        {pins.map((pin) => (
          <PinDot
            key={`${pinKey(pin)}${pin.direction}`}
            pin={pin}
            findings={marks[`${pin.block}.${pin.port}`]}
            onGrab={grabPin}
          />
        ))}

        {draft && (
          <g pointerEvents="none">
            <path
              d={portPath(draft.from, draft.target ?? draft.cur)}
              fill="none"
              stroke={draft.target ? typeColor(draft.target.type) : "#8f8f8f"}
              strokeWidth={2}
              strokeDasharray={draft.target ? undefined : "6 4"}
              markerEnd="url(#wire-head)"
            />
            {draft.target && <circle cx={draft.target.x} cy={draft.target.y} r={9} fill="none" stroke="#007acc" strokeWidth={2} />}
          </g>
        )}
      </svg>
    </div>
  );
}

export type { DraftState };
