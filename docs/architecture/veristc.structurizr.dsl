workspace "VeriSTC current-state architecture" "VeriSTC = SafeST(ST) -> SafeASM 编译器 + C 语言虚拟机。当前状态(AS-IS)模型；每个节点/关系的 description 内含 文件:行号 证据，标签编码置信度与接入状态。生成日期 2026-10-14，2026-10-28 随 Phase 6 G0(W1-W6) 全量重推证据：下位机现有三个主程序 svm / sim / veristc-agent。" {

    // ==========================================================
    // MODEL
    // ==========================================================
    model {

        // ---------- Actors ----------
        stEngineer = person "ST 应用工程师" "在上位机侧编写 .st 并调用 veristc 命令行做编译/分析/生成可重定位对象。证据: AGENTS.md 架构概览、veri-stc/extraction/veristc_main.ml:808+ 命令行分支。无图形界面代码，人机交互仅证据到 CLI 层（工程站 VeriIDE 属 Phase 6 目标态，见 spec/ 三份协议）。" {
            tags "Person", "Conf-Medium"
        }

        // ---------- External systems ----------
        coqToolchain = softwareSystem "Rocq/Coq + OCaml 工具链" "coqc/rocq 编译 .v -> .vo，Extraction 产出 .ml/.mli，ocamlfind ocamlopt 链接可执行文件。" {
            tags "ExternalSystem", "Conf-High"
        }
        rtosSdk = softwareSystem "RT-Thread SDK" "目标平台 OS API；仅在 RTTHREAD_SDK 变量非空时参与语法编译，不链接。" {
            tags "ExternalSystem", "NotWired", "Conf-High"
        }
        ioHardware = softwareSystem "物理 I/O 通道 (AI/AO/DI/DO)" "由 VM_Interface 的 io_read/io_write/io_group_* 函数指针协议描述。" {
            tags "ExternalSystem", "Conf-Medium"
        }
        qaTools = softwareSystem "QA 工具链 (cppcheck / Unity-CMock / ASan-UBSan)" "MISRA 静态检查、单元测试框架、sanitizer 与 .sasm 加载器 fuzzing。" {
            tags "ExternalSystem", "Conf-High"
        }
        futureLinker = softwareSystem "veristc-ld 链接器" "目标态: 消费 .svobj 做跨模块链接 (计划 P3)。当前仓库无实现。" {
            tags "ExternalSystem", "TargetState"
        }

        // ---------- The system ----------
        veristc = softwareSystem "VeriSTC" "ST -> SafeASM 字节码编译器 + SafeASM 虚拟机，用于安全级仪控设备。" {

            // ----- 上位机: 编译器可执行 -----
            compiler = container "veristc (编译器可执行)" "单入口 OCaml 原生程序，按 -c/-a/-g/-x 四种模式驱动 Coq 提取出来的计算函数；机器可读接口 --json(NDJSON) + 退出码 0/11/21/22/23/24/25，协议见 spec/safest-spec.md 附录 D。" "OCaml native (ocamlopt) + Coq-extracted modules" {
                tags "Conf-High", "HostTool", "Deploy-上位机"

                cli = component "CLI 入口 (手写)" "veristc_main.ml 为手写源，不参与提取；负责参数解析、读写文件、CRC32、段 7 编码、.svobj 字节编码。模式分派 parse_args :808-841（默认 -a :840），-c/-g 缺 -o 判 exit_usage 且绝不写 CWD :843-846。" "OCaml" {
                    tags "Conf-High"
                }
                analyzeSt = component "analyze_st (-a 模式独立管线)" "read_file→parse_or_fail→重名→prepare→展开后重名→diag→normalize→optimize→desugar→analyze 与 frontend(:423-482) 重复实现，但**不做递归拒绝与栈深门禁**(:475-481 只在 frontend 里)，只把 stack depth / recursive calls / estimated wcet / loops bounded 四项 printf 到 stdout。证据 veristc_main.ml:721-780。" "Coq extracted + OCaml" {
                    tags "Conf-High", "DuplicatedLogic"
                }
                lexer = component "Lexer.lex" "字符流 -> token 表。证据 veri-stc/src/lexer.v:377, 调用点 veristc_main.ml:215。" "Coq extracted" {
                    tags "Conf-High"
                }
                parser = component "Parser.parse" "token -> st_program；失败时用 parse_fail_pos + lex_offsets 回推行列。v1.5.1: `inst.field` 在此融合为派生名 `inst#field`(分隔符 safest.v:94)，AST 不新增成员访问构造。证据 veri-stc/src/parser.v:1330,1354; veristc_main.ml:220-233。" "Coq extracted" {
                    tags "Conf-High"
                }
                dupchk = component "check_no_duplicate_declarations / duplicate_declaration_msg" "扁平命名空间重名即编译错误。v1.5.1 起该门禁跑两次：解析后(:184, 调用:432-434) 与 expand_instances 之后(:262, 调用:444-452，报出冲突名字；不漏报/不误报各有定理)。证据 veri-stc/src/typechecker.v:184,262; veristc_main.ml:432-452。" "Coq extracted" {
                    tags "Conf-High"
                }
                funcCheck = component "Function_check.prepare_program / check_program_full_diag(_rows)" "FUNCTION 结果变量准备 + 作用域/纯性/调用类型全量诊断；expand_instances 在此把 FB 实例摊成 `inst#field` 扁平全局。v1.5.1 新增字段封装门禁 check_program_access(:1034)：体外只读 VAR_OUTPUT，读写内部 VAR 或体外写 VAR_OUTPUT 以 KIND=access 拒绝。文本模式用单条 API(:1227)，--json 用全量行 API(调用 :455-459)。证据 veri-stc/src/function_check.v:1084,1227,1034; veristc_main.ml:435-461。" "Coq extracted" {
                    tags "Conf-High"
                }
                inline = component "Inline.normalize_program / optimize_inline_program" "保留函数的规范化 + 叶子内联/死函数消除。证据 veri-stc/src/inline.v:647,942; veristc_main.ml:464-468。" "Coq extracted" {
                    tags "Conf-High"
                }
                desugar = component "Desugar.desugar_program" "st_program -> corest_program (CoreST)。证据 veri-stc/src/desugar.v:409; veristc_main.ml:471,473。" "Coq extracted" {
                    tags "Conf-High"
                }
                analysis = component "Analysis.analyze" "调用图/递归/栈深/WCET；生产入口用它做递归拒绝与栈深门禁。证据 veri-stc/src/analysis.v:242; veristc_main.ml:474-481。" "Coq extracted" {
                    tags "Conf-High"
                }
                gcCodegen = component "Global_codegen.compile_program_gc" "生产 codegen 路径: CoreST -> sasm_module (全局偏移 + FB 实例)。v1.5 VAR_IN_OUT 逐引用别名: 端口降级为持有调用方地址的形参槽，读写发 I32_LOAD_PTR/I32_STORE_PTR(地址取自值栈而非静态 mem_offset)。G0/W3 起 IOMAP 的 mem_offset 由 resolve_io_map(:61) 按名向 build_global_env(:46) 取真实槽位，与段 7 同源；名字未声明即编译拒绝。证据 veri-stc/src/global_codegen.v:801,46,61; veristc_main.ml:486,617。" "Coq extracted" {
                    tags "Conf-High"
                }
                relocMeta = component "compile_program_reloc_info / inst_info / sym_info / debug_info / io_cal_info" "只导出扁平重定位/实例/符号/量程元数据行，排序去重留给 OCaml。reloc kind 0=CALL_IDX / 1=INST_BASE_IMM / 2=GLOBAL_OFF(VAR_IN_OUT 别名实参, 由 build_alias_table(:934) 从调用点派生; 别名判定优先于基址判定)。段 7 出行 compile_program_debug_info(:1154)、量程出行 compile_module_io_cal_info(:1172)。证据 veri-stc/src/global_codegen.v:1021,1037,1072,1154,1172; veristc_main.ml:491,496,578-589。" "Coq extracted" {
                    tags "Conf-High"
                }
                encoder = component "Encoder.encode_module" "sasm_module -> list Z 字节序列(定宽小端, 不含 CRC)。Coq 侧 PrimFloat.float 无 IEEE-754 位 ⇒ IOMAP 的 scale/bias 在此只写占位零。证据 veri-stc/src/encoder.v:327; veristc_main.ml:489,622。" "Coq extracted" {
                    tags "Conf-High"
                }
                iomapPatch = component "patch_iomap_cal (OCaml 侧量程真值覆盖)" "按 compile_module_io_cal_info 的 IR 值把 IOMAP 条目 [18-33] 的 float64 覆盖为真值；条目数/段长/通道号三重核对不符即 die exit_internal，绝不产出半成品。证据 veristc_main.ml:375-421,488。" "OCaml" {
                    tags "Conf-High"
                }
                debugEmit = component "emit_debug_section (段 7 STRPOOL+SYMTAB)" "把 Coq 出的符号行排序/去重后编码为 name→addr→type 子块，插在尾部 CRC 占位之前，因此 CRC 自动覆盖段 7。运行核整段跳过，解析归 svm -s/-l 与 sim --watch。布局协议 spec/safeasm-spec.md §4.8。证据 veristc_main.ml:293,337,493-499。" "OCaml" {
                    tags "Conf-High"
                }
                crcHost = component "attach_crc32 (OCaml 侧)" "对第 6 字节起的有效载荷计算 CRC32 并回填尾部 4 字节。证据 veristc_main.ml:255-267,499。" "OCaml" {
                    tags "Conf-High"
                }
                svobjEmit = component "emit_svobj" "Header36B|SYMTAB|RELOC|BLOCKS|IMAGE|CRC32 字节布局，IMAGE 复用 encode_module(compile_program_gc)。证据 veristc_main.ml:574-647。" "OCaml" {
                    tags "Conf-High"
                }
                svobjVerify = component "verify_svobj" "纯 OCaml 反向走查 .svobj 结构与 CRC(-x 模式)，不调用 Coq 代码。证据 veristc_main.ml:649-719。" "OCaml" {
                    tags "Conf-High"
                }
                dataTypes = component "Coq 规范数据类型 (veri-stc/spec/safest.v, veri-stc/spec/safeasm.v)" "st_program / corest 承接类型 / sasm_module 与 sasm_io_map 的定义来源，且作为提取模块进入可执行文件。证据 veri-stc/spec/safest.v:357,94, safeasm.v:282,293; veri-stc/extraction/dune:4-13。" "Coq extracted" {
                    tags "Conf-High"
                }
                proofLayer = component "证明层 (veri-stc/spec/st_semantics.v, asm_semantics.v, function_semantics.v, compiler_correctness.v)" "纯定义 + 定理，构建期需要，不产出运行期指令。端到端语义保持链(compile_st_to_sasm = compile_core_program, compiler_correctness.v:85-99,98)由 type_check_program + codegen.compile_program 组成(:1688,:1739,:2007,:2204,:2216)；针对生产函数 compile_program_gc 的定理集中在 WS-C 段(:2228-2493)，内容是 CALL 结构性质(类型段/函数段长度、被调目标存在、形参数<=局部槽位数)。证据 veri-stc/Makefile:35-82,105-117（coq → extraction → dune 路线）。" "Rocq/Coq" {
                    tags "Conf-High", "BuildTimeOnly"
                }
                deadCode = component "证明路径专用 / 已提取但入口未调用的计算函数" "codegen.compile_program(codegen.v:1077)、typechecker.type_check_program(:626) 只出现在证明组合里；另有 global_codegen.compile_program_g(:289)、inline.inline_program(inline.v:367) 亦未被调用。生产入口调 compile_program_gc，它额外串入 csites(调用点表)与 fbctx(self 相对字段上下文)。这是有意的解耦边界: 结构证明留在 codegen.v，工程扩展在 global_codegen.v 推进而不触碰已证明结构。代价: 端到端 semantics preservation 不覆盖生产入口。证据 veri-stc/extraction/extraction.v:40-63; compiler_correctness.v:85-99; AGENTS.md .svobj 实现分层。" "Coq extracted" {
                    tags "Conf-High", "NotWired"
                }
            }

            // ----- 下位机: svm —— 纯 VM 执行器 -----
            svm = container "svm (纯 VM 执行器)" "三个主程序之一。加载 .sasm -> 两道校验 -> 周期执行，另含 dump/info/符号/量程查询模式。按设计不链接 libvm_io / libvm_hs: 它不含 I/O 同步，也不含镜像换版。" "C11, POSIX (gcc)" {
                tags "Conf-High", "Deploy-运行站"

                svmMain = component "main + 周期循环" "参数 -d/-i/-m/-l/-s/-n/-p；循环体只做 vm_run -> 打印 -> 绝对定时休眠；vm_run 失败即 return 3 停机。查询模式在装载前直接返回(-d/-i/-l/-s)。证据 veri-runtime/core/svm.c:155-248,257-278。" "C11" {
                    tags "Conf-High"
                }
                fileRead = component "load_module 文件读取" "fopen/fread 进 2MB 静态缓冲(SVM_MAX_FILE_SIZE)，len==0 或越界即拒绝。证据 veri-runtime/core/svm.c:71-98,33。" "C11" {
                    tags "Conf-High"
                }
                loader = component "sasm_load / sasm_validate" "magic->version->段循环->尾部 CRC32。CRC 为全零或值不符一律 -2(veri-runtime/core/loader.c:305-314)，未签名文件放行后门已在 G0/W5 关闭；损坏制品仍被 run_vm_checks.sh 第 8 组断言拒收。第二道 sasm_validate 检查 cycle_limit/栈深/内存/入口/代码区间。证据 veri-runtime/core/loader.c:110-319,327-367; veri-runtime/core/svm.c:86-93。" "C11" {
                    tags "Conf-High"
                }
                iomapLoad = component "IOMap 段量程采信" "scale/bias 逐条读文件里的 float64(不再硬写 1.0/0.0)，read_f64 拒绝 NaN/±Inf -> 加载失败 -1。svm -m 打印的就是运行期真正生效的量程。证据 veri-runtime/core/loader.c:199-215,65; veri-runtime/core/svm.c:103-116。" "C11" {
                    tags "Conf-High"
                }
                symQuery = component "sasm_dump / sasm_info / 段 7 符号查询" "主机侧工具：反汇编(-d)、段信息(-i)、符号表(-l/-s NAME)。段 7 由运行核按未知段跳过，解析只发生在这里。证据 veri-runtime/core/svm.c:217-236; veri-runtime/core/sasm_dump.c, veri-runtime/core/sasm_info.c。" "C11" {
                    tags "Conf-High"
                }
                interp = component "vm_execute_cycle / vm_run / vm_rebind" "while(pc<body_size) 的大 opcode switch；每指令 cycle_count++ 并对 safety.cycle_limit 检查；越界/非法码/除零写 last_error。已实现 VAR_IN_OUT 指针指令 OP_I32_LOAD_PTR(0x30)/OP_I32_STORE_PTR(0x31)。vm_rebind 提供下装后的冷启动重绑(清零两套栈+线性内存)。证据 veri-runtime/core/safeasm_interp.c:259-1096,265-268,577,594,1164-1178,1136-1155; veri-runtime/core/vm.h:147-148。" "C11" {
                    tags "Conf-High"
                }
            }

            // ----- 下位机: sim —— 闭环仿真后端 -----
            sim = container "sim (仿真主程序)" "三个主程序之二。走 io_mapping_cycle 全路径，用 .plant 被控对象表充当软件 I/O 硬件；--watch 逐周期发 stdout JSONL 帧，即工程站仿真按钮的数据面。链 libvm_io + libvm_core。" "C11, POSIX (gcc)" {
                tags "Conf-High", "Deploy-运行站"

                simMain = component "sim 主循环" "参数 -n/-t/--watch；周期体 = io_mapping_cycle(read_all -> vm_run -> write_all)。证据 veri-runtime/sim/sim_main.c:240-290,273,90-92。" "C11" {
                    tags "Conf-High"
                }
                plant = component "plant.c 被控对象表" "解析 .plant(CONST/LAG/RAMP/ACTUATOR) 并确定性步进；逐行校验重名/方向/越界/字段数/非有限值，drives 链断裂即拒绝。证据 veri-runtime/sim/plant.c:150-219,220-345,347-365。" "C11" {
                    tags "Conf-High"
                }
                simIo = component "sim_io.c 软件 VM_Interface" "实现 abstract.h 的 VM_Interface：io_read/io_write 落到 plant 通道，sleep 走虚拟时钟 -> 无实时依赖、可复现。这是仓库内唯一可用的 VM_Interface 后端。证据 veri-runtime/sim/sim_io.c:17-60。" "C11" {
                    tags "Conf-High"
                }
                watch = component "watch.c 帧发射" "名字表启动即解析(段 7 名字 -> 地址 -> 数值)，未知名字直接拒绝启动；逐周期 cycle 帧 + 收尾 done 帧。协议见 spec/simulation-spec.md §4。证据 veri-runtime/sim/watch.c:82-135,177-207,264-290; veri-runtime/sim/sim_main.c:251-254,275-276,287-289。" "C11" {
                    tags "Conf-High"
                }
            }

            // ----- 下位机: veristc-agent —— 目标端常驻 -----
            agent = container "veristc-agent (目标端下装代理)" "三个主程序之三。装载初始镜像 + 周期执行 + 收 DLF1 帧流 + 周期边界原子换版 + 健康窗不过即回滚。链 libvm_hs + libvm_core。当前不含 I/O 同步(与 svm 同因)。" "C11, POSIX (gcc)" {
                tags "Conf-High", "Deploy-运行站"

                agentMain = component "agent 主循环 + 周期边界切换" "vm_run 返回后、下一周期开始前才调 dl_apply_switch；健康窗 --health-cycles 内出错即 dl_rollback 并继续跑旧镜像 —— 这是全仓唯一的运行期故障收敛机制。证据 veri-runtime/agent/agent_main.c:406-520,473,486-496,512-514。" "C11" {
                    tags "Conf-High"
                }
                agentDl = component "帧流接收服务" "从 --dl-stream 文件读 DLF1 帧，dl_rx_pump -> dl_rx_finish -> dl_stage_image 装入待切换槽；HMAC 先于 CRC 校验(两道独立门禁)。证据 veri-runtime/agent/agent_main.c:269-320,286,299,305; veri-runtime/hotstandby/download_wire.c:226,267。" "C11" {
                    tags "Conf-High"
                }
                agentKey = component "密钥与失败粘滞" "--key 64 位十六进制解析；开启下装服务却没给密钥即拒绝启动；接收侧一次失败即粘滞，需 dl_rx_reset。真签名推到 G4。证据 veri-runtime/agent/agent_main.c:137-156,351,397; veri-runtime/hotstandby/download_wire.c:130。" "C11" {
                    tags "Conf-High", "TargetState"
                }
                agentStatus = component "状态上报 stdout" "status 事件行(装载/换版/回滚/健康)写 stdout，供工程站读取运行态。证据 veri-runtime/agent/agent_main.c:104-116,458。" "C11" {
                    tags "Conf-High"
                }
            }

            // ----- I/O 映射库 -----
            libIo = container "libvm_io.a (I/O 映射静态库)" "通道缩放/偏置、安全限值饱和、read_all/write_all/cycle。自 G0/W3 起被 sim 链接并逐周期调用；svm 与 veristc-agent 不链它。" "C11 静态库" {
                tags "Conf-High"

                ioInit = component "io_mapping_init 建表" "从 SasmModule 的 IOMap 段逐条拷入 scale/bias(文件真值)，可选从段 7 解析显示用变量名(sim 传 NULL 即不解析)；绑定内存位置用的是 mem_offset，不是名字。证据 veri-runtime/io/io_mapping.c:86-133,24-42。" "C11" { tags "Conf-High" }
                ioConv = component "工程量换算与限值检查" "raw_to_eng = raw*scale+bias(饱和到 int32)、eng_to_raw 反算并防 scale==0 除零、safety_check 以 low>high 表示不限值。证据 veri-runtime/io/io_mapping.c:51-62,64-76,78-84。" "C11" { tags "Conf-High" }
                ioRead = component "io_mapping_read_all" "物理通道 -> raw_to_eng -> 安全限值饱和 -> 写 vm->memory。证据 veri-runtime/io/io_mapping.c:141-189。" "C11" { tags "Conf-High" }
                ioWrite = component "io_mapping_write_all" "内存 -> safety_check -> eng_to_raw -> 物理输出。证据 veri-runtime/io/io_mapping.c:199-244。" "C11" { tags "Conf-High" }
                ioCycle = component "io_mapping_cycle" "read_all -> vm_run -> write_all。由 sim 主循环逐周期调用，是 I/O 集成路径的真实入口。证据 veri-runtime/io/io_mapping.c:254-269 @ veri-runtime/sim/sim_main.c:273。" "C11" { tags "Conf-High" }
            }

            // ----- 热备库 -----
            libHs = container "libvm_hs.a (双机热备 + 下装静态库)" "快照/脏页/状态机/镜像下装/帧协议。自 G0/W5 起被 veristc-agent 链接，但只有 download + download_wire + hmac 三个模块进入运行路径；快照/同步/状态机仍无任何调用者。" "C11 静态库" {
                tags "Conf-High"

                hsSnap = component "snapshot.c 快照" "hs_snapshot_create 包头->脏页->值栈->帧栈->CRC 回填；hs_snapshot_apply 先校验 CRC(-2)/magic(-3)/栈指针(-4)。FB_DATA+GLOBAL 段强制整段纳入。无主程序调用。证据 veri-runtime/hotstandby/snapshot.c:207,324,239-257,304-310。" "C11" { tags "Conf-High", "NotWired" }
                hsSync = component "sync.c 主备同步" "共享内存 send/recv + 心跳 + sync_send/receive + hs_sync_cycle。hs_chan_shmem_init 把回调全置 NULL。无主程序调用。证据 veri-runtime/hotstandby/sync.c:75-77,92,119,158,205,230,253。" "C11" { tags "Conf-High", "NotWired" }
                hsSm = component "state_machine.c 主备状态机" "5 状态 x 7 事件迁移表；故障计数达阈值转 FAILED；备站连续 3 次丢心跳转 SWITCHING；hs_master_cycle 是本模块内唯一调 vm_run 的周期封装。hs_run_cycle/hs_master_cycle/hs_standby_cycle 全仓零调用点。证据 veri-runtime/hotstandby/state_machine.c:98-255,326,357,371,333。" "C11" { tags "Conf-High", "NotWired" }
                hsDl = component "download.c 版本槽与周期边界切换" "dl_manager_load_image(冷启动首装) / dl_stage_image(装入待切换槽，先 sasm_load+sasm_validate) / dl_apply_switch(周期边界提交 + vm_rebind，失败即 dl_rollback) / dl_rollback(两槽 => 一级回退)。这条链已由 veristc-agent 逐周期驱动。compute_diff/apply_patch 的增量补丁路径仍无调用者。证据 veri-runtime/hotstandby/download.c:482,510,543-559,568-588,381; veri-runtime/agent/agent_main.c:434,473,490。" "C11" { tags "Conf-High" }
                hsWire = component "download_wire.c + hmac_sha256.c 帧协议" "DLF1: 24B 头(magic|ver|kind|flags|image_len|seq|payload_len|crc32) + 载荷 + 32B HMAC-SHA256；MAC 先于 CRC 校验；接收侧粘滞失败 + DlResult 码。SHA-256/HMAC 自实现，过 FIPS 180-4 / RFC 4231 向量。证据 veri-runtime/hotstandby/download_wire.c:130,226,267; veri-runtime/hotstandby/hmac_sha256.c。" "C11" { tags "Conf-High" }
            }

            // ----- 目标移植 -----
            rtthread = container "vm_rtthread (RT-Thread 移植)" "候补硬件后端：三线程架构(io_drv/vm_main/vm_wdt) + 看门狗周期停滞复位 + VM_Interface 全量实现；但不在 all(=vm-lib vm-io vm-hs svm build-sim agent)、CC 仍是 gcc、且 include 了不存在的 veri-runtime/core/loader.h:30，当前连语法检查都无法通过。" "C11 + RT-Thread SDK" {
                tags "Conf-High", "NotWired", "Broken"

                rtWdt = component "vm_wdt 看门狗线程" "检测周期停滞并 vm_init 复位。三个主程序都没有看门狗，这是全仓唯一的超周期兜底设计，但不在构建路径。证据 veri-runtime/rtos/rtthread/vm_rtthread.c:398-427,483-505。" "C" { tags "Conf-High", "NotWired" }
                rtIo = component "io_drv 线程" "调用 io_mapping_read_all/write_all。证据 veri-runtime/rtos/rtthread/vm_rtthread.c:335,347。" "C" { tags "Conf-High", "NotWired" }
            }

            // ----- QA 可执行 -----
            qaBin = container "测试与质量工具可执行" "test_vm / test_io_mapping / test_hotstandby / test_download_wire / test_download_switch / test_nuclear_protection_full_e2e / sasm_fuzzer / svm-asan。test_hotstandby 靠 #include .c 源码内联；两个下装测试直接编译 hotstandby/*.c 源，只有 sim 与 agent 走真实归档 ABI。仿真不设 C 单测，门禁是 integration/run_sim_e2e.sh 黑盒跑 build/bin/sim。" "C11 (Unity/CMock 风格), ASan/UBSan 变体" {
                tags "Conf-High", "TestOnly"
            }

            // ----- 文件产物 -----
            stSrc = container "ST 源程序 (.st)" "veri-stc/tests/st-examples 下的示例、特性探针与核电 RPS/ESFAS 模型。" "IEC 61131-3 文本文件" {
                tags "Conf-High", "ArtifactFile"
            }
            sasmFile = container ".sasm 镜像" "不可执行镜像: Header | 段表 | IOMap(段 3) | Code | Debug(段 7) | CRC32。尾部 CRC 覆盖 [6, len-4)，加载时值不符或全零一律拒收。" "自定义二进制" {
                tags "Conf-High", "ArtifactFile"
            }
            svobjFile = container ".svobj 可重定位对象" "SYMTAB/RELOC/BLOCKS/IMAGE + CRC32。三类重定位行(CALL_IDX/INST_BASE_IMM/GLOBAL_OFF)现已全部产出，但仓库内无消费者(链接器 veristc-ld 属 P3 计划)。" "自定义二进制" {
                tags "Conf-High", "ArtifactFile", "TargetState"
            }
            plantFile = container "被控对象表 (.plant)" "仿真侧的工程量程与被控动力学真值源；定宽文本表，逐行协议校验。协议唯一源 spec/simulation-spec.md。" "文本表格" {
                tags "Conf-High", "ArtifactFile"
            }
            watchFrames = container "watch 帧流 (stdout JSONL)" "sim --watch 逐周期发出的「符号名 -> 段 7 地址 -> 数值」帧，工程站仿真按钮的数据面。" "JSONL" {
                tags "Conf-High", "ArtifactFile"
            }
            dlStream = container "下装帧流 (DLF1)" "24B 头 + 载荷 + 32B HMAC-SHA256 的帧序列；当前经文件传输，socket 传输推到 G1+。协议唯一源 spec/download-spec.md。" "自定义二进制帧" {
                tags "Conf-High", "ArtifactFile", "TargetState"
            }

            // ===== 容器级关系 =====
            stEngineer -> compiler "调用编译/分析/生成/校验" "-c / -a / -g / -x / --json" { tags "Conf-High" }
            compiler -> stSrc "读取源码" "文件读" { description "veristc_main.ml:57 定义, :425/-c 与 :724/-a 调用"; tags "Conf-High" }
            compiler -> sasmFile "写出镜像" "文件写" { description "compile_st_to_sasm veristc_main.ml:484-499 -> write_file :501-... @ :864"; tags "Conf-High" }
            compiler -> svobjFile "写出可重定位对象" "文件写" { description "emit_svobj veristc_main.ml:574-647 -> write_file @ :873"; tags "Conf-High" }
            compiler -> coqToolchain "构建期依赖" "coqc -> extraction -> ocamlopt" { description "veri-stc/Makefile:35-99; dune 目标见 veri-stc/extraction/dune:4-13"; tags "Conf-High", "BuildTimeOnly" }
            sasmFile -> svm "载入字节流" "fread -> sasm_load" { description "veri-runtime/core/svm.c:71-98,86"; tags "Conf-High" }
            sasmFile -> sim "载入字节流" "fread -> sasm_load" { description "veri-runtime/sim/sim_main.c:90-92"; tags "Conf-High" }
            sasmFile -> agent "首装镜像载入版本槽" "dl_manager_load_image -> sasm_load" { description "veri-runtime/agent/agent_main.c:434; veri-runtime/hotstandby/download.c:482,456"; tags "Conf-High" }
            plantFile -> sim "充当物理被控对象" "文件读 -> 通道 raw 值" { description "veri-runtime/sim/plant.c:220-345 @ sim_main.c:231"; tags "Conf-High" }
            sim -> watchFrames "逐周期发出" "stdout JSONL" { description "veri-runtime/sim/watch.c:264-290 @ sim_main.c:275-276,287-289"; tags "Conf-High" }
            dlStream -> agent "帧流式下装" "文件读 -> dl_rx_pump" { description "veri-runtime/agent/agent_main.c:269-320,286; veri-runtime/hotstandby/download_wire.c:226"; tags "Conf-High" }
            svm -> svobjFile "不读取" "无入口" { description "三个主程序均无 .svobj 装载路径；可重定位对象只在编译器侧被 -x 校验"; tags "Conf-High", "NotWired" }
            svobjFile -> futureLinker "预期消费者" "链接" { description "AGENTS.md .svobj 约定: 链接器 veristc-ld 为 P3 计划"; tags "TargetState" }
            qaBin -> svm "驱动周期执行与 dump" "进程调用" { description "veri-runtime/run_vm_checks.sh; veri-runtime/Makefile:149-155"; tags "Conf-High" }
            qaBin -> libIo "链接并 mock 硬件" "-lvm_io -lvm_core + g_vm_interface mock" { description "veri-runtime/tests/vm-tests/test_io_mapping.c:16,44-45"; tags "Conf-High" }
            qaBin -> libHs "源码内联后直调底层 API" "#include ../../hotstandby/*.c 或直接编源" { description "veri-runtime/tests/vm-tests/test_hotstandby.c:18-23; veri-runtime/Makefile:127-143"; tags "Conf-High", "NotWired" }
            qaBin -> qaTools "构建/运行依赖" "命令行" { description "veri-runtime/Makefile:188-249,252; 根 Makefile:77-83,148-149; veri-runtime/run_misra_check.sh"; tags "Conf-High" }
            libIo -> sim "周期入口被逐扫描调用" "链接 -lvm_io + io_mapping_cycle" { description "veri-runtime/Makefile:162-169; veri-runtime/io/io_mapping.c:254 @ sim/sim_main.c:273"; tags "Conf-High" }
            libHs -> agent "版本槽/换版/回滚被逐周期驱动" "链接 -lvm_hs" { description "veri-runtime/Makefile:176-182; download.c:543 @ agent_main.c:473"; tags "Conf-High" }
            rtthread -> libIo "调用 I/O 扫描" "函数调用" { description "veri-runtime/rtos/rtthread/vm_rtthread.c:335,347"; tags "Conf-High", "NotWired" }
            rtthread -> svm "使用 VM core 与 loader" "函数调用" { description "veri-runtime/rtos/rtthread/vm_rtthread.c:29-30; 其中 veri-runtime/core/loader.h 不存在 -> 当前不可编译"; tags "Conf-High", "Broken" }
            rtthread -> rtosSdk "依赖 OS API" "rtthread.h" { description "veri-runtime/rtos/rtthread/vm_rtthread.c:34; veri-runtime/Makefile:259-270 需 RTTHREAD_SDK 且只做语法编译"; tags "Conf-High", "NotWired" }
            rtthread -> ioHardware "读写物理通道" "VM_Interface.io_read/io_write" { description "veri-runtime/rtos/abstract.h:77-288,294"; tags "Conf-High", "NotWired" }
            sim -> ioHardware "以软件后端充当" "VM_Interface 的 sim_io 实现" { description "veri-runtime/sim/sim_io.c:17-60 —— 仓库内唯一可用的 VM_Interface 后端；生产级通道驱动仍缺位"; tags "Conf-High", "NotWired" }
            svm -> ioHardware "有意不含 I/O 同步" "无" { description "veri-runtime/core/svm.c:257-278 循环体内只有 vm_run —— G0 起这是三个主程序的分工，不再算缺口；I/O 在 sim，换版在 agent"; tags "Conf-High", "NotWired" }
        }

        // ===== 编译器内部管线关系 (证据: veri-stc/extraction/veristc_main.ml frontend/后端) =====
        veristc.compiler.cli -> veristc.compiler.lexer "1 源码字符串 -> token" "in-process" { description "parse_or_fail veristc_main.ml:214-218, L.lex :215"; tags "Conf-High" }
        veristc.compiler.lexer -> veristc.compiler.parser "2 token -> st_program" "in-process" { description "veristc_main.ml:220-234 (P.parse + parse_fail_pos 回推行列)"; tags "Conf-High" }
        veristc.compiler.parser -> veristc.compiler.dupchk "3 重名检查" "in-process" { description "veristc_main.ml:432-434"; tags "Conf-High" }
        veristc.compiler.dupchk -> veristc.compiler.funcCheck "4 FUNCTION 准备 + 展开后重名 + 全量诊断" "in-process" { description "veristc_main.ml:435-461 (prepare :435, 展开后重名 :444, 诊断 :453-461)"; tags "Conf-High" }
        veristc.compiler.funcCheck -> veristc.compiler.inline "5 规范化 + 内联优化" "in-process" { description "veristc_main.ml:464-468"; tags "Conf-High" }
        veristc.compiler.inline -> veristc.compiler.desugar "6 st_program -> corest_program" "in-process" { description "veristc_main.ml:471"; tags "Conf-High" }
        veristc.compiler.desugar -> veristc.compiler.analysis "7 corest -> 分析结果 + 递归/栈深门禁" "in-process" { description "veristc_main.ml:474-481"; tags "Conf-High" }
        veristc.compiler.analysis -> veristc.compiler.gcCodegen "8 -c/-g: corest -> sasm_module" "in-process" { description "veristc_main.ml:486 (-c), :617 (-g)"; tags "Conf-High" }
        veristc.compiler.gcCodegen -> veristc.compiler.encoder "9 sasm_module -> list Z 字节" "in-process" { description "veristc_main.ml:489,622"; tags "Conf-High" }
        veristc.compiler.encoder -> veristc.compiler.iomapPatch "9.5 量程占位 -> IR 真值覆盖" "in-process" { description "veristc_main.ml:488-492,375-421 (-g 侧 :620-625 同)"; tags "Conf-High" }
        veristc.compiler.gcCodegen -> veristc.compiler.debugEmit "9.6 段 7 符号行 -> STRPOOL+SYMTAB 字节" "in-process" { description "veristc_main.ml:493-497,293-335"; tags "Conf-High" }
        veristc.compiler.iomapPatch -> veristc.compiler.crcHost "10 拼接段 7 后附尾部 CRC32" "in-process" { description "splice_debug :337 -> attach_crc32 :255-267 @ :499"; tags "Conf-High" }
        veristc.compiler.gcCodegen -> veristc.compiler.relocMeta "8b -g: 扁平元数据行" "in-process" { description "veristc_main.ml:578,583,589"; tags "Conf-High" }
        veristc.compiler.relocMeta -> veristc.compiler.svobjEmit "9b 排序/去重/字节布局" "in-process" { description "veristc_main.ml:574-647"; tags "Conf-High" }
        veristc.compiler.encoder -> veristc.compiler.svobjEmit "IMAGE 复用同一 encode_module + patch_iomap_cal 结果" "in-process" { description "veristc_main.ml:617-625"; tags "Conf-High" }
        veristc.compiler.cli -> veristc.compiler.svobjVerify "-x 独立校验路径" "in-process" { description "veristc_main.ml:649-719"; tags "Conf-High" }
        veristc.compiler.cli -> veristc.compiler.analyzeSt "-a 独立路径, 不经 frontend" "in-process" { description "parse_args :808-841(默认 Analyze :840); 管线 :721-780"; tags "Conf-High", "DuplicatedLogic" }
        veristc.compiler.analyzeSt -> veristc.compiler.desugar "复用同一批 Coq 计算函数(第 6-7 步)" "in-process" { description "A.analyze (D.desugar_program ast) :760 —— 与 frontend:471-474 重复；且 -a 侧无递归/栈深门禁(:761-780 只报告)"; tags "Conf-High", "DuplicatedLogic" }
        veristc.compiler.dataTypes -> veristc.compiler.lexer "共享 AST/IR 类型定义" "提取模块" { description "veri-stc/spec/safest.v:357,94, safeasm.v:282"; tags "Conf-High" }
        veristc.compiler.proofLayer -> veristc.compiler.dataTypes "复用规范定义陈述定理" "Coq Require" { description "veri-stc/spec/compiler_correctness.v:19-22 反向引用 src 计算函数"; tags "Conf-High", "BuildTimeOnly" }
        veristc.compiler.deadCode -> veristc.compiler.gcCodegen "证明路径函数与生产函数并列" "未被调用" { description "端到端语义保持建立在 compile_program + type_check_program 上(compiler_correctness.v:85-99); 生产入口调 compile_program_gc; gc 路径另有 CALL 结构定理(:2228-2493)"; tags "Conf-High", "NotWired" }
    }

    // ==========================================================
    // VIEWS
    // ==========================================================
    views {

        systemContext veristc "v1-system-context" "L1 系统上下文: 边界内的编译器+VM，边界外的工具链/硬件/OS/计划中的链接器" {
            include *
            autoLayout TB
        }

        container veristc "v2-containers" "L2 容器: 真实可部署单元 vs 已实现未接入单元(虚线)" {
            include *
            autoLayout TB
        }

        component veristc.compiler "v3-compiler-components" "L3 组件: 编译器生产管线阶段与证明层边界" {
            include *
            autoLayout TB
        }

        component veristc.svm "v4-svm-components" "L3 组件: svm 内部结构 —— 装载两道关 + 纯计算周期，有意不含 I/O 与换版" {
            include *
            autoLayout TB
        }

        component veristc.sim "v4b-sim-components" "L3 组件: sim 仿真主程序 —— io_mapping_cycle 全路径 + .plant 软件后端 + watch 帧" {
            include *
            autoLayout TB
        }

        component veristc.agent "v4c-agent-components" "L3 组件: veristc-agent —— 版本槽、周期边界换版、健康窗回滚" {
            include *
            autoLayout TB
        }

        component veristc.libIo "v4d-io-components" "L3 组件: libvm_io 内部结构与它在 sim 里的唯一入口" {
            include *
            autoLayout TB
        }

        component veristc.libHs "v5-hotstandby-components" "L3 组件: 双机热备库内部结构 —— download/wire 已接入 agent，快照/同步/状态机仍零调用点" {
            include *
            autoLayout TB
        }

        // ---- 样式: 用视觉编码区分接入状态 ----
        styles {
            element "Person" {
                shape Person
                background "#1f6feb"
                color "#ffffff"
            }
            element "ExternalSystem" {
                shape Rectangle
                background "#6e7781"
                color "#ffffff"
            }
            element "ArtifactFile" {
                shape Folder
                background "#f2cc60"
                color "#3b3000"
            }
            element "TestOnly" {
                background "#a371f7"
                color "#ffffff"
            }
            element "NotWired" {
                border "#fb8500"
                color "#c2410c"
                fontSize 12
            }
            element "Broken" {
                border "#f85149"
                color "#f85149"
            }
            element "TargetState" {
                opacity 60
            }
            element "BuildTimeOnly" {
                background "#0e4429"
                color "#aff5b4"
            }
            element "DuplicatedLogic" {
                border "#bf3989"
                color "#bf3989"
            }
            relationship "NotWired" {
                style Dashed
                color "#fb8500"
                thickness 2
            }
            relationship "TargetState" {
                style Dotted
                color "#8b949e"
            }
            relationship "BuildTimeOnly" {
                style Dashed
                color "#2ea043"
            }
            relationship "Conf-High" {
                color "#57606a"
            }
        }
    }
}
