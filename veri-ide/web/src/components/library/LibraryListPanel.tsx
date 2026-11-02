import { useState, useEffect } from "react";
import { useI18n } from "../../lib/i18n";
import { toast } from "../ui";

interface Library {
  id: string;
  name: string;
  description: string;
  owner: string;
  version: string;
  is_shared: boolean;
  blocks_count: number;
  created_at: string;
  updated_at: string;
  scope: string;
  directory: string;
}

interface LibraryListPanelProps {
  selectedLibrary: string | null;
  onSelect: (libraryId: string) => void;
  onRefresh: () => void;
}

export function LibraryListPanel({ selectedLibrary, onSelect, onRefresh }: LibraryListPanelProps) {
  const { t } = useI18n();
  const [libraries, setLibraries] = useState<Library[]>([]);
  const [showCreateDialog, setShowCreateDialog] = useState(false);
  const [newLibName, setNewLibName] = useState("");
  const [newLibDesc, setNewLibDesc] = useState("");

  useEffect(() => {
    fetchLibraries();
  }, []);

  const fetchLibraries = async () => {
    try {
      const response = await fetch("http://localhost:8000/library/libraries");
      if (response.ok) {
        const data = await response.json();
        setLibraries(data);
      }
    } catch (error) {
      console.error("Failed to fetch libraries:", error);
    }
  };

  const handleCreate = async () => {
    if (!newLibName.trim()) return;
    try {
      const response = await fetch("http://localhost:8000/library/libraries", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name: newLibName, description: newLibDesc }),
      });
      if (response.ok) {
        toast.success(t("libraryManager.created"), newLibName);
        setShowCreateDialog(false);
        setNewLibName("");
        setNewLibDesc("");
        fetchLibraries();
        onRefresh();
      } else {
        toast.error(t("libraryManager.createFailed"), await response.text());
      }
    } catch (error) {
      toast.error(t("libraryManager.createFailed"), error instanceof Error ? error.message : String(error));
    }
  };

  const handleDelete = async (libId: string) => {
    if (!window.confirm(t("libraryManager.confirmDelete"))) return;
    try {
      const response = await fetch(`http://localhost:8000/library/libraries/${libId}`, {
        method: "DELETE",
      });
      if (response.ok) {
        toast.success(t("libraryManager.deleted"), libId);
        if (selectedLibrary === libId) {
          onSelect("user-default");
        }
        fetchLibraries();
        onRefresh();
      }
    } catch (error) {
      toast.error(t("libraryManager.deleteFailed"), error instanceof Error ? error.message : String(error));
    }
  };

  const handleClear = async (libId: string) => {
    if (!window.confirm(t("libraryManager.confirmClear"))) return;
    try {
      const response = await fetch(`http://localhost:8000/library/libraries/${libId}/clear`, {
        method: "POST",
      });
      if (response.ok) {
        toast.success(t("libraryManager.cleared"), libId);
        fetchLibraries();
        onRefresh();
      }
    } catch (error) {
      toast.error(t("libraryManager.clearFailed"), error instanceof Error ? error.message : String(error));
    }
  };

  const handleExportZip = async (libId: string) => {
    try {
      const response = await fetch(`http://localhost:8000/library/libraries/${libId}/export-zip`);
      if (response.ok) {
        const blob = await response.blob();
        const url = URL.createObjectURL(blob);
        const a = document.createElement("a");
        a.href = url;
        a.download = `${libId}.zip`;
        a.click();
        URL.revokeObjectURL(url);
        toast.success(t("libraryManager.exported"), libId);
      }
    } catch (error) {
      toast.error(t("libraryManager.exportFailed"), error instanceof Error ? error.message : String(error));
    }
  };

  const handleImportZip = async () => {
    const input = document.createElement("input");
    input.type = "file";
    input.accept = ".zip";
    input.onchange = async (e) => {
      const file = (e.target as HTMLInputElement).files?.[0];
      if (!file) return;
      const formData = new FormData();
      formData.append("file", file);
      try {
        const response = await fetch("http://localhost:8000/library/libraries/import-zip", {
          method: "POST",
          body: formData,
        });
        if (response.ok) {
          const result = await response.json();
          toast.success(t("libraryManager.imported"), result.library_id);
          fetchLibraries();
          onRefresh();
        } else {
          toast.error(t("libraryManager.importFailed"), await response.text());
        }
      } catch (error) {
        toast.error(t("libraryManager.importFailed"), error instanceof Error ? error.message : String(error));
      }
    };
    input.click();
  };

  return (
    <div className="w-56 bg-ide-sidebar border-r border-ide-border flex flex-col">
      <div className="p-3 border-b border-ide-border">
        <h3 className="text-xs font-semibold uppercase text-ide-textDim mb-2">{t("library.title")}</h3>
        <div className="flex gap-1">
          <button
            onClick={() => setShowCreateDialog(true)}
            className="flex-1 px-2 py-1 text-xs bg-ide-accent hover:bg-blue-600 rounded text-white transition-colors"
            title={t("libraryManager.create")}
          >
            + {t("libraryManager.create")}
          </button>
          <button
            onClick={handleImportZip}
            className="px-2 py-1 text-xs bg-ide-bg border border-ide-border rounded text-ide-text hover:bg-ide-hover transition-colors"
            title={t("libraryManager.importZip")}
          >
            ↓
          </button>
        </div>
      </div>

      <div className="flex-1 overflow-y-auto">
        {libraries.map((lib) => (
          <div
            key={lib.id}
            onClick={() => onSelect(lib.id)}
            className={`px-3 py-2 cursor-pointer border-b border-ide-border/50 transition-colors ${
              selectedLibrary === lib.id
                ? "bg-ide-accent/10 border-l-2 border-l-ide-accent"
                : "hover:bg-ide-hover"
            }`}
          >
            <div className="flex items-start justify-between gap-1">
              <div className="flex-1 min-w-0">
                <div className="text-sm font-medium text-ide-strong truncate">{lib.name}</div>
                <div className="text-xs text-ide-textDim truncate">{lib.description || "-"}</div>
                <div className="flex items-center gap-2 mt-1 text-xs text-ide-textDim">
                  <span>{lib.blocks_count} {t("library.blockCount")}</span>
                  <span>v{lib.version}</span>
                </div>
              </div>
              <div className="flex flex-col gap-1">
                <button
                  onClick={(e) => { e.stopPropagation(); handleExportZip(lib.id); }}
                  className="p-1 text-ide-textDim hover:text-ide-accent transition-colors"
                  title={t("libraryManager.exportZip")}
                >
                  <svg viewBox="0 0 24 24" className="w-3 h-3" fill="none" stroke="currentColor" strokeWidth="2">
                    <path d="M4 16v1a3 3 0 003 3h10a3 3 0 003-3v-1m-4-4l-4 4m0 0l-4-4m4 4V4" />
                  </svg>
                </button>
                {lib.id !== "builtin" && (
                  <>
                    <button
                      onClick={(e) => { e.stopPropagation(); handleClear(lib.id); }}
                      className="p-1 text-ide-textDim hover:text-orange-400 transition-colors"
                      title={t("libraryManager.clear")}
                    >
                      <svg viewBox="0 0 24 24" className="w-3 h-3" fill="none" stroke="currentColor" strokeWidth="2">
                        <path d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16" />
                      </svg>
                    </button>
                    <button
                      onClick={(e) => { e.stopPropagation(); handleDelete(lib.id); }}
                      className="p-1 text-ide-textDim hover:text-red-400 transition-colors"
                      title={t("libraryManager.delete")}
                    >
                      <svg viewBox="0 0 24 24" className="w-3 h-3" fill="none" stroke="currentColor" strokeWidth="2">
                        <path d="M6 18L18 6M6 6l12 12" />
                      </svg>
                    </button>
                  </>
                )}
              </div>
            </div>
          </div>
        ))}
      </div>

      {showCreateDialog && (
        <div className="fixed inset-0 z-50 bg-black/50 flex items-center justify-center" onClick={() => setShowCreateDialog(false)}>
          <div className="bg-ide-sidebar border border-ide-border rounded-lg p-4 w-96" onClick={(e) => e.stopPropagation()}>
            <h3 className="text-sm font-semibold text-ide-strong mb-3">{t("libraryManager.create")}</h3>
            <div className="space-y-2">
              <div>
                <label className="block text-xs text-ide-textDim mb-1">{t("libraryManager.name")}</label>
                <input
                  value={newLibName}
                  onChange={(e) => setNewLibName(e.target.value)}
                  className="w-full px-2 py-1.5 bg-ide-bg border border-ide-border rounded text-sm text-ide-strong focus:outline-none focus:border-ide-accent"
                  autoFocus
                />
              </div>
              <div>
                <label className="block text-xs text-ide-textDim mb-1">{t("libraryManager.description")}</label>
                <textarea
                  value={newLibDesc}
                  onChange={(e) => setNewLibDesc(e.target.value)}
                  rows={2}
                  className="w-full px-2 py-1.5 bg-ide-bg border border-ide-border rounded text-sm text-ide-strong focus:outline-none focus:border-ide-accent resize-none"
                />
              </div>
            </div>
            <div className="flex gap-2 mt-4">
              <button
                onClick={handleCreate}
                className="flex-1 px-3 py-1.5 bg-ide-accent hover:bg-blue-600 rounded text-sm text-white transition-colors"
              >
                {t("libraryManager.create")}
              </button>
              <button
                onClick={() => setShowCreateDialog(false)}
                className="flex-1 px-3 py-1.5 bg-ide-bg border border-ide-border rounded text-sm text-ide-text hover:bg-ide-hover transition-colors"
              >
                {t("libraryManager.cancel")}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
