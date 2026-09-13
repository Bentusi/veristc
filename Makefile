# Makefile — veristc 项目构建
# 编译器 (Coq) + 虚拟机 (C)

CC = gcc
CFLAGS = -Wall -Wextra -std=c11 -g -O0 -I.
AR = ar
ARFLAGS = rcs

# ================================================================
# VM 核心库
# ================================================================

VM_CORE_SRCS = vm/safeasm_interp.c vm/loader.c
VM_CORE_OBJS = $(VM_CORE_SRCS:.c=.o)
VM_CORE_LIB  = vm/libvm_core.a

# VM I/O 映射层
VM_IO_SRCS   = vm/io/io_mapping.c
VM_IO_OBJS   = $(VM_IO_SRCS:.c=.o)
VM_IO_LIB    = vm/io/libvm_io.a

# VM 热备模块
VM_HS_SRCS   = vm/hotstandby/snapshot.c \
               vm/hotstandby/sync.c \
               vm/hotstandby/state_machine.c \
               vm/hotstandby/download.c
VM_HS_OBJS   = $(VM_HS_SRCS:.c=.o)
VM_HS_LIB    = vm/hotstandby/libvm_hs.a

# VM 测试
VM_TEST_DIR  = tests/vm-tests
VM_TEST_SRCS = $(VM_TEST_DIR)/test_vm.c
VM_TEST_BIN  = $(VM_TEST_DIR)/test_vm
SMOKE_ST = tests/st-examples/core_assign.st
SMOKE_SASM = tests/veristc-tests/out/core_assign.sasm
NUCLEAR_FULL_ST = tests/st-examples/nuclear_rps_esfas_full.st
NUCLEAR_FULL_SASM = tests/veristc-tests/out/nuclear_rps_esfas_full.sasm
NUCLEAR_FULL_TEST_SRC = $(VM_TEST_DIR)/test_nuclear_protection_full_e2e.c
NUCLEAR_FULL_TEST_BIN = $(VM_TEST_DIR)/test_nuclear_protection_full_e2e
HS_SNAPSHOT_SRC = vm/hotstandby/snapshot.c

# 统一 SVM: 默认周期运行，-d 输出 dump
SVM_SRC = vm/svm.c
SVM_BIN = vm/svm

# RT-Thread 适配层 (需要 RT-Thread SDK)
RTTHREAD_DIR  = rtos/rtthread
RTTHREAD_SRCS = $(RTTHREAD_DIR)/vm_rtthread.c
RTTHREAD_OBJS = $(RTTHREAD_SRCS:.c=.o)
RTTHREAD_BIN  = $(RTTHREAD_DIR)/vm_rtthread.elf

.PHONY: all build-tests build-vm-test build-smoke build-nuclear-e2e
.PHONY: coq vm-lib vm-io vm-hs svm rtthread clean

all: coq vm-lib vm-hs vm-io svm

build-tests: build-vm-test build-smoke build-nuclear-e2e

# ================================================================
# VM 核心库编译
# ================================================================

vm-lib: $(VM_CORE_LIB)

$(VM_CORE_LIB): $(VM_CORE_OBJS)
	$(AR) $(ARFLAGS) $@ $^

vm/%.o: vm/%.c vm/vm.h
	$(CC) $(CFLAGS) -c -o $@ $<

# ================================================================
# VM I/O 映射层编译
# ================================================================

vm-io: vm-lib $(VM_IO_LIB)

$(VM_IO_LIB): $(VM_IO_OBJS)
	$(AR) $(ARFLAGS) $@ $^

vm/io/%.o: vm/io/%.c vm/io/io_mapping.h vm/vm.h rtos/abstract.h
	$(CC) $(CFLAGS) -c -o $@ $<

# ================================================================
# VM 热备模块编译
# ================================================================

vm-hs: vm-lib $(VM_HS_LIB)

$(VM_HS_LIB): $(VM_HS_OBJS)
	$(AR) $(ARFLAGS) $@ $^

vm/hotstandby/%.o: vm/hotstandby/%.c vm/hotstandby/hotstandby.h vm/vm.h
	$(CC) $(CFLAGS) -c -o $@ $<

# ================================================================
# VM 测试二进制构建
# ================================================================

build-vm-test: $(VM_TEST_BIN)

$(VM_TEST_BIN): $(VM_TEST_SRCS) $(VM_CORE_LIB) $(VM_IO_LIB) -lm
	$(CC) $(CFLAGS) -o $@ $< -Lvm -Lvm/io -lvm_io -lvm_core -lm

# 统一 VM 可执行程序: 默认周期运行; -d 为 dump 模式
svm: $(SVM_BIN)

$(SVM_BIN): $(SVM_SRC) vm/sasm_dump.c vm/sasm_dump.h \
		vm/loader.c vm/safeasm_interp.c vm/vm.h
	$(CC) $(CFLAGS) -o $@ vm/svm.c vm/sasm_dump.c \
		vm/loader.c vm/safeasm_interp.c -lm

E2E_OUT_DIR = tests/veristc-tests/out

$(SMOKE_SASM): veristc/extraction/veristc $(SMOKE_ST)
	@mkdir -p $(dir $@)
	./veristc/extraction/veristc -c $(SMOKE_ST) -o $@

build-smoke: $(SMOKE_SASM)

# 复杂核电模型构建: ST -> VeriSTC -> SASM -> VM 测试程序
build-nuclear-e2e: $(NUCLEAR_FULL_SASM) $(NUCLEAR_FULL_TEST_BIN)

$(NUCLEAR_FULL_SASM): veristc/extraction/veristc $(NUCLEAR_FULL_ST)
	@mkdir -p $(dir $@)
	./veristc/extraction/veristc -a $(NUCLEAR_FULL_ST)
	./veristc/extraction/veristc -c $(NUCLEAR_FULL_ST) -o $@

$(NUCLEAR_FULL_TEST_BIN): $(NUCLEAR_FULL_TEST_SRC) $(NUCLEAR_FULL_SASM) \
		$(HS_SNAPSHOT_SRC) \
		vm/hotstandby/hotstandby.h $(VM_CORE_LIB) $(VM_IO_LIB) -lm
	$(CC) $(CFLAGS) -o $@ $< -Lvm -Lvm/io -lvm_io -lvm_core -lm

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
SPEC_FILES = spec/safeasm.v spec/safest.v spec/st_semantics.v spec/asm_semantics.v

# Src files (depend on spec files)
SRC_FILES = src/encoder.v src/lexer.v src/parser.v src/inline.v src/desugar.v src/analysis.v src/typechecker.v src/codegen.v src/global_codegen.v

# Extraction files
EXTRACTION_DIR = extraction
EXTRACTION_FILE = extraction/extraction.v

# 编译后的 .vo 文件路径
SPEC_VO = $(addprefix $(VERISTC_DIR)/, $(SPEC_FILES:.v=.vo))
SRC_VO  = $(addprefix $(VERISTC_DIR)/, $(SRC_FILES:.v=.vo))
EXTR_VO = $(addprefix $(VERISTC_DIR)/, $(EXTRACTION_FILE:.v=.vo))
COMPILER_VO = $(VERISTC_DIR)/spec/compiler_correctness.vo
COMPILER_SRC = $(VERISTC_DIR)/spec/compiler_correctness.v

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
	@cd $(VERISTC_DIR) && $(ROQC) $(ROQCFLAGS) spec/compiler_correctness.v

$(VERISTC_DIR)/spec/safest.vo:        $(VERISTC_DIR)/spec/safeasm.vo
$(VERISTC_DIR)/spec/st_semantics.vo:  $(VERISTC_DIR)/spec/safest.vo
$(VERISTC_DIR)/spec/asm_semantics.vo: $(VERISTC_DIR)/spec/safeasm.vo
$(VERISTC_DIR)/src/encoder.vo:       $(VERISTC_DIR)/spec/safeasm.vo
$(VERISTC_DIR)/src/lexer.vo:         $(VERISTC_DIR)/spec/safest.vo
$(VERISTC_DIR)/src/parser.vo:        $(VERISTC_DIR)/spec/safest.vo $(VERISTC_DIR)/src/lexer.vo
$(VERISTC_DIR)/src/inline.vo:       $(VERISTC_DIR)/spec/safest.vo
$(VERISTC_DIR)/src/desugar.vo:       $(VERISTC_DIR)/spec/safest.vo $(VERISTC_DIR)/spec/st_semantics.vo
$(VERISTC_DIR)/src/analysis.vo:      $(VERISTC_DIR)/spec/safeasm.vo $(VERISTC_DIR)/spec/safest.vo $(VERISTC_DIR)/src/desugar.vo
$(VERISTC_DIR)/src/typechecker.vo:   $(VERISTC_DIR)/spec/safest.vo $(VERISTC_DIR)/spec/st_semantics.vo
$(VERISTC_DIR)/src/codegen.vo:       $(VERISTC_DIR)/spec/safest.vo $(VERISTC_DIR)/spec/safeasm.vo $(VERISTC_DIR)/spec/st_semantics.vo $(VERISTC_DIR)/src/desugar.vo $(VERISTC_DIR)/src/analysis.vo
$(VERISTC_DIR)/src/global_codegen.vo: $(VERISTC_DIR)/spec/safeasm.vo $(VERISTC_DIR)/src/desugar.vo $(VERISTC_DIR)/src/analysis.vo $(VERISTC_DIR)/src/codegen.vo

$(VERISTC_DIR)/extraction/extraction.vo: $(SPEC_VO) $(SRC_VO)

# ================================================================
# Coq → OCaml Extraction
# ================================================================

ROQC_EXTRACT = rocq extract

# 提取 OCaml 代码
extract: coq
	@echo "  [EXTRACT] Extracting OCaml code..."
	@cd $(VERISTC_DIR) && $(ROQC) -Q spec veristc_spec -Q src veristc_src $(EXTRACTION_FILE) 2>&1
	@cp $(VERISTC_DIR)/$(EXTRACTION_DIR)/PrimFloat_support_impl.ocaml $(VERISTC_DIR)/$(EXTRACTION_DIR)/PrimFloat.ml
	@cp $(VERISTC_DIR)/$(EXTRACTION_DIR)/PrimFloat_support_iface.ocaml $(VERISTC_DIR)/$(EXTRACTION_DIR)/PrimFloat.mli
	@echo "  [EXTRACT] Extraction complete"

# 编译提取后的 OCaml 可执行程序
VERISTC_BIN = veristc/extraction/veristc

$(VERISTC_BIN): extract
	@echo "  [OCAML] Compiling veristc executable..."
	@cd $(VERISTC_DIR)/$(EXTRACTION_DIR) && \
		ocamlfind ocamlopt -package str -linkpkg -c $$(ocamldep -sort *.mli 2>/dev/null) && \
		OCAML_FILES="$$(ocamldep -sort *.ml 2>/dev/null)" && \
		ocamlfind ocamlopt -o veristc -package str -linkpkg $$OCAML_FILES 2>&1 || \
		(ocamlopt -c $$(ocamldep -sort *.mli 2>/dev/null) && \
		 ocamlopt -o veristc str.cmxa $$OCAML_FILES) 2>&1
	@echo "  [OCAML] veristc executable built: $(VERISTC_DIR)/$(EXTRACTION_DIR)/veristc"

veristc: $(VERISTC_BIN)

# ================================================================
# 清理
# ================================================================

clean:
	rm -f $(VM_TEST_BIN) $(NUCLEAR_FULL_TEST_BIN)
	rm -f $(SVM_BIN) $(SMOKE_SASM) $(NUCLEAR_FULL_SASM)
	rm -f veristc/extraction/veristc
	rm -f output.sasm output.txt .lia.cache .test_fix.aux
	rm -rf tests/veristc-tests/out
	rm -f $(VM_CORE_LIB) $(VM_CORE_OBJS)
	rm -f $(VM_IO_LIB) $(VM_IO_OBJS)
	rm -f $(VM_HS_LIB) $(VM_HS_OBJS)
	rm -f $(RTTHREAD_OBJS) $(RTTHREAD_BIN)
	find . -type f ! -path './.git/*' ! -path './.venv/*' \( \
			-name '*.vo' -o -name '*.vos' -o -name '*.vok' -o \
			-name '*.vio' -o -name '*.glob' -o -name '*.aux' -o \
			-name '*.cache' -o -name '*.cmi' -o -name '*.cmx' -o \
			-name '*.cmo' -o -name '*.cma' -o -name '*.cmxa' -o \
			-name '*.cmxs' -o -name '*.o' -o -name '*.obj' -o \
			-name '*.a' -o -name '*.lib' -o -name '*.so' -o \
			-name '*.dll' -o -name '*.dylib' -o -name '*.d' -o \
			-name '*.dep' -o -name '*.pyc' -o -name '*.pyo' -o \
			-name '*.annot' -o -name '*.merlin' \) -delete
	find veristc/extraction vstac/extraction -type f \
		\( -name '*.ml' -o -name '*.mli' \) \
		! -name 'veristc_main.ml' -delete 2>/dev/null || true
	find . -type d ! -path './.git*' ! -path './.venv*' \( \
		-name '__pycache__' -o -name '.coq-native' -o \
		-name '_build' \) -exec rm -rf {} + 2>/dev/null || true
	cd veristc && dune clean 2>/dev/null || true
	cd vstac && dune clean 2>/dev/null || true
