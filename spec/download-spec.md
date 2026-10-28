# 下装帧协议（工程站 → 运行站全量镜像）

| 版本 | 日期 | 说明 |
|------|------|------|
| v0.1 | 2026-10-28 | G0/W5 首版：冻结帧字节布局、两道校验与拒绝码、版本槽/周期边界切换/一级回滚语义、`veristc-agent` 命令行与状态帧 |

**这份文件是什么**：上位机把一份 `.sasm` 送进正在运行的下位机时，两侧唯一共同遵守的契约。
工程站（未来的 project-svc / `veride`）是**发送端**，运行站的 `veristc-agent` 是**接收端**。
编译产物本身的字节布局属 `spec/safeasm-spec.md`；本文只管"怎么把它安全地换上去"。

依赖规则（AGENTS.md R1）：跨组件只经由本文定义的字节/JSON 格式通信，禁止跨组件 include 源文件。
参考实现：接收端 `veri-runtime/hotstandby/download_wire.c`（协议）+ `download.c`（版本槽与切换）
+ `agent/agent_main.c`（服务）；发送端参考实现 `integration/dl_frames.py`（Python，与 C 相互独立）。

**首期范围（决策 D5 + plan §6.2）**：只做**全量镜像**、只做 **HMAC 鉴权**、只对接**文件/管道**后端。
增量补丁、真签名、UDS/网络传输、重传与断点续传全部推到 G4，本文末尾 §8 逐条列出。

---

## 1. 帧字节布局

定宽小端（与 `.sasm` 同一套编码纪律，非 LEB128）。一帧 = 24 字节头 + n 字节载荷 + 32 字节 MAC。

```
off   size  field        含义
  0      4  magic        "DLF1" = 0x31464C44（小端读法，字节序 D L F 1）
  4      1  ver          = 1
  5      1  kind         0=DATA 1=ACK 2=ERR
  6      2  flags        bit0 = 本帧是整镜像的末帧，其余保留为 0
  8      4  image_len    整镜像字节数（每帧都带）
 12      4  seq          帧序号，从 0 起连续
 16      4  payload_len  本帧载荷字节数，<= 4096
 20      4  crc32        覆盖 payload（payload_len=0 时必须为 0）
 24      n  payload      镜像的连续切片
24+n     32  hmac        HMAC-SHA256，覆盖 [4, 24+n) —— 即 ver..payload，**不含 magic**
```

- 整帧长 = `24 + payload_len + 32`，接收侧按此长度精确取帧，长度不符即拒（`-3`）。
- 帧**自描述**：任何一帧都带 `image_len`，接收侧在 seq=0 那帧锚定它，其后每帧核对。
  没有这个锚定，一个被截短的流会被当成"合法的完整小镜像"收下。
- `magic` 刻意排除在 MAC 覆盖之外：它是"是不是本协议"的判别，不是被保护的内容。

上限：`DL_MAX_PAYLOAD = 4096`、`DL_MAX_IMAGE = 1048576`（与 `vm.h` 的 1 MiB 内存模型同量级；
实测最大黄金制品 `nuclear_rps_esfas_full.sasm` = 196,738 B）。`image_len` 越界即拒（`-4`），
镜像总长超限同样拒（`-8`）。

## 2. 两道校验，两种失败

| 校验 | 算法 | 挡什么 | 失败码 |
|---|---|---|---|
| CRC32 | 反射多项式 `0xEDB88320`，init `0xFFFFFFFF`，输出异或 `0xFFFFFFFF`（= `zlib.crc32`），覆盖 payload | **意外损坏**：截断、位翻转、缓冲错位 | `-6` |
| HMAC-SHA256 | FIPS 180-4 SHA-256 + RFC 2104，密钥 32 字节，覆盖 `ver..payload` | **伪造与替换**：改得动镜像的人算不出没有密钥的 MAC | `-7` |

两者不可互相替代：一个能算正确 CRC32 的攻击者改得动镜像；一个持有正确密钥的人不接触链路也会
因线路噪声产生错帧。**接收顺序固定为 MAC 先、CRC 后**——MAC 不过说明这帧不属于本次下装，
它的 CRC 字段同样不可信，按损坏处理会把鉴权失败误诊成线路噪声。

## 3. 接收侧规则（逐条可测）

R1 `magic`/`ver` 不符 ⇒ `-2`（非本协议，不视作下装事故）。
R2 `payload_len > 4096` 或帧长与 `24+payload_len+32` 不符 ⇒ `-3`。
R3 先验 MAC（密钥不符/未提供 ⇒ `-7`），再验 CRC（不符 ⇒ `-6`）。
R4 `seq` 必须等于已收帧数；出现缺口 ⇒ `-5`（G0 不重传，缺口即整镜像作废）。
R5 `image_len`：首帧锚定；为 0、超 `DL_MAX_IMAGE` 或与锚定值不符 ⇒ `-4`。
R6 `kind=ERR` ⇒ `-10`；`ACK`/`ERR` 的 `payload_len` 必须为 0，否则 `-3`。
R7 累加后 `received > image_len` ⇒ `-8`（尾部有多余数据）。
R8 流结束但 `received != image_len` 或未见末帧标志 ⇒ `-9`（绝不把残缺镜像交给下装层）。
R9 任一拒绝都是**粘性的**：接收器随即作废，后续帧一律不再吸收；调用方必须丢弃整镜像重来。
R10 拒绝只作废**待切换**的那份镜像。正在运行的程序、活动版本槽不受任何影响——
    这是整份契约唯一不可让的不变量。

## 4. 下装层语义（版本槽 · 周期边界 · 冷启动 · 一级回滚）

接收侧交出的完整字节流进入 `veri-runtime/hotstandby/download.c`：

| 返回码 | 含义 |
|---|---|
| `0 DL_RC_OK` | 成功 |
| `-101 DL_RC_EARG` | 空指针 / 长度 0 / 超 `DL_MAX_IMAGE` |
| `-102 DL_RC_EBUSY` | 上一份下装尚未提交或回滚 |
| `-103 DL_RC_ELOAD` | `sasm_load` 拒绝（`dl_last_error()` 给出加载器码：`-1` 格式、`-2` CRC） |
| `-104 DL_RC_EVALIDATE` | `sasm_validate` 拒绝（结构/安全注解不合法） |
| `-105 DL_RC_ENOSWITCH` | 无待切换镜像却请求提交 |
| `-106 DL_RC_ENOVMBIND` | `vm_rebind` 失败（已自动回切，见下） |

- **两槽 + 单调版本号**：`active` 槽在跑，`pending` 槽收下装。版本号只增不减，
  回滚不回退编号（`dl_active_version()` / `dl_pending_version()` 可查）。
- **提交只发生在周期边界**：`dl_apply_switch(VM*)` 必须在 `vm_run` 返回之后、下一扫描开始之前
  被调用。别处重绑一个正在执行的 VM 会让旧帧里保存的 `code_pool` 指针与新程序混叠。
- **全量下装 = 冷启动语义**：`vm_rebind` 换镜像时清零值栈/帧栈/周期计数与整块线性内存。
  换的是整个程序，保留旧全局字节会让新镜像读到上一版本的值。带状态的无缝切换属增量下装，
  不在 G0。
- **一级回滚**：`dl_rollback(VM*)` 只回切 `previous_slot`；两槽 ⇒ 只有一级深度，
  第二次调用返回 `NULL`。回滚后失败的新槽作废，不会被再次提交。
- **切换前置失败**：`dl_apply_switch` 若 `vm_rebind` 失败，立即自动回切旧槽并返回 `-106`，
  绝不留下"没有镜像的 VM"。
- **健康检查**：由 agent 负责（下装层不驱动周期）。切换后连续跑 `--health-cycles` 个周期，
  任一 `vm_run` 失败即回滚并上报。典型触发是"装载校验都过、跑起来超自身周期预算"。

## 5. 密钥注入（决策 D5）

G0 用**静态配置的 32 字节共享密钥**，命令行注入（`--key`，64 个 hex 字符）。
两侧各自的实现必须逐字节一致，否则表现为 `-7`；参考实现用 RFC 4231 TC1–TC4/TC6 测试向量
校验 HMAC-SHA256 本体，用 FIPS 180-4 向量校验 SHA-256 本体。
真签名（非对称、固件验链）推到 G4；届时帧布局的 `flags`/`ver` 字段留出演进位，
`ver` 不等即判 `-2`，不做静默兼容。

## 6. `veristc-agent` 命令行与状态帧

```
veristc-agent [options] <image.sasm>
  --key HEX          32 字节 HMAC 密钥（64 hex 字符），与 --download-from 搭配必需
  --download-from P  下装帧流：普通文件、管道或 FIFO；"-" = stdin
  --download-at N    在第 N 个周期把已收到的镜像装入待切换槽（默认 1）
  --health-cycles N  新镜像必须存活的健康检查周期数（默认 3）
  --cycles N         扫描周期数，0 = 收到 SIGINT/SIGTERM 为止（默认 10）
  --period-ms MS     扫描周期，0 = 全速（默认 0）
  --role NAME        状态帧里的角色标记（默认 active，仅字母数字 . _ -）
  --node-id N        状态帧里的节点号（默认 0）
```

G0 的下装流**在启动时一次性读到 EOF** 再进入周期循环（没有重传/超时 ⇒ 边跑边等字节没有意义）；
`--download-at` 控制的是"在第几个周期边界落地"，不是"什么时候开始读"。

状态帧：一行一条 JSON（JSONL），走 stdout，与程序自身 `PRINT` 共用一个通道，
因此**每条都以 `{"frame":"status"` 开头**，消费方按此前缀过滤（与 watch 帧同一规则，
见 `spec/simulation-spec.md` §4）。

```
{"frame":"status","event":E,"role":R,"node":N,"version":V,"cycle":C,...}
```

| `event` | 附加字段 | 时机 |
|---|---|---|
| `start` | `image,download,planned` | 首装完成、进入周期循环前 |
| `download_begin` | — | 开始吸收帧流 |
| `download_staged` | `staged,bytes` | 镜像收满且装入待切换槽 |
| `download_rejected` | `stage,rc,loader,progress` | 任一拒绝（`stage` = `frame`/`reassemble`/`stage`） |
| `switch` | `from,to` | 周期边界提交并重绑成功 |
| `switch_failed` | — | 提交被下装层拒绝 |
| `health_ok` | — | 健康窗口内无失败 |
| `rollback` | `rc,rolled_back_to` | 健康窗口内 `vm_run` 失败，已回切旧槽 |
| `cycle_error` | `rc[,rollback_failed]` | 周期失败且无可回滚落点，agent 退出 |
| `end` | `ran,switches,rollbacks` | 周期循环结束 |

退出码：`0` 正常（**含下装被拒**——正在跑的程序没受影响就算成功）；`2` 参数错；
`3` 首装镜像装载失败；`4` 密钥缺失或非法；`5` 周期执行失败；`6` 下装流不可读。

## 7. 一致性不变量（跨组件可机检）

- I1 `download_staged` 的 `bytes` == 送出镜像文件的字节数（`run_download_e2e.sh` 第 2 步）。
- I2 任何 `download_rejected` 之后，`end` 帧的 `version` 与首装版本相同、`switches=0`，
  且 agent 退出码为 0（同第 3 步的六条拒绝用例）。
- I3 切换是否真的生效，不看状态帧自证，看**程序输出形状改变**（第 2 步在 `switch` 之后断言
  新镜像的 `FB` 输出行）。
- I4 回滚判据同样是可观测输出：回滚后旧镜像继续扫描并重新输出（第 4 步）。
- I5 帧的 MAC 约定由**两个独立实现**共同确认：C 接收端 + Python 发送端
  （`integration/dl_frames.py`）。任一侧单独改动必然表现为 `-7`。

## 8. 明确不在首期（逐条推到的阶段）

| 能力 | 状态 | 去处 |
|---|---|---|
| 增量补丁下装 | `compute_diff`/`apply_patch` 代码在，**不进链路**（`apply_patch` 是 static 零调用者） | 结构性变更能力补齐后 |
| 重传 / 超时 / 断点续传 | 无；序号缺口即整镜像作废（R4） | G4 |
| UDS / TCP 传输 | 无；G0 只有文件与管道后端（`DlStream` 抽象已把协议与链路 API 解耦） | G4 |
| 真签名 / 密钥轮换 | 无；共享密钥静态注入 | G4 |
| 备站下装、主备同步传输 | `hotstandby/sync.c` 仍是共享内存 | Phase 3 遗留，独立评审 |
| 加密存储 / 回滚审计日志 | 无 | G4 |

## 9. 参考实现与语料

| 位置 | 内容 |
|---|---|
| `veri-runtime/hotstandby/hmac_sha256.c` | SHA-256 + HMAC-SHA256（自持，不依赖 OpenSSL） |
| `veri-runtime/hotstandby/download_wire.{c,h}` | 组帧 / 收帧状态机 + 拒绝码 |
| `veri-runtime/hotstandby/download.c` | 版本槽、`dl_stage_image`、`dl_apply_switch`、`dl_rollback` |
| `veri-runtime/core/safeasm_interp.c` | `vm_rebind`（周期边界重绑 + 冷启动清零） |
| `veri-runtime/agent/agent_main.c` | `veristc-agent` |
| `integration/dl_frames.py` | Python 参考发送端（含负例开关） |
| `veri-runtime/tests/vm-tests/test_download_wire.c` | 协议字节层单测（公开测试向量 + 全部拒绝类） |
| `veri-runtime/tests/vm-tests/test_download_switch.c` | 收帧→装槽→切换→回滚，用真实 `.sasm` 制品 |
| `veri-runtime/run_vm_checks.sh` 第 9/10 步 | 上述两组进门禁 |
| `integration/run_download_e2e.sh` | 端到端：管道送帧、拒绝矩阵、健康回滚、CLI 契约（34 项） |
