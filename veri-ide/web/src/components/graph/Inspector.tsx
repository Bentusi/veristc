import { useI18n } from "../../lib/i18n";
import type {
  BlockNode,
  ConstantNode,
  ExternalVarRow,
  LibraryBlock,
  PageDoc,
  Port,
  PortDirection,
  Selection,
  SystemVarRow,
} from "./types";
import { INTERFACE, pinsOf, typeColor } from "./types";

export interface InspectorProps {
  page: PageDoc;
  library: Record<string, LibraryBlock>;
  selected: Selection;
  external: ExternalVarRow[];
  system: SystemVarRow[];
  station: string;
  onPage: (mutate: (page: PageDoc) => PageDoc) => void;
  onDelete: () => void;
}

const ST_TYPES = ["BOOL", "BYTE", "WORD", "DWORD", "SINT", "INT", "DINT", "LINT", "REAL", "LREAL", "TIME", "QBOOL", "QINT", "QDINT", "QREAL", "STRING"];

const field = "w-full bg-ide-bg border border-ide-border rounded px-2 py-1 text-xs text-ide-text font-mono";
const label = "text-[10px] uppercase tracking-wide text-ide-textDim mb-1 block";

/**
 * Editing an element rewrites the page document, so what the inspector shows is
 * exactly what the checker and the ST generator will read.
 */
export function Inspector({ page, library, selected, external, system, station, onPage, onDelete }: InspectorProps) {
  const { t } = useI18n();

  const SCOPES = [
    { value: "external", label: t("inspector.externalVar") },
    { value: "intermediate", label: t("inspector.middleVar") },
    { value: "local", label: t("inspector.localVar") },
  ];

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
        <p>{t("inspector.selectHint")}</p>
        <p className="mt-2">{t("inspector.dragHint")}</p>
      </div>
    );
  }

  if (selected.kind === "wire") {
    const conn = page.connections[selected.index];
    if (!conn) return <div className="p-3 text-xs text-ide-textDim">{t("inspector.wireDeleted")}</div>;
    return (
      <div className="p-3 space-y-3 text-xs">
        <div>
          <span className={label}>{t("inspector.wire")}</span>
          <div className={field}>
            {conn.from.block === INTERFACE ? "⬚" : ""}
            {conn.from.block}.{conn.from.port} → {conn.to.block}.{conn.to.port}
          </div>
        </div>
        <button onClick={onDelete} className="px-2 py-1 rounded bg-ide-hover hover:bg-ide-selected text-red-400">
          {t("inspector.deleteWire")}
        </button>
      </div>
    );
  }

  if (selected.kind === "block") {
    const block = page.blocks.find((item) => item.id === selected.id);
    if (!block) return <div className="p-3 text-xs text-ide-textDim">{t("inspector.blockDeleted")}</div>;
    const def = library[block.library_id || block.type] ?? library[block.type];
    const table = pinsOf(block, library);
    const entries = Object.entries(block.parameters ?? {});
    return (
      <div className="p-3 space-y-3 text-xs">
        <div className="grid grid-cols-2 gap-2">
          <div>
            <span className={label}>{t("inspector.instanceName")}</span>
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
            <span className={label}>{t("inspector.type")}</span>
            <div className={field}>{def?.name ?? block.type}</div>
          </div>
        </div>
        <div>
          <span className={label}>{t("inspector.pin")}</span>
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
          <span className={label}>{t("inspector.parameters")}</span>
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
              {t("inspector.addParam")}
            </button>
          </div>
        </div>
        <button onClick={onDelete} className="px-2 py-1 rounded bg-ide-hover hover:bg-ide-selected text-red-400">
          {t("inspector.deleteBlock")}
        </button>
      </div>
    );
  }

  if (selected.kind === "constant") {
    const constant = page.constants.find((item) => item.id === selected.id);
    if (!constant) return <div className="p-3 text-xs text-ide-textDim">{t("inspector.constantDeleted")}</div>;
    return (
      <div className="p-3 space-y-3 text-xs">
        <div>
          <span className={label}>{t("inspector.constantName")}</span>
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
            <span className={label}>{t("inspector.type")}</span>
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
            <span className={label}>{t("inspector.value")}</span>
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
        <p className="text-[10px] text-ide-textDim">{t("inspector.constantHint")}</p>
        <button onClick={onDelete} className="px-2 py-1 rounded bg-ide-hover hover:bg-ide-selected text-red-400">
          {t("inspector.deleteConstant")}
        </button>
      </div>
    );
  }

  const port = page.interface[selected.direction].find((item) => item.name === selected.name);
  if (!port) return <div className="p-3 text-xs text-ide-textDim">{t("inspector.varDeleted")}</div>;
  const scope = port.scope ?? "external";
  const bound = port.bind?.variable ?? "";
  /** The runtime supplies these by name, so nothing here may be re-declared. */
  const systemVar = system.find((item) => item.name === port.name);
  return (
    <div className="p-3 space-y-3 text-xs">
      <div className="grid grid-cols-2 gap-2">
        <div>
          <span className={label}>{t("inspector.varName")}</span>
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
          <span className={label}>{t("inspector.direction")}</span>
          <div className={field}>{selected.direction === "input" ? t("graph.direction.input") : selected.direction === "output" ? t("graph.direction.output") : t("graph.direction.inout")}</div>
        </div>
      </div>
      <div className="grid grid-cols-2 gap-2">
        <div>
          <span className={label}>{t("inspector.type")}</span>
          {systemVar ? (
            <div className={field}>{systemVar.st_type}</div>
          ) : (
            <select className={field} value={port.type} onChange={(event) => patchPort(selected.direction, port.name, { type: event.target.value })}>
              {ST_TYPES.map((type) => (
                <option key={type} value={type}>
                  {type}
                </option>
              ))}
            </select>
          )}
        </div>
        <div>
          <span className={label}>{t("inspector.unit")}</span>
          <input className={field} value={port.unit ?? ""} onChange={(event) => patchPort(selected.direction, port.name, { unit: event.target.value })} />
        </div>
      </div>
      {systemVar ? (
        <div>
          <span className={label}>{t("inspector.scope")}</span>
          <div className={field}>{t("inspector.systemVar")}</div>
          <p className="mt-1 text-[10px] text-ide-textDim">
            {systemVar.description} —— {t("inspector.systemVarHint")}
          </p>
        </div>
      ) : (
        <div>
          <span className={label}>{t("inspector.scope")}</span>
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
      )}
      {!systemVar && scope === "external" && (
        <div>
          <span className={label}>{t("inspector.associateDevice")}（{station || t("inspector.noStation")}）</span>
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
            <option value="">{t("inspector.notAssociated")}</option>
            {external.map((row) => (
              <option key={row.name} value={row.name}>
                {row.name} · {row.st_type} · {row.direction}
                {row.unit ? ` · ${row.unit}` : ""}
              </option>
            ))}
          </select>
          {external.length === 0 && (
            <p className="mt-1 text-[10px] text-ide-textDim">{t("inspector.noExternalVars")}</p>
          )}
        </div>
      )}
      <button onClick={onDelete} className="px-2 py-1 rounded bg-ide-hover hover:bg-ide-selected text-red-400">
        {t("inspector.deleteVarPin")}
      </button>
    </div>
  );
}
