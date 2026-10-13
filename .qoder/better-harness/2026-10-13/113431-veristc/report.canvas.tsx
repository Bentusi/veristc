import {
  Callout,
  Card,
  CardBody,
  Divider,
  H1,
  MetricsGrid,
  Pill,
  RadarChart,
  ReportSection,
  ReportShell,
  Row,
  ScrollArea,
  Stack,
  Stat,
  Table,
  Tag,
  Text,
  useCanvasState,
} from "qoder/canvas";

const radarCategories = [
  "构建系统",
  "测试体系",
  "CI/CD",
  "形式化验证",
  "代码架构",
  "文档规范",
  "安全质量",
];

const radarSeries = [
  { name: "评分", data: [72, 85, 45, 95, 82, 88, 80] },
];

const pipelineNodes = [
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
];

const testPyramidLayers = [
  { label: "端到端验证", count: "1 用例", detail: "nuclear_rps_esfas_full.st (>10000行)", tone: "danger" as const },
  { label: "特性探针矩阵", count: "12 探针", detail: "8 PASS + 4 XFAIL，golden 比对", tone: "info" as const },
  { label: "VM/SVM 检查", count: "4 组", detail: "单元+周期+FUNCTION安全门+CRC+定时", tone: "warning" as const },
  { label: "指令级单元", count: "4 测试", detail: "算术/分支/除零/CALL", tone: "success" as const },
];

const strengthsRows = [
  ["🏛️ 形式化验证深度", "25,397 行 Coq 代码，4 大核心定理覆盖完整编译管线语义保持"],
  ["🔬 特性探针矩阵", "12 个探针 PASS/XFAIL/TRAP 三态设计，XFAIL→PASS 自动检测防漂移"],
  ["🎯 独立黄金验证", "核电 RPS 38 周期黄金时间线由设计文档手算推导，非捕获式"],
  ["📐 编译器管线分层", "10 层管线每层独立证明，codegen.v 单文件 8,200 行"],
  ["📚 三层文档体系", "Spec → Plan → AGENTS.md 交叉引用，版本控制规范"],
];

const weaknessesData = [
  { title: "无 CI/CD 自动化", desc: "无 GitHub Actions，所有测试需手动执行", severity: "critical" as const },
  { title: "Coq 依赖手动维护", desc: "Makefile 中 21 条 .vo 依赖手动声明", severity: "warning" as const },
  { title: "VM 测试构建不一致", desc: "test_vm.c #include 源码内联而非链接静态库", severity: "warning" as const },
  { title: "MISRA-C 未自动检查", desc: "声明使用但无 cppcheck/PC-lint 集成", severity: "warning" as const },
  { title: "无模糊测试", desc: "VM 处理外部输入但未集成 ASan/AFL", severity: "info" as const },
];

const recommendationsData = [
  { priority: "P0", title: "添加 GitHub Actions CI", desc: "Coq → extraction → C → 全量测试", effort: "中" },
  { priority: "P1", title: "迁移 Coq 构建到 dune", desc: "自动处理依赖和并行编译", effort: "中" },
  { priority: "P1", title: "集成 MISRA-C 检查", desc: "cppcheck 自动验证安全约束", effort: "低" },
  { priority: "P2", title: "添加 ASan/UBSan 变体", desc: "CI 中捕获内存安全漏洞", effort: "低" },
  { priority: "P2", title: ".sasm 模糊测试", desc: "AFL/libFuzzer 验证加载器", effort: "中" },
];

const severityToneMap: Record<string, "danger" | "warning" | "info"> = {
  critical: "danger",
  warning: "warning",
  info: "info",
};

const priorityToneMap: Record<string, "danger" | "warning" | "info"> = {
  P0: "danger",
  P1: "warning",
  P2: "info",
};

export default function VeriSTCHarnessReport() {
  const [tab, setTab] = useCanvasState<"overview" | "details" | "actions">("report-tab", "overview");

  return (
    <ReportShell width="wide" ariaLabel="VeriSTC Harness 实践分析">
      <Stack gap="sectionCompact">
        {/* Header */}
        <Stack gap="component">
          <H1>VeriSTC Harness 实践分析</H1>
          <Text tone="secondary">形式化验证编译器 + 安全虚拟机的工程化实践评估</Text>
          <Row gap="component" align="center">
            <Stat label="Harness 评分" value="78" valueSuffix="/100" tone="success" size="lg" />
            <Stat label="等级" value="B" size="lg" />
          </Row>
          <MetricsGrid
            variant="header"
            columns={4}
            items={[
              { label: "Harness 评分", value: "78/100", tone: "success" },
              { label: "Coq 代码", value: "25,397 行" },
              { label: "C 代码", value: "4,751 行" },
              { label: "测试层级", value: "4 层" },
            ]}
          />
        </Stack>

        <Divider />

        {/* Tab navigation */}
        <Row gap="inline">
          {(["overview", "details", "actions"] as const).map((t) => (
            <Tag
              key={t}
              tone={tab === t ? "primary" : "neutral"}
              active={tab === t}
              onClick={() => setTab(t)}
              style={{ cursor: "pointer" }}
            >
              {t === "overview" ? "概览" : t === "details" ? "详细发现" : "改进建议"}
            </Tag>
          ))}
        </Row>

        {/* Overview Tab */}
        {tab === "overview" && (
          <Stack gap="section">
            <ReportSection title="维度评分" divided>
              <RadarChart
                categories={radarCategories}
                series={radarSeries}
                maxValue={100}
                valueSuffix=""
                ariaLabel="七维度评分雷达图"
              />
            </ReportSection>

            <ReportSection title="编译器管线" divided>
              <ScrollArea axis="x">
                <Row gap="inline" align="center" style={{ padding: "8px 0" }}>
                  {pipelineNodes.map((node, i) => (
                    <Row key={i} gap="inline" align="center">
                      <Card size="sm">
                        <CardBody>
                          <Stack gap={0} align="center">
                            <Text weight="bold" size="small">{node.label}</Text>
                            <Text tone="tertiary" size="small">{node.short}</Text>
                          </Stack>
                        </CardBody>
                      </Card>
                      {i < pipelineNodes.length - 1 && (
                        <Text tone="tertiary" size="small">→</Text>
                      )}
                    </Row>
                  ))}
                </Row>
              </ScrollArea>
            </ReportSection>

            <ReportSection title="测试金字塔" divided>
              <Stack gap="inline">
                {testPyramidLayers.map((layer, i) => (
                  <Row key={i} justify="space-between" align="center" style={{
                    padding: "8px 16px",
                    width: `${60 + i * 10}%`,
                    margin: "0 auto",
                  }}>
                    <Row gap="inline" align="center">
                      <Text weight="bold" size="small">{layer.label}</Text>
                      <Text tone="tertiary" size="small">{layer.detail}</Text>
                    </Row>
                    <Pill tone={layer.tone}>{layer.count}</Pill>
                  </Row>
                ))}
              </Stack>
            </ReportSection>
          </Stack>
        )}

        {/* Details Tab */}
        {tab === "details" && (
          <Stack gap="section">
            <ReportSection title="核心优势" divided>
              <Stack gap="inline">
                {strengthsRows.map((row, i) => (
                  <Callout key={i} type="success">
                    <Text weight="semibold">{row[0]}</Text>
                    <Text tone="secondary" size="small">{row[1]}</Text>
                  </Callout>
                ))}
              </Stack>
            </ReportSection>

            <ReportSection title="待改进项" divided>
              <Stack gap="inline">
                {weaknessesData.map((w, i) => (
                  <Callout key={i} type={severityToneMap[w.severity]}>
                    <Row justify="space-between" align="center">
                      <Text weight="semibold">{w.title}</Text>
                      <Pill tone={severityToneMap[w.severity]} size="sm">{w.severity}</Pill>
                    </Row>
                    <Text tone="secondary" size="small">{w.desc}</Text>
                  </Callout>
                ))}
              </Stack>
            </ReportSection>
          </Stack>
        )}

        {/* Actions Tab */}
        {tab === "actions" && (
          <ReportSection title="改进路线图" divided>
            <Table
              columns={[
                { key: "priority", title: "优先级", width: "72px" },
                { key: "title", title: "改进项", role: "label" },
                { key: "desc", title: "说明", role: "description" },
                { key: "effort", title: "工作量", width: "80px", align: "center" },
              ]}
              rows={recommendationsData.map((r) => ({
                priority: <Pill tone={priorityToneMap[r.priority]} size="sm">{r.priority}</Pill>,
                title: r.title,
                desc: r.desc,
                effort: r.effort,
              }))}
            />
          </ReportSection>
        )}

        {/* Footer */}
        <Divider />
        <Text tone="tertiary" size="small" style={{ textAlign: "center" }}>
          VeriSTC Harness Analysis — Generated 2026-10-13 — 7 categories, 29 findings
        </Text>
      </Stack>
    </ReportShell>
  );
}
