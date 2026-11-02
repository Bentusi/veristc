import { useState, useCallback, useMemo, useEffect, useRef } from "react";
import { useI18n } from "../../lib/i18n";
import { formatValue, type SymbolSeries } from "../graph/types";
import { toast } from "../ui";

interface BlockPort {
  name: string;
  direction: string;
  data_type: string;
  description: string;
  default_value: unknown;
}

interface BlockParameter {
  name: string;
  data_type: string;
  default_value: unknown;
  min_value: unknown;
  max_value: unknown;
  description: string;
}

export interface AlgorithmBlock {
  id: string;
  name: string;
  category: string;
  version: string;
  description: string;
  author: string;
  block_kind: string;
  time_based: boolean;
  inputs: BlockPort[];
  outputs: BlockPort[];
  parameters: BlockParameter[];
  st_template: string;
  icon_svg: string;
  tags: string[];
  sha256?: string;
  created_at?: string;
  updated_at?: string;
  scope?: string;
  path?: string;
}

interface BlockEditorProps {
  block: AlgorithmBlock;
  onSave: (updated: AlgorithmBlock) => Promise<void>;
  onClose: () => void;
}

type EditorTab = "edit" | "simulate";

interface SectionState {
  ports: boolean;
  symbol: boolean;
  source: boolean;
}

const DATA_TYPES = ["BOOL", "INT", "DINT", "REAL", "LREAL", "STRING"];
const CATEGORIES = ["math", "control", "logic", "filter", "converter", "custom"];

const ST_KEYWORDS = new Set([
  "FUNCTION_BLOCK", "FUNCTION", "END_FUNCTION_BLOCK", "END_FUNCTION",
  "VAR_INPUT", "VAR_OUTPUT", "VAR_IN_OUT", "VAR", "END_VAR",
  "IF", "THEN", "ELSIF", "ELSE", "END_IF",
  "CASE", "OF", "END_CASE",
  "FOR", "TO", "BY", "DO", "END_FOR",
  "WHILE", "END_WHILE",
  "REPEAT", "UNTIL", "END_REPEAT",
  "RETURN", "EXIT",
  "TRUE", "FALSE",
  "AND", "OR", "NOT", "XOR", "MOD",
  "REAL", "INT", "DINT", "BOOL", "STRING", "LREAL",
]);

function highlightSt(code: string): string {
  const lines = code.split("\n");
  return lines
    .map((line) => {
      const escaped = line
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;");
      const TOKEN =
        /(\(\*[\s\S]*?\*\))|(--.*)|('(?:[^'\\]|\\.)*')|(:\s*(?:REAL|INT|DINT|BOOL|STRING|LREAL)\b)|(\b[A-Za-z_][A-Za-z0-9_]*\b)|(\b\d+\.?\d*\b)/g;
      return escaped.replace(TOKEN, (full, blockComment, lineComment, stringLit, typeAnn, ident, num) => {
        if (blockComment) return `<span class="text-ide-textDim italic">${blockComment}</span>`;
        if (lineComment) return `<span class="text-ide-textDim italic">${lineComment}</span>`;
        if (stringLit) return `<span class="text-green-400">${stringLit}</span>`;
        if (typeAnn) {
          const colon = typeAnn.match(/^(:\s*)/)![1];
          const typeName = typeAnn.slice(colon.length);
          return `${colon}<span class="text-cyan-400">${typeName}</span>`;
        }
        if (ident) {
          if (ST_KEYWORDS.has(ident.toUpperCase())) {
            return `<span class="text-purple-400">${ident}</span>`;
          }
          return ident;
        }
        if (num) return `<span class="text-orange-400">${num}</span>`;
        return full;
      });
    })
    .join("\n");
}

function escapeXml(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

function highlightXml(xml: string): string {
  return xml
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(
      /(&lt;\/?)([\w:-]+)/g,
      '$1<span class="text-red-400">$2</span>',
    )
    .replace(
      /([\w:-]+)(=)/g,
      '<span class="text-yellow-300">$1</span>$2',
    )
    .replace(
      /("(?:[^"\\]|\\.)*")/g,
      '<span class="text-green-400">$1</span>',
    )
    .replace(
      /(&lt;!--[\s\S]*?--&gt;)/g,
      '<span class="text-ide-textDim italic">$1</span>',
    );
}

function generateSymbolSvg(block: AlgorithmBlock): string {
  const inputCount = block.inputs.length;
  const outputCount = block.outputs.length;
  const portCount = Math.max(inputCount, outputCount, 1);
  const height = Math.max(80, portCount * 28 + 24);
  const width = 160;
  const paramCount = block.parameters.length;
  const totalHeight = paramCount > 0 ? height + paramCount * 20 : height;

  const safeName = escapeXml(block.name);

  const inputs = block.inputs
    .map(
      (p, i) =>
        `<line x1="0" y1="${20 + i * 28}" x2="12" y2="${20 + i * 28}" stroke="#9ca3af" stroke-width="1.5"/>
         <text x="16" y="${24 + i * 28}" fill="#60a5fa" font-size="10" font-family="monospace">${escapeXml(p.name)}</text>
         <text x="16" y="${36 + i * 28}" fill="#6b7280" font-size="8" font-family="monospace">${escapeXml(p.data_type)}</text>`,
    )
    .join("\n");

  const outputs = block.outputs
    .map(
      (p, i) =>
        `<line x1="${width - 12}" y1="${20 + i * 28}" x2="${width}" y2="${20 + i * 28}" stroke="#9ca3af" stroke-width="1.5"/>
         <text x="${width - 16}" y="${24 + i * 28}" fill="#34d399" font-size="10" font-family="monospace" text-anchor="end">${escapeXml(p.name)}</text>
         <text x="${width - 16}" y="${36 + i * 28}" fill="#6b7280" font-size="8" font-family="monospace" text-anchor="end">${escapeXml(p.data_type)}</text>`,
    )
    .join("\n");

  const params = block.parameters
    .map(
      (p, i) =>
        `<text x="${width / 2}" y="${height + 16 + i * 20}" fill="#fb923c" font-size="9" font-family="monospace" text-anchor="middle">${escapeXml(p.name)} : ${escapeXml(p.data_type)}</text>`,
    )
    .join("\n");

  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="-4 -4 ${width + 8} ${totalHeight + 8}" width="${width + 8}" height="${totalHeight + 8}">
    <rect x="8" y="4" width="${width - 16}" height="${height - 8}" rx="3" fill="#1e293b" stroke="#475569" stroke-width="1.5"/>
    <text x="${width / 2}" y="${height - 10}" fill="#e2e8f0" font-size="12" font-family="monospace" font-weight="bold" text-anchor="middle">${safeName}</text>
    ${inputs}
    ${outputs}
    ${params}
  </svg>`;
}

export function BlockEditor({ block, onSave, onClose }: BlockEditorProps) {
  const { t } = useI18n();
  const [activeTab, setActiveTab] = useState<EditorTab>("edit");
  const [dirty, setDirty] = useState(false);
  const [saving, setSaving] = useState(false);
  const [sections, setSections] = useState<SectionState>({ ports: true, symbol: false, source: true });

  const [name, setName] = useState(block.name);
  const [category, setCategory] = useState(block.category);
  const [version, setVersion] = useState(block.version);
  const [description, setDescription] = useState(block.description);
  const [author, setAuthor] = useState(block.author);
  const [blockKind, setBlockKind] = useState(block.block_kind);
  const [timeBased, setTimeBased] = useState(block.time_based);
  const [inputs, setInputs] = useState<BlockPort[]>(block.inputs);
  const [outputs, setOutputs] = useState<BlockPort[]>(block.outputs);
  const [parameters, setParameters] = useState<BlockParameter[]>(block.parameters);
  const [stTemplate, setStTemplate] = useState(block.st_template);
  const [iconSvg, setIconSvg] = useState(block.icon_svg);
  const [tagsText, setTagsText] = useState(block.tags.join(", "));

  useEffect(() => {
    setName(block.name);
    setCategory(block.category);
    setVersion(block.version);
    setDescription(block.description);
    setAuthor(block.author);
    setBlockKind(block.block_kind);
    setTimeBased(block.time_based);
    setInputs(block.inputs);
    setOutputs(block.outputs);
    setParameters(block.parameters);
    setStTemplate(block.st_template);
    setIconSvg(block.icon_svg);
    setTagsText(block.tags.join(", "));
    setDirty(false);
  }, [block.id, block.updated_at]);

  const markDirty = useCallback(() => setDirty(true), []);

  interface EditorSnapshot {
    name: string; category: string; version: string; description: string;
    author: string; blockKind: string; timeBased: boolean;
    inputs: BlockPort[]; outputs: BlockPort[]; parameters: BlockParameter[];
    stTemplate: string; iconSvg: string; tagsText: string;
  }

  const historyRef = useRef<{ snapshots: EditorSnapshot[]; index: number }>({
    snapshots: [],
    index: -1,
  });
  const debounceRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const stateRef = useRef<EditorSnapshot>(null!);
  stateRef.current = {
    name, category, version, description, author, blockKind, timeBased,
    inputs, outputs, parameters, stTemplate, iconSvg, tagsText,
  };

  const pushSnapshot = useCallback((override?: Partial<EditorSnapshot>) => {
    const snap: EditorSnapshot = JSON.parse(JSON.stringify({ ...stateRef.current, ...override }));
    const h = historyRef.current;
    h.snapshots = h.snapshots.slice(0, h.index + 1);
    h.snapshots.push(snap);
    if (h.snapshots.length > 80) { h.snapshots.shift(); } else { h.index = h.snapshots.length - 1; }
  }, []);

  const debouncedPush = useCallback(() => {
    if (debounceRef.current) clearTimeout(debounceRef.current);
    debounceRef.current = setTimeout(() => pushSnapshot(), 500);
  }, [pushSnapshot]);

  const restoreSnapshot = useCallback((s: EditorSnapshot) => {
    setName(s.name); setCategory(s.category); setVersion(s.version);
    setDescription(s.description); setAuthor(s.author); setBlockKind(s.blockKind);
    setTimeBased(s.timeBased); setInputs(s.inputs); setOutputs(s.outputs);
    setParameters(s.parameters); setStTemplate(s.stTemplate); setIconSvg(s.iconSvg);
    setTagsText(s.tagsText); setDirty(true);
  }, []);

  const undo = useCallback(() => {
    const h = historyRef.current;
    if (h.index > 0) { h.index--; restoreSnapshot(h.snapshots[h.index]); }
  }, [restoreSnapshot]);

  const redo = useCallback(() => {
    const h = historyRef.current;
    if (h.index < h.snapshots.length - 1) { h.index++; restoreSnapshot(h.snapshots[h.index]); }
  }, [restoreSnapshot]);

  useEffect(() => {
    pushSnapshot();
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  const handleSaveRef = useRef<(() => void) | null>(null);

  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      const mod = e.ctrlKey || e.metaKey;
      if (!mod) return;
      if (e.key === "s") { e.preventDefault(); handleSaveRef.current?.(); }
      else if (e.key === "z" && !e.shiftKey) { e.preventDefault(); undo(); }
      else if (e.key === "y" || (e.key === "z" && e.shiftKey)) { e.preventDefault(); redo(); }
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, [undo, redo]);

  const handleSave = async () => {
    setSaving(true);
    try {
      const updated: AlgorithmBlock = {
        ...block,
        name,
        category,
        version,
        description,
        author,
        block_kind: blockKind,
        time_based: timeBased,
        inputs,
        outputs,
        parameters,
        st_template: stTemplate,
        icon_svg: iconSvg || generateSymbolSvg({ ...block, name, inputs, outputs, parameters }),
        tags: tagsText
          .split(",")
          .map((s) => s.trim())
          .filter(Boolean),
      };
      await onSave(updated);
      setDirty(false);
      toast.success(t("editor.saved"), name);
    } catch (error) {
      toast.error(t("editor.saveFailed"), error instanceof Error ? error.message : String(error));
    } finally {
      setSaving(false);
    }
  };
  handleSaveRef.current = handleSave;

  const handleClose = () => {
    if (dirty && !window.confirm(t("editor.closeConfirm"))) return;
    onClose();
  };

  const generatedSvg = useMemo(
    () => generateSymbolSvg({ ...block, name, inputs, outputs, parameters }),
    [block, name, inputs, outputs, parameters],
  );

  const tabs: { id: EditorTab; label: string }[] = [
    { id: "edit", label: t("editor.tabs.edit") },
    { id: "simulate", label: t("editor.tabs.simulate") },
  ];

  const toggleSection = (key: keyof SectionState) => {
    setSections((s) => ({ ...s, [key]: !s[key] }));
  };

  return (
    <div className="fixed inset-0 z-50 bg-ide-bg flex flex-col">
      {/* Header */}
      <div className="h-12 bg-ide-sidebar border-b border-ide-border flex items-center px-4 gap-3">
        <svg viewBox="0 0 24 24" className="w-5 h-5 text-ide-accent" fill="none" stroke="currentColor" strokeWidth="2">
          <path d="M11 4H4a2 2 0 00-2 2v14a2 2 0 002 2h14a2 2 0 002-2v-7" />
          <path d="M18.5 2.5a2.121 2.121 0 013 3L12 15l-4 1 1-4 9.5-9.5z" />
        </svg>
        <h1 className="text-lg font-semibold text-ide-strong">{t("editor.title")}</h1>
        <span className="text-sm text-ide-textDim">— {name}</span>
        {dirty && <span className="text-xs text-orange-400">●</span>}

        <div className="flex-1" />

        <button
          onClick={handleSave}
          disabled={saving}
          className="px-4 py-1.5 bg-ide-accent hover:bg-blue-600 rounded text-sm text-white transition-colors disabled:opacity-50"
        >
          {saving ? t("editor.saving") : t("editor.save")}
        </button>
        <button
          onClick={handleClose}
          className="px-4 py-1.5 bg-ide-sidebar border border-ide-border rounded text-sm text-ide-text hover:bg-ide-hover transition-colors"
        >
          {t("editor.close")}
        </button>
      </div>

      {/* Tab bar */}
      <div className="h-10 bg-ide-sidebar border-b border-ide-border flex items-center px-4 gap-1">
        {tabs.map((tab) => (
          <button
            key={tab.id}
            onClick={() => setActiveTab(tab.id)}
            className={`px-4 py-1.5 rounded-t text-sm font-medium transition-colors ${
              activeTab === tab.id
                ? "bg-ide-bg text-ide-strong border-b-2 border-ide-accent"
                : "text-ide-textDim hover:text-ide-text hover:bg-ide-hover"
            }`}
          >
            {tab.label}
          </button>
        ))}
      </div>

      {/* Content */}
      <div className="flex-1 flex overflow-hidden">
        {activeTab === "edit" ? (
          <>
            {/* Left: metadata sidebar */}
            <div className="w-64 bg-ide-sidebar border-r border-ide-border overflow-y-auto p-3 space-y-2.5">
              <h3 className="text-xs font-semibold uppercase text-ide-textDim">{t("editor.metadata")}</h3>

              <Field label={t("editor.blockName")}>
                <input
                  value={name}
                  onChange={(e) => {
                    const sanitized = e.target.value.replace(/<[^>]*>/g, "");
                    setName(sanitized);
                    markDirty();
                    debouncedPush();
                  }}
                  className="w-full px-2 py-1 bg-ide-bg border border-ide-border rounded text-xs text-ide-strong font-mono focus:outline-none focus:border-ide-accent"
                />
              </Field>

              <Field label={t("editor.category")}>
                <select
                  value={category}
                  onChange={(e) => { setCategory(e.target.value); markDirty(); pushSnapshot(); }}
                  className="w-full px-2 py-1 bg-ide-bg border border-ide-border rounded text-xs text-ide-strong focus:outline-none focus:border-ide-accent"
                >
                  {CATEGORIES.map((c) => (
                    <option key={c} value={c}>{c}</option>
                  ))}
                </select>
              </Field>

              <div className="grid grid-cols-2 gap-2">
                <Field label={t("editor.version")}>
                  <input
                    value={version}
                    onChange={(e) => { setVersion(e.target.value); markDirty(); debouncedPush(); }}
                    className="w-full px-2 py-1 bg-ide-bg border border-ide-border rounded text-xs text-ide-strong font-mono focus:outline-none focus:border-ide-accent"
                  />
                </Field>

                <Field label={t("editor.blockKind")}>
                  <select
                    value={blockKind}
                    onChange={(e) => {
                      const newKind = e.target.value;
                      setBlockKind(newKind);
                      setTimeBased(newKind === "FB");
                      markDirty();
                      pushSnapshot();
                    }}
                    className="w-full px-2 py-1 bg-ide-bg border border-ide-border rounded text-xs text-ide-strong focus:outline-none focus:border-ide-accent"
                  >
                    <option value="FB">{t("editor.blockKind.fb")}</option>
                    <option value="FUN">{t("editor.blockKind.fun")}</option>
                  </select>
                </Field>
              </div>

              <div className="text-xs text-ide-textDim px-1">
                {blockKind === "FB" ? t("editor.blockKind.fbHint") : t("editor.blockKind.funHint")}
              </div>

              <Field label={t("editor.description")}>
                <textarea
                  value={description}
                  onChange={(e) => { setDescription(e.target.value); markDirty(); debouncedPush(); }}
                  rows={2}
                  className="w-full px-2 py-1 bg-ide-bg border border-ide-border rounded text-xs text-ide-strong focus:outline-none focus:border-ide-accent resize-none"
                />
              </Field>

              <Field label={t("editor.author")}>
                <input
                  value={author}
                  onChange={(e) => { setAuthor(e.target.value); markDirty(); debouncedPush(); }}
                  className="w-full px-2 py-1 bg-ide-bg border border-ide-border rounded text-xs text-ide-strong focus:outline-none focus:border-ide-accent"
                />
              </Field>

              <Field label={t("editor.tags")}>
                <input
                  value={tagsText}
                  onChange={(e) => { setTagsText(e.target.value); markDirty(); debouncedPush(); }}
                  placeholder={t("editor.tagsHint")}
                  className="w-full px-2 py-1 bg-ide-bg border border-ide-border rounded text-xs text-ide-strong focus:outline-none focus:border-ide-accent"
                />
              </Field>
            </div>

            {/* Right: scrollable sections */}
            <div className="flex-1 overflow-y-auto p-4 space-y-4">
              {/* Top row: Ports and Symbol side by side */}
              <div className="grid grid-cols-2 gap-4">
                {/* Ports section */}
                <CollapsibleSection
                  title={t("editor.ports.title")}
                  open={sections.ports}
                  onToggle={() => toggleSection("ports")}
                  color="text-blue-400"
                >
                  <PortsSection
                    inputs={inputs}
                    outputs={outputs}
                    parameters={parameters}
                    onInputsChange={(v) => { setInputs(v); markDirty(); pushSnapshot({ inputs: v }); }}
                    onOutputsChange={(v) => { setOutputs(v); markDirty(); pushSnapshot({ outputs: v }); }}
                    onParametersChange={(v) => { setParameters(v); markDirty(); pushSnapshot({ parameters: v }); }}
                  />
                </CollapsibleSection>

                {/* Symbol section */}
                <CollapsibleSection
                  title={t("editor.symbol.title")}
                  open={sections.symbol}
                  onToggle={() => toggleSection("symbol")}
                  color="text-purple-400"
                >
                  <SymbolSection
                    svg={iconSvg || generatedSvg}
                    generatedSvg={generatedSvg}
                    onCustomSvg={(v) => { setIconSvg(v); markDirty(); debouncedPush(); }}
                    onReset={() => { setIconSvg(""); markDirty(); pushSnapshot(); }}
                  />
                </CollapsibleSection>
              </div>

              {/* Bottom: Source section (full width) */}
              <CollapsibleSection
                title={t("editor.source.title")}
                open={sections.source}
                onToggle={() => toggleSection("source")}
                color="text-green-400"
              >
                <SourceSection
                  code={stTemplate}
                  onChange={(v) => { setStTemplate(v); markDirty(); debouncedPush(); }}
                  blockName={name}
                  blockKind={blockKind}
                  inputs={inputs}
                  outputs={outputs}
                  parameters={parameters}
                />
              </CollapsibleSection>
            </div>
          </>
        ) : (
          <div className="flex-1 overflow-auto p-4">
            <SimulateTab
              block={{ ...block, name, inputs, outputs, parameters, st_template: stTemplate, block_kind: blockKind }}
            />
          </div>
        )}
      </div>
    </div>
  );
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div>
      {label && <label className="block text-xs text-ide-textDim mb-1">{label}</label>}
      {children}
    </div>
  );
}

/* ========== Collapsible Section ========== */

function CollapsibleSection({
  title,
  open,
  onToggle,
  color,
  children,
}: {
  title: string;
  open: boolean;
  onToggle: () => void;
  color: string;
  children: React.ReactNode;
}) {
  return (
    <div className="border border-ide-border rounded-lg overflow-hidden">
      <button
        onClick={onToggle}
        className="w-full flex items-center gap-2 px-3 py-2 bg-ide-sidebar hover:bg-ide-hover transition-colors"
      >
        <svg
          viewBox="0 0 24 24"
          className={`w-4 h-4 ${color} transition-transform ${open ? "rotate-90" : ""}`}
          fill="none"
          stroke="currentColor"
          strokeWidth="2"
        >
          <path d="M9 5l7 7-7 7" />
        </svg>
        <span className={`text-sm font-semibold ${color}`}>{title}</span>
      </button>
      {open && <div className="p-3 bg-ide-bg">{children}</div>}
    </div>
  );
}

/* ========== Ports Section ========== */

interface PortsSectionProps {
  inputs: BlockPort[];
  outputs: BlockPort[];
  parameters: BlockParameter[];
  onInputsChange: (v: BlockPort[]) => void;
  onOutputsChange: (v: BlockPort[]) => void;
  onParametersChange: (v: BlockParameter[]) => void;
}

function PortsSection({ inputs, outputs, parameters, onInputsChange, onOutputsChange, onParametersChange }: PortsSectionProps) {
  const { t } = useI18n();

  return (
    <div className="space-y-4">
      <PortSection
        title={t("editor.ports.inputs")}
        ports={inputs}
        onChange={onInputsChange}
        color="text-blue-400"
        kind="port"
      />
      <button
        onClick={() => onInputsChange([...inputs, { name: `IN${inputs.length}`, direction: "input", data_type: "REAL", description: "", default_value: null }])}
        className="px-3 py-1 text-xs bg-ide-sidebar border border-ide-border rounded text-blue-400 hover:bg-ide-hover transition-colors"
      >
        {t("editor.ports.addInput")}
      </button>

      <PortSection
        title={t("editor.ports.outputs")}
        ports={outputs}
        onChange={onOutputsChange}
        color="text-green-400"
        kind="port"
      />
      <button
        onClick={() => onOutputsChange([...outputs, { name: `OUT${outputs.length}`, direction: "output", data_type: "REAL", description: "", default_value: null }])}
        className="px-3 py-1 text-xs bg-ide-sidebar border border-ide-border rounded text-green-400 hover:bg-ide-hover transition-colors"
      >
        {t("editor.ports.addOutput")}
      </button>

      <PortSection
        title={t("editor.ports.parameters")}
        ports={parameters.map((p) => ({ name: p.name, direction: "param", data_type: p.data_type, description: p.description, default_value: p.default_value }))}
        onChange={(v) => onParametersChange(v.map((p, idx) => ({
          name: p.name,
          data_type: p.data_type,
          default_value: p.default_value,
          min_value: parameters[idx]?.min_value ?? null,
          max_value: parameters[idx]?.max_value ?? null,
          description: parameters[idx]?.description ?? p.description,
        })))}
        color="text-orange-400"
        kind="param"
      />
      <button
        onClick={() => onParametersChange([...parameters, { name: `P${parameters.length}`, data_type: "REAL", default_value: 0, min_value: null, max_value: null, description: "" }])}
        className="px-3 py-1 text-xs bg-ide-sidebar border border-ide-border rounded text-orange-400 hover:bg-ide-hover transition-colors"
      >
        {t("editor.ports.addParam")}
      </button>
    </div>
  );
}

interface PortSectionProps {
  title: string;
  ports: BlockPort[];
  onChange: (v: BlockPort[]) => void;
  color: string;
  kind: "port" | "param";
}

function PortSection({ title, ports, onChange, color, kind }: PortSectionProps) {
  const { t } = useI18n();

  if (ports.length === 0) {
    return (
      <div>
        <h3 className={`text-xs font-semibold uppercase mb-2 ${color}`}>{title} (0)</h3>
        <p className="text-xs text-ide-textDim">{t("editor.ports.empty")}</p>
      </div>
    );
  }

  return (
    <div>
      <h3 className={`text-xs font-semibold uppercase mb-2 ${color}`}>{title} ({ports.length})</h3>
      <table className="w-full text-xs">
        <thead>
          <tr className="text-ide-textDim border-b border-ide-border">
            <th className="text-left py-1.5 px-2">{t("editor.ports.name")}</th>
            <th className="text-left py-1.5 px-2">{t("editor.ports.dataType")}</th>
            {kind === "port" && <th className="text-left py-1.5 px-2">{t("editor.ports.description")}</th>}
            {kind === "param" && <th className="text-left py-1.5 px-2">{t("editor.ports.defaultValue")}</th>}
            <th className="w-16 py-1.5 px-2"></th>
          </tr>
        </thead>
        <tbody>
          {ports.map((port, idx) => (
            <tr key={idx} className="border-b border-ide-border/50 hover:bg-ide-sidebar/50">
              <td className="py-1 px-2">
                <input
                  value={port.name}
                  onChange={(e) => {
                    const sanitized = e.target.value.replace(/<[^>]*>/g, "");
                    const next = [...ports];
                    next[idx] = { ...next[idx], name: sanitized };
                    onChange(next);
                  }}
                  className="w-full px-1.5 py-1 bg-ide-bg border border-ide-border rounded font-mono text-ide-strong focus:outline-none focus:border-ide-accent"
                />
              </td>
              <td className="py-1 px-2">
                <select
                  value={port.data_type}
                  onChange={(e) => {
                    const next = [...ports];
                    next[idx] = { ...next[idx], data_type: e.target.value };
                    onChange(next);
                  }}
                  className="px-1.5 py-1 bg-ide-bg border border-ide-border rounded font-mono text-ide-strong focus:outline-none focus:border-ide-accent"
                >
                  {DATA_TYPES.map((dt) => (
                    <option key={dt} value={dt}>{dt}</option>
                  ))}
                </select>
              </td>
              {kind === "port" && (
                <td className="py-1 px-2">
                  <input
                    value={(port as BlockPort).description}
                    onChange={(e) => {
                      const next = [...ports];
                      next[idx] = { ...next[idx], description: e.target.value };
                      onChange(next);
                    }}
                    className="w-full px-1.5 py-1 bg-ide-bg border border-ide-border rounded text-ide-text focus:outline-none focus:border-ide-accent"
                  />
                </td>
              )}
              {kind === "param" && (
                <td className="py-1 px-2">
                  <input
                    value={String(port.default_value ?? "")}
                    onChange={(e) => {
                      const next = [...ports];
                      const num = Number(e.target.value);
                      next[idx] = { ...next[idx], default_value: Number.isFinite(num) ? num : e.target.value };
                      onChange(next);
                    }}
                    className="w-full px-1.5 py-1 bg-ide-bg border border-ide-border rounded font-mono text-ide-strong focus:outline-none focus:border-ide-accent"
                  />
                </td>
              )}
              <td className="py-1 px-2">
                <button
                  onClick={() => onChange(ports.filter((_, i) => i !== idx))}
                  className="p-1 text-ide-textDim hover:text-red-400 transition-colors"
                  title={t("editor.ports.remove")}
                >
                  <svg viewBox="0 0 24 24" className="w-3.5 h-3.5" fill="none" stroke="currentColor" strokeWidth="2">
                    <path d="M6 18L18 6M6 6l12 12" />
                  </svg>
                </button>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

/* ========== Symbol Section ========== */

interface SymbolSectionProps {
  svg: string;
  generatedSvg: string;
  onCustomSvg: (v: string) => void;
  onReset: () => void;
}

function SymbolSection({ svg, generatedSvg, onCustomSvg, onReset }: SymbolSectionProps) {
  const { t } = useI18n();
  const [mode, setMode] = useState<"auto" | "custom">(svg === generatedSvg ? "auto" : "custom");
  const svgTextareaRef = useRef<HTMLTextAreaElement>(null);
  const svgLineRef = useRef<HTMLDivElement>(null);
  const [svgFontSize, setSvgFontSize] = useState(12);
  const svgLineCount = svg.split("\n").length;

  const syncSvgScroll = () => {
    if (svgTextareaRef.current && svgLineRef.current) {
      svgLineRef.current.scrollTop = svgTextareaRef.current.scrollTop;
    }
  };

  return (
    <div className="space-y-3">
      <div className="flex gap-2">
        <button
          onClick={() => setMode("auto")}
          className={`px-3 py-1 text-xs rounded border transition-colors ${
            mode === "auto" ? "bg-ide-accent text-white border-ide-accent" : "bg-ide-sidebar text-ide-textDim border-ide-border hover:bg-ide-hover"
          }`}
        >
          {t("editor.symbol.autoGenerate")}
        </button>
        <button
          onClick={() => setMode("custom")}
          className={`px-3 py-1 text-xs rounded border transition-colors ${
            mode === "custom" ? "bg-ide-accent text-white border-ide-accent" : "bg-ide-sidebar text-ide-textDim border-ide-border hover:bg-ide-hover"
          }`}
        >
          {t("editor.symbol.custom")}
        </button>
        {mode === "custom" && (
          <button
            onClick={() => { setMode("auto"); onReset(); }}
            className="px-3 py-1 text-xs rounded border border-ide-border bg-ide-sidebar text-ide-textDim hover:bg-ide-hover transition-colors"
          >
            {t("editor.symbol.reset")}
          </button>
        )}
      </div>

      <div className="bg-ide-sidebar border border-ide-border rounded p-4 flex items-center justify-center min-h-[160px]">
        <div dangerouslySetInnerHTML={{ __html: mode === "auto" ? generatedSvg : svg }} />
      </div>

      {mode === "custom" && (
        <div className="space-y-2">
          <div className="flex items-center gap-2">
            <label className="text-xs text-ide-textDim">SVG / XML</label>
            <div className="flex-1" />
            <div className="flex items-center gap-1 text-xs text-ide-textDim">
              <button
                onClick={() => setSvgFontSize((s) => Math.max(10, s - 1))}
                className="px-1.5 py-0.5 bg-ide-sidebar border border-ide-border rounded hover:bg-ide-hover transition-colors"
              >A-</button>
              <span className="w-6 text-center font-mono">{svgFontSize}</span>
              <button
                onClick={() => setSvgFontSize((s) => Math.min(24, s + 1))}
                className="px-1.5 py-0.5 bg-ide-sidebar border border-ide-border rounded hover:bg-ide-hover transition-colors"
              >A+</button>
            </div>
          </div>
          <div className="flex rounded border border-ide-border overflow-hidden bg-[#0d1117]">
            <div
              ref={svgLineRef}
              className="select-none overflow-hidden text-right bg-[#0d1117] border-r border-ide-border/30 py-2 px-2"
              style={{ fontSize: svgFontSize, lineHeight: 1.6, fontFamily: "monospace" }}
              aria-hidden
            >
              {Array.from({ length: svgLineCount }, (_, i) => (
                <div key={i} className="text-ide-textDim/50">{i + 1}</div>
              ))}
            </div>
            <div className="flex-1 relative overflow-hidden">
              <pre
                className="absolute inset-0 overflow-auto pointer-events-none whitespace-pre-wrap break-words p-2"
                style={{ fontSize: svgFontSize, lineHeight: 1.6, fontFamily: "monospace" }}
                dangerouslySetInnerHTML={{ __html: highlightXml(svg) }}
              />
              <textarea
                ref={svgTextareaRef}
                value={svg}
                onChange={(e) => onCustomSvg(e.target.value)}
                onScroll={syncSvgScroll}
                spellCheck={false}
                rows={8}
                className="w-full h-full p-2 bg-transparent text-transparent caret-white resize-y focus:outline-none"
                style={{ fontSize: svgFontSize, lineHeight: 1.6, fontFamily: "monospace", tabSize: 2 }}
              />
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

/* ========== Source Section ========== */

interface SourceSectionProps {
  code: string;
  onChange: (v: string) => void;
  blockName: string;
  blockKind: string;
  inputs: BlockPort[];
  outputs: BlockPort[];
  parameters: BlockParameter[];
}

function SourceSection({ code, onChange, blockName, blockKind, inputs, outputs, parameters }: SourceSectionProps) {
  const { t } = useI18n();
  const textareaRef = useRef<HTMLTextAreaElement>(null);
  const lineNumbersRef = useRef<HTMLDivElement>(null);
  const highlightRef = useRef<HTMLPreElement>(null);
  const [showHighlight, setShowHighlight] = useState(true);
  const [fontSize, setFontSize] = useState(13);

  const sanitize = (s: string) => s.replace(/<[^>]*>/g, "").trim();

  const skeleton = useMemo(() => {
    const keyword = blockKind === "FUN" ? "FUNCTION" : "FUNCTION_BLOCK";
    const endKeyword = blockKind === "FUN" ? "END_FUNCTION" : "END_FUNCTION_BLOCK";
    const safeName = sanitize(blockName) || "UnnamedBlock";
    const lines: string[] = [`${keyword} ${safeName}`];

    if (inputs.length > 0) {
      lines.push("VAR_INPUT");
      for (const p of inputs) {
        const safePortName = sanitize(p.name) || "port";
        const safeType = sanitize(p.data_type) || "REAL";
        lines.push(`    ${safePortName} : ${safeType};`);
      }
      lines.push("END_VAR");
    }

    if (outputs.length > 0) {
      lines.push("VAR_OUTPUT");
      for (const p of outputs) {
        const safePortName = sanitize(p.name) || "port";
        const safeType = sanitize(p.data_type) || "REAL";
        lines.push(`    ${safePortName} : ${safeType};`);
      }
      lines.push("END_VAR");
    }

    if (parameters.length > 0) {
      lines.push("VAR");
      for (const p of parameters) {
        const safeParamName = sanitize(p.name) || "param";
        const safeType = sanitize(p.data_type) || "REAL";
        lines.push(`    ${safeParamName} : ${safeType} := ${p.default_value ?? 0};`);
      }
      lines.push("END_VAR");
    }

    lines.push("");
    lines.push(endKeyword);
    return lines.join("\n");
  }, [blockName, blockKind, inputs, outputs, parameters]);

  const effectiveCode = code || skeleton;
  const lineCount = effectiveCode.split("\n").length;


  useEffect(() => {
    if (!code) onChange(skeleton);
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  const syncScroll = () => {
    const ta = textareaRef.current;
    if (!ta) return;
    if (lineNumbersRef.current) {
      lineNumbersRef.current.scrollTop = ta.scrollTop;
    }
    if (highlightRef.current) {
      highlightRef.current.scrollTop = ta.scrollTop;
      highlightRef.current.scrollLeft = ta.scrollLeft;
    }
  };

  return (
    <div className="space-y-2">
      <div className="flex items-center gap-2">
        <div className="flex-1" />
        <div className="flex items-center gap-1 text-xs text-ide-textDim">
          <button
            onClick={() => setFontSize((s) => Math.max(10, s - 1))}
            className="px-1.5 py-0.5 bg-ide-sidebar border border-ide-border rounded hover:bg-ide-hover transition-colors"
            title={t("editor.source.fontSmaller")}
          >A-</button>
          <span className="w-6 text-center font-mono">{fontSize}</span>
          <button
            onClick={() => setFontSize((s) => Math.min(24, s + 1))}
            className="px-1.5 py-0.5 bg-ide-sidebar border border-ide-border rounded hover:bg-ide-hover transition-colors"
            title={t("editor.source.fontBigger")}
          >A+</button>
        </div>
        <label className="flex items-center gap-1 text-xs text-ide-textDim cursor-pointer">
          <input
            type="checkbox"
            checked={showHighlight}
            onChange={(e) => setShowHighlight(e.target.checked)}
            className="w-3 h-3 accent-ide-accent"
          />
          {t("editor.source.validate")}
        </label>
        <button
          onClick={() => onChange(skeleton)}
          className="px-2 py-0.5 text-xs bg-ide-sidebar border border-ide-border rounded text-ide-textDim hover:bg-ide-hover transition-colors"
        >
          {t("editor.source.format")}
        </button>
      </div>

      <div className="flex rounded border border-ide-border overflow-hidden bg-[#0d1117]" style={{ minHeight: "200px" }}>
        {/* Line numbers gutter */}
        <div
          ref={lineNumbersRef}
          className="select-none overflow-hidden text-right bg-[#0d1117] border-r border-ide-border/30 py-2 px-2"
          style={{ fontSize, lineHeight: 1.6, fontFamily: "monospace" }}
          aria-hidden
        >
          {Array.from({ length: lineCount }, (_, i) => (
            <div key={i} className="text-ide-textDim/50">{i + 1}</div>
          ))}
        </div>

        {/* Editor area */}
        <div className="flex-1 relative overflow-hidden">
          {showHighlight && (
            <pre
              ref={highlightRef}
              className="absolute inset-0 overflow-auto pointer-events-none whitespace-pre-wrap break-words m-0"
              style={{ fontSize, lineHeight: 1.6, padding: "8px" }}
              dangerouslySetInnerHTML={{ __html: highlightSt(effectiveCode) }}
            />
          )}
          <textarea
            ref={textareaRef}
            value={effectiveCode}
            onChange={(e) => onChange(e.target.value)}
            onScroll={syncScroll}
            spellCheck={false}
            className={`w-full h-full overflow-auto whitespace-pre-wrap break-words bg-transparent focus:outline-none border-0`}
            style={{
              fontSize,
              lineHeight: 1.6,
              padding: "8px",
              tabSize: 4,
              color: showHighlight ? "transparent" : undefined,
              caretColor: showHighlight ? "white" : undefined,
              fontFamily: "monospace",
            }}
          />
        </div>
      </div>
    </div>
  );
}

/* ========== Simulate Tab ========== */

interface SimulateTabProps {
  block: AlgorithmBlock;
}

type SimMode = "cycle" | "truth";

/** A single-block run: the same frames `POST /sim/run` answers, plus the port map. */
interface BlockSimRun {
  ok: boolean;
  stage?: string;
  errors?: string[];
  cycles?: number;
  cycle_ms?: number;
  symbols?: SymbolSeries[];
  ports?: {
    inputs: { port: string; symbol: string; type: string }[];
    outputs: { port: string; symbol: string; type: string }[];
  };
  program?: string;
}

/** Mirror of the backend's port-to-symbol rule, so a force names the right slot. */
function portSymbol(name: string, taken: Set<string>): string {
  let cleaned = (name || "").trim().replace(/[^A-Za-z0-9_]/g, "_");
  if (!cleaned || /^[0-9]/.test(cleaned)) cleaned = "P" + cleaned;
  let candidate = cleaned;
  let suffix = 2;
  while (taken.has(candidate)) {
    candidate = `${cleaned}_${suffix}`;
    suffix += 1;
  }
  taken.add(candidate);
  return candidate;
}

/** The bool token the runner expects for a checkbox. */
function boolToken(value: string): string {
  return value === "1" || value.toUpperCase() === "TRUE" ? "TRUE" : "FALSE";
}

function SimulateTab({ block }: SimulateTabProps) {
  const { t } = useI18n();
  const [mode, setMode] = useState<SimMode>("cycle");
  const [cycles, setCycles] = useState(4);
  const [run, setRun] = useState<BlockSimRun | null>(null);
  const [running, setRunning] = useState(false);
  const [showProgram, setShowProgram] = useState(false);

  // One symbol per port, computed the way the driver names it: inputs first, then
  // a FUNCTION's single output; a FUNCTION_BLOCK reads its outputs through the
  // instance field, so the symbol is `B1#PORT` and needs no collision handling.
  const portMap = useMemo(() => {
    const taken = new Set<string>();
    const inputs = block.inputs.map((p) => ({ port: p.name, symbol: portSymbol(p.name, taken), type: p.data_type }));
    const outputs = block.outputs.map((p) => ({
      port: p.name,
      symbol: block.block_kind === "FB" ? `B1#${p.name}` : portSymbol(p.name, taken),
      type: p.data_type,
    }));
    return { inputs, outputs };
  }, [block]);

  const boolInputs = portMap.inputs.filter((p) => p.type.includes("BOOL"));
  const fixedInputs = portMap.inputs.filter((p) => !p.type.includes("BOOL"));

  const [inputValues, setInputValues] = useState<Record<string, string>>(() =>
    Object.fromEntries(block.inputs.map((p) => [p.name, String(p.default_value ?? (p.data_type === "BOOL" ? "FALSE" : "0"))])),
  );

  // Cycle mode is a per-cycle stimulus grid: grid[cycle][port] is the value the
  // engineer presets for that cycle, so a stateful block can be watched evolving
  // over time. `step` is how many cycles have been run and revealed so far.
  const defaultCell = (p: { name: string; data_type: string; default_value?: unknown }) =>
    String(p.default_value ?? (p.data_type === "BOOL" ? "FALSE" : "0"));

  const buildGrid = (n: number, prev: Record<number, Record<string, string>> | null) => {
    const next: Record<number, Record<string, string>> = {};
    for (let c = 1; c <= n; c++) {
      next[c] = {};
      for (const p of block.inputs) next[c][p.name] = prev?.[c]?.[p.name] ?? defaultCell(p);
    }
    return next;
  };

  const [grid, setGrid] = useState<Record<number, Record<string, string>>>(() => buildGrid(cycles, null));
  const [step, setStep] = useState(0);

  useEffect(() => {
    setGrid((prev) => buildGrid(cycles, prev));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [cycles, block]);

  const series = useMemo(() => new Map((run?.symbols ?? []).map((s) => [s.name, s])), [run]);

  // Once a run has come back, its `ports` carry the symbols the frames actually
  // use -- the driver may resolve a renamed port to the body's own port name, so
  // the run's table is authoritative over the client-side guess above. Until the
  // first run, fall back to the mirrored names (inputs always agree).
  const inCols = run?.ports?.inputs ?? portMap.inputs;
  const outCols = run?.ports?.outputs ?? portMap.outputs;

  async function post(payload: Record<string, unknown>): Promise<BlockSimRun> {
    const response = await fetch("http://localhost:8000/sim/run-block", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    if (!response.ok) throw new Error(await response.text());
    return (await response.json()) as BlockSimRun;
  }

  /** The runner's own budget for `--script` records; beyond it, it refuses to start. */
  const SCRIPT_MAX = 64;

  const tokenFor = (p: { type: string }, raw: string | undefined) =>
    p.type.includes("BOOL") ? boolToken(raw ?? "FALSE") : (raw ?? "0");

  // A symbol must live in EITHER `forces` OR `script`, never both -- the runner
  // refuses a name that appears in both at startup. So an input held constant
  // across the whole run rides as a `force`; one that varies is expressed purely
  // as script records, a cycle-1 record setting its initial value plus a record
  // at each later change (a record holds until the next one for that symbol).
  function buildStimulus(upto: number) {
    const forces: { name: string; value: string }[] = [];
    const script: { cycle: number; name: string; value: string }[] = [];
    for (const p of portMap.inputs) {
      const first = tokenFor(p, grid[1]?.[p.port]);
      let constant = true;
      for (let c = 2; c <= upto; c++) {
        if (tokenFor(p, grid[c]?.[p.port]) !== first) {
          constant = false;
          break;
        }
      }
      if (constant) {
        forces.push({ name: p.symbol, value: first });
        continue;
      }
      script.push({ cycle: 1, name: p.symbol, value: first });
      let prev = first;
      for (let c = 2; c <= upto; c++) {
        const cur = tokenFor(p, grid[c]?.[p.port]);
        if (cur !== prev) {
          script.push({ cycle: c, name: p.symbol, value: cur });
          prev = cur;
        }
      }
    }
    return { forces, script };
  }

  async function runCycles(k: number) {
    if (running || k < 1 || k > cycles) return;
    const { forces, script } = buildStimulus(k);
    if (script.length > SCRIPT_MAX) {
      setRun({ ok: false, stage: "compose", errors: [t("editor.simulate.recordsExceed")] });
      return;
    }
    setRunning(true);
    try {
      const result = await post({ block_id: block.id, cycles: k, forces, script });
      setRun(result);
      if (result.ok) setStep(k);
    } catch (error) {
      setRun({ ok: false, stage: "request", errors: [(error as Error).message] });
    } finally {
      setRunning(false);
    }
  }

  /** Advance exactly one cycle, reading that cycle's preset inputs. */
  const handleStep = () => runCycles(step + 1);
  /** Run every cycle in one go. */
  const handleRunAll = () => runCycles(cycles);

  const setCell = (cycle: number, port: string, value: string) => {
    setGrid((prev) => ({ ...prev, [cycle]: { ...prev[cycle], [port]: value } }));
    // A grid edit invalidates what has been stepped so far; start over cleanly.
    setStep(0);
    setRun(null);
  };

  // A truth table is ONE run: each combination lands on a successive cycle. Only
  // the bits that change from the held value get a script record, so a run over
  // 2^n combinations stays inside the runner's script budget.
  async function handleRunTruth() {
    setRunning(true);
    const n = boolInputs.length;
    const combos = 1 << n;
    try {
      const script: { cycle: number; name: string; value: string }[] = [];
      const held: Record<string, string> = {};
      for (let row = 0; row < combos; row++) {
        const cycle = row + 1;
        boolInputs.forEach((p, j) => {
          const value = (row & (1 << (n - 1 - j))) ? "TRUE" : "FALSE";
          if (held[p.symbol] !== value) {
            script.push({ cycle, name: p.symbol, value });
            held[p.symbol] = value;
          }
        });
      }
      const forces = fixedInputs.map((p) => ({ name: p.symbol, value: inputValues[p.port] ?? "0" }));
      setRun(await post({ block_id: block.id, cycles: combos, forces, script }));
    } catch (error) {
      setRun({ ok: false, stage: "request", errors: [(error as Error).message] });
    } finally {
      setRunning(false);
    }
  }

  function reset() {
    setRun(null);
    setStep(0);
    setGrid(buildGrid(cycles, null));
    setInputValues(
      Object.fromEntries(block.inputs.map((p) => [p.name, String(p.default_value ?? (p.data_type === "BOOL" ? "FALSE" : "0"))])),
    );
  }

  const errorList = run && !run.ok ? run.errors ?? [] : [];

  return (
    <div className="space-y-4">
      <div className="flex items-center gap-3">
        <h2 className="text-sm font-semibold text-ide-strong">{t("editor.simulate.title")}</h2>
        <div className="flex-1" />
        <div className="flex gap-1 bg-ide-sidebar border border-ide-border rounded p-0.5">
          <button
            onClick={() => { setMode("cycle"); }}
            className={`px-3 py-1 text-xs rounded transition-colors ${
              mode === "cycle" ? "bg-ide-accent text-white" : "text-ide-textDim hover:text-ide-text"
            }`}
          >
            {t("editor.simulate.cycleSim")}
          </button>
          <button
            onClick={() => { setMode("truth"); }}
            className={`px-3 py-1 text-xs rounded transition-colors ${
              mode === "truth" ? "bg-ide-accent text-white" : "text-ide-textDim hover:text-ide-text"
            }`}
          >
            {t("editor.simulate.truthTable")}
          </button>
        </div>
      </div>

      <p className="text-xs text-ide-textDim">{t("editor.simulate.engineHint")}</p>

      {block.time_based && mode === "truth" && (
        <p className="text-xs text-amber-400">{t("editor.simulate.statefulHint")}</p>
      )}

      {/* Cycle mode: a per-cycle stimulus grid. Truth mode: the fixed non-bool inputs. */}
      {mode === "cycle" ? (
        portMap.inputs.length > 0 && (
          <div>
            <h3 className="text-xs font-semibold uppercase text-ide-textDim mb-1">{t("editor.simulate.stepGrid")}</h3>
            <p className="text-xs text-ide-textDim mb-2">{t("editor.simulate.gridHint")}</p>
            <div className="overflow-auto border border-ide-border rounded">
              <table className="text-xs">
                <thead>
                  <tr className="text-ide-textDim border-b border-ide-border bg-ide-sidebar">
                    <th className="text-left py-1.5 px-2 font-normal">{t("editor.simulate.cycle")}</th>
                    {portMap.inputs.map((p) => (
                      <th key={p.port} className="text-left py-1.5 px-2 font-normal">
                        <span className="text-blue-400 font-mono">{p.port}</span>
                        <span className="ml-1 text-ide-textDim">{p.type}</span>
                      </th>
                    ))}
                  </tr>
                </thead>
                <tbody>
                  {Array.from({ length: cycles }, (_, i) => i + 1).map((c) => (
                    <tr key={c} className={`border-b border-ide-border/50 ${c <= step ? "bg-ide-hover/40" : ""}`}>
                      <td className="py-1 px-2 font-mono text-ide-textDim">{c}</td>
                      {portMap.inputs.map((p) => (
                        <td key={p.port} className="py-1 px-2">
                          {p.type.includes("BOOL") ? (
                            <input
                              type="checkbox"
                              checked={boolToken(grid[c]?.[p.port] ?? "FALSE") === "TRUE"}
                              onChange={(e) => setCell(c, p.port, e.target.checked ? "TRUE" : "FALSE")}
                              className="accent-ide-accent"
                            />
                          ) : (
                            <input
                              value={grid[c]?.[p.port] ?? ""}
                              onChange={(e) => setCell(c, p.port, e.target.value)}
                              className="w-24 px-2 py-0.5 bg-ide-bg border border-ide-border rounded text-ide-strong font-mono focus:outline-none focus:border-ide-accent"
                            />
                          )}
                        </td>
                      ))}
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
        )
      ) : (
        fixedInputs.length > 0 && (
          <div>
            <h3 className="text-xs font-semibold uppercase text-ide-textDim mb-2">{t("editor.simulate.fixedInputs")}</h3>
            <div className="grid grid-cols-2 gap-2">
              {fixedInputs.map((p) => (
                <div key={p.port} className="flex items-center gap-2">
                  <span className="text-xs text-blue-400 font-mono w-20 truncate" title={p.port}>{p.port}</span>
                  <span className="text-xs text-ide-textDim">{p.type}</span>
                  <input
                    value={inputValues[p.port] ?? ""}
                    onChange={(e) => setInputValues({ ...inputValues, [p.port]: e.target.value })}
                    className="flex-1 px-2 py-1 bg-ide-bg border border-ide-border rounded text-xs text-ide-strong font-mono focus:outline-none focus:border-ide-accent"
                  />
                </div>
              ))}
            </div>
          </div>
        )
      )}

      {/* Controls */}
      <div className="flex items-center gap-3 flex-wrap">
        {mode === "cycle" ? (
          <>
            <label className="text-xs text-ide-textDim flex items-center gap-2">
              {t("editor.simulate.cycles")}
              <input
                type="number"
                min={1}
                value={cycles}
                onChange={(e) => setCycles(Math.max(1, Number(e.target.value)))}
                className="w-16 px-2 py-1 bg-ide-bg border border-ide-border rounded text-sm text-ide-strong font-mono focus:outline-none focus:border-ide-accent"
              />
            </label>
            <span className="text-xs text-ide-textDim font-mono">
              {t("editor.simulate.stepProgress")}: {step}/{cycles}
            </span>
            <div className="flex-1" />
            <button
              onClick={handleStep}
              disabled={running || step >= cycles || portMap.inputs.length === 0}
              className="px-4 py-1.5 bg-ide-accent hover:bg-blue-600 rounded text-sm text-white transition-colors disabled:opacity-50"
            >
              {running ? t("editor.simulate.running") : t("editor.simulate.step")}
            </button>
            <button
              onClick={handleRunAll}
              disabled={running || portMap.inputs.length === 0}
              className="px-4 py-1.5 bg-ide-sidebar border border-ide-border rounded text-sm text-ide-text hover:bg-ide-hover transition-colors disabled:opacity-50"
            >
              {t("editor.simulate.runAll")}
            </button>
          </>
        ) : (
          <>
            {boolInputs.length > 0 && (
              <span className="text-xs text-ide-textDim">
                {boolInputs.length} {t("editor.simulate.boolInputs")}, {1 << boolInputs.length} {t("editor.simulate.combinations")}
              </span>
            )}
            <div className="flex-1" />
            <button
              onClick={handleRunTruth}
              disabled={running || boolInputs.length === 0}
              className="px-4 py-1.5 bg-ide-accent hover:bg-blue-600 rounded text-sm text-white transition-colors disabled:opacity-50"
            >
              {running ? t("editor.simulate.running") : t("editor.simulate.run")}
            </button>
          </>
        )}
        <button
          onClick={reset}
          className="px-4 py-1.5 bg-ide-sidebar border border-ide-border rounded text-sm text-ide-textDim hover:bg-ide-hover transition-colors"
        >
          {t("editor.simulate.reset")}
        </button>
      </div>

      {mode === "truth" && boolInputs.length === 0 && (
        <div className="text-sm text-ide-textDim py-4 text-center border border-ide-border rounded">
          {t("editor.simulate.noBoolInputs")}
        </div>
      )}

      {errorList.length > 0 && (
        <div className="rounded border border-red-500/40 bg-red-500/5 px-3 py-2 space-y-1">
          <div className="text-xs font-semibold text-red-400">{t("editor.simulate.failed")}（{run?.stage}）</div>
          {errorList.map((message, i) => (
            <div key={i} className="text-xs font-mono text-red-300 break-words">{message}</div>
          ))}
        </div>
      )}

      {run?.ok && mode === "cycle" && (
        <ResultTable
          caption={t("editor.simulate.outputs")}
          cycles={run.symbols?.[0]?.values.length ?? run.cycles ?? cycles}
          columns={[
            ...inCols.map((p) => ({ ...p, kind: "in" as const })),
            ...outCols.map((p) => ({ ...p, kind: "out" as const })),
          ]}
          series={series}
          showForced
        />
      )}

      {run?.ok && mode === "truth" && boolInputs.length > 0 && (
        <TruthTable
          boolInputs={boolInputs}
          fixedInputs={fixedInputs}
          inputValues={inputValues}
          outputs={outCols}
          series={series}
        />
      )}

      {run?.program && (
        <div>
          <button
            onClick={() => setShowProgram((v) => !v)}
            className="text-xs text-ide-textDim hover:text-ide-text underline"
          >
            {t("editor.simulate.viewProgram")}
          </button>
          {showProgram && (
            <pre className="mt-2 p-3 bg-ide-bg border border-ide-border rounded text-xs font-mono text-ide-text overflow-auto max-h-72 whitespace-pre">
              {run.program}
            </pre>
          )}
        </div>
      )}
    </div>
  );
}

type Column = { port: string; symbol: string; type: string; kind?: "in" | "out" };

function ResultTable({
  caption,
  cycles,
  columns,
  series,
  showForced,
}: {
  caption: string;
  cycles: number;
  columns: Column[];
  series: Map<string, SymbolSeries>;
  showForced: boolean;
}) {
  const { t } = useI18n();
  return (
    <div>
      <h3 className="text-xs font-semibold uppercase text-ide-textDim mb-2">{caption}</h3>
      <div className="overflow-auto">
        <table className="w-full text-xs">
          <thead>
            <tr className="text-ide-textDim border-b border-ide-border">
              <th className="text-left py-1.5 px-2">{t("editor.simulate.cycle")}</th>
              {columns.map((c) => (
                <th key={c.symbol} className={`text-left py-1.5 px-2 ${c.kind === "out" ? "text-green-400" : "text-blue-400"}`}>
                  {c.port}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {Array.from({ length: cycles }, (_, i) => (
              <tr key={i} className="border-b border-ide-border/50">
                <td className="py-1 px-2 font-mono text-ide-textDim">{i + 1}</td>
                {columns.map((c) => {
                  const row = series.get(c.symbol);
                  const forced = showForced && row?.forced?.[i] === true;
                  return (
                    <td
                      key={c.symbol}
                      className={`py-1 px-2 font-mono ${forced ? "text-amber-400 italic" : "text-ide-strong"}`}
                      title={forced ? t("editor.simulate.forced") : undefined}
                    >
                      {row ? formatValue(row.type, row.values[i] ?? null) : "—"}
                    </td>
                  );
                })}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}

function TruthTable({
  boolInputs,
  fixedInputs,
  inputValues,
  outputs,
  series,
}: {
  boolInputs: Column[];
  fixedInputs: Column[];
  inputValues: Record<string, string>;
  outputs: Column[];
  series: Map<string, SymbolSeries>;
}) {
  const { t } = useI18n();
  const n = boolInputs.length;
  const combos = 1 << n;
  return (
    <div>
      <h3 className="text-xs font-semibold uppercase text-ide-textDim mb-2">{t("editor.simulate.truthTable")}</h3>
      <div className="overflow-auto">
        <table className="w-full text-xs">
          <thead>
            <tr className="text-ide-textDim border-b border-ide-border">
              <th className="text-left py-1.5 px-2">#</th>
              {boolInputs.map((c) => (
                <th key={c.symbol} className="text-left py-1.5 px-2 text-blue-400">{c.port}</th>
              ))}
              {fixedInputs.map((c) => (
                <th key={c.symbol} className="text-left py-1.5 px-2 text-blue-300">{c.port}</th>
              ))}
              {outputs.map((c) => (
                <th key={c.symbol} className="text-left py-1.5 px-2 text-green-400">{c.port}</th>
              ))}
            </tr>
          </thead>
          <tbody>
            {Array.from({ length: combos }, (_, row) => {
              const cycleIndex = row; // cycle = row + 1 → values[cycleIndex]
              return (
                <tr key={row} className="border-b border-ide-border/50">
                  <td className="py-1 px-2 font-mono text-ide-textDim">{row + 1}</td>
                  {boolInputs.map((c, j) => {
                    const bit = (row & (1 << (n - 1 - j))) ? "TRUE" : "FALSE";
                    return (
                      <td key={c.symbol} className="py-1 px-2 font-mono text-ide-strong">{bit}</td>
                    );
                  })}
                  {fixedInputs.map((c) => (
                    <td key={c.symbol} className="py-1 px-2 font-mono text-ide-textDim">{inputValues[c.port] ?? "0"}</td>
                  ))}
                  {outputs.map((c) => {
                    const s = series.get(c.symbol);
                    return (
                      <td key={c.symbol} className="py-1 px-2 font-mono text-ide-strong">
                        {s ? formatValue(s.type, s.values[cycleIndex] ?? null) : "—"}
                      </td>
                    );
                  })}
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </div>
  );
}
