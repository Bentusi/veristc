import { type CrossPageRow, type PageRow } from "./types";

export interface PageTabsProps {
  pages: PageRow[];
  active: string;
  crossPage: CrossPageRow[];
  dirty: boolean;
  onSelect: (pageId: string) => void;
  onAdd: () => void;
  onClose: (pageId: string) => void;
  onRename: (pageId: string, label: string) => void;
  onJump: (pageId: string, variable: string) => void;
}

/**
 * One tab per sheet, plus the cross-page variable index.
 *
 * The index is the jump: a name that lives on two sheets is the wire between
 * them, so picking it opens the other sheet and highlights that connector.
 */
export function PageTabs({ pages, active, crossPage, dirty, onSelect, onAdd, onClose, onRename, onJump }: PageTabsProps) {
  const byId = new Map(pages.map((page) => [page.id, page]));

  return (
    <div className="flex items-stretch border-b border-ide-bg bg-ide-sidebar text-xs">
      <div className="flex items-stretch overflow-x-auto">
        {pages.map((page) => {
          const on = page.id === active;
          return (
            <div
              key={page.id}
              onClick={() => onSelect(page.id)}
              onDoubleClick={() => {
                const label = window.prompt("图页名称", page.label);
                if (label) onRename(page.id, label);
              }}
              title={`${page.id} · ${page.sheet} · ${page.blocks} 块 ${page.connections} 线`}
              className={`group flex items-center gap-2 px-3 cursor-pointer border-r border-ide-border whitespace-nowrap ${
                on ? "bg-ide-bg text-ide-text" : "bg-ide-sidebar text-ide-textDim hover:bg-ide-hover"
              }`}
            >
              <span className="font-mono text-[10px] opacity-60">{page.index + 1}</span>
              <span>{page.label}</span>
              <span className="text-ide-textDim">{page.sheet}</span>
              {on && dirty && <span className="w-1.5 h-1.5 rounded-full bg-ide-status" title="未保存" />}
              {pages.length > 1 && (
                <button
                  onClick={(event) => {
                    event.stopPropagation();
                    onClose(page.id);
                  }}
                  className="opacity-0 group-hover:opacity-100 text-ide-textDim hover:text-red-400"
                  title="删除图页"
                >
                  ×
                </button>
              )}
            </div>
          );
        })}
        <button
          onClick={onAdd}
          className="px-3 text-ide-textDim hover:bg-ide-hover hover:text-ide-text"
          title="新建图页"
        >
          +
        </button>
      </div>

      <div className="flex-1" />

      <div className="flex items-center gap-1 px-3 text-[11px] text-ide-textDim">
        <span className="uppercase tracking-wide">跨页变量</span>
        {crossPage.length === 0 && <span className="opacity-60">无</span>}
        {crossPage.map((row) => (
          <span key={row.name} className="flex items-center gap-1 rounded bg-ide-hover px-1.5 py-0.5">
            <span className="font-mono text-ide-text">{row.name}</span>
            {row.pages
              .filter((id) => id !== active)
              .map((id) => (
                <button
                  key={id}
                  onClick={() => onJump(id, row.name)}
                  className="text-ide-status hover:underline"
                  title={`跳转到 ${byId.get(id)?.label ?? id} 上的 ${row.name}`}
                >
                  ↗{byId.get(id)?.label ?? id}
                </button>
              ))}
          </span>
        ))}
      </div>
    </div>
  );
}
