import { useState } from "react";
import { useI18n } from "../../lib/i18n";

interface AlgorithmBlock {
  id: string;
  name: string;
  category: string;
  version: string;
  description: string;
  author: string;
  inputs: Array<{ name: string; direction: string; data_type: string }>;
  outputs: Array<{ name: string; direction: string; data_type: string }>;
  parameters: Array<{ name: string; data_type: string; default_value: any }>;
  st_template: string;
  icon_svg: string;
  tags: string[];
}

interface BlockLibraryProps {
  blocks: AlgorithmBlock[];
  selectedBlock: string | null;
  onSelect: (blockId: string) => void;
  onDelete: (blockId: string) => void;
}

const CATEGORY_COLORS: Record<string, string> = {
  math: "bg-blue-500/20 text-blue-400 border-blue-500/30",
  control: "bg-green-500/20 text-green-400 border-green-500/30",
  logic: "bg-purple-500/20 text-purple-400 border-purple-500/30",
  filter: "bg-orange-500/20 text-orange-400 border-orange-500/30",
  converter: "bg-cyan-500/20 text-cyan-400 border-cyan-500/30",
  custom: "bg-gray-500/20 text-ide-textDim border-gray-500/30",
};

const CATEGORY_LABELS: Record<string, string> = {
  math: "blockLibrary.math",
  control: "blockLibrary.control",
  logic: "blockLibrary.logic",
  filter: "blockLibrary.filter",
  converter: "blockLibrary.convert",
  custom: "blockLibrary.custom",
};

export function BlockLibrary({ blocks, selectedBlock, onSelect, onDelete }: BlockLibraryProps) {
  const { t } = useI18n();
  const [filterCategory, setFilterCategory] = useState<string>("all");
  const [searchText, setSearchText] = useState("");
  const [showImportDialog, setShowImportDialog] = useState(false);
  const [importJson, setImportJson] = useState("");

  const filteredBlocks = blocks.filter((block) => {
    const matchesCategory = filterCategory === "all" || block.category === filterCategory;
    const matchesSearch = searchText === "" || 
      block.name.toLowerCase().includes(searchText.toLowerCase()) ||
      block.description.toLowerCase().includes(searchText.toLowerCase());
    return matchesCategory && matchesSearch;
  });

  const groupedBlocks = filteredBlocks.reduce((acc, block) => {
    if (!acc[block.category]) {
      acc[block.category] = [];
    }
    acc[block.category].push(block);
    return acc;
  }, {} as Record<string, AlgorithmBlock[]>);

  const handleImport = async () => {
    try {
      const blockData = JSON.parse(importJson);
      const response = await fetch("http://localhost:8000/library/import", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(blockData),
      });
      
      if (response.ok) {
        const result = await response.json();
        alert(result.message);
        setShowImportDialog(false);
        setImportJson("");
        // Reload blocks
        window.location.reload();
      }
    } catch (error) {
      alert(t("blockLibrary.importFailed"));
    }
  };

  const handleExport = async (blockId: string) => {
    try {
      const response = await fetch(`http://localhost:8000/library/export/${blockId}`);
      if (response.ok) {
        const data = await response.json();
        const blob = new Blob([JSON.stringify(data, null, 2)], { type: "application/json" });
        const url = URL.createObjectURL(blob);
        const a = document.createElement("a");
        a.href = url;
        a.download = `${data.name}.json`;
        a.click();
        URL.revokeObjectURL(url);
      }
    } catch (error) {
      console.error(t("libraryManager.exportFailed"), error);
    }
  };

  return (
    <div className="h-full flex flex-col">
      {/* Toolbar */}
      <div className="flex items-center gap-3 mb-4">
        <input
          type="text"
          placeholder={t("blockLibrary.searchPlaceholder")}
          value={searchText}
          onChange={(e) => setSearchText(e.target.value)}
          className="flex-1 px-3 py-2 bg-ide-sidebar border border-ide-border rounded text-sm text-ide-strong placeholder-ide-textDim focus:outline-none focus:border-ide-accent"
        />
        <select
          value={filterCategory}
          onChange={(e) => setFilterCategory(e.target.value)}
          className="px-3 py-2 bg-ide-sidebar border border-ide-border rounded text-sm text-ide-strong focus:outline-none focus:border-ide-accent"
        >
          <option value="all">{t("blockLibrary.allCategories")}</option>
          <option value="math">{t("blockLibrary.math")}</option>
          <option value="control">{t("blockLibrary.control")}</option>
          <option value="logic">{t("blockLibrary.logic")}</option>
          <option value="filter">{t("blockLibrary.filter")}</option>
          <option value="converter">{t("blockLibrary.convert")}</option>
          <option value="custom">{t("blockLibrary.custom")}</option>
        </select>
        <button
          onClick={() => setShowImportDialog(true)}
          className="flex items-center gap-2 px-4 py-2 bg-ide-accent hover:bg-blue-600 rounded text-sm text-white transition-colors"
        >
          <svg viewBox="0 0 24 24" className="w-4 h-4" fill="none" stroke="currentColor" strokeWidth="2">
            <path d="M12 4v16m8-8H4" />
          </svg>
          {t("blockLibrary.import")}
        </button>
      </div>

      {/* Blocks Grid */}
      <div className="flex-1 overflow-auto">
        {Object.keys(groupedBlocks).length === 0 ? (
          <div className="h-full flex items-center justify-center">
            <div className="text-center">
              <svg viewBox="0 0 24 24" className="w-16 h-16 text-ide-textDim mx-auto mb-4" fill="none" stroke="currentColor" strokeWidth="1.5">
                <path d="M19.428 15.428a2 2 0 00-1.022-.547l-2.387-.477a6 6 0 00-3.86.517l-.318.158a6 6 0 01-3.86.517L6.05 15.21a2 2 0 00-1.022.547L3 17.5h2m14.428-2.072a2 2 0 011.022.547l2.387.477a6 6 0 003.86-.517l.318-.158a6 6 0 013.86-.517l1.95-1.592a2 2 0 011.022-.547H21" />
              </svg>
              <p className="text-ide-textDim mb-2">{t("blockLibrary.noBlocks")}</p>
              <p className="text-sm text-ide-textDim">{t("blockLibrary.noBlocksHint")}</p>
            </div>
          </div>
        ) : (
          <div className="space-y-6">
            {Object.entries(groupedBlocks).map(([category, categoryBlocks]) => (
              <div key={category}>
                <h3 className="text-sm font-semibold text-ide-strong mb-3 flex items-center gap-2">
                  <span className={`px-2 py-0.5 rounded text-xs ${CATEGORY_COLORS[category] || CATEGORY_COLORS.custom}`}>
                    {CATEGORY_LABELS[category] ? t(`blockLibrary.${category === "converter" ? "convert" : category}` as any) : category}
                  </span>
                  <span className="text-xs text-ide-textDim">({categoryBlocks.length})</span>
                </h3>
                
                <div className="grid grid-cols-2 gap-3">
                  {categoryBlocks.map((block) => (
                    <div
                      key={block.id}
                      onClick={() => onSelect(block.id)}
                      className={`p-4 rounded-lg border cursor-pointer transition-all ${
                        selectedBlock === block.id
                          ? "bg-ide-accent/10 border-ide-accent"
                          : "bg-ide-sidebar border-ide-border hover:border-ide-textDim"
                      }`}
                    >
                      <div className="flex items-start justify-between mb-2">
                        <h4 className="text-sm font-semibold text-ide-strong">{block.name}</h4>
                        <div className="flex gap-1">
                          <button
                            onClick={(e) => {
                              e.stopPropagation();
                              handleExport(block.id);
                            }}
                            className="p-1 text-ide-textDim hover:text-ide-accent transition-colors"
                            title={t("blockLibrary.export")}
                          >
                            <svg viewBox="0 0 24 24" className="w-4 h-4" fill="none" stroke="currentColor" strokeWidth="2">
                              <path d="M4 16v1a3 3 0 003 3h10a3 3 0 003-3v-1m-4-4l-4 4m0 0l-4-4m4 4V4" />
                            </svg>
                          </button>
                          <button
                            onClick={(e) => {
                              e.stopPropagation();
                              if (confirm(`${t("blockLibrary.confirmDelete")} "${block.name}" ${t("blockLibrary.confirmDelete2")}`)) {
                                onDelete(block.id);
                              }
                            }}
                            className="p-1 text-ide-textDim hover:text-red-400 transition-colors"
                            title={t("common.delete")}
                          >
                            <svg viewBox="0 0 24 24" className="w-4 h-4" fill="none" stroke="currentColor" strokeWidth="2">
                              <path d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16" />
                            </svg>
                          </button>
                        </div>
                      </div>
                      
                      <p className="text-xs text-ide-text mb-3 line-clamp-2">{block.description}</p>
                      
                      <div className="flex items-center gap-2 text-xs">
                        <span className="text-ide-textDim">v{block.version}</span>
                        <span className="text-ide-textDim">•</span>
                        <span className="text-ide-textDim">{block.inputs.length} {t("blockLibrary.inputs")}</span>
                        <span className="text-ide-textDim">•</span>
                        <span className="text-ide-textDim">{block.outputs.length} {t("blockLibrary.outputs")}</span>
                      </div>
                      
                      {block.tags.length > 0 && (
                        <div className="flex flex-wrap gap-1 mt-2">
                          {block.tags.slice(0, 3).map((tag) => (
                            <span key={tag} className="px-1.5 py-0.5 bg-ide-bg rounded text-xs text-ide-textDim">
                              {tag}
                            </span>
                          ))}
                        </div>
                      )}
                    </div>
                  ))}
                </div>
              </div>
            ))}
          </div>
        )}
      </div>

      {/* Import Dialog */}
      {showImportDialog && (
        <div className="fixed inset-0 bg-black/50 flex items-center justify-center z-50" onClick={() => setShowImportDialog(false)}>
          <div className="bg-ide-sidebar border border-ide-border rounded-lg p-6 w-[600px]" onClick={(e) => e.stopPropagation()}>
            <h3 className="text-lg font-semibold text-ide-strong mb-4">{t("blockLibrary.importTitle")}</h3>
            <p className="text-sm text-ide-textDim mb-4">
              {t("blockLibrary.importDesc")}
            </p>
            
            <textarea
              value={importJson}
              onChange={(e) => setImportJson(e.target.value)}
              placeholder='{"name": "MyBlock", "category": "custom", ...}'
              className="w-full h-64 px-3 py-2 bg-ide-bg border border-ide-border rounded text-sm text-ide-strong font-mono focus:outline-none focus:border-ide-accent resize-none"
            />
            
            <div className="flex gap-2 mt-4">
              <button
                onClick={() => setShowImportDialog(false)}
                className="flex-1 px-4 py-2 bg-ide-bg border border-ide-border rounded text-sm text-ide-text hover:bg-ide-hover transition-colors"
              >
                {t("common.cancel")}
              </button>
              <button
                onClick={handleImport}
                className="flex-1 px-4 py-2 bg-ide-accent hover:bg-blue-600 rounded text-sm text-white transition-colors"
              >
                {t("blockLibrary.import")}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
