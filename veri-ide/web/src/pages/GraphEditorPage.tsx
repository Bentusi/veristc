import { useState, useRef, useEffect, useCallback } from "react";

interface Block {
  id: string;
  type: string;
  x: number;
  y: number;
  parameters: Record<string, string | number>;
}

interface Connection {
  id: string;
  from: { block: string; port: string };
  to: { block: string; port: string };
}

interface Variable {
  name: string;
  type: string;
  direction: "INPUT" | "OUTPUT" | "IN_OUT" | "LOCAL";
}

const BLOCK_TYPES = [
  { type: "PID", label: "PID 控制器", color: "#4ec9b0", desc: "比例积分微分控制" },
  { type: "LIMITER", label: "限幅器", color: "#569cd6", desc: "信号限幅保护" },
  { type: "RS", label: "RS 触发器", color: "#c586c0", desc: "置位复位触发器" },
  { type: "FBY", label: "延迟单元", color: "#dcdcaa", desc: "单周期延迟" },
];

const VARIABLES: Variable[] = [
  { name: "SP", type: "REAL", direction: "INPUT" },
  { name: "PV", type: "REAL", direction: "INPUT" },
  { name: "OUT", type: "REAL", direction: "OUTPUT" },
  { name: "ERR", type: "REAL", direction: "LOCAL" },
];

export function GraphEditorPage() {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const [blocks, setBlocks] = useState<Block[]>([]);
  const [connections] = useState<Connection[]>([]);
  const [selectedBlock, setSelectedBlock] = useState<string | null>(null);
  const [dragging, setDragging] = useState<{ id: string; offsetX: number; offsetY: number } | null>(null);
  const [showAddBlock, setShowAddBlock] = useState(false);

  const drawCanvas = useCallback(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;

    canvas.width = canvas.offsetWidth;
    canvas.height = canvas.offsetHeight;

    // Background
    ctx.fillStyle = "#1e1e1e";
    ctx.fillRect(0, 0, canvas.width, canvas.height);

    // Grid
    ctx.strokeStyle = "#2d2d30";
    ctx.lineWidth = 1;
    for (let x = 0; x < canvas.width; x += 20) {
      ctx.beginPath();
      ctx.moveTo(x, 0);
      ctx.lineTo(x, canvas.height);
      ctx.stroke();
    }
    for (let y = 0; y < canvas.height; y += 20) {
      ctx.beginPath();
      ctx.moveTo(0, y);
      ctx.lineTo(canvas.width, y);
      ctx.stroke();
    }

    // Connections
    connections.forEach((conn) => {
      const fromBlock = blocks.find((b) => b.id === conn.from.block);
      const toBlock = blocks.find((b) => b.id === conn.to.block);
      if (fromBlock && toBlock) {
        ctx.strokeStyle = "#569cd6";
        ctx.lineWidth = 2;
        ctx.setLineDash([5, 3]);
        ctx.beginPath();
        ctx.moveTo(fromBlock.x + 60, fromBlock.y + 30);
        ctx.lineTo(toBlock.x, toBlock.y + 30);
        ctx.stroke();
        ctx.setLineDash([]);
      }
    });

    // Blocks
    blocks.forEach((block) => {
      const blockType = BLOCK_TYPES.find((bt) => bt.type === block.type);
      const color = blockType?.color || "#569cd6";
      const isSelected = block.id === selectedBlock;

      // Shadow
      ctx.shadowColor = "rgba(0, 0, 0, 0.3)";
      ctx.shadowBlur = 8;
      ctx.shadowOffsetY = 2;

      // Block body
      ctx.fillStyle = isSelected ? "#2d2d30" : "#252526";
      ctx.strokeStyle = color;
      ctx.lineWidth = isSelected ? 3 : 2;
      ctx.beginPath();
      ctx.roundRect(block.x, block.y, 120, 60, 6);
      ctx.fill();
      ctx.stroke();

      ctx.shadowColor = "transparent";

      // Type label
      ctx.fillStyle = color;
      ctx.font = "bold 11px sans-serif";
      ctx.fillText(block.type, block.x + 10, block.y + 22);

      // ID label
      ctx.fillStyle = "#cccccc";
      ctx.font = "10px sans-serif";
      ctx.fillText(block.id, block.x + 10, block.y + 40);

      // Port indicators
      ctx.fillStyle = "#4ec9b0";
      ctx.beginPath();
      ctx.arc(block.x, block.y + 30, 4, 0, Math.PI * 2);
      ctx.fill();

      ctx.fillStyle = "#f48771";
      ctx.beginPath();
      ctx.arc(block.x + 120, block.y + 30, 4, 0, Math.PI * 2);
      ctx.fill();
    });

    // Empty state
    if (blocks.length === 0) {
      ctx.fillStyle = "#585b70";
      ctx.font = "14px sans-serif";
      ctx.textAlign = "center";
      ctx.fillText("点击左侧功能块添加到画布", canvas.width / 2, canvas.height / 2);
      ctx.textAlign = "left";
    }
  }, [blocks, connections, selectedBlock]);

  useEffect(() => {
    drawCanvas();
  }, [drawCanvas]);

  const handleCanvasClick = (e: React.MouseEvent<HTMLCanvasElement>) => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const rect = canvas.getBoundingClientRect();
    const x = e.clientX - rect.left;
    const y = e.clientY - rect.top;

    const clickedBlock = blocks.find(
      (b) => x >= b.x && x <= b.x + 120 && y >= b.y && y <= b.y + 60
    );

    if (clickedBlock) {
      setSelectedBlock(clickedBlock.id);
      setDragging({ id: clickedBlock.id, offsetX: x - clickedBlock.x, offsetY: y - clickedBlock.y });
    } else {
      setSelectedBlock(null);
    }
  };

  const handleCanvasMouseMove = (e: React.MouseEvent<HTMLCanvasElement>) => {
    if (!dragging) return;
    const canvas = canvasRef.current;
    if (!canvas) return;
    const rect = canvas.getBoundingClientRect();
    const x = e.clientX - rect.left - dragging.offsetX;
    const y = e.clientY - rect.top - dragging.offsetY;

    setBlocks((prev) =>
      prev.map((b) => (b.id === dragging.id ? { ...b, x, y } : b))
    );
  };

  const handleCanvasMouseUp = () => {
    setDragging(null);
  };

  const addBlock = (type: string) => {
    const newBlock: Block = {
      id: `${type}_${blocks.length + 1}`,
      type,
      x: 100 + Math.random() * 200,
      y: 100 + Math.random() * 200,
      parameters: {},
    };
    setBlocks([...blocks, newBlock]);
    setShowAddBlock(false);
  };

  const generateST = () => {
    const lines = ["PROGRAM MAIN", "VAR", ...VARIABLES.map((v) => `  ${v.name} : ${v.type};`), "END_VAR", ""];

    blocks.forEach((block) => {
      lines.push(`${block.id} : ${block.type};`);
    });
    lines.push("");

    blocks.forEach((block) => {
      const params = Object.entries(block.parameters)
        .map(([k, v]) => `${k} := ${v}`)
        .join(", ");
      lines.push(`${block.id}(${params});`);
    });

    lines.push("END_PROGRAM");
    return lines.join("\n");
  };

  const selectedBlockData = blocks.find((b) => b.id === selectedBlock);

  return (
    <div className="h-full flex flex-col">
      {/* Toolbar */}
      <div className="h-10 bg-ide-sidebar border-b border-ide-border flex items-center px-4 gap-2">
        <button
          onClick={() => setShowAddBlock(!showAddBlock)}
          className="px-3 py-1.5 bg-ide-accent text-white text-xs rounded hover:bg-blue-600 transition-colors"
        >
          + 添加功能块
        </button>
        <div className="w-px h-5 bg-ide-border mx-1" />
        <button className="px-3 py-1.5 bg-ide-hover text-ide-text text-xs rounded hover:bg-ide-selected transition-colors">
          清空画布
        </button>
        <div className="flex-1" />
        <span className="text-xs text-ide-textDim">
          {blocks.length} 个功能块 · {connections.length} 条连线
        </span>
        <div className="w-px h-5 bg-ide-border mx-1" />
        <button className="px-3 py-1.5 bg-ide-hover text-ide-text text-xs rounded hover:bg-ide-selected transition-colors">
          导出 ST
        </button>
      </div>

      <div className="flex-1 flex overflow-hidden">
        {/* Left Panel - Block Library */}
        <div className="w-56 bg-ide-sidebar border-r border-ide-border flex flex-col">
          <div className="p-3 border-b border-ide-border">
            <div className="text-xs font-semibold uppercase text-ide-textDim mb-2">功能块库</div>
            <div className="space-y-1">
              {BLOCK_TYPES.map((bt) => (
                <button
                  key={bt.type}
                  onClick={() => addBlock(bt.type)}
                  className="w-full text-left px-2.5 py-2 text-xs rounded hover:bg-ide-hover transition-colors flex items-center gap-2"
                >
                  <div className="w-2.5 h-2.5 rounded-full" style={{ backgroundColor: bt.color }} />
                  <div>
                    <div className="font-medium">{bt.label}</div>
                    <div className="text-[10px] text-ide-textDim">{bt.desc}</div>
                  </div>
                </button>
              ))}
            </div>
          </div>

          <div className="p-3 flex-1 overflow-y-auto">
            <div className="text-xs font-semibold uppercase text-ide-textDim mb-2">变量</div>
            <div className="space-y-1">
              {VARIABLES.map((v) => (
                <div key={v.name} className="px-2 py-1.5 text-xs flex justify-between items-center rounded hover:bg-ide-hover">
                  <div className="flex items-center gap-2">
                    <div className={`w-1.5 h-1.5 rounded-full ${
                      v.direction === "INPUT" ? "bg-green-500" :
                      v.direction === "OUTPUT" ? "bg-red-500" :
                      "bg-gray-500"
                    }`} />
                    <span>{v.name}</span>
                  </div>
                  <span className="text-ide-textDim">{v.type}</span>
                </div>
              ))}
            </div>
          </div>
        </div>

        {/* Canvas */}
        <div className="flex-1 relative">
          <canvas
            ref={canvasRef}
            className="w-full h-full cursor-crosshair"
            onClick={handleCanvasClick}
            onMouseMove={handleCanvasMouseMove}
            onMouseUp={handleCanvasMouseUp}
            onMouseLeave={handleCanvasMouseUp}
          />
          {showAddBlock && (
            <div className="absolute top-12 left-4 bg-ide-sidebar border border-ide-border rounded-lg p-2 shadow-xl z-10">
              {BLOCK_TYPES.map((bt) => (
                <button
                  key={bt.type}
                  onClick={() => addBlock(bt.type)}
                  className="w-full text-left px-3 py-2 text-xs rounded hover:bg-ide-hover mb-1 flex items-center gap-2"
                >
                  <div className="w-2 h-2 rounded-full" style={{ backgroundColor: bt.color }} />
                  {bt.label}
                </button>
              ))}
            </div>
          )}
        </div>

        {/* Right Panel - Properties */}
        <div className="w-72 bg-ide-sidebar border-l border-ide-border flex flex-col">
          <div className="p-3 border-b border-ide-border">
            <div className="text-xs font-semibold uppercase text-ide-textDim">属性</div>
          </div>

          {selectedBlockData ? (
            <div className="p-3 flex-1 overflow-y-auto">
              <div className="space-y-4">
                <div>
                  <div className="text-xs text-ide-textDim mb-1">块 ID</div>
                  <div className="text-sm font-mono bg-ide-bg px-2 py-1 rounded">{selectedBlockData.id}</div>
                </div>
                <div>
                  <div className="text-xs text-ide-textDim mb-1">类型</div>
                  <div className="text-sm">{selectedBlockData.type}</div>
                </div>
                <div>
                  <div className="text-xs text-ide-textDim mb-1">位置</div>
                  <div className="text-sm font-mono">
                    X: {Math.round(selectedBlockData.x)}, Y: {Math.round(selectedBlockData.y)}
                  </div>
                </div>
              </div>
            </div>
          ) : (
            <div className="p-3 flex-1 flex items-center justify-center text-ide-textDim text-xs">
              <div className="text-center">
                <svg viewBox="0 0 24 24" className="w-8 h-8 mx-auto mb-2 opacity-30" fill="currentColor">
                  <path d="M3 3h8v8H3V3zm0 10h8v8H3v-8zm10-10h8v8h-8V3zm0 10h8v8h-8v-8z" />
                </svg>
                选择功能块查看属性
              </div>
            </div>
          )}

          {/* ST Code Preview */}
          <div className="border-t border-ide-border">
            <div className="p-3 text-xs font-semibold uppercase text-ide-textDim flex justify-between items-center">
              <span>生成的 ST 代码</span>
              <button className="text-[10px] text-ide-accent hover:underline">复制</button>
            </div>
            <pre className="p-3 bg-ide-bg text-xs text-ide-text overflow-auto max-h-48 font-mono leading-relaxed">
              {generateST()}
            </pre>
          </div>
        </div>
      </div>
    </div>
  );
}
