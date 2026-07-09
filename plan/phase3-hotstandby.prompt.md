---
name: phase3-hotstandby
description: 'Phase 3: implement dual-machine hot standby, incremental download, and bumpless switchover. Use when: building redundancy logic, state synchronization, failover mechanisms.'
---

# Phase 3: 双机热备 + 增量下装（第 21-25 周）

## 目标

实现安全级系统必需的双机冗余机制：主备状态同步、故障检测与无扰切换、增量下装与原子切换。

## 核心产出物

| 产出物 | 路径 | 内容 |
|--------|------|------|
| 状态快照引擎 | `vm/hotstandby/snapshot.c` | 序列化 WASM 线性内存 + 全局变量 + PC |
| 同步通信协议 | `vm/hotstandby/sync.c` | 共享内存/TCP 同步通道 |
| 主备状态机 | `vm/hotstandby/state_machine.c` | 故障检测 + 角色切换 |
| 增量补丁引擎（编译器端） | `veristc/src/codegen.v`（扩展） | 新旧 `.sasm` 差异计算 |
| 增量下装模块 | `vm/hotstandby/download.c` | 周期边界原子切换 + 回滚 |

## 实现流程

1. **状态快照**：序列化 VM 完整状态（线性内存 + 全局寄存器 + 函数调用栈 + PC）为字节流，带 CRC32 校验
2. **脏页追踪**：在内存容器层记录修改的页面，仅同步差异部分
3. **同步协议**：主站每周期结束发送快照 → 备站接收并 ACK → 超时重传
4. **主备状态机**：主（ACTIVE）/ 备（STANDBY）/ 故障（FAILED）/ 切换中（SWITCHING）四状态
5. **增量下装**：bsdiff 计算新旧 `.sasm` 差异 → 下装到备站 → 周期边界原子切换 → 新版本验证 → 失败回滚
6. **无扰切换**：主站故障 → 备站启用最近快照继续执行，输出值保持平滑

## 上下游关系

- **上游依赖**：Phase 1（解释器 + 内存容器）
- **下游产出**：Phase 4 测试阶段依赖本阶段功能

## 关键决策

- 热备策略（选项 C）：主备同步执行 + 逐周期状态同步
- 同步粒度：脏页追踪，非全量
- 切换时间目标：< 1 扫描周期
