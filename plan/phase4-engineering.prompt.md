---
name: phase4-engineering
description: 'Phase 4: engineering polish — testing, documentation, performance optimization. Use when: writing tests, generating docs, profiling, hardening the system.'
---

# Phase 4: 工程化完善（第 26-29 周）

## 目标

完成项目的工程化收尾工作：全面的测试覆盖、技术文档编写、性能分析优化。

## 核心产出物

| 产出物 | 路径 | 内容 |
|--------|------|------|
| WCET 分析工具 | `veristc/src/analysis.v`（完善） | 编译器端 WCET 静态分析 |
| 安全性测试套件 | `tests/` | 单元测试 + fuzz + 边界测试 + 故障注入 |
| 性能评测报告 | `docs/performance.md` | 解释器性能数据 + 优化建议 |
| 用户手册 | `docs/user-guide.md` | API 文档 + 使用示例 |

## 实现流程

1. **WCET 分析**：完善编译器的 WCET 分析模块，输出每个函数的最差执行时间
2. **测试**：
   - 编译器：ST 示例程序 → 编译 → 反汇编验证
   - VM：逐指令单元测试 + 长稳测试（72h）
   - 集成：端到端测试
   - 故障注入：内存损坏、通信中断、主站宕机
3. **性能优化**：基于实测数据，优化解释器热点路径
4. **文档**：用户手册 + API 文档 + 组态工具集成指南

## 上下游关系

- **上游依赖**：Phase 1-3 全部完成
- **下游产出**：项目交付物

## 关键决策

- 无认证工作内容
- 文档优先关注使用指南和 API 参考
