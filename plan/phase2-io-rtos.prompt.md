---
name: phase2-io-rtos
description: 'Phase 2: integrate I/O mapping and RTOS abstraction for the C VM. Use when: implementing I/O drivers, RTOS adaptation, scan cycle scheduling.'
---

# Phase 2: I/O 集成 + RTOS 适配（第 17-20 周）

## 目标

实现 ST 变量与物理 I/O 通道的映射，将 SafeASM 虚拟机集成到嵌入式 RTOS 中，完成周期扫描调度。

## 核心产出物

| 产出物 | 路径 | 内容 |
|--------|------|------|
| I/O 映射表生成器（编译器端） | `veristc/src/codegen.v`（扩展） | 从 ST 程序生成 `.iomap` 文件 |
| I/O 映射层（VM 端） | `vm/io/` | 加载 `.iomap`，ST 变量↔物理通道映射 |
| RTOS 抽象层 | `rtos/abstract.h` | `VM_Interface` 结构体定义 |
| RT-Thread 适配 | `rtos/rtthread/` | 周期调度 + I/O 驱动任务 |

## 实现流程

1. **扩展编译器**：在 `codegen.v` 中增加 I/O 映射表生成逻辑——从 ST 程序的 `VAR_INPUT`/`VAR_OUTPUT` 声明推导物理通道绑定
2. **实现 VM I/O 层**：解析 `.iomap` 文件，建立 `IO_Mapping_Table`（ST 变量名 → 物理通道 → WASM 内存偏移）
3. **定义 RTOS 抽象层**：`VM_Interface` 结构体（init/deinit/execute_cycle/read_input/write_output/snapshot/restore）
4. **RT-Thread 适配**：
   - 创建 I/O 驱动线程（高优先级）：周期采样 AI/DI，写入共享内存
   - 创建 VM 主线程（中优先级）：加载 `.sasm` → 解释执行
   - 创建看门狗线程（低优先级）：健康检查
   - 使用 RT-Thread 设备框架管理 I/O 通道
   - 使用 IPC 机制（信号量/邮箱）实现线程间同步

## 上下游关系

- **上游依赖**：Phase 1（codegen.v + 解释器 + 内存容器）
- **下游产出**：Phase 3 依赖本阶段的 VM 基础设施

## 关键决策

- I/O 映射表格式：自定义 `.iomap`（JSON 或二进制）
- RTOS 优先适配 RT-Thread
- 扫描周期通过 RTOS 定时器触发，非忙等
