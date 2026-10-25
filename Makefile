# Makefile — veristc 项目构建
# 编译器 (Coq) + 虚拟机 (C)

CC = gcc
CFLAGS = -Wall -Wextra -std=c11 -g -O0 -I.
AR = ar
ARFLAGS = rcs

# ── 构建输出目录 ──
BUILD_DIR = build
BUILD_BIN = $(BUILD_DIR)/bin
BUILD_LIB = $(BUILD_DIR)/lib
BUILD_SASM = $(BUILD_DIR)/sasm

# ── Sanitizer 变体 (P2: ASan/UBSan) ──
# 用法: make sanitize-test   (构建 ASan/UBSan 测试二进制)
#        make run-sanitize   (构建并运行 sanitizer 测试)
SANITIZE_FLAGS = -fsanitize=address,undefined -fno-omit-frame-pointer -O1
SANITIZE_LDFLAGS = -fsanitize=address,undefined

# ================================================================
# VM 核心库
# ================================================================

VM_CORE_SRCS = vm/safeasm_interp.c vm/loader.c
VM_CORE_OBJS = $(VM_CORE_SRCS:.c=.o)
VM_CORE_LIB  = $(BUILD_LIB)/libvm_core.a

# VM I/O 映射层
VM_IO_SRCS   = vm/io/io_mapping.c
VM_IO_OBJS   = $(VM_IO_SRCS:.c=.o)
VM_IO_LIB    = $(BUILD_LIB)/libvm_io.a

# VM 热备模块
VM_HS_SRCS   = vm/hotstandby/snapshot.c \
               vm/hotstandby/sync.c \
               vm/hotstandby/state_machine.c \
               vm/hotstandby/download.c
VM_HS_OBJS   = $(VM_HS_SRCS:.c=.o)
VM_HS_LIB    = $(BUILD_LIB)/libvm_hs.a

# VM 测试
VM_TEST_DIR  = tests/vm-tests
VM_TEST_SRCS = $(VM_TEST_DIR)/test_vm.c
VM_TEST_BIN  = $(BUILD_BIN)/test_vm
IO_TEST_SRCS = $(VM_TEST_DIR)/test_io_mapping.c
IO_TEST_BIN  = $(BUILD_BIN)/test_io_mapping
HS_TEST_SRCS = $(VM_TEST_DIR)/test_hotstandby.c
HS_TEST_BIN  = $(BUILD_BIN)/test_hotstandby
SMOKE_ST = tests/st-examples/core_assign.st
SMOKE_SASM = $(BUILD_SASM)/core_assign.sasm
FUNCTION_ST = tests/st-examples/function_control_flow.st
FUNCTION_SASM = $(BUILD_SASM)/function_control_flow.sasm
FUNCTION_NEGATIVE_STS = tests/st-examples/function_impure.st \
                        tests/st-examples/function_recursive.st
NUCLEAR_FULL_ST = tests/st-examples/nuclear_rps_esfas_full.st
NUCLEAR_FULL_SASM = $(BUILD_SASM)/nuclear_rps_esfas_full.sasm
NUCLEAR_FULL_TEST_SRC = $(VM_TEST_DIR)/test_nuclear_protection_full_e2e.c
NUCLEAR_FULL_TEST_BIN = $(BUILD_BIN)/test_nuclear_protection_full_e2e
CHANNEL_ST = tests/st-examples/nuclear_rps_channel.st
CHANNEL_SASM = $(BUILD_SASM)/nuclear_rps_channel.sasm
HS_SNAPSHOT_SRC = vm/hotstandby/snapshot.c

# 统一 SVM: 默认周期运行，-d 输出 dump，-i 显示信息
SVM_SRC = vm/svm.c
SVM_BIN = $(BUILD_BIN)/svm

# RT-Thread 适配层 (需要 RT-Thread SDK)
RTTHREAD_DIR  = rtos/rtthread
RTTHREAD_SRCS = $(RTTHREAD_DIR)/vm_rtthread.c
RTTHREAD_OBJS = $(RTTHREAD_SRCS:.c=.o)
RTTHREAD_BIN  = $(BUILD_BIN)/vm_rtthread.elf

.PHONY: all build-tests build-vm-test build-io-test build-hs-test build-smoke build-nuclear-e2e build-channel-e2e
.PHONY: coq vm-lib vm-io vm-hs svm veristc rtthread clean misra-check dune-build
.PHONY: sanitize-test run-sanitize build-fuzzer

all: coq veristc vm-lib vm-hs vm-io svm

build-tests: build-vm-test build-io-test build-hs-test build-smoke build-function-tests build-nuclear-e2e

# ================================================================
# VM 核心库编译
# ================================================================

vm-lib: $(VM_CORE_LIB)

$(VM_CORE_LIB): $(VM_CORE_OBJS)
	@mkdir -p $(BUILD_LIB)
	$(AR) $(ARFLAGS) $@ $^

vm/%.o: vm/%.c vm/vm.h
	$(CC) $(CFLAGS) -c -o $@ $<

# ================================================================
# VM I/O 映射层编译
# ================================================================

vm-io: vm-lib $(VM_IO_LIB)

$(VM_IO_LIB): $(VM_IO_OBJS)
	@mkdir -p $(BUILD_LIB)
	$(AR) $(ARFLAGS) $@ $^

vm/io/%.o: vm/io/%.c vm/io/io_mapping.h vm/vm.h rtos/abstract.h
	$(CC) $(CFLAGS) -c -o $@ $<

# ================================================================
# VM 热备模块编译
# ================================================================

vm-hs: vm-lib $(VM_HS_LIB)

$(VM_HS_LIB): $(VM_HS_OBJS)
	@mkdir -p $(BUILD_LIB)
	$(AR) $(ARFLAGS) $@ $^

vm/hotstandby/%.o: vm/hotstandby/%.c vm/hotstandby/hotstandby.h vm/vm.h
	$(CC) $(CFLAGS) -c -o $@ $<

# ================================================================
# VM 测试二进制构建
# ================================================================

build-vm-test: $(VM_TEST_BIN)

$(VM_TEST_BIN): $(VM_TEST_SRCS) $(VM_CORE_SRCS) vm/vm.h $(VM_CORE_LIB) $(VM_IO_LIB) -lm
	@mkdir -p $(BUILD_BIN)
	$(CC) $(CFLAGS) -o $@ $< -L$(BUILD_LIB) -Lvm/io -lvm_io -lvm_core -lm

build-io-test: $(IO_TEST_BIN)

$(IO_TEST_BIN): $(IO_TEST_SRCS) vm/io/io_mapping.h vm/vm.h $(VM_CORE_LIB) $(VM_IO_LIB)
	@mkdir -p $(BUILD_BIN)
	$(CC) $(CFLAGS) -o $@ $< -L$(BUILD_LIB) -Lvm/io -lvm_io -lvm_core -lm

build-hs-test: $(HS_TEST_BIN)

$(HS_TEST_BIN): $(HS_TEST_SRCS) $(VM_CORE_SRCS) vm/vm.h vm/hotstandby/hotstandby.h
	@mkdir -p $(BUILD_BIN)
	$(CC) $(CFLAGS) -o $@ $< -lm

# 统一 VM 可执行程序: 默认周期运行; -d 为 dump 模式; -i 为 info 模式
svm: $(SVM_BIN)

$(SVM_BIN): $(SVM_SRC) vm/sasm_dump.c vm/sasm_dump.h \
		vm/sasm_info.c vm/sasm_info.h \
		vm/loader.c vm/safeasm_interp.c vm/vm.h
	@mkdir -p $(BUILD_BIN)
	$(CC) $(CFLAGS) -o $@ vm/svm.c vm/sasm_dump.c vm/sasm_info.c \
		vm/loader.c vm/safeasm_interp.c -lm

E2E_OUT_DIR = $(BUILD_SASM)

$(SMOKE_SASM): $(VERISTC_BIN) $(SMOKE_ST)
	@mkdir -p $(BUILD_SASM)
	$(VERISTC_BIN) -c $(SMOKE_ST) -o $@

build-smoke: $(SMOKE_SASM)

$(FUNCTION_SASM): $(VERISTC_BIN) $(FUNCTION_ST)
	@mkdir -p $(BUILD_SASM)
	$(VERISTC_BIN) -c $(FUNCTION_ST) -o $@

build-function-tests: $(FUNCTION_SASM)

# 复杂核电模型构建: ST -> VeriSTC -> SASM -> VM 测试程序
build-nuclear-e2e: $(NUCLEAR_FULL_SASM) $(NUCLEAR_FULL_TEST_BIN)

$(NUCLEAR_FULL_SASM): $(VERISTC_BIN) $(NUCLEAR_FULL_ST)
	@mkdir -p $(BUILD_SASM)
	$(VERISTC_BIN) -a $(NUCLEAR_FULL_ST)
	$(VERISTC_BIN) -c $(NUCLEAR_FULL_ST) -o $@

# 单组 RPS 4 通道保护 + ESFAS 顺序器（状态密集中型用例，golden 由
# run_channel_e2e.sh 比对；SASM 构建在此收敛）
build-channel-e2e: $(CHANNEL_SASM)

$(CHANNEL_SASM): $(VERISTC_BIN) $(CHANNEL_ST)
	@mkdir -p $(BUILD_SASM)
	$(VERISTC_BIN) -c $(CHANNEL_ST) -o $@

$(NUCLEAR_FULL_TEST_BIN): $(NUCLEAR_FULL_TEST_SRC) $(NUCLEAR_FULL_SASM) \
		$(HS_SNAPSHOT_SRC) \
		vm/hotstandby/hotstandby.h $(VM_CORE_LIB) $(VM_IO_LIB) -lm
	@mkdir -p $(BUILD_BIN)
	$(CC) $(CFLAGS) -o $@ $< -L$(BUILD_LIB) -Lvm/io -lvm_io -lvm_core -lm

# ================================================================
# RT-Thread 适配层 (需要 RT-Thread SDK)
# ================================================================
# 在目标硬件上编译时需指定:
#   make rtthread RTTHREAD_DIR=/path/to/rt-thread RTTHREAD_INC=-I/path/to/rt-thread/include
#
# 本地仅做语法检查，不链接 RT-Thread 库

rtthread: $(VM_CORE_LIB) $(VM_IO_LIB)
	@echo "  [RTTHREAD] Compiling RT-Thread port (requires RT-Thread SDK)..."
	@if [ -n "$(RTTHREAD_SDK)" ]; then \
		$(CC) $(CFLAGS) $(RTTHREAD_INC) -c -o $(RTTHREAD_DIR)/vm_rtthread.o \
			$(RTTHREAD_DIR)/vm_rtthread.c && \
		echo "  [RTTHREAD] Compilation OK"; \
	else \
		echo "  [RTTHREAD] Skip (set RTTHREAD_SDK to the RT-Thread root)"; \
	fi

# ================================================================
# Coq/Rocq 编译器
# ================================================================

# 自动检测 Rocq/Coq 编译器路径；仍可通过 make COQC=/path/to/coqc 覆盖。
COQC ?= $(shell command -v coqc 2>/dev/null || command -v rocq 2>/dev/null || echo coqc)

VERISTC_DIR = veristc
ROQC = $(COQC)
ROQCFLAGS = -Q spec veristc_spec -Q src veristc_src

# Spec files (compile in order due to dependencies)
SPEC_FILES = spec/safeasm.v spec/safest.v spec/st_semantics.v spec/function_semantics.v spec/asm_semantics.v

# Src files (depend on spec files)
SRC_FILES = src/encoder.v src/lexer.v src/parser.v src/inline.v src/desugar.v src/analysis.v src/typechecker.v src/function_check.v src/codegen.v src/global_codegen.v

# Extraction files
EXTRACTION_DIR = extraction
EXTRACTION_FILE = extraction/extraction.v

# 编译后的 .vo 文件路径
SPEC_VO = $(addprefix $(VERISTC_DIR)/, $(SPEC_FILES:.v=.vo))
SRC_VO  = $(addprefix $(VERISTC_DIR)/, $(SRC_FILES:.v=.vo))
EXTR_VO = $(addprefix $(VERISTC_DIR)/, $(EXTRACTION_FILE:.v=.vo))
COMPILER_VO = $(VERISTC_DIR)/src/compiler_correctness.vo
COMPILER_SRC = $(VERISTC_DIR)/src/compiler_correctness.v

# 顶层目标：构建所有 .vo 文件
coq: $(SPEC_VO) $(SRC_VO) $(COMPILER_VO) $(EXTR_VO)

# ── 泛型模式规则：.v → .vo ──
$(VERISTC_DIR)/spec/%.vo: $(VERISTC_DIR)/spec/%.v
	@echo "  [ROQC] $<"
	@cd $(VERISTC_DIR) && $(ROQC) $(ROQCFLAGS) spec/$*.v

$(VERISTC_DIR)/src/%.vo: $(VERISTC_DIR)/src/%.v
	@echo "  [ROQC] $<"
	@cd $(VERISTC_DIR) && $(ROQC) $(ROQCFLAGS) src/$*.v

$(VERISTC_DIR)/extraction/%.vo: $(VERISTC_DIR)/extraction/%.v
	@echo "  [ROQC] $<"
	@cd $(VERISTC_DIR) && $(ROQC) $(ROQCFLAGS) extraction/$*.v

# ── 依赖关系 ──
$(COMPILER_VO): $(COMPILER_SRC) $(SPEC_VO) $(SRC_VO)
	@echo "  [ROQC] $<"
	@cd $(VERISTC_DIR) && $(ROQC) $(ROQCFLAGS) src/compiler_correctness.v

$(VERISTC_DIR)/spec/safest.vo:        $(VERISTC_DIR)/spec/safeasm.vo
$(VERISTC_DIR)/spec/st_semantics.vo:  $(VERISTC_DIR)/spec/safest.vo
$(VERISTC_DIR)/spec/function_semantics.vo: $(VERISTC_DIR)/spec/safest.vo $(VERISTC_DIR)/spec/st_semantics.vo
$(VERISTC_DIR)/spec/asm_semantics.vo: $(VERISTC_DIR)/spec/safeasm.vo
$(VERISTC_DIR)/src/encoder.vo:       $(VERISTC_DIR)/spec/safeasm.vo
$(VERISTC_DIR)/src/lexer.vo:         $(VERISTC_DIR)/spec/safest.vo
$(VERISTC_DIR)/src/parser.vo:        $(VERISTC_DIR)/spec/safest.vo $(VERISTC_DIR)/src/lexer.vo
$(VERISTC_DIR)/src/inline.vo:       $(VERISTC_DIR)/spec/safest.vo
$(VERISTC_DIR)/src/desugar.vo:       $(VERISTC_DIR)/spec/safest.vo $(VERISTC_DIR)/spec/st_semantics.vo
$(VERISTC_DIR)/src/analysis.vo:      $(VERISTC_DIR)/spec/safeasm.vo $(VERISTC_DIR)/spec/safest.vo $(VERISTC_DIR)/src/desugar.vo
$(VERISTC_DIR)/src/typechecker.vo:   $(VERISTC_DIR)/spec/safest.vo $(VERISTC_DIR)/spec/st_semantics.vo
$(VERISTC_DIR)/src/function_check.vo: $(VERISTC_DIR)/spec/safest.vo $(VERISTC_DIR)/spec/st_semantics.vo $(VERISTC_DIR)/src/typechecker.vo
$(VERISTC_DIR)/src/codegen.vo:       $(VERISTC_DIR)/spec/safest.vo $(VERISTC_DIR)/spec/safeasm.vo $(VERISTC_DIR)/spec/st_semantics.vo $(VERISTC_DIR)/src/desugar.vo $(VERISTC_DIR)/src/analysis.vo
$(VERISTC_DIR)/src/global_codegen.vo: $(VERISTC_DIR)/spec/safeasm.vo $(VERISTC_DIR)/src/desugar.vo $(VERISTC_DIR)/src/analysis.vo $(VERISTC_DIR)/src/codegen.vo

$(VERISTC_DIR)/extraction/extraction.vo: $(SPEC_VO) $(SRC_VO)

# ================================================================
# Coq → OCaml Extraction
# ================================================================

ROQC_EXTRACT = rocq extract

# 提取 OCaml 代码（使用 stamp 文件避免重复提取）
EXTRACT_STAMP = $(VERISTC_DIR)/$(EXTRACTION_DIR)/.extract_stamp

$(EXTRACT_STAMP): $(EXTR_VO)
	@echo "  [EXTRACT] Extracting OCaml code..."
	@cd $(VERISTC_DIR) && $(ROQC) -Q spec veristc_spec -Q src veristc_src $(EXTRACTION_FILE) 2>&1
	@cp $(VERISTC_DIR)/$(EXTRACTION_DIR)/PrimFloat_support_impl.ocaml $(VERISTC_DIR)/$(EXTRACTION_DIR)/PrimFloat.ml
	@cp $(VERISTC_DIR)/$(EXTRACTION_DIR)/PrimFloat_support_iface.ocaml $(VERISTC_DIR)/$(EXTRACTION_DIR)/PrimFloat.mli
	@touch $@
	@echo "  [EXTRACT] Extraction complete"

# 用户可手动调用的提取入口
extract: $(EXTRACT_STAMP)

# 编译提取后的 OCaml 可执行程序
VERISTC_SRC_BIN = veristc/extraction/veristc
VERISTC_BIN = $(BUILD_BIN)/veristc

# veristc_main.ml 为手写源（不参与提取），须显式列为依赖，否则改动不重链接
$(VERISTC_SRC_BIN): $(EXTRACT_STAMP) $(VERISTC_DIR)/$(EXTRACTION_DIR)/veristc_main.ml
	@echo "  [OCAML] Compiling veristc executable..."
	@cd $(VERISTC_DIR)/$(EXTRACTION_DIR) && \
		ocamlfind ocamlopt -package str -linkpkg -c $$(ocamldep -sort *.mli 2>/dev/null) && \
		OCAML_FILES="$$(ocamldep -sort *.ml 2>/dev/null)" && \
		ocamlfind ocamlopt -o veristc -package str -linkpkg $$OCAML_FILES 2>&1 || \
		(ocamlopt -c $$(ocamldep -sort *.mli 2>/dev/null) && \
		 ocamlopt -o veristc str.cmxa $$OCAML_FILES) 2>&1
	@echo "  [OCAML] veristc executable built: $(VERISTC_SRC_BIN)"

$(VERISTC_BIN): $(VERISTC_SRC_BIN)
	@mkdir -p $(BUILD_BIN)
	cp $(VERISTC_SRC_BIN) $(VERISTC_BIN)

veristc: $(VERISTC_BIN)

# ================================================================
# Dune 构建目标 (P1: 迁移 Coq 构建到 dune)
# ================================================================

dune-build:
	@echo "  [DUNE] Building Coq libraries..."
	cd veristc && dune build
	@echo "  [DUNE] Coq libraries built successfully"

dune-extract: dune-build
	@echo "  [DUNE] Extracting OCaml code..."
	cd veristc && dune build @extraction
	@echo "  [DUNE] Extraction complete"

dune-veristc: dune-extract
	@echo "  [DUNE] Building veristc executable..."
	cd veristc && dune build extraction/veristc.exe
	@mkdir -p $(BUILD_BIN)
	cp veristc/_build/default/extraction/veristc.exe $(VERISTC_BIN)
	@echo "  [DUNE] veristc executable built: $(VERISTC_BIN)"

# ================================================================
# Sanitizer 变体 (P2: ASan/UBSan 内存安全检测)
# ================================================================

SANITIZE_SVM_BIN = $(BUILD_BIN)/svm-asan
SANITIZE_TEST_VM_BIN = $(BUILD_BIN)/test_vm-asan
SANITIZE_FUZZER_BIN = $(BUILD_BIN)/sasm_fuzzer

# 使用 sanitizer 标志编译 SVM
sanitize-svm: vm/svm.c vm/sasm_dump.c vm/sasm_info.c vm/loader.c vm/safeasm_interp.c vm/vm.h
	@echo "  [SANITIZE] Building SVM with ASan/UBSan..."
	@mkdir -p $(BUILD_BIN)
	$(CC) $(CFLAGS) $(SANITIZE_FLAGS) -o $(SANITIZE_SVM_BIN) \
		vm/svm.c vm/sasm_dump.c vm/sasm_info.c vm/loader.c vm/safeasm_interp.c \
		$(SANITIZE_LDFLAGS) -lm
	@echo "  [SANITIZE] SVM (ASan/UBSan) built: $(SANITIZE_SVM_BIN)"

# 使用 sanitizer 标志编译 VM 测试
sanitize-test: $(SANITIZE_TEST_VM_BIN)

$(SANITIZE_TEST_VM_BIN): $(VM_TEST_DIR)/test_vm.c $(VM_CORE_SRCS) vm/vm.h \
		$(VM_CORE_LIB) $(VM_IO_LIB)
	@echo "  [SANITIZE] Building test_vm with ASan/UBSan..."
	@mkdir -p $(BUILD_BIN)
	$(CC) $(CFLAGS) $(SANITIZE_FLAGS) -o $@ $< \
		-L$(BUILD_LIB) -Lvm/io -lvm_io -lvm_core $(SANITIZE_LDFLAGS) -lm
	@echo "  [SANITIZE] test_vm (ASan/UBSan) built: $@"

# 构建并运行 sanitizer 测试（需要先正常构建 .sasm 测试文件）
run-sanitize: sanitize-svm sanitize-test build-smoke build-function-tests
	@echo "  [SANITIZE] Running test_vm under ASan/UBSan..."
	@$(SANITIZE_TEST_VM_BIN)
	@echo "  [SANITIZE] Running SVM under ASan/UBSan..."
	@$(SANITIZE_SVM_BIN) -n 1 -p 0 $(BUILD_SASM)/core_assign.sasm 42 > /dev/null
	@$(SANITIZE_SVM_BIN) -n 6 -p 0 $(BUILD_SASM)/function_control_flow.sasm > /dev/null
	@echo "  [SANITIZE] All sanitizer checks passed"

# ================================================================
# Fuzz 测试 (P2: .sasm 加载器模糊测试)
# ================================================================

FUZZ_DIR = tests/fuzz
FUZZ_SRC = $(FUZZ_DIR)/sasm_fuzzer.c

build-fuzzer: $(SANITIZE_FUZZER_BIN)

$(SANITIZE_FUZZER_BIN): $(FUZZ_SRC) vm/loader.c vm/vm.h vm/crc32_table.inc
	@echo "  [FUZZ] Building .sasm fuzzer..."
	@mkdir -p $(FUZZ_DIR)/corpus
	@mkdir -p $(BUILD_BIN)
	$(CC) $(CFLAGS) $(SANITIZE_FLAGS) -I. \
		-o $@ $< $(SANITIZE_LDFLAGS) -lm
	@echo "  [FUZZ] Fuzzer built: $@"

# ================================================================
# MISRA-C 检查 (P1: 集成静态分析工具)
# ================================================================

# 检查实现已拆分到独立脚本 run_misra_check.sh：逐文件运行 cppcheck MISRA addon，
# 输出与其它 run_*.sh 一致的用例式结果，便于统计违规与定位修改。
# 保留 make misra-check 作为薄封装，兼容既有 CI 调用（可直接运行脚本并传入文件参数）。

misra-check:
	@./run_misra_check.sh

# ================================================================
# 清理
# ================================================================

clean:
	@echo "  [CLEAN] Removing build directory..."
	rm -rf $(BUILD_DIR)
	@echo "  [CLEAN] Removing object files..."
	rm -f $(VM_CORE_OBJS) $(VM_IO_OBJS) $(VM_HS_OBJS) $(RTTHREAD_OBJS)
	@echo "  [CLEAN] Removing temporary files..."
	rm -f output.sasm output.txt .lia.cache .test_fix.aux
	rm -f .misra_report.txt
	rm -rf .misra_reports
	@echo "  [CLEAN] Removing Coq build artifacts..."
	find . -type f ! -path './.git/*' ! -path './.venv/*' \( \
			-name '*.vo' -o -name '*.vos' -o -name '*.vok' -o \
			-name '*.vio' -o -name '*.glob' -o -name '*.aux' -o \
			-name '*.cache' -o -name '*.cmi' -o -name '*.cmx' -o \
			-name '*.cmo' -o -name '*.cma' -o -name '*.cmxa' -o \
			-name '*.cmxs' -o -name '*.d' -o -name '*.dep' -o \
			-name '*.annot' -o -name '*.merlin' \) -delete 2>/dev/null || true
	find veristc/extraction -type f \
		\( -name '*.ml' -o -name '*.mli' \) \
		! -name 'veristc_main.ml' -delete 2>/dev/null || true
	find . -type d ! -path './.git*' ! -path './.venv*' \( \
		-name '__pycache__' -o -name '.coq-native' -o \
		-name '_build' \) -exec rm -rf {} + 2>/dev/null || true
	cd veristc && dune clean 2>/dev/null || true
	@echo "  [CLEAN] Clean complete"
