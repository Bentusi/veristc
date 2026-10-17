workspace "VeriSTC current-state architecture" "VeriSTC = SafeST(ST) -> SafeASM 编译器 + C 语言虚拟机。当前状态(AS-IS)模型；每个节点/关系的 description 内含 文件:行号 证据，标签编码置信度与接入状态。生成日期 2026-10-14。" {

    // ==========================================================
    // MODEL
    // ==========================================================
    model {

        // ---------- Actors ----------
        stEngineer = person "ST 应用工程师" "在上位机侧编写 .st 并调用 veristc 命令行做编译/分析/生成可重定位对象。证据: AGENTS.md 架构概览、veristc/extraction/veristc_main.ml:495+ 命令行分支。无图形界面代码，人机交互仅证据到 CLI 层。" {
            tags "Person", "Conf-Medium"
        }

        // ---------- External systems ----------
        coqToolchain = softwareSystem "Rocq/Coq + OCaml 工具链" "coqc/rocq 编译 .v -> .vo，Extraction 产出 .ml/.mli，ocamlfind ocamlopt 链接可执行文件。" {
            tags "ExternalSystem", "Conf-High"
        }
        rtosSdk = softwareSystem "RT-Thread SDK" "目标平台 OS API；仅在 RTTHREAD_SDK 变量非空时参与语法编译，不链接。" {
            tags "ExternalSystem", "NotWired", "Conf-High"
        }
        ioHardware = softwareSystem "物理 I/O 通道 (AI/AO/DI/DO)" "由 VM_Interface 的 io_read/io_write/io_group_* 函数指针契约描述。" {
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
            compiler = container "veristc (编译器可执行)" "单入口 OCaml 原生程序，按 -c/-a/-g/-x 四种模式驱动 Coq 提取出来的计算函数。" "OCaml native (ocamlopt) + Coq-extracted modules" {
                tags "Conf-High", "HostTool", "Deploy-上位机"

                cli = component "CLI 入口 (手写)" "veristc_main.ml 为手写源，不参与提取；负责参数解析、读写文件、CRC32、.svobj 字节编码。模式分派在 :488-500，-a 为默认模式。" "OCaml" {
                    tags "Conf-High"
                }
                analyzeSt = component "analyze_st (-a 模式独立管线)" "read_file→parse_or_fail→重名→prepare→diag→normalize→optimize→desugar→analyze 九步与 frontend(:183-217) 重复实现，但**不做递归拒绝与栈深门禁**(:210-216 只在 frontend 里)，只把 stack depth / recursive calls / estimated wcet / loops bounded 四项 printf 到 stdout。证据 veristc_main.ml:443-472。" "Coq extracted + OCaml" {
                    tags "Conf-High", "DuplicatedLogic"
                }
                lexer = component "Lexer.lex" "字符流 -> token 表。证据 veristc/src/lexer.v:377, 调用点 veristc_main.ml:132。" "Coq extracted" {
                    tags "Conf-High"
                }
                parser = component "Parser.parse" "token -> st_program；失败时用 parse_fail_pos + lex_offsets 回推行列。证据 veristc/src/parser.v:1295,1319; veristc_main.ml:136-148。" "Coq extracted" {
                    tags "Conf-High"
                }
                dupchk = component "check_no_duplicate_declarations" "扁平命名空间重名即编译错误。证据 veristc/src/typechecker.v:184, veristc_main.ml:189-190。" "Coq extracted" {
                    tags "Conf-High"
                }
                funcCheck = component "Function_check.prepare_program / check_program_full_diag" "FUNCTION 结果变量准备 + 作用域/纯性/调用类型全量诊断。证据 veristc/src/function_check.v:881,984; veristc_main.ml:191-198。" "Coq extracted" {
                    tags "Conf-High"
                }
                inline = component "Inline.normalize_program / optimize_inline_program" "保留函数的规范化 + 叶子内联/死函数消除。证据 veristc/src/inline.v:647,942; veristc_main.ml:199-203。" "Coq extracted" {
                    tags "Conf-High"
                }
                desugar = component "Desugar.desugar_program" "st_program -> corest_program (CoreST)。证据 veristc/src/desugar.v:401,62; veristc_main.ml:206。" "Coq extracted" {
                    tags "Conf-High"
                }
                analysis = component "Analysis.analyze" "调用图/递归/栈深/WCET；生产入口用它做递归拒绝与栈深门禁。证据 veristc/src/analysis.v:242; veristc_main.ml:209-216。" "Coq extracted" {
                    tags "Conf-High"
                }
                gcCodegen = component "Global_codegen.compile_program_gc" "生产 codegen 路径: CoreST -> sasm_module (全局偏移 + FB 实例)。v1.5 VAR_IN_OUT 逐引用别名: 端口降级为持有调用方地址的形参槽，读写发 I32_LOAD_PTR/I32_STORE_PTR(地址取自值栈而非静态 mem_offset)。证据 veristc/src/global_codegen.v:780,480,623; veristc_main.ml:221,347。" "Coq extracted" {
                    tags "Conf-High"
                }
                relocMeta = component "compile_program_reloc_info / inst_info / sym_info" "只导出扁平重定位/实例/符号元数据行，排序去重留给 OCaml。reloc kind 0=CALL_IDX / 1=INST_BASE_IMM / 2=GLOBAL_OFF(VAR_IN_OUT 别名实参, 由 build_alias_table 从调用点派生; 别名判定优先于基址判定)。证据 veristc/src/global_codegen.v:991,1007,1042,858-932,1008; veristc_main.ml:307-319。" "Coq extracted" {
                    tags "Conf-High"
                }
                encoder = component "Encoder.encode_module" "sasm_module -> list Z 字节序列(定宽小端, 不含 CRC)。证据 veristc/src/encoder.v:327; veristc_main.ml:221,347。" "Coq extracted" {
                    tags "Conf-High"
                }
                crcHost = component "attach_crc32 (OCaml 侧)" "对第 6 字节起的有效载荷计算 CRC32 并回填尾部 4 字节。证据 veristc_main.ml:163-181,221。" "OCaml" {
                    tags "Conf-High"
                }
                svobjEmit = component "emit_svobj" "Header36B|SYMTAB|RELOC|BLOCKS|IMAGE|CRC32 字节布局，IMAGE 复用 encode_module(compile_program_gc)。证据 veristc_main.ml:304-369。" "OCaml" {
                    tags "Conf-High"
                }
                svobjVerify = component "verify_svobj" "纯 OCaml 反向走查 .svobj 结构与 CRC(-x 模式)，不调用 Coq 代码。证据 veristc_main.ml:371-441。" "OCaml" {
                    tags "Conf-High"
                }
                dataTypes = component "Coq 规范数据类型 (spec/safest.v, spec/safeasm.v)" "st_program / corest 承接类型 / sasm_module 与 sasm_io_map 的定义来源，且作为提取模块进入可执行文件。证据 veristc/spec/safest.v:343, safeasm.v:282,293; veristc/extraction/dune:4-13。" "Coq extracted" {
                    tags "Conf-High"
                }
                proofLayer = component "证明层 (spec/st_semantics.v, asm_semantics.v, function_semantics.v, compiler_correctness.v)" "纯定义 + 定理，构建期需要，不产出运行期指令。端到端语义保持链(compile_st_to_sasm = compile_core_program, compiler_correctness.v:85-99,98)由 type_check_program + codegen.compile_program 组成(:1688,:1739,:2007,:2204,:2216)；针对生产函数 compile_program_gc 的定理集中在 WS-C 段(:2228-2493)，内容是 CALL 结构性质(类型段/函数段长度、被调目标存在、形参数<=局部槽位数)。证据 Makefile:204-219,237-239。" "Rocq/Coq" {
                    tags "Conf-High", "BuildTimeOnly"
                }
                deadCode = component "证明路径专用 / 已提取但入口未调用的计算函数" "codegen.compile_program(codegen.v:1077)、typechecker.type_check_program(:511) 只出现在证明组合里；另有 global_codegen.compile_program_g(:269)、inline.inline_program(inline.v:367) 亦未被调用。生产入口调 compile_program_gc，它额外串入 csites(调用点表)与 fbctx(self 相对字段上下文)。这是有意的解耦边界: 结构证明留在 codegen.v，工程扩展在 global_codegen.v 推进而不触碰已证明结构。代价: 端到端 semantics preservation 不覆盖生产入口。证据 extraction/extraction.v:40-63; compiler_correctness.v:85-99; AGENTS.md .svobj 实现分层。" "Coq extracted" {
                    tags "Conf-High", "NotWired"
                }
            }

            // ----- 下位机: SVM 运行程序 -----
            svm = container "svm (运行站程序)" "唯一的 VM 可执行文件；加载 .sasm -> 校验 -> 周期执行 -> 可选 dump。不链接 libvm_io / libvm_hs。" "C11, POSIX (gcc)" {
                tags "Conf-High", "Deploy-运行站"

                svmMain = component "main + 周期循环" "参数 -d/-n/-p；循环体只做 vm_run -> 打印 -> 绝对定时休眠；vm_run 失败即 return 3 停机。证据 vm/svm.c:138,204-225。" "C11" {
                    tags "Conf-High"
                }
                fileRead = component "load_module 文件读取" "fopen/fread 进 2MB 静态缓冲，尺寸非法即拒绝。证据 vm/svm.c:70-99,24。" "C11" {
                    tags "Conf-High"
                }
                loader = component "sasm_load / sasm_validate" "magic->version->段循环->尾部 CRC32；损坏文件返回 -2(run_vm_checks.sh:209 断言)，但 stored_crc==0 的未签名文件被放行(loader.c:286-288, legacy fixture 约定)。第二道 validate 检查 cycle_limit/栈深/内存/入口/代码区间。证据 vm/loader.c:91-295,283-289,302-342; vm/svm.c:90-93。" "C11" {
                    tags "Conf-High"
                }
                interp = component "vm_execute_cycle / vm_run" "while(pc<body_size) 的大 opcode switch；每指令 cycle_count++ 并对 safety.cycle_limit 检查；越界/非法码/除零写 last_error。已实现 VAR_IN_OUT 指针指令 OP_I32_LOAD_PTR(0x30)/OP_I32_STORE_PTR(0x31)。证据 vm/safeasm_interp.c:259-1090,265-269,577,594,1138-1156; vm/vm.h:147-148。" "C11" {
                    tags "Conf-High"
                }
                dumpTool = component "sasm_dump (反汇编 -d)" "把已加载模块反汇编输出。证据 vm/svm.c:8,-d 分支, vm/sasm_dump.c。" "C11" {
                    tags "Conf-High"
                }
                ioShim = component "io_mapping_cycle 链接桩" "svm.c 内的同名本地实现，丢弃 table 参数直接 return vm_run。存在的原因是链入的 vm_scan_cycle 引用该符号；它自身在 svm 主循环里也没被调用。证据 vm/svm.c:31-37,205; vm/safeasm_interp.c:1162-1174。" "C11" {
                    tags "Conf-High", "NotWired"
                }
                scanCycle = component "vm_scan_cycle (I/O 集成扫描入口)" "为完整 I/O+VM 周期而设计，全仓零调用点。证据 vm/safeasm_interp.c:1162, vm/vm.h:349。" "C11" {
                    tags "Conf-High", "NotWired"
                }
            }

            // ----- I/O 映射库 -----
            libIo = container "libvm_io.a (I/O 映射静态库)" "通道缩放/偏置、安全限值饱和、read_all/write_all/cycle。真实周期实现只在 io_mapping.c:254-269。" "C11 静态库" {
                tags "Conf-High", "NotWired"

                ioRead = component "io_mapping_read_all" "物理通道 -> raw_to_eng -> 安全限值饱和 -> 写 vm->memory。证据 vm/io/io_mapping.c:141-189。" "C11" { tags "Conf-High" }
                ioWrite = component "io_mapping_write_all" "内存 -> safety_check -> eng_to_raw -> 物理输出。证据 vm/io/io_mapping.c:199-244。" "C11" { tags "Conf-High" }
                ioCycle = component "io_mapping_cycle (真实实现)" "read_all -> vm_run -> write_all。证据 vm/io/io_mapping.c:254-269。" "C11" { tags "Conf-High", "NotWired" }
            }

            // ----- 热备库 -----
            libHs = container "libvm_hs.a (双机热备静态库)" "快照/脏页/状态机/增量下装。构建进 all，但没有任何可执行目标链接它。" "C11 静态库" {
                tags "Conf-High", "NotWired"

                hsSnap = component "snapshot.c 快照" "hs_snapshot_create 包头->脏页->值栈->帧栈->CRC 回填；hs_snapshot_apply 先校验 CRC(-2)/magic(-3)/栈指针(-4)。FB_DATA+GLOBAL 段强制整段纳入。证据 vm/hotstandby/snapshot.c:207,324,239-257,304-310。" "C11" { tags "Conf-High" }
                hsSync = component "sync.c 主备同步" "共享内存 send/recv + 心跳 + sync_send/receive + hs_sync_cycle。hs_chan_shmem_init 把回调全置 NULL。证据 vm/hotstandby/sync.c:75-77,92,119,158,205,230,253。" "C11" { tags "Conf-High" }
                hsSm = component "state_machine.c 主备状态机" "5 状态 x 7 事件迁移表；故障计数达阈值转 FAILED；备站连续 3 次丢心跳转 SWITCHING；hs_master_cycle 是本模块内唯一调 vm_run 的周期封装。hs_run_cycle/hs_master_cycle/hs_standby_cycle 全仓零调用点。证据 vm/hotstandby/state_machine.c:98-255,326,357,371,333。" "C11" { tags "Conf-High", "NotWired" }
                hsDl = component "download.c 增量下装" "compute_diff/apply_patch/dl_prepare_download/dl_commit_switch(先 sasm_validate 再换槽, 失败回滚)；静态单例管理器。dl_commit_switch 仅测试调用。证据 vm/hotstandby/download.c:100,210,297,332-346,266。" "C11" { tags "Conf-High" }
            }

            // ----- 目标移植 -----
            rtthread = container "vm_rtthread (RT-Thread 移植)" "三线程架构(io_drv/vm_main/vm_wdt) + 看门狗周期停滞复位 + VM_Interface 全量实现；但不在 all/build-tests、CC 仍是 gcc、且 include 了不存在的 vm/loader.h，当前连语法检查都无法通过。" "C11 + RT-Thread SDK" {
                tags "Conf-High", "NotWired", "Broken"

                rtWdt = component "vm_wdt 看门狗线程" "检测周期停滞并 vm_init 复位。运行期唯一的超周期兜底，但不在构建路径。证据 rtos/rtthread/vm_rtthread.c:398-427,483-505。" "C" { tags "Conf-High", "NotWired" }
                rtIo = component "io_drv 线程" "调用 io_mapping_read_all/write_all。证据 rtos/rtthread/vm_rtthread.c:335,347。" "C" { tags "Conf-High", "NotWired" }
            }

            // ----- QA 可执行 -----
            qaBin = container "测试与质量工具可执行" "test_vm / test_io_mapping / test_hotstandby / test_nuclear_protection_full_e2e / sasm_fuzzer / svm-asan / test_vm-asan。test_hotstandby 靠 #include .c 源码内联而非链接 libvm_hs.a。" "C11 (Unity/CMock 风格), ASan/UBSan 变体" {
                tags "Conf-High", "TestOnly"
            }

            // ----- 文件产物 -----
            stSrc = container "ST 源程序 (.st)" "tests/st-examples 下的示例、特性探针与核电 RPS/ESFAS 模型。" "IEC 61131-3 文本文件" {
                tags "Conf-High", "ArtifactFile"
            }
            sasmFile = container ".sasm 镜像" "不可执行镜像: Header | 段表 | IOMap(Section type=3) | Code | CRC32。" "自定义二进制" {
                tags "Conf-High", "ArtifactFile"
            }
            svobjFile = container ".svobj 可重定位对象" "SYMTAB/RELOC/BLOCKS/IMAGE + CRC32。三类重定位行(CALL_IDX/INST_BASE_IMM/GLOBAL_OFF)现已全部产出，但仓库内无消费者(链接器 veristc-ld 属 P3 计划)。" "自定义二进制" {
                tags "Conf-High", "ArtifactFile", "TargetState"
            }

            // ===== 容器级关系 =====
            stEngineer -> compiler "调用编译/分析/生成/校验" "-c / -a / -g / -x" { tags "Conf-High" }
            compiler -> stSrc "读取源码" "文件读" { description "veristc_main.ml:184 read_file"; tags "Conf-High" }
            compiler -> sasmFile "写出镜像" "文件写" { description "veristc_main.ml:219-226"; tags "Conf-High" }
            compiler -> svobjFile "写出可重定位对象" "文件写" { description "veristc_main.ml:304-369,520-522"; tags "Conf-High" }
            compiler -> coqToolchain "构建期依赖" "coqc -> extraction -> ocamlopt" { description "Makefile:197-292; dune 目标见 veristc/extraction/dune:4-13"; tags "Conf-High", "BuildTimeOnly" }
            sasmFile -> svm "载入字节流" "fread -> sasm_load" { description "vm/svm.c:70-99"; tags "Conf-High" }
            svm -> svobjFile "不读取" "无入口" { description "当前 SVM 无 .svobj 装载路径；可重定位对象只在编译器侧被 -x 校验"; tags "Conf-High", "NotWired" }
            svobjFile -> futureLinker "预期消费者" "链接" { description "AGENTS.md .svobj 约定: 链接器 veristc-ld 为 P3 计划"; tags "TargetState" }
            qaBin -> svm "驱动周期执行与 dump" "进程调用" { description "run_vm_checks.sh; Makefile:132-137"; tags "Conf-High" }
            qaBin -> libIo "链接并 mock 硬件" "-lvm_io -lvm_core + g_vm_interface mock" { description "Makefile:121-124; tests/vm-tests/test_io_mapping.c:16,44-45"; tags "Conf-High" }
            qaBin -> libHs "源码内联后直调底层 API" "#include ../../vm/hotstandby/*.c" { description "tests/vm-tests/test_hotstandby.c:18-23; Makefile:128-129"; tags "Conf-High", "NotWired" }
            qaBin -> qaTools "构建/运行依赖" "命令行" { description "Makefile:322-373; run_misra_check.sh"; tags "Conf-High" }
            libIo -> svm "被引用名由本地桩替代" "链接符号 io_mapping_cycle" { description "vm/svm.c:31-37 定义同名桩; 真实实现 vm/io/io_mapping.c:254 未被 svm 链接"; tags "Conf-High", "NotWired" }
            libHs -> svm "库内调用 vm_run 做主备周期" "函数调用" { description "vm/hotstandby/state_machine.c:333; 但 libvm_hs.a 未被任何可执行目标链接(Makefile:104-107)"; tags "Conf-High", "NotWired" }
            rtthread -> libIo "调用 I/O 扫描" "函数调用" { description "rtos/rtthread/vm_rtthread.c:335,347 — 唯一真实消费者"; tags "Conf-High", "NotWired" }
            rtthread -> svm "使用 VM core 与 loader" "函数调用" { description "rtos/rtthread/vm_rtthread.c:29-30; 其中 vm/loader.h 不存在 -> 当前不可编译"; tags "Conf-High", "Broken" }
            rtthread -> rtosSdk "依赖 OS API" "rtthread.h" { description "rtos/rtthread/vm_rtthread.c:34; Makefile:182-190 需 RTTHREAD_SDK 且只做语法编译"; tags "Conf-High", "NotWired" }
            rtthread -> ioHardware "读写物理通道" "VM_Interface.io_read/io_write" { description "rtos/abstract.h:77-288,294"; tags "Conf-High", "NotWired" }
            svm -> ioHardware "应当读写(当前被桩绕过)" "无" { description "vm/svm.c:204-225 循环体内只有 vm_run，无 read_all/write_all；且 IOMap 的 scale/bias 在加载时被硬编码 1.0/0.0 并跳过 16 字节(vm/loader.c:186-190)"; tags "Conf-High", "NotWired" }
        }

        // ===== 编译器内部管线关系 (证据: veristc/extraction/veristc_main.ml frontend/后端) =====
        veristc.compiler.cli -> veristc.compiler.lexer "1 源码字符串 -> token" "in-process" { description "veristc_main.ml:132,186"; tags "Conf-High" }
        veristc.compiler.lexer -> veristc.compiler.parser "2 token -> st_program" "in-process" { description "veristc_main.ml:136"; tags "Conf-High" }
        veristc.compiler.parser -> veristc.compiler.dupchk "3 重名检查" "in-process" { description "veristc_main.ml:189"; tags "Conf-High" }
        veristc.compiler.dupchk -> veristc.compiler.funcCheck "4 FUNCTION 准备 + 全量诊断" "in-process" { description "veristc_main.ml:191,195"; tags "Conf-High" }
        veristc.compiler.funcCheck -> veristc.compiler.inline "5 规范化 + 内联优化" "in-process" { description "veristc_main.ml:199,203"; tags "Conf-High" }
        veristc.compiler.inline -> veristc.compiler.desugar "6 st_program -> corest_program" "in-process" { description "veristc_main.ml:206"; tags "Conf-High" }
        veristc.compiler.desugar -> veristc.compiler.analysis "7 corest -> 分析结果" "in-process" { description "veristc_main.ml:209"; tags "Conf-High" }
        veristc.compiler.analysis -> veristc.compiler.gcCodegen "8 -c/-g: corest -> sasm_module" "in-process" { description "veristc_main.ml:221,347"; tags "Conf-High" }
        veristc.compiler.gcCodegen -> veristc.compiler.encoder "9 sasm_module -> list Z 字节" "in-process" { description "veristc_main.ml:221"; tags "Conf-High" }
        veristc.compiler.encoder -> veristc.compiler.crcHost "10 字节串 -> 附 CRC32" "in-process" { description "veristc_main.ml:171-181"; tags "Conf-High" }
        veristc.compiler.gcCodegen -> veristc.compiler.relocMeta "8b -g: 扁平元数据行" "in-process" { description "veristc_main.ml:307,313,319"; tags "Conf-High" }
        veristc.compiler.relocMeta -> veristc.compiler.svobjEmit "9b 排序/去重/字节布局" "in-process" { description "veristc_main.ml:285-296,332-365"; tags "Conf-High" }
        veristc.compiler.encoder -> veristc.compiler.svobjEmit "IMAGE 复用同一 encode_module 结果" "in-process" { description "veristc_main.ml:347"; tags "Conf-High" }
        veristc.compiler.cli -> veristc.compiler.svobjVerify "-x 独立校验路径" "in-process" { description "veristc_main.ml:371-441"; tags "Conf-High" }
        veristc.compiler.cli -> veristc.compiler.analyzeSt "-a 独立路径, 不经 frontend" "in-process" { description "模式分派 veristc_main.ml:488-500; 管线 :443-472"; tags "Conf-High", "DuplicatedLogic" }
        veristc.compiler.analyzeSt -> veristc.compiler.desugar "复用同一批 Coq 计算函数(第 9 步)" "in-process" { description "A.analyze (D.desugar_program ast) :464 —— 与 frontend:206-209 重复"; tags "Conf-High", "DuplicatedLogic" }
        veristc.compiler.dataTypes -> veristc.compiler.lexer "共享 AST/IR 类型定义" "提取模块" { description "veristc/spec/safest.v:343, safeasm.v:282"; tags "Conf-High" }
        veristc.compiler.proofLayer -> veristc.compiler.dataTypes "复用规范定义陈述定理" "Coq Require" { description "veristc/spec/compiler_correctness.v:19-22 反向引用 src 计算函数"; tags "Conf-High", "BuildTimeOnly" }
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

        component veristc.svm "v4-svm-components" "L3 组件: SVM 内部结构与被桩替代的 I/O 入口" {
            include *
            autoLayout TB
        }

        component veristc.libHs "v5-hotstandby-components" "L3 组件: 双机热备库内部结构与零调用点的周期封装" {
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
