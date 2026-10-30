import type {
  BlockNode,
  ConstantNode,
  ExternalVarRow,
  LibraryBlock,
  PageDoc,
  Port,
  PortDirection,
  Selection,
} from "./types";
import { INTERFACE, pinsOf, typeColor } from "./types";

export interface InspectorProps {
  page: PageDoc;
  library: Record<string, LibraryBlock>;
  selected: Selection;
  external: ExternalVarRow[];
  station: string;
  onPage: (mutate: (page: PageDoc) => PageDoc) => void;
  onDelete: () => void;
}

const SCOPES: { value: string; label: string }[] = [
  { value: "external", label: "外部变量（关联设备）" },
  { value: "intermediate", label: "中间变量（跨页跳转）" },
  { value: "local", label: "局部变量（本页临时）" },
];

const ST_TYPES = ["BOOL", "BYTE", "WORD", "DWORD", "SINT", "INT", "DINT", "LINT", "REAL", "LREAL", "TIME", "QBOOL", "QINT", "QDINT", "QREAL", "STRING"];

const field = "w-full bg-ide-bg border border-ide-border rounded px-2 py-1 text-xs text-ide-text font-mono";
const label = "text-[10px] uppercase tracking-wide text-ide-textDim mb-1 block";

/**
 * Editing an element rewrites the page document, so what the inspector shows is
 * exactly what the checker and the ST generator will read.
 */
export function Inspector({ page, library, selected, external, station, onPage, onDelete }: InspectorProps) {
  const patchBlock = (id: string, next: Partial<BlockNode>) =>
    onPage((current) => ({ ...current, blocks: current.blocks.map((block) => (block.id === id ? { ...block, ...next } : block)) }))

  const patchConstant = (id: string, next: Partial<ConstantNode>) =>
    onPage((current) => ({ ...current, constants: current.constants.map((item) => (item.id === id ? { ...item, ...next } : item)) }))

  const patchPort = (direction: PortDirection, name: string, next: Partial<Port>) =>
    onPage((current) => ({
      ...current,
      interface: {
        ...current.interface,
        [direction]: current.interface[direction].map((port) => (port.name === name ? { ...port, ...next } : port)),
      },
    }))

  if (!selected) {
    return (
      <div className="p-3 text-xs text-ide-textDim">
        <p>选择一个算法块、常量或变量引脚查看属性。</p>
        <p className="mt-2">从左侧算法库拖拽到画布可放置算法块；从引脚上按下并拖到另一个引脚即完成连线。</p>
      </div>
    );
  }

  if (selected.kind === "wire") {
    const conn = page.connections[selected.index];
    if (!conn) return <div className="p-3 text-xs text-ide-textDim">连线已删除。</div>;
    return (
      <div className="p-3 space-y-3 text-xs">
        <div>
          <span className={label}>连线</span>
          <div className={field}>
            {conn.from.block === INTERFACE ? "⬚" : ""}
            {conn.from.block}.{conn.from.port} → {conn.to.block}.{conn.to.port}
          </div>
        </div>
        <button onClick={onDelete} className="px-2 py-1 rounded bg-ide-hover hover:bg-ide-selected text-red-400">
          删除连线
        </button>
      </div>
    );
  }

  if (selected.kind === "block") {
    const block = page.blocks.find((item) => item.id === selected.id);
    if (!block) return <div className="p-3 text-xs text-ide-textDim">块已删除。</div>;
    const def = library[block.library_id || block.type] ?? library[block.type];
    const table = pinsOf(block, library);
    const entries = Object.entries(block.parameters ?? {});
    return (
      <div className="p-3 space-y-3 text-xs">
        <div className="grid grid-cols-2 gap-2">
          <div>
            <span className={label}>实例名</span>
            <input
              className={field}
              value={block.id}
              onChange={(event) => {
                const id = event.target.value;
                onPage((current) => ({ ...current, blocks: current.blocks.map((item) => (item.id === block.id ? { ...item, id } : item)) }))
              }}
            />
          </div>
          <div>
            <span className={label}>类型</span>
            <div className={field}>{def?.name ?? block.type}</div>
          </div>
        </div>
        <div>
          <span className={label}>引脚</span>
          <div className="flex justify-between gap-2">
            <div className="flex-1 space-y-0.5">
              {table.inputs.map((pin) => (
                <div key={pin.name} className="flex justify-between font-mono">
                  <span>{pin.name}</span>
                  <span style={{ color: typeColor(pin.type) }}>{pin.type}</span>
                </div>
              ))}
              {!table.inputs.length && <span className="text-ide-textDim">—</span>}
            </div>
            <div className="flex-1 space-y-0.5 text-right">
              {table.outputs.map((pin) => (
                <div key={pin.name} className="flex justify-end gap-2 font-mono">
                  <span style={{ color: typeColor(pin.type) }}>{pin.type}</span>
                  <span>{pin.name}</span>
                </div>
              ))}
              {!table.outputs.length && <span className="text-ide-textDim">—</span>}
            </div>
          </div>
        </div>
        <div>
          <span className={label}>参数</span>
          <div className="space-y-1">
            {entries.map(([key, value]) => (
              <div key={key} className="flex gap-1">
                <input
                  className={`${field} w-1/3`}
                  defaultValue={key}
                  onBlur={(event) => {
                    const parameters = { ...(block.parameters ?? {}) };
                    if (event.target.value !== key) delete parameters[key];
                    parameters[event.target.value] = value;
                    patchBlock(block.id, { parameters });
                  }}
                />
                <input
                  className={field}
                  defaultValue={String(value)}
                  onBlur={(event) => {
                    const numeric = Number(event.target.value);
                    const next =
                      event.target.value === "true" || event.target.value === "false"
                        ? event.target.value === "true"
                        : Number.isNaN(numeric)
                          ? event.target.value
                          : numeric;
                    patchBlock(block.id, { parameters: { ...(block.parameters ?? {}), [key]: next } });
                  }}
                />
                <button
                  onClick={() => {
                    const parameters = { ...(block.parameters ?? {}) };
                    delete parameters[key];
                    patchBlock(block.id, { parameters });
                  }}
                  className="px-1 text-ide-textDim hover:text-red-400"
                >
                  ×
                </button>
              </div>
            ))}
            <button
              onClick={() => patchBlock(block.id, { parameters: { ...(block.parameters ?? {}), P: 0 } })}
              className="px-2 py-0.5 rounded bg-ide-hover hover:bg-ide-selected"
            >
              + 参数
            </button>
          </div>
        </div>
        <button onClick={onDelete} className="px-2 py-1 rounded bg-ide-hover hover:bg-ide-selected text-red-400">
          删除算法块
        </button>
      </div>
    );
  }

  if (selected.kind === "constant") {
    const constant = page.constants.find((item) => item.id === selected.id);
    if (!constant) return <div className="p-3 text-xs text-ide-textDim">常量已删除。</div>;
    return (
      <div className="p-3 space-y-3 text-xs">
        <div>
          <span className={label}>常量名</span>
          <input
            className={field}
            value={constant.id}
            onChange={(event) => {
              const id = event.target.value;
              onPage((current) => ({
                ...current,
                constants: current.constants.map((item) => (item.id === constant.id ? { ...item, id } : item)),
              }))
            }}
          />
        </div>
        <div className="grid grid-cols-2 gap-2">
          <div>
            <span className={label}>类型</span>
            <select
              className={field}
              value={constant.type}
              onChange={(event) => patchConstant(constant.id, { type: event.target.value })}
            >
              {ST_TYPES.map((type) => (
                <option key={type} value={type}>
                  {type}
                </option>
              ))}
            </select>
          </div>
          <div>
            <span className={label}>数值</span>
            <input
              className={field}
              value={String(constant.value)}
              onChange={(event) => {
                const raw = event.target.value;
                const numeric = Number(raw);
                patchConstant(constant.id, {
                  value: raw === "true" || raw === "false" ? raw === "true" : Number.isNaN(numeric) ? raw : numeric,
                });
              }}
            />
          </div>
        </div>
        <p className="text-[10px] text-ide-textDim">常量在生成 ST 时内联为字面量，不产生变量。</p>
        <button onClick={onDelete} className="px-2 py-1 rounded bg-ide-hover hover:bg-ide-selected text-red-400">
          删除常量
        </button>
      </div>
    );
  }

  const port = page.interface[selected.direction].find((item) => item.name === selected.name);
  if (!port) return <div className="p-3 text-xs text-ide-textDim">变量已删除。</div>;
  const scope = port.scope ?? "external";
  const bound = port.bind?.variable ?? "";
  return (
    <div className="p-3 space-y-3 text-xs">
      <div className="grid grid-cols-2 gap-2">
        <div>
          <span className={label}>变量名</span>
          <input
            className={field}
            defaultValue={port.name}
            onBlur={(event) => {
              const name = event.target.value.trim();
              if (!name || name === port.name) return;
              onPage((current) => ({
                ...current,
                interface: {
                  ...current.interface,
                  [selected.direction]: current.interface[selected.direction].map((item) =>
                    item.name === port.name ? { ...item, name } : item
                  ),
                },
                connections: current.connections.map((conn) => ({
                  from:
                    conn.from.block === INTERFACE && conn.from.port === port.name
                      ? { ...conn.from, port: name }
                      : conn.from,
                  to:
                    conn.to.block === INTERFACE && conn.to.port === port.name
                      ? { ...conn.to, port: name }
                      : conn.to,
                })),
              }))
            }}
          />
        </div>
        <div>
          <span className={label}>方向</span>
          <div className={field}>{selected.direction === "input" ? "输入" : selected.direction === "output" ? "输出" : "读写"}</div>
        </div>
      </div>
      <div className="grid grid-cols-2 gap-2">
        <div>
          <span className={label}>类型</span>
          <select className={field} value={port.type} onChange={(event) => patchPort(selected.direction, port.name, { type: event.target.value })}>
            {ST_TYPES.map((type) => (
              <option key={type} value={type}>
                {type}
              </option>
            ))}
          </select>
        </div>
        <div>
          <span className={label}>单位</span>
          <input className={field} value={port.unit ?? ""} onChange={(event) => patchPort(selected.direction, port.name, { unit: event.target.value })} />
        </div>
      </div>
      <div>
        <span className={label}>作用域</span>
        <select
          className={field}
          value={scope}
          onChange={(event) => patchPort(selected.direction, port.name, { scope: event.target.value as Port["scope"] })}
        >
          {SCOPES.map((item) => (
            <option key={item.value} value={item.value}>
              {item.label}
            </option>
          ))}
        </select>
      </div>
      {scope === "external" && (
        <div>
          <span className={label}>关联设备变量（{station || "未选站"}）</span>
          <select
            className={field}
            value={bound}
            onChange={(event) => {
              const variable = event.target.value;
              patchPort(selected.direction, port.name, {
                bind: variable ? { station, variable } : undefined,
              });
            }}
          >
            <option value="">未关联</option>
            {external.map((row) => (
              <option key={row.name} value={row.name}>
                {row.name} · {row.st_type} · {row.direction}
                {row.unit ? ` · ${row.unit}` : ""}
              </option>
            ))}
          </select>
          {external.length === 0 && (
            <p className="mt-1 text-[10px] text-ide-textDim">该站还没有外部变量表，先在设备组态完成通道配置。</p>
          )}
        </div>
      )}
      <button onClick={onDelete} className="px-2 py-1 rounded bg-ide-hover hover:bg-ide-selected text-red-400">
        删除变量引脚
      </button>
    </div>
  );
}
