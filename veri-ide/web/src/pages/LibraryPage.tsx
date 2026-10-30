import { useState, useEffect } from "react";
import { BlockLibrary } from "../components/library/BlockLibrary";
import { LibraryManager } from "../components/library/LibraryManager";

interface AlgorithmBlock {
  id: string;
  name: string;
  category: string;
  version: string;
  description: string;
  author: string;
  created_at: string;
  updated_at: string;
  inputs: Array<{ name: string; direction: string; data_type: string; description: string }>;
  outputs: Array<{ name: string; direction: string; data_type: string; description: string }>;
  parameters: Array<{ name: string; data_type: string; default_value: any; description: string }>;
  st_template: string;
  icon_svg: string;
  tags: string[];
  sha256: string;
}

type LibraryTab = "blocks" | "libraries";

export function LibraryPage() {
  const [activeTab, setActiveTab] = useState<LibraryTab>("blocks");
  const [blocks, setBlocks] = useState<AlgorithmBlock[]>([]);
  const [selectedBlock, setSelectedBlock] = useState<string | null>(null);

  // Fetch blocks from backend
  useEffect(() => {
    const fetchBlocks = async () => {
      try {
        const response = await fetch("http://localhost:8000/library/blocks");
        if (response.ok) {
          const data = await response.json();
          setBlocks(data);
        }
      } catch (error) {
        console.error("Failed to fetch blocks:", error);
      }
    };

    fetchBlocks();
  }, []);

  const handleDeleteBlock = async (blockId: string) => {
    try {
      const response = await fetch(`http://localhost:8000/library/blocks/${blockId}`, {
        method: "DELETE",
      });
      if (response.ok) {
        setBlocks(blocks.filter((b) => b.id !== blockId));
        if (selectedBlock === blockId) {
          setSelectedBlock(null);
        }
      }
    } catch (error) {
      console.error("Failed to delete block:", error);
    }
  };

  const tabs = [
    { id: "blocks" as LibraryTab, label: "算法块库", icon: "M19.428 15.428a2 2 0 00-1.022-.547l-2.387-.477a6 6 0 00-3.86.517l-.318.158a6 6 0 01-3.86.517L6.05 15.21a2 2 0 00-1.022.547L3 17.5h2m14.428-2.072a2 2 0 011.022.547l2.387.477a6 6 0 003.86-.517l.318-.158a6 6 0 013.86-.517l1.95-1.592a2 2 0 011.022-.547H21m-14.428-2.072a2 2 0 00-1.022-.547l-2.387-.477a6 6 0 00-3.86.517l-.318.158a6 6 0 01-3.86.517L3 7.5h2m14.428 2.072a2 2 0 011.022.547l2.387.477a6 6 0 003.86-.517l.318-.158a6 6 0 013.86-.517l1.95-1.592a2 2 0 001.022-.547H21" },
    { id: "libraries" as LibraryTab, label: "库管理", icon: "M5 19a2 2 0 01-2-2V7a2 2 0 012-2h4l2 2h4a2 2 0 012 2v1M5 19h14a2 2 0 002-2v-5a2 2 0 00-2-2H9a2 2 0 00-2 2v5a2 2 0 01-2 2z" },
  ];

  return (
    <div className="h-full flex flex-col">
      {/* Header */}
      <div className="h-12 bg-ide-sidebar border-b border-ide-border flex items-center px-4">
        <div className="flex items-center gap-2">
          <svg viewBox="0 0 24 24" className="w-5 h-5 text-ide-accent" fill="none" stroke="currentColor" strokeWidth="2">
            <path d="M19.428 15.428a2 2 0 00-1.022-.547l-2.387-.477a6 6 0 00-3.86.517l-.318.158a6 6 0 01-3.86.517L6.05 15.21a2 2 0 00-1.022.547L3 17.5h2m14.428-2.072a2 2 0 011.022.547l2.387.477a6 6 0 003.86-.517l.318-.158a6 6 0 013.86-.517l1.95-1.592a2 2 0 011.022-.547H21" />
          </svg>
          <h1 className="text-lg font-semibold text-white">算法块与算法库</h1>
        </div>
        
        <div className="flex-1" />
        
        <span className="text-sm text-ide-textDim">{blocks.length} 个算法块</span>
      </div>

      {/* Tab Navigation */}
      <div className="h-10 bg-ide-sidebar border-b border-ide-border flex items-center px-4 gap-1">
        {tabs.map((tab) => (
          <button
            key={tab.id}
            onClick={() => setActiveTab(tab.id)}
            className={`flex items-center gap-2 px-4 py-1.5 rounded-t text-sm font-medium transition-colors ${
              activeTab === tab.id
                ? "bg-ide-bg text-white border-b-2 border-ide-accent"
                : "text-ide-textDim hover:text-ide-text hover:bg-ide-hover"
            }`}
          >
            <svg viewBox="0 0 24 24" className="w-4 h-4" fill="none" stroke="currentColor" strokeWidth="2">
              <path d={tab.icon} />
            </svg>
            {tab.label}
          </button>
        ))}
      </div>

      {/* Content */}
      <div className="flex-1 flex overflow-hidden">
        {/* Main Content Area */}
        <div className="flex-1 overflow-auto bg-ide-bg p-4">
          {activeTab === "blocks" && (
            <BlockLibrary
              blocks={blocks}
              selectedBlock={selectedBlock}
              onSelect={setSelectedBlock}
              onDelete={handleDeleteBlock}
            />
          )}
          {activeTab === "libraries" && (
            <LibraryManager />
          )}
        </div>

        {/* Right Panel - Block Details */}
        {selectedBlock && activeTab === "blocks" && (
          <div className="w-96 bg-ide-sidebar border-l border-ide-border overflow-y-auto">
            <div className="p-4">
              <h3 className="text-sm font-semibold text-white mb-3">算法块详情</h3>
              {(() => {
                const block = blocks.find((b) => b.id === selectedBlock);
                if (!block) return null;
                
                return (
                  <div className="space-y-4">
                    {/* Basic Info */}
                    <div>
                      <div className="text-xs text-ide-textDim mb-1">名称</div>
                      <div className="text-sm text-white font-semibold">{block.name}</div>
                    </div>
                    
                    <div>
                      <div className="text-xs text-ide-textDim mb-1">ID</div>
                      <div className="text-sm text-white font-mono text-xs">{block.id}</div>
                    </div>
                    
                    <div>
                      <div className="text-xs text-ide-textDim mb-1">分类</div>
                      <div className="text-sm text-white capitalize">{block.category}</div>
                    </div>
                    
                    <div>
                      <div className="text-xs text-ide-textDim mb-1">版本</div>
                      <div className="text-sm text-white">{block.version}</div>
                    </div>
                    
                    <div>
                      <div className="text-xs text-ide-textDim mb-1">描述</div>
                      <div className="text-sm text-ide-text">{block.description}</div>
                    </div>
                    
                    <div>
                      <div className="text-xs text-ide-textDim mb-1">作者</div>
                      <div className="text-sm text-white">{block.author || "-"}</div>
                    </div>
                    
                    {/* Inputs */}
                    <div>
                      <div className="text-xs text-ide-textDim mb-2">输入端口 ({block.inputs.length})</div>
                      <div className="space-y-1">
                        {block.inputs.map((input) => (
                          <div key={input.name} className="px-2 py-1 bg-ide-bg rounded text-xs">
                            <span className="text-blue-400 font-mono">{input.name}</span>
                            <span className="text-ide-textDim ml-2">{input.data_type}</span>
                          </div>
                        ))}
                      </div>
                    </div>
                    
                    {/* Outputs */}
                    <div>
                      <div className="text-xs text-ide-textDim mb-2">输出端口 ({block.outputs.length})</div>
                      <div className="space-y-1">
                        {block.outputs.map((output) => (
                          <div key={output.name} className="px-2 py-1 bg-ide-bg rounded text-xs">
                            <span className="text-green-400 font-mono">{output.name}</span>
                            <span className="text-ide-textDim ml-2">{output.data_type}</span>
                          </div>
                        ))}
                      </div>
                    </div>
                    
                    {/* Parameters */}
                    {block.parameters.length > 0 && (
                      <div>
                        <div className="text-xs text-ide-textDim mb-2">参数 ({block.parameters.length})</div>
                        <div className="space-y-1">
                          {block.parameters.map((param) => (
                            <div key={param.name} className="px-2 py-1 bg-ide-bg rounded text-xs">
                              <span className="text-orange-400 font-mono">{param.name}</span>
                              <span className="text-ide-textDim ml-2">= {String(param.default_value)}</span>
                            </div>
                          ))}
                        </div>
                      </div>
                    )}
                    
                    {/* Tags */}
                    {block.tags.length > 0 && (
                      <div>
                        <div className="text-xs text-ide-textDim mb-2">标签</div>
                        <div className="flex flex-wrap gap-1">
                          {block.tags.map((tag) => (
                            <span key={tag} className="px-2 py-0.5 bg-ide-accent/20 text-ide-accent rounded text-xs">
                              {tag}
                            </span>
                          ))}
                        </div>
                      </div>
                    )}
                    
                    {/* ST Template Preview */}
                    {block.st_template && (
                      <div>
                        <div className="text-xs text-ide-textDim mb-2">ST 代码模板</div>
                        <pre className="px-3 py-2 bg-ide-bg rounded text-xs text-ide-text overflow-auto max-h-48 font-mono">
                          {block.st_template}
                        </pre>
                      </div>
                    )}
                    
                    {/* SHA-256 */}
                    <div>
                      <div className="text-xs text-ide-textDim mb-1">SHA-256</div>
                      <div className="text-xs text-ide-textDim font-mono break-all">{block.sha256}</div>
                    </div>
                  </div>
                );
              })()}
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
