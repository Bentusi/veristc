import { useEffect, useState, type ReactNode } from "react";
import { useNavigate } from "react-router-dom";
import { open as pickDirectory } from "@tauri-apps/plugin-dialog";
import { apiCall, inTauri, json } from "../lib/api";
import {
  formatWhen,
  useProject,
  type RecentBlock,
  type RecentProject,
} from "../project/ProjectProvider";

const PROJECT_NAME = /^[A-Za-z_][A-Za-z0-9_]*$/;
const SAFETY_LEVELS = ["SIL1", "SIL2", "SIL3"];
const ST_TYPE_NAME = /^[A-Za-z_][A-Za-z0-9_]*$/;

type Panel = "new-project" | "open-project" | "new-block" | null;

const ST_SKELETON = (type: string) => `FUNCTION_BLOCK ${type}
VAR_INPUT
    IN : REAL;
END_VAR
VAR_OUTPUT
    OUT : REAL;
END_VAR

OUT := IN;
END_FUNCTION_BLOCK`;

function pouNameOf(value: string): string {
  const cleaned = value
    .trim()
    .toUpperCase()
    .replace(/[^A-Z0-9_]/g, "_")
    .replace(/_+/g, "_")
    .replace(/^_+|_+$/g, "");
  return /^[A-Z][A-Z0-9_]*$/.test(cleaned) ? cleaned : "";
}

/** The POU name an ST body declares -- the same rule the block store uses for the file name. */
function pouInSt(value: string): string {
  for (const keyword of ["FUNCTION_BLOCK", "FUNCTION"]) {
    const match = value.match(new RegExp(`\\b${keyword}\\s+([A-Za-z_][A-Za-z0-9_]*)`));
    if (match) return match[1];
  }
  return "";
}

export function HomePage() {
  const navigate = useNavigate();
  const { state, current, error, create, open, forget } = useProject();
  const [panel, setPanel] = useState<Panel>(null);

  const recentProjects = state?.recent_projects ?? [];
  const recentBlocks = state?.recent_blocks ?? [];

  return (
    <div className="h-full flex flex-col overflow-y-auto" data-testid="launcher">
      <div className="flex-1 px-8 py-8">
        <div className="mx-auto w-full max-w-6xl">
          <header className="mb-8 flex items-start justify-between gap-6">
            <div className="flex items-center gap-3">
              <div className="w-10 h-10 rounded-lg bg-ide-accent/20 flex items-center justify-center">
                <svg viewBox="0 0 24 24" className="w-6 h-6 text-ide-accent" fill="currentColor">
                  <path d="M12 2L2 7l10 5 10-5-10-5zM2 17l10 5 10-5M2 12l10 5 10-5" />
                </svg>
              </div>
              <div>
                <h1 className="text-2xl font-semibold text-white">VeriIDE 工程站</h1>
                <p className="text-sm text-ide-textDim">
                  工程是磁盘上的一个文件夹：设备、图页、变量与算法块全部文本化存储
                </p>
              </div>
            </div>
            {current && (
              <button
                data-testid="continue-project"
                onClick={() => navigate("/device")}
                className="px-4 py-2 rounded-lg bg-ide-accent text-white text-sm hover:opacity-90"
              >
                继续 {current.name}
              </button>
            )}
          </header>

          {error && (
            <div className="mb-6 px-4 py-3 rounded-lg border border-red-500/40 bg-red-500/10 text-sm text-red-300">
              后端未就绪：{error}
            </div>
          )}

          <div className="grid grid-cols-3 gap-4 mb-8">
            <ActionTile
              testid="action-new-project"
              title="新建工程"
              desc="在项目位置创建工程文件夹并初始化 Git"
              icon="M12 4v16m8-8H4"
              onClick={() => setPanel("new-project")}
            />
            <ActionTile
              testid="action-open-project"
              title="打开工程"
              desc="选择已有工程文件夹，读入设备、图页与变量"
              icon="M3 7v10a2 2 0 002 2h14a2 2 0 002-2V9a2 2 0 00-2-2h-6l-2-2H5a2 2 0 00-2 2z"
              onClick={() => setPanel("open-project")}
            />
            <ActionTile
              testid="action-new-block"
              title="新建算法块"
              desc="写一个 FUNCTION_BLOCK 存进算法库"
              icon="M12 2l9 5v10l-9 5-9-5V7l9-5zm0 9l4-2M12 11L8 9m4 2v4"
              onClick={() => setPanel("new-block")}
            />
          </div>

          <div className="grid grid-cols-2 gap-6">
            <section>
              <h2 className="text-sm font-semibold uppercase tracking-wider text-ide-textDim mb-3">
                最近打开的工程
              </h2>
              {recentProjects.length === 0 ? (
                <Empty text="还没有打开过工程" />
              ) : (
                <ul className="space-y-2">
                  {recentProjects.map((row) => (
                    <RecentProjectRow
                      key={row.path}
                      row={row}
                      onOpen={() => open(row.path).then(() => navigate("/device"))}
                      onForget={() => forget(row.path)}
                    />
                  ))}
                </ul>
              )}
            </section>

            <section>
              <h2 className="text-sm font-semibold uppercase tracking-wider text-ide-textDim mb-3">
                最近使用的算法块
              </h2>
              {recentBlocks.length === 0 ? (
                <Empty text="还没有创建或编辑过算法块" />
              ) : (
                <ul className="space-y-2">
                  {recentBlocks.map((row) => (
                    <RecentBlockRow
                      key={row.id}
                      row={row}
                      onOpen={() => navigate("/library")}
                    />
                  ))}
                </ul>
              )}
            </section>
          </div>
        </div>
      </div>

      {panel === "new-project" && (
        <NewProjectPanel defaultParent={state?.default_parent_dir ?? ""} onClose={() => setPanel(null)} onCreate={create} onDone={() => navigate("/device")} />
      )}
      {panel === "open-project" && (
        <OpenProjectPanel onClose={() => setPanel(null)} onOpen={open} onDone={() => navigate("/device")} />
      )}
      {panel === "new-block" && <NewBlockPanel onClose={() => setPanel(null)} onDone={() => navigate("/library")} />}
    </div>
  );
}

function ActionTile({
  title,
  desc,
  icon,
  onClick,
  testid,
}: {
  title: string;
  desc: string;
  icon: string;
  onClick: () => void;
  testid: string;
}) {
  return (
    <button
      data-testid={testid}
      onClick={onClick}
      className="text-left bg-ide-sidebar border border-ide-border rounded-xl p-5 hover:border-ide-accent/60 hover:bg-ide-hover transition-all"
    >
      <svg viewBox="0 0 24 24" className="w-6 h-6 text-ide-accent mb-3" fill="none" stroke="currentColor" strokeWidth="1.8">
        <path d={icon} />
      </svg>
      <div className="text-base font-semibold text-white mb-1">{title}</div>
      <div className="text-xs text-ide-textDim leading-relaxed">{desc}</div>
    </button>
  );
}

function Empty({ text }: { text: string }) {
  return (
    <div className="px-4 py-8 text-center text-sm text-ide-textDim border border-dashed border-ide-border rounded-lg">
      {text}
    </div>
  );
}

function RecentProjectRow({
  row,
  onOpen,
  onForget,
}: {
  row: RecentProject;
  onOpen: () => void;
  onForget: () => void;
}) {
  return (
    <li
      className={`group flex items-center gap-3 px-4 py-3 rounded-lg border transition-colors ${
        row.exists
          ? "bg-ide-sidebar border-ide-border hover:border-ide-accent/60 cursor-pointer"
          : "bg-ide-sidebar/40 border-ide-border opacity-60"
      }`}
      onClick={row.exists ? onOpen : undefined}
      data-testid={`recent-project-${row.name}`}
    >
      <div className="flex-1 min-w-0">
        <div className="flex items-center gap-2">
          <span className="text-sm font-medium text-white truncate">{row.name}</span>
          <span className="text-[10px] px-1.5 py-0.5 rounded bg-ide-hover text-ide-textDim">
            {row.safety_level}
          </span>
          {!row.exists && (
            <span className="text-[10px] px-1.5 py-0.5 rounded bg-red-500/20 text-red-300">
              路径不存在
            </span>
          )}
        </div>
        <div className="text-[11px] text-ide-textDim truncate mt-0.5" title={row.path}>
          {row.path}
        </div>
      </div>
      {row.exists && (
        <div className="text-[11px] text-ide-textDim text-right whitespace-nowrap">
          {row.stations} 站 · {row.pages} 图页 · {row.blocks} 块
          <div>{formatWhen(row.opened_at)}</div>
        </div>
      )}
      <button
        className="opacity-0 group-hover:opacity-100 text-xs text-ide-textDim hover:text-red-300 px-2 py-1"
        onClick={(event) => {
          event.stopPropagation();
          onForget();
        }}
        title="从最近列表移除（不删除磁盘文件）"
      >
        移除
      </button>
    </li>
  );
}

function RecentBlockRow({ row, onOpen }: { row: RecentBlock; onOpen: () => void }) {
  return (
    <li
      className="flex items-center gap-3 px-4 py-3 rounded-lg border bg-ide-sidebar border-ide-border hover:border-ide-accent/60 cursor-pointer"
      onClick={onOpen}
      data-testid={`recent-block-${row.name}`}
    >
      <div className="flex-1 min-w-0">
        <div className="flex items-center gap-2">
          <span className="text-sm font-medium text-white truncate">{row.name}</span>
          <span className="text-[10px] px-1.5 py-0.5 rounded bg-ide-hover text-ide-textDim">
            v{row.version}
          </span>
          <span className="text-[10px] px-1.5 py-0.5 rounded bg-ide-hover text-ide-textDim">
            {row.scope !== "project" ? "用户库" : row.project ? `工程块 · ${row.project}` : "工程块"}
          </span>
        </div>
        <div className="text-[11px] text-ide-textDim mt-0.5">{row.category}</div>
      </div>
      <div className="text-[11px] text-ide-textDim whitespace-nowrap">{formatWhen(row.touched_at)}</div>
    </li>
  );
}

function Panel({
  title,
  onClose,
  children,
}: {
  title: string;
  onClose: () => void;
  children: ReactNode;
}) {
  return (
    <div className="fixed inset-0 z-40 flex items-center justify-center bg-black/60" data-testid="panel-backdrop">
      <div className="w-full max-w-lg bg-ide-panel border border-ide-border rounded-xl shadow-2xl">
        <div className="flex items-center justify-between px-5 py-3 border-b border-ide-border">
          <h3 className="text-sm font-semibold text-white">{title}</h3>
          <button onClick={onClose} className="text-ide-textDim hover:text-white text-lg leading-none" aria-label="关闭">
            ×
          </button>
        </div>
        <div className="px-5 py-4 space-y-4">{children}</div>
      </div>
    </div>
  );
}

function Field({ label, children }: { label: string; children: ReactNode }) {
  return (
    <label className="block">
      <span className="block text-xs text-ide-textDim mb-1">{label}</span>
      {children}
    </label>
  );
}

const inputClass =
  "w-full px-3 py-2 rounded-lg bg-ide-sidebar border border-ide-border text-sm text-white focus:outline-none focus:border-ide-accent";

function SubmitError({ message }: { message: string }) {
  if (!message) return null;
  return <p className="text-xs text-red-300">{message}</p>;
}

function NewProjectPanel({
  defaultParent,
  onClose,
  onCreate,
  onDone,
}: {
  defaultParent: string;
  onClose: () => void;
  onCreate: (input: { name: string; parent_dir: string; safety_level: string }) => Promise<unknown>;
  onDone: () => void;
}) {
  const [name, setName] = useState("");
  const [parent, setParent] = useState(defaultParent);
  const [safetyLevel, setSafetyLevel] = useState("SIL2");
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState("");

  const submit = async () => {
    if (!PROJECT_NAME.test(name)) {
      setMessage("工程名只能用字母、数字和下划线，且不能以数字开头");
      return;
    }
    setBusy(true);
    try {
      await onCreate({ name, parent_dir: parent, safety_level: safetyLevel });
      onDone();
    } catch (cause) {
      setMessage((cause as Error).message);
      setBusy(false);
    }
  };

  return (
    <Panel title="新建工程" onClose={onClose}>
      <Field label="工程名称">
        <input
          data-testid="new-project-name"
          className={inputClass}
          value={name}
          onChange={(e) => setName(e.target.value)}
          placeholder="rps_unit"
          autoFocus
        />
      </Field>
      <Field label="项目位置">
        <div className="flex gap-2">
          <input
            data-testid="new-project-parent"
            className={inputClass}
            value={parent}
            onChange={(e) => setParent(e.target.value)}
          />
          <button
            className="px-3 py-2 rounded-lg bg-ide-sidebar border border-ide-border text-sm text-ide-text hover:border-ide-accent"
            onClick={async () => {
              if (!inTauri()) return;
              const picked = await pickDirectory({ title: "选择工程存放位置" });
              if (picked) setParent(String(picked));
            }}
            title={inTauri() ? "浏览…" : "桌面版可用目录选择器"}
          >
            浏览…
          </button>
        </div>
      </Field>
      <Field label="安全等级">
        <select
          data-testid="new-project-sil"
          className={inputClass}
          value={safetyLevel}
          onChange={(e) => setSafetyLevel(e.target.value)}
        >
          {SAFETY_LEVELS.map((level) => (
            <option key={level} value={level}>
              {level}
            </option>
          ))}
        </select>
      </Field>
      <p className="text-[11px] text-ide-textDim leading-relaxed">
        将在 <span className="text-ide-text">{parent || "…"}</span> 下创建 <span className="text-ide-text">{name || "…"}</span>：
        project.yaml + logic/ iomap/ device/ blocks/ sim/ build/，并初始化 Git 仓库。
      </p>
      <SubmitError message={message} />
      <div className="flex justify-end gap-2 pt-1">
        <button className="px-4 py-2 text-sm text-ide-textDim hover:text-white" onClick={onClose}>
          取消
        </button>
        <button
          data-testid="new-project-submit"
          disabled={busy}
          onClick={submit}
          className="px-4 py-2 rounded-lg bg-ide-accent text-white text-sm hover:opacity-90 disabled:opacity-50"
        >
          {busy ? "创建中…" : "创建并打开"}
        </button>
      </div>
    </Panel>
  );
}

function OpenProjectPanel({
  onClose,
  onOpen,
  onDone,
}: {
  onClose: () => void;
  onOpen: (path: string) => Promise<unknown>;
  onDone: () => void;
}) {
  const [path, setPath] = useState("");
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState("");

  const submit = async () => {
    setBusy(true);
    try {
      await onOpen(path.trim());
      onDone();
    } catch (cause) {
      setMessage((cause as Error).message);
      setBusy(false);
    }
  };

  return (
    <Panel title="打开工程" onClose={onClose}>
      <Field label="工程文件夹">
        <div className="flex gap-2">
          <input
            data-testid="open-project-path"
            className={inputClass}
            value={path}
            onChange={(e) => setPath(e.target.value)}
            placeholder="/home/you/VeriIDE/rps_unit"
            autoFocus
          />
          <button
            className="px-3 py-2 rounded-lg bg-ide-sidebar border border-ide-border text-sm text-ide-text hover:border-ide-accent"
            onClick={async () => {
              if (!inTauri()) return;
              const picked = await pickDirectory({ title: "选择工程文件夹", canCreateDirectories: false });
              if (picked) setPath(String(picked));
            }}
          >
            浏览…
          </button>
        </div>
      </Field>
      <p className="text-[11px] text-ide-textDim">
        文件夹里必须有 project.yaml；打开后会读入 device/、iomap/、logic/ 与 blocks/。
      </p>
      <SubmitError message={message} />
      <div className="flex justify-end gap-2 pt-1">
        <button className="px-4 py-2 text-sm text-ide-textDim hover:text-white" onClick={onClose}>
          取消
        </button>
        <button
          data-testid="open-project-submit"
          disabled={busy || !path.trim()}
          onClick={submit}
          className="px-4 py-2 rounded-lg bg-ide-accent text-white text-sm hover:opacity-90 disabled:opacity-50"
        >
          {busy ? "打开中…" : "打开"}
        </button>
      </div>
    </Panel>
  );
}

function NewBlockPanel({ onClose, onDone }: { onClose: () => void; onDone: () => void }) {
  const { current, refresh } = useProject();
  const [name, setName] = useState("");
  const [typeName, setTypeName] = useState("NEW_BLOCK");
  const [typeEdited, setTypeEdited] = useState(false);
  const [category, setCategory] = useState("control");
  const [st, setSt] = useState(ST_SKELETON("NEW_BLOCK"));
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState("");

  // The display name is what a human reads -- it may be Chinese, which cannot be an
  // ST identifier. Only an ASCII-readable name is offered as a suggestion, and once the
  // user types the type name themselves the suggestion stops overwriting it.
  useEffect(() => {
    const suggested = pouNameOf(name);
    if (!suggested || typeEdited) return;
    setSt((prev) => (prev === ST_SKELETON(typeName) ? ST_SKELETON(suggested) : prev));
    setTypeName(suggested);
  }, [name, typeEdited, typeName]);

  const onTypeName = (value: string) => {
    setSt((prev) => (prev === ST_SKELETON(typeName) ? ST_SKELETON(value) : prev));
    setTypeName(value);
    setTypeEdited(true);
  };

  const scopeHint = current ? `当前工程 blocks/：${current.name}` : "全局用户库 ~/.veride/library";

  const submit = async () => {
    if (!name.trim()) {
      setMessage("请填写算法块显示名");
      return;
    }
    if (!ST_TYPE_NAME.test(typeName.trim())) {
      setMessage("类型名请写成 ST 标识符：字母或下划线开头，只含字母、数字、下划线");
      return;
    }
    if (pouInSt(st) !== typeName.trim()) {
      setMessage(`ST 里声明的是 ${pouInSt(st) || "（没有）"}，与类型名 ${typeName.trim()} 不一致：文件名取自 ST 声明`);
      return;
    }
    setBusy(true);
    try {
      await apiCall("/library/blocks", {
        ...json({
          name: name.trim(),
          category,
          inputs: [{ name: "IN", direction: "input", data_type: "REAL" }],
          outputs: [{ name: "OUT", direction: "output", data_type: "REAL" }],
          st_template: st,
        }),
      });
      await refresh();
      onDone();
    } catch (cause) {
      setMessage((cause as Error).message);
      setBusy(false);
    }
  };

  return (
    <Panel title="新建算法块" onClose={onClose}>
      <Field label="显示名称">
        <input
          data-testid="new-block-name"
          className={inputClass}
          value={name}
          onChange={(e) => setName(e.target.value)}
          placeholder="两速比较器"
          autoFocus
        />
      </Field>
      <Field label="类型名（ST POU）">
        <input
          data-testid="new-block-type"
          className={inputClass}
          value={typeName}
          onChange={(e) => onTypeName(e.target.value)}
          placeholder="TWO_SPEED"
        />
      </Field>
      <Field label="分类">
        <select className={inputClass} value={category} onChange={(e) => setCategory(e.target.value)}>
          {["math", "control", "logic", "filter", "converter", "custom"].map((option) => (
            <option key={option} value={option}>
              {option}
            </option>
          ))}
        </select>
      </Field>
      <Field label="ST 实现">
        <textarea
          data-testid="new-block-st"
          className={`${inputClass} font-mono text-xs h-48 resize-y`}
          value={st}
          onChange={(e) => setSt(e.target.value)}
        />
      </Field>
      <p className="text-[11px] text-ide-textDim">
        存储位置：{scopeHint}。块会写成{" "}
        <span className="text-ide-text">{`${typeName.trim() || "<Type>"}.block.yaml`}</span> +{" "}
        <span className="text-ide-text">{`${typeName.trim() || "<Type>"}.st`}</span> 两个文本文件。
      </p>
      <SubmitError message={message} />
      <div className="flex justify-end gap-2 pt-1">
        <button className="px-4 py-2 text-sm text-ide-textDim hover:text-white" onClick={onClose}>
          取消
        </button>
        <button
          data-testid="new-block-submit"
          disabled={busy}
          onClick={submit}
          className="px-4 py-2 rounded-lg bg-ide-accent text-white text-sm hover:opacity-90 disabled:opacity-50"
        >
          {busy ? "保存中…" : "保存算法块"}
        </button>
      </div>
    </Panel>
  );
}
