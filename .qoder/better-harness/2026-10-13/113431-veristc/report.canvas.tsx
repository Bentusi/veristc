import { useState } from "react";

const data = {
  title: "VeriSTC Harness 实践分析",
  subtitle: "形式化验证编译器 + 安全虚拟机的工程化实践评估",
  grade: "B",
  score: 78,
  metrics: [
    { label: "Harness 评分", value: "78/100", color: "#4CAF50" },
    { label: "Coq 代码", value: "25,397 行", color: "#2196F3" },
    { label: "C 代码", value: "4,751 行", color: "#FF9800" },
    { label: "测试层级", value: "4 层", color: "#9C27B0" },
  ],
  radar: [
    { label: "构建系统", value: 72 },
    { label: "测试体系", value: 85 },
    { label: "CI/CD", value: 45 },
    { label: "形式化验证", value: 95 },
    { label: "代码架构", value: 82 },
    { label: "文档规范", value: 88 },
    { label: "安全质量", value: 80 },
  ],
  strengths: [
    { icon: "🏛️", title: "形式化验证深度", desc: "25,397 行 Coq 代码，4 大核心定理覆盖完整编译管线语义保持" },
    { icon: "🔬", title: "特性探针矩阵", desc: "12 个探针 PASS/XFAIL/TRAP 三态设计，XFAIL→PASS 自动检测防漂移" },
    { icon: "🎯", title: "独立黄金验证", desc: "核电 RPS 38 周期黄金时间线由设计文档手算推导，非捕获式" },
    { icon: "📐", title: "编译器管线分层", desc: "10 层管线每层独立证明，codegen.v 单文件 8,200 行" },
    { icon: "📚", title: "三层文档体系", desc: "Spec → Plan → AGENTS.md 交叉引用，版本控制规范" },
  ],
  weaknesses: [
    { icon: "🚨", title: "无 CI/CD 自动化", desc: "无 GitHub Actions，所有测试需手动执行", severity: "critical" },
    { icon: "⚠️", title: "Coq 依赖手动维护", desc: "Makefile 中 21 条 .vo 依赖手动声明", severity: "warning" },
    { icon: "⚠️", title: "VM 测试构建不一致", desc: "test_vm.c #include 源码内联而非链接静态库", severity: "warning" },
    { icon: "⚠️", title: "MISRA-C 未自动检查", desc: "声明使用但无 cppcheck/PC-lint 集成", severity: "warning" },
    { icon: "ℹ️", title: "无模糊测试", desc: "VM 处理外部输入但未集成 ASan/AFL", severity: "info" },
  ],
  pipeline: [
    { label: ".st", short: "ST 源文件" },
    { label: "lexer", short: "词法分析" },
    { label: "parser", short: "递归下降解析" },
    { label: "fcheck", short: "函数检查" },
    { label: "inline", short: "内联展开" },
    { label: "desugar", short: "脱糖" },
    { label: "analysis", short: "静态分析" },
    { label: "codegen", short: "代码生成" },
    { label: "global", short: "全局编排" },
    { label: "encoder", short: "二进制编码" },
    { label: ".sasm", short: "SafeASM 字节码" },
    { label: "VM", short: "C 虚拟机" },
  ],
  testPyramid: [
    { label: "端到端验证", count: "1 用例", detail: "nuclear_rps_esfas_full.st (>10000行)", color: "#E91E63", width: 40 },
    { label: "特性探针矩阵", count: "12 探针", detail: "8 PASS + 4 XFAIL，golden 比对", color: "#9C27B0", width: 55 },
    { label: "VM/SVM 检查", count: "4 组", detail: "单元+周期+FUNCTION安全门+CRC+定时", color: "#FF9800", width: 70 },
    { label: "指令级单元", count: "4 测试", detail: "算术/分支/除零/CALL", color: "#4CAF50", width: 85 },
  ],
  recommendations: [
    { priority: "P0", title: "添加 GitHub Actions CI", desc: "Coq → extraction → C → 全量测试", effort: "中" },
    { priority: "P1", title: "迁移 Coq 构建到 dune", desc: "自动处理依赖和并行编译", effort: "中" },
    { priority: "P1", title: "集成 MISRA-C 检查", desc: "cppcheck 自动验证安全约束", effort: "低" },
    { priority: "P2", title: "添加 ASan/UBSan 变体", desc: "CI 中捕获内存安全漏洞", effort: "低" },
    { priority: "P2", title: ".sasm 模糊测试", desc: "AFL/libFuzzer 验证加载器", effort: "中" },
  ],
};

function GradeBadge({ grade, score }: { grade: string; score: number }) {
  const colors: Record<string, string> = {
    A: "#4CAF50", B: "#2196F3", C: "#FF9800", D: "#f44336",
  };
  return (
    <div style={{
      display: "flex", alignItems: "center", gap: 12,
      background: "linear-gradient(135deg, #1a1a2e 0%, #16213e 100%)",
      borderRadius: 16, padding: "16px 24px",
    }}>
      <div style={{
        width: 64, height: 64, borderRadius: "50%",
        background: colors[grade] || "#666",
        display: "flex", alignItems: "center", justifyContent: "center",
        fontSize: 32, fontWeight: "bold", color: "#fff",
        boxShadow: `0 0 20px ${colors[grade]}40`,
      }}>{grade}</div>
      <div>
        <div style={{ fontSize: 28, fontWeight: "bold", color: "#fff" }}>{score}<span style={{ fontSize: 14, color: "#888" }}>/100</span></div>
        <div style={{ fontSize: 12, color: "#888" }}>Harness Score</div>
      </div>
    </div>
  );
}

function MetricCards({ metrics }: { metrics: typeof data.metrics }) {
  return (
    <div style={{ display: "grid", gridTemplateColumns: "repeat(4, 1fr)", gap: 12 }}>
      {metrics.map((m, i) => (
        <div key={i} style={{
          background: "#1a1a2e", borderRadius: 12, padding: "14px 16px",
          borderLeft: `3px solid ${m.color}`,
        }}>
          <div style={{ fontSize: 11, color: "#888", marginBottom: 4 }}>{m.label}</div>
          <div style={{ fontSize: 20, fontWeight: "bold", color: m.color }}>{m.value}</div>
        </div>
      ))}
    </div>
  );
}

function RadarChart({ axes }: { axes: typeof data.radar }) {
  const cx = 140, cy = 140, r = 110;
  const n = axes.length;
  const angleStep = (2 * Math.PI) / n;

  const getPoint = (index: number, value: number) => {
    const angle = angleStep * index - Math.PI / 2;
    const dist = (value / 100) * r;
    return { x: cx + dist * Math.cos(angle), y: cy + dist * Math.sin(angle) };
  };

  const dataPoints = axes.map((a, i) => getPoint(i, a.value));
  const pathD = dataPoints.map((p, i) => `${i === 0 ? "M" : "L"} ${p.x} ${p.y}`).join(" ") + " Z";

  return (
    <svg width={280} height={280} style={{ display: "block", margin: "0 auto" }}>
      {[20, 40, 60, 80, 100].map((v) => {
        const pts = Array.from({ length: n }, (_, i) => getPoint(i, v));
        const d = pts.map((p, i) => `${i === 0 ? "M" : "L"} ${p.x} ${p.y}`).join(" ") + " Z";
        return <path key={v} d={d} fill="none" stroke="#333" strokeWidth={0.5} />;
      })}
      {axes.map((_, i) => {
        const end = getPoint(i, 100);
        return <line key={i} x1={cx} y1={cy} x2={end.x} y2={end.y} stroke="#333" strokeWidth={0.5} />;
      })}
      <path d={pathD} fill="rgba(33, 150, 243, 0.2)" stroke="#2196F3" strokeWidth={2} />
      {dataPoints.map((p, i) => (
        <circle key={i} cx={p.x} cy={p.y} r={4} fill="#2196F3" />
      ))}
      {axes.map((a, i) => {
        const lp = getPoint(i, 118);
        return (
          <text key={i} x={lp.x} y={lp.y} textAnchor="middle" dominantBaseline="middle"
            fill="#ccc" fontSize={10}>{a.label}</text>
        );
      })}
    </svg>
  );
}

function Pipeline() {
  return (
    <div style={{ display: "flex", alignItems: "center", gap: 2, overflowX: "auto", padding: "8px 0" }}>
      {data.pipeline.map((node, i) => (
        <div key={i} style={{ display: "flex", alignItems: "center" }}>
          <div style={{
            background: i === 0 || i === data.pipeline.length - 2
              ? "linear-gradient(135deg, #1a237e, #283593)"
              : i === data.pipeline.length - 1
                ? "linear-gradient(135deg, #b71c1c, #c62828)"
                : "linear-gradient(135deg, #1a1a2e, #16213e)",
            borderRadius: 8, padding: "6px 8px", minWidth: 52, textAlign: "center",
            border: "1px solid #333",
          }}>
            <div style={{ fontSize: 10, fontWeight: "bold", color: "#fff" }}>{node.label}</div>
            <div style={{ fontSize: 8, color: "#888" }}>{node.short}</div>
          </div>
          {i < data.pipeline.length - 1 && (
            <div style={{ color: "#555", fontSize: 12, margin: "0 1px" }}>→</div>
          )}
        </div>
      ))}
    </div>
  );
}

function TestPyramid() {
  return (
    <div style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: 4 }}>
      {data.testPyramid.map((layer, i) => (
        <div key={i} style={{
          width: `${layer.width}%`, background: layer.color + "20",
          border: `1px solid ${layer.color}60`, borderRadius: 8,
          padding: "8px 16px", display: "flex", justifyContent: "space-between", alignItems: "center",
        }}>
          <div>
            <span style={{ fontSize: 12, fontWeight: "bold", color: layer.color }}>{layer.label}</span>
            <span style={{ fontSize: 10, color: "#888", marginLeft: 8 }}>{layer.detail}</span>
          </div>
          <span style={{ fontSize: 11, color: layer.color, fontWeight: "bold" }}>{layer.count}</span>
        </div>
      ))}
    </div>
  );
}

function SeverityBadge({ severity }: { severity: string }) {
  const colors: Record<string, string> = {
    critical: "#f44336", warning: "#FF9800", info: "#2196F3",
  };
  return (
    <span style={{
      fontSize: 9, padding: "2px 6px", borderRadius: 4,
      background: colors[severity] + "20", color: colors[severity],
      border: `1px solid ${colors[severity]}40`,
    }}>{severity}</span>
  );
}

export default function VeriSTCHarnessReport() {
  const [tab, setTab] = useState<"overview" | "details" | "actions">("overview");

  return (
    <div style={{
      fontFamily: "-apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif",
      background: "#0d1117", color: "#c9d1d9", minHeight: "100vh", padding: 24,
    }}>
      <div style={{ maxWidth: 960, margin: "0 auto" }}>
        {/* Header */}
        <div style={{ marginBottom: 24 }}>
          <h1 style={{ fontSize: 24, fontWeight: "bold", color: "#fff", margin: 0 }}>
            {data.title}
          </h1>
          <p style={{ fontSize: 13, color: "#888", margin: "4px 0 16px" }}>{data.subtitle}</p>
          <GradeBadge grade={data.grade} score={data.score} />
        </div>

        {/* Tabs */}
        <div style={{ display: "flex", gap: 8, marginBottom: 20, borderBottom: "1px solid #333", paddingBottom: 8 }}>
          {(["overview", "details", "actions"] as const).map((t) => (
            <button key={t} onClick={() => setTab(t)} style={{
              padding: "6px 16px", borderRadius: 6, border: "none", cursor: "pointer",
              fontSize: 13, fontWeight: tab === t ? "bold" : "normal",
              background: tab === t ? "#2196F3" : "#1a1a2e",
              color: tab === t ? "#fff" : "#888",
            }}>{t === "overview" ? "概览" : t === "details" ? "详细发现" : "改进建议"}</button>
          ))}
        </div>

        {/* Overview Tab */}
        {tab === "overview" && (
          <div style={{ display: "flex", flexDirection: "column", gap: 20 }}>
            <MetricCards metrics={data.metrics} />
            <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 16 }}>
              <div style={{ background: "#1a1a2e", borderRadius: 12, padding: 16 }}>
                <h3 style={{ fontSize: 14, color: "#fff", margin: "0 0 12px" }}>维度评分</h3>
                <RadarChart axes={data.radar} />
              </div>
              <div style={{ display: "flex", flexDirection: "column", gap: 16 }}>
                <div style={{ background: "#1a1a2e", borderRadius: 12, padding: 16 }}>
                  <h3 style={{ fontSize: 14, color: "#fff", margin: "0 0 8px" }}>编译器管线</h3>
                  <Pipeline />
                </div>
                <div style={{ background: "#1a1a2e", borderRadius: 12, padding: 16 }}>
                  <h3 style={{ fontSize: 14, color: "#fff", margin: "0 0 8px" }}>测试金字塔</h3>
                  <TestPyramid />
                </div>
              </div>
            </div>
          </div>
        )}

        {/* Details Tab */}
        {tab === "details" && (
          <div style={{ display: "flex", flexDirection: "column", gap: 16 }}>
            <div style={{ background: "#1a1a2e", borderRadius: 12, padding: 16 }}>
              <h3 style={{ fontSize: 14, color: "#4CAF50", margin: "0 0 12px" }}>核心优势</h3>
              <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
                {data.strengths.map((s, i) => (
                  <div key={i} style={{
                    display: "flex", gap: 12, padding: "8px 12px",
                    background: "#0d1117", borderRadius: 8, borderLeft: "3px solid #4CAF50",
                  }}>
                    <span style={{ fontSize: 20 }}>{s.icon}</span>
                    <div>
                      <div style={{ fontSize: 13, fontWeight: "bold", color: "#fff" }}>{s.title}</div>
                      <div style={{ fontSize: 11, color: "#888" }}>{s.desc}</div>
                    </div>
                  </div>
                ))}
              </div>
            </div>
            <div style={{ background: "#1a1a2e", borderRadius: 12, padding: 16 }}>
              <h3 style={{ fontSize: 14, color: "#f44336", margin: "0 0 12px" }}>待改进项</h3>
              <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
                {data.weaknesses.map((w, i) => (
                  <div key={i} style={{
                    display: "flex", gap: 12, padding: "8px 12px", alignItems: "flex-start",
                    background: "#0d1117", borderRadius: 8,
                    borderLeft: `3px solid ${w.severity === "critical" ? "#f44336" : w.severity === "warning" ? "#FF9800" : "#2196F3"}`,
                  }}>
                    <span style={{ fontSize: 20 }}>{w.icon}</span>
                    <div style={{ flex: 1 }}>
                      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
                        <span style={{ fontSize: 13, fontWeight: "bold", color: "#fff" }}>{w.title}</span>
                        <SeverityBadge severity={w.severity} />
                      </div>
                      <div style={{ fontSize: 11, color: "#888" }}>{w.desc}</div>
                    </div>
                  </div>
                ))}
              </div>
            </div>
          </div>
        )}

        {/* Actions Tab */}
        {tab === "actions" && (
          <div style={{ background: "#1a1a2e", borderRadius: 12, padding: 16 }}>
            <h3 style={{ fontSize: 14, color: "#fff", margin: "0 0 16px" }}>改进路线图</h3>
            <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>
              {data.recommendations.map((r, i) => {
                const pColors: Record<string, string> = { P0: "#f44336", P1: "#FF9800", P2: "#2196F3" };
                return (
                  <div key={i} style={{
                    display: "flex", gap: 12, padding: "10px 14px",
                    background: "#0d1117", borderRadius: 8,
                    border: `1px solid ${pColors[r.priority]}30`,
                  }}>
                    <div style={{
                      background: pColors[r.priority] + "20", color: pColors[r.priority],
                      borderRadius: 6, padding: "4px 8px", fontSize: 11, fontWeight: "bold",
                      minWidth: 28, textAlign: "center", alignSelf: "flex-start",
                    }}>{r.priority}</div>
                    <div style={{ flex: 1 }}>
                      <div style={{ fontSize: 13, fontWeight: "bold", color: "#fff" }}>{r.title}</div>
                      <div style={{ fontSize: 11, color: "#888" }}>{r.desc}</div>
                    </div>
                    <div style={{
                      fontSize: 10, color: "#888", background: "#1a1a2e",
                      borderRadius: 4, padding: "2px 8px", alignSelf: "center",
                    }}>工作量: {r.effort}</div>
                  </div>
                );
              })}
            </div>
          </div>
        )}

        {/* Footer */}
        <div style={{ marginTop: 24, padding: "12px 0", borderTop: "1px solid #333", textAlign: "center" }}>
          <span style={{ fontSize: 11, color: "#555" }}>
            VeriSTC Harness Analysis — Generated 2026-10-13 — 7 categories, 29 findings
          </span>
        </div>
      </div>
    </div>
  );
}
