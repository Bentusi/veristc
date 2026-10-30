import { useState, useEffect } from "react";

interface LibraryInfo {
  id: string;
  name: string;
  description: string;
  owner: string;
  is_shared: boolean;
  blocks_count: number;
  created_at: string;
  updated_at: string;
}

export function LibraryManager() {
  const [libraries, setLibraries] = useState<LibraryInfo[]>([]);
  const [showCreateDialog, setShowCreateDialog] = useState(false);
  const [newLibraryName, setNewLibraryName] = useState("");
  const [newLibraryDesc, setNewLibraryDesc] = useState("");

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

  const handleCreateLibrary = async () => {
    try {
      const response = await fetch("http://localhost:8000/library/libraries", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          name: newLibraryName,
          description: newLibraryDesc,
        }),
      });
      
      if (response.ok) {
        setShowCreateDialog(false);
        setNewLibraryName("");
        setNewLibraryDesc("");
        fetchLibraries();
      }
    } catch (error) {
      console.error("Failed to create library:", error);
    }
  };

  const handleToggleShare = async (libraryId: string, currentShared: boolean) => {
    try {
      const response = await fetch(
        `http://localhost:8000/library/libraries/${libraryId}/share?shared=${!currentShared}`,
        { method: "POST" }
      );
      
      if (response.ok) {
        fetchLibraries();
      }
    } catch (error) {
      console.error("Failed to toggle share:", error);
    }
  };

  const handleDeleteLibrary = async (libraryId: string) => {
    try {
      const response = await fetch(`http://localhost:8000/library/libraries/${libraryId}`, {
        method: "DELETE",
      });
      
      if (response.ok) {
        fetchLibraries();
      }
    } catch (error) {
      console.error("Failed to delete library:", error);
    }
  };

  const handleExportLibrary = async () => {
    try {
      const response = await fetch("http://localhost:8000/library/export/library");
      if (response.ok) {
        const data = await response.json();
        const blob = new Blob([JSON.stringify(data, null, 2)], { type: "application/json" });
        const url = URL.createObjectURL(blob);
        const a = document.createElement("a");
        a.href = url;
        a.download = "algorithm_library.json";
        a.click();
        URL.revokeObjectURL(url);
      }
    } catch (error) {
      console.error("导出失败:", error);
    }
  };

  return (
    <div className="h-full flex flex-col">
      {/* Toolbar */}
      <div className="flex items-center gap-3 mb-4">
        <button
          onClick={() => setShowCreateDialog(true)}
          className="flex items-center gap-2 px-4 py-2 bg-ide-accent hover:bg-blue-600 rounded text-sm text-white transition-colors"
        >
          <svg viewBox="0 0 24 24" className="w-4 h-4" fill="none" stroke="currentColor" strokeWidth="2">
            <path d="M12 4v16m8-8H4" />
          </svg>
          新建库
        </button>
        <button
          onClick={handleExportLibrary}
          className="flex items-center gap-2 px-4 py-2 bg-ide-sidebar border border-ide-border rounded text-sm text-ide-text hover:bg-ide-hover transition-colors"
        >
          <svg viewBox="0 0 24 24" className="w-4 h-4" fill="none" stroke="currentColor" strokeWidth="2">
            <path d="M4 16v1a3 3 0 003 3h10a3 3 0 003-3v-1m-4-4l-4 4m0 0l-4-4m4 4V4" />
          </svg>
          导出库
        </button>
        <div className="flex-1" />
        <span className="text-sm text-ide-textDim">{libraries.length} 个库</span>
      </div>

      {/* Libraries List */}
      <div className="flex-1 overflow-auto">
        {libraries.length === 0 ? (
          <div className="h-full flex items-center justify-center">
            <div className="text-center">
              <svg viewBox="0 0 24 24" className="w-16 h-16 text-ide-textDim mx-auto mb-4" fill="none" stroke="currentColor" strokeWidth="1.5">
                <path d="M5 19a2 2 0 01-2-2V7a2 2 0 012-2h4l2 2h4a2 2 0 012 2v1M5 19h14a2 2 0 002-2v-5a2 2 0 00-2-2H9a2 2 0 00-2 2v5a2 2 0 01-2 2z" />
              </svg>
              <p className="text-ide-textDim mb-2">暂无算法库</p>
              <p className="text-sm text-ide-textDim">点击"新建库"创建算法库</p>
            </div>
          </div>
        ) : (
          <div className="grid grid-cols-2 gap-4">
            {libraries.map((library) => (
              <div
                key={library.id}
                className="p-4 rounded-lg border border-ide-border bg-ide-sidebar hover:border-ide-textDim transition-colors"
              >
                <div className="flex items-start justify-between mb-3">
                  <div>
                    <h3 className="text-sm font-semibold text-white">{library.name}</h3>
                    <p className="text-xs text-ide-textDim mt-1 line-clamp-2">{library.description}</p>
                  </div>
                  <div className="flex gap-1">
                    <button
                      onClick={() => handleToggleShare(library.id, library.is_shared)}
                      className={`p-1 transition-colors ${
                        library.is_shared
                          ? "text-green-400 hover:text-green-300"
                          : "text-ide-textDim hover:text-ide-text"
                      }`}
                      title={library.is_shared ? "取消共享" : "设为共享"}
                    >
                      <svg viewBox="0 0 24 24" className="w-4 h-4" fill="none" stroke="currentColor" strokeWidth="2">
                        {library.is_shared ? (
                          <path d="M13.828 10.172a4 4 0 00-5.656 0l-4 4a4 4 0 105.656 5.656l1.102-1.101m-.758-4.899a4 4 0 005.656 0l4-4a4 4 0 00-5.656-5.656l-1.1 1.1" />
                        ) : (
                          <path d="M15.707 15.707a4 4 0 01-5.656 0l-4-4a4 4 0 015.656-5.656l1.102 1.101m-.758 4.899a4 4 0 01-5.656 0l-4-4a4 4 0 015.656-5.656l1.1 1.1" />
                        )}
                      </svg>
                    </button>
                    <button
                      onClick={() => {
                        if (confirm(`确定要删除库 "${library.name}" 吗？`)) {
                          handleDeleteLibrary(library.id);
                        }
                      }}
                      className="p-1 text-ide-textDim hover:text-red-400 transition-colors"
                      title="删除"
                    >
                      <svg viewBox="0 0 24 24" className="w-4 h-4" fill="none" stroke="currentColor" strokeWidth="2">
                        <path d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16" />
                      </svg>
                    </button>
                  </div>
                </div>
                
                <div className="flex items-center gap-4 text-xs text-ide-textDim">
                  <span>{library.blocks_count} 个算法块</span>
                  <span>•</span>
                  <span>{library.owner || "未指定"}</span>
                  <span>•</span>
                  <span>{new Date(library.created_at).toLocaleDateString()}</span>
                </div>
                
                {library.is_shared && (
                  <div className="mt-2">
                    <span className="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-green-500/20 text-green-400">
                      共享库
                    </span>
                  </div>
                )}
              </div>
            ))}
          </div>
        )}
      </div>

      {/* Create Dialog */}
      {showCreateDialog && (
        <div className="fixed inset-0 bg-black/50 flex items-center justify-center z-50" onClick={() => setShowCreateDialog(false)}>
          <div className="bg-ide-sidebar border border-ide-border rounded-lg p-6 w-96" onClick={(e) => e.stopPropagation()}>
            <h3 className="text-lg font-semibold text-white mb-4">新建算法库</h3>
            
            <div className="mb-4">
              <label className="block text-sm text-ide-textDim mb-2">库名称</label>
              <input
                type="text"
                value={newLibraryName}
                onChange={(e) => setNewLibraryName(e.target.value)}
                className="w-full px-3 py-2 bg-ide-bg border border-ide-border rounded text-sm text-white focus:outline-none focus:border-ide-accent"
                placeholder="例如：我的算法库"
              />
            </div>
            
            <div className="mb-6">
              <label className="block text-sm text-ide-textDim mb-2">描述</label>
              <textarea
                value={newLibraryDesc}
                onChange={(e) => setNewLibraryDesc(e.target.value)}
                className="w-full px-3 py-2 bg-ide-bg border border-ide-border rounded text-sm text-white focus:outline-none focus:border-ide-accent resize-none"
                rows={3}
                placeholder="可选的库描述"
              />
            </div>
            
            <div className="flex gap-2">
              <button
                onClick={() => setShowCreateDialog(false)}
                className="flex-1 px-4 py-2 bg-ide-bg border border-ide-border rounded text-sm text-ide-text hover:bg-ide-hover transition-colors"
              >
                取消
              </button>
              <button
                onClick={handleCreateLibrary}
                disabled={!newLibraryName.trim()}
                className="flex-1 px-4 py-2 bg-ide-accent hover:bg-blue-600 rounded text-sm text-white transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
              >
                创建
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
