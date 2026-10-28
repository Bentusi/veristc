# 仿真协议（`.plant` 被控对象表 + `sim` 主程序 + watch 帧）

| 版本 | 日期 | 说明 |
|------|------|------|
| v0.1 | 2026-10-28 | G0/W3 首版：冻结 `.plant` 运行协议、程序/对象一致性规则、`sim` 命令行与时间线格式 |
| v0.2 | 2026-10-28 | G0/W4：冻结 watch 帧协议（§4，决策 D4 的 stdout JSONL），`sim` 增 `--watch` |

**这份文件是什么**：VeriIDE 仿真按钮背后那台"假控制器硬件"的对外协议。
编译器产出的 `.sasm` 只描述程序逻辑；被控对象（罐温、阀位、水位……）不在编译产物里，
由一张 `.plant` 表在仿真时提供。上位机（未来的 project-svc）生成这张表，
运行站（`veri-runtime/sim/`）消费它。两侧唯一的耦合点就是本文。

依赖规则：`veri-ide` 与 `veri-runtime` 之间只经由本 spec 定义的文本格式通信（AGENTS.md R1）。

---

## 1. `.plant` 文件格式

### 1.1 词法

- 一行一个通道；字段以**空白**分隔，顺序固定，共 9 个字段。
- `#` 开头的行是注释；全空行忽略；不支持行续写。
- 行长上限 128 字节（`PLANT_LINE_MAX`），超长即拒绝启动而非截断。
- 通道数上限 64（与 `IO_MAX_CHANNELS` 对齐）。

### 1.2 字段

```
channel  dir  kind  gain  offset  min  max  init  drive
```

| 字段 | 取值 | 含义 |
|------|------|------|
| `channel` | `0..63` | 物理通道 ID，表内唯一 |
| `dir` | `INPUT` \| `OUTPUT` | 相对**程序**的方向：程序读=INPUT，程序写=OUTPUT |
| `kind` | `CONST` \| `LAG` \| `RAMP` \| `ACTUATOR` | 动态模型；`ACTUATOR` 仅 `OUTPUT` |
| `gain` | float64，必须有限 | `LAG`：离散步进系数，开 `(0,1]`；`RAMP`：每周期增量，任意有限值 |
| `offset` | float64，必须有限 | 仅 `LAG` 使用：叠加在驱动值上的偏置 |
| `min` / `max` | sint32，`min <= max` | 物理量程上下限 |
| `init` | sint32，必须落在 `[min,max]` | 上电初值 |
| `drive` | 通道 ID 或 `-1` | 仅 `LAG` 可用：驱动本通道的 `OUTPUT` 通道；`-1` 表示无驱动（趋向 `offset`） |

**单位约定**：表内所有数值一律是 **raw**，即 `io_read/io_write` 那一层交换的值。
`.sasm` IOMAP 段的 `scale/bias` 由映射层负责 raw ↔ 工程值换算（`safeasm-spec.md` §4.4），
两侧不重复缩放。当前编译器发射 `scale=1.0 / bias=0.0`，因此 raw == 工程值。

### 1.3 动态模型

每个扫描周期调用一次步进，INPUT 通道按下列规则更新后统一钳位到 `[min,max]`：

| kind | 更新式 |
|------|--------|
| `CONST` | 不变 |
| `RAMP` | `x ← x + gain` |
| `LAG` | `target = drive>=0 ? 驱动通道值 : 0`；`x ← x + gain*(target + offset − x)` |
| `ACTUATOR` | 无自主动态，值等于程序最近一次写下的输出（钳位后） |

状态以 float64 累加，读出时向零截断为 sint32 —— 与映射层 `raw ↔ eng` 的截断方向一致。

**确定性**：INPUT 的步进只读执行器（`OUTPUT`）状态和自身上一周期值，输入通道之间无耦合。
因此行序、通道序都不影响结果；同一 `(sasm, plant, 周期数, 周期时长)` 必然产生同一时间线。
虚拟时钟同样不参考墙钟：`sleep` 是空操作，`get_ticks` 由主程序每周期加 `period`。

### 1.4 解析即校验（拒绝启动，不静默降级）

以下任一情形，`sim` 以退出码 2 终止并把行号写到 stderr：

| 情形 | 理由 |
|------|------|
| 字段数 ≠ 9 / 枚举拼写错 / 数字带尾串 | 配置读错比不跑更危险 |
| 通道重复 | 两个逻辑通道共用一份物理状态会互相覆盖 |
| `OUTPUT` 配非 `ACTUATOR`，或 `ACTUATOR` 配 `INPUT` | 执行器没有自主动态可言 |
| `min > max`，或 `init` 越界 | 上电即处于非法工作点 |
| `gain` / `offset` 非有限（NaN、±Inf） | 一旦进入状态更新，NaN 会污染整条时间线 |
| `LAG` 的 `gain` 不在 `(0,1]` | 大于 1 是发散步进，等于 0 是假装有动态 |
| `CONST` / `RAMP` 声明了 `drive` | 会被静默忽略，必须显式禁止 |
| `drive` 指向不存在或非 `OUTPUT` 的通道 | 驱动链路断裂 |
| 表为空 | 无对象可仿真 |

---

## 2. 程序侧一致性规则

`sim` 在启动前核对 `.sasm` 的 IOMAP 段与 `.plant` 表：

1. 映射段里每个 `channel_id` 必须在表中存在 —— 否则该通道每次读都返回失败，
   程序会把它标记为 `fault` 并一路跳过，时间线看起来"正常"却全是常量。
2. 表里的 `dir` 必须与映射段一致 —— 方向反了等价于程序在写一个传感器。
3. 映射段条目为 0 的程序不该用 `sim` 跑（用 `svm`），`sim` 直接拒绝。

任一不符即退出码 2 终止。

地址侧的不变量（IOMAP 的 `mem_offset` == 符号段里该全局变量的槽位地址）
由编译器保证，见 `safeasm-spec.md` §4.4「地址单一真值」与 `safest-spec.md` GATE-7。

---

## 3. `sim` 命令行

```
sim [options] <file.sasm> <plant-file>

  -n CYCLES      扫描周期数，默认 10，上限 100000
  -t MS          周期时长（虚拟毫秒），默认 100
  -q             只输出配置与汇总，不输出逐周期时间线
  --watch NAMES  每周期输出一行 JSONL watch 帧（见 §4），NAMES 逗号分隔
  -h             帮助
```

加载路径与 `svm` 相同（CRC32 → `sasm_load` → `sasm_validate` → `vm_init`），
区别在于每周期走完整 I/O 扫描：

```
io_mapping_read_all()   被控对象 -> VM 线性内存的真实全局槽位
vm_run()                执行程序一个周期
io_mapping_write_all()  VM 线性内存 -> 执行器
plant_step()            对象向前推进一个周期 + 虚拟时钟前进
```

### 3.1 输出格式

首块是配置回显（`-q` 时省略），随后每周期一行：

```
  cycle=<n> t=<虚拟毫秒> ch<id>=<工程值> [...] status=<vm 返回码>
```

`ch<id>` 打印的是映射层缓存的**工程值**（经 `scale/bias` 与安全限值钳位后的值），
不是原始 ADC 码。末行是汇总：

```
done: <cycles> cycles, <virtual ms> virtual ms, violations=<safety_violations>
      read_errors=<n> write_errors=<n>
```

### 3.2 退出码

| 码 | 含义 |
|----|------|
| 0 | 全部周期执行成功 |
| 2 | 参数错误 / `.plant` 协议不符 / 程序与对象不一致 / 程序无 I/O 映射 / `--watch` 名字表被拒 |
| 3 | `.sasm` 加载失败 |
| 4 | 某周期 `vm_run` 返回非 0（stderr 指出周期号） |

---

## 4. watch 帧协议

G0/W4 产出物，决策 **D4**：首期只走 **stdout JSONL**，不引入 socket / 共享内存。
唯一生产者是 `sim --watch`，G0 的唯一消费者是门禁脚本，G1 起是 `veride` 后端子进程管道。

### 4.1 边界

- **只读**：帧不改 `vm->memory`。变量写入/强制明确留在范围外（核级仪控需单独安全评审）。
- 通道层的量程不在这里重复：`raw` 就是映射层末次与物理侧交换的那一层。
- 高频连续波形不在这里：一周期一行的 stdout 只够趋势监视与断言，需要波形时上 UDS（G3）。

### 4.2 流格式

- `--watch` 生效时，每个扫描周期输出一行 **cycle 帧**，流末输出**恰好一行 done 帧**；
  除此之外 `sim` 自身不向 stdout 写任何行（配置回显改道 stderr）。
- stdout 是**复用**的：被编译程序的 `PRINT` 端口输出同样落在 stdout 上。帧行一律以
  `{"frame":` 起始 ⇒ 消费者按该前缀过滤，非帧行属于被编译程序的跟踪输出，不在本协议内。
- 键序与列序固定：`values` 的顺序等于命令行 `--watch` 的书写顺序，逐周期一致 ⇒ 前端可按列下标取数。

### 4.3 cycle 帧

```
{"frame":"cycle","cycle":12,"t_ms":1100,"status":0,"violations":0,
 "values":[{"name":"pv","addr":4100,"type":"DINT","size":4,"value":625,
            "channel":0,"raw":625},
           {"name":"integ","addr":4112,"type":"DINT","size":4,"value":526,
            "channel":null,"raw":null}]}
```

| 键 | 类型 | 含义 |
|----|------|------|
| `cycle` | uint | 周期号，从 1 开始 |
| `t_ms` | uint | **本周期起始**的虚拟毫秒（`-t` 的整数倍累加，不取墙上时钟） |
| `status` | int | 本周期 `io_mapping_cycle()` 返回值，0 = 成功；非 0 时 `sim` 在打完这帧后以退出码 4 终止 |
| `violations` | uint | `safety_violations` **累计**值（映射层越限只钳位不跳闸，此处透给上位工具） |
| `values` | array | 每个被监视符号一项，键序固定 |

`values` 元素（七个键恒在，非标量情况不存在——见 §4.6）：

| 键 | 类型 | 含义 |
|----|------|------|
| `name` | string | 符号名原文，含派生名 `实例#字段`；写法与 `svm -s` 完全一致 |
| `addr` | uint | 十进制线性内存偏移。**必须**等于 `svm -l` 对同名符号报出的地址（同一真值链） |
| `type` | string | 段 7 类型名（`DINT` / `BOOL` / `REAL` …），不是数字 tag |
| `size` | uint | 槽位字节数；单字布局下当前恒为 4（见 §4.5） |
| `value` | number \| null | 该地址处按 §4.5 解码后的内存内容，即**程序看到的量** |
| `channel` | uint \| null | 绑定的 I/O 通道号；非 I/O 绑定为 `null` |
| `raw` | int \| null | 该通道上一周期与物理侧交换的原始值；非 I/O 绑定为 `null` |

### 4.4 done 帧

```
{"frame":"done","cycles":12,"t_ms":1200,"violations":0,"read_errors":0,"write_errors":0}
```

`cycles` = 实际执行完成的周期数；三个计数器取 `IOMappingTable` 的累计值。
消费者据此判定「正常结束」；缺 done 帧即视为流中断。

### 4.5 `value` 的类型驱动解码

一律从小端 `vm->memory[addr]` 读**一个 4 字节全局槽**，再按段 7 的 `type_tag`
（枚举见 `spec/safeasm-spec.md` §4.8）解释：

| 类别 | type | 处理 |
|------|------|------|
| 有符号 32 位 | `INT` `DINT` `SINT` `QINT` `QDINT` `QSINT` `TIME` `QTIME` `QUALITY` | 十进制整数 |
| 无符号 32 位 | `BOOL` `BYTE` `WORD` `DWORD` `QBOOL` `QBYTE` `QWORD` `QDWORD` | 十进制整数（`BOOL` 为 0/1） |
| 单精度 | `REAL` `QREAL` | 位模式解释为 float32，`%.8g` 输出；非有限值输出 `null` |
| 64 位 | `LINT` `QLINT` `LREAL` `QLREAL` | **启动即拒绝**（§4.6）：`assign_global_offsets` 每个声明只给一个 int32 单字，没有第二个槽可读，半吊子解码只会给出假数 |
| 非标量 | `ARRAY` `FB` | **启动即拒绝**：实例基名没有「一个值」，字段派生名（`cnt#N`）才有 |

单字布局是编译器的既有事实（`global_codegen.v:37-44`；`veristc_main.ml:321` 把每行的
`size` 恒写为 4），因此 `size` 键今天恒等于 4 —— 保留它是为了 64 位槽位落地后不必改帧格式。
这也与决策 **D1**（首期只接受 DINT 链）一致：能真正跑通的数值就是第一行那一类。

### 4.6 启动即拒绝，不留歧义

`--watch` 的名字表在**进入周期循环之前**整体校验，任一条不符即退出码 2、不跑一个周期：

| 情形 | 理由 |
|------|------|
| 段 7 里查不到该名字 | 上位工具必须能区分「符号不存在」与「值为 0」。原方案（`plan` §5.2）设想的是帧里带 `{"unknown":…}` 前置标记，实测取向启动即拒：把歧义消灭在周期循环之外，比在流里多一个必须记得检查的标记更可靠 |
| 名字缺失段 7 / 段 7 畸形 | 没有地址就没有帧 |
| 类型是 `LINT` / `QLINT` / `LREAL` / `QLREAL` | 一个全局槽只有一个 int32 单字，64 位量没有存储可读 |
| 类型是 `ARRAY` / `FB` | 实例基名没有「一个值」可读，字段名（`cnt#N`）才有 |
| `addr + 4` 超出 VM 内存镜像 | 帧不能读越界字节 |
| 名字重复 / 空名 / 名字长度 ≥ 64 / 数量 > 16 | 列序与缓冲区都是静态的 |

### 4.7 确定性与可比对

`value` 只依赖 VM 内存与已冻结的段 7，`t_ms` 只依赖虚拟时钟 ⇒ 同一 `.sasm` + 同一 `.plant`
+ 同一参数 ⇒ 帧流逐字节一致。门禁 `integration/run_sim_e2e.sh` 第 6 步钉住三件事：
帧的 `addr`/`type`/`size` 与 `svm -l` 逐条相等；帧的 `value` 与 12 周期黄金时间线逐周期相等
（这是 W2 留下、按地址读值才能补上的那条断言）；两次 watch 输出逐字节一致。

---

## 5. 参考实现与语料

| 位置 | 内容 |
|------|------|
| `veri-runtime/sim/plant.{c,h}` | `.plant` 解析、校验、步进（无 malloc，静态表） |
| `veri-runtime/sim/sim_io.{c,h}` | `VM_Interface` 的软件实现：`io_read/io_write/get_ticks/sleep/ms_to_ticks/ticks_to_ms/init/deinit` |
| `veri-runtime/sim/watch.{c,h}` | 帧协议的实现：名字表校验、按地址解码、JSONL 输出（本文 §4） |
| `veri-runtime/core/sasm_info.c` | 段 7 解析。`sasm_sym_resolve(buf,len,name,out)` 是 watch 的地址来源，与 `svm -s/-l` 走同一个行读取器 |
| `veri-runtime/sim/sim_main.c` | `sim` 主程序 |
| `veri-runtime/sim/plants/closed_loop.plant` | 演示对象表：一阶惯性 + 恒值设定 + 执行器 |
| `veri-stc/tests/st-examples/sim_closed_loop.st` | 演示控制器（纯 DINT，带抗积分饱和）+ 一个只供 watch 使用的 `COUNTER_FB` 实例 |
| `veri-stc/tests/st-examples/sim_closed_loop.golden.timeline` | 12 周期黄金时间线 |
| `integration/run_sim_e2e.sh` | 门禁：黄金比对 + 确定性 + 协议拒绝 + 一致性拒绝 + watch 帧交叉核对（26 项） |

**G0 范围外的一件事**（记录在 `plan/phase6-g0-technical-plan.md` §7 的 W3 落地补充）：
工程源 YAML（`plant.yaml`）与其转换器归 G1 的 project-svc —— C 侧不解析 YAML。
变量名监视（watch 帧，§4）已在 W4 落地。
