# Makefile — vstac 项目构建
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
VM_TEST_SRCS = $(VM_TEST_DIR)/test_minimal.c
VM_TEST_BIN  = $(VM_TEST_DIR)/test_minimal

# sasm_dump 工具
SASM_DUMP_SRC = vm/sasm_dump.c
SASM_DUMP_BIN = vm/sasm_dump

# RT-Thread 适配层 (需要 RT-Thread SDK)
RTTHREAD_DIR  = rtos/rtthread
RTTHREAD_SRCS = $(RTTHREAD_DIR)/vm_rtthread.c
RTTHREAD_OBJS = $(RTTHREAD_SRCS:.c=.o)
RTTHREAD_BIN  = $(RTTHREAD_DIR)/vm_rtthread.elf

.PHONY: all coq vm-lib vm-io vm-hs vm-test sasm-dump rtthread clean

all: coq vm-lib vm-hs vm-test sasm-dump

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
# VM 测试 (C)
# ================================================================

vm-test: $(VM_CORE_LIB) $(VM_IO_LIB) $(VM_TEST_BIN)
	$(VM_TEST_BIN)

$(VM_TEST_BIN): $(VM_TEST_SRCS) $(VM_CORE_LIB) $(VM_IO_LIB) -lm
	$(CC) $(CFLAGS) -o $@ $< -Lvm -Lvm/io -lvm_io -lvm_core -lm

# ================================================================
# sasm_dump 工具
# ================================================================

sasm-dump: $(VM_CORE_LIB) $(SASM_DUMP_BIN)

$(SASM_DUMP_BIN): $(SASM_DUMP_SRC) $(VM_CORE_LIB) -lm
	$(CC) $(CFLAGS) -o $@ $< -Lvm -lvm_core -lm

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

VSTAC_DIR = vstac
ROQC = rocq c
ROQCFLAGS = -Q spec vstac_spec -Q src vstac_src

# Spec files (compile in order due to dependencies)
SPEC_FILES = spec/safeasm.v spec/safest.v spec/compiler_correctness.v

# Src files (depend on spec files)
SRC_FILES = src/encoder.v src/lexer.v src/parser.v src/desugar.v src/analysis.v src/typechecker.v src/codegen.v

# Extraction files
EXTRACTION_DIR = extraction
EXTRACTION_FILE = extraction/extraction.v

coq:
	@echo "  [ROQC] spec files..."
	cd $(VSTAC_DIR) && for f in $(SPEC_FILES); do \
		echo "    $$f"; $(ROQC) $(ROQCFLAGS) $$f || exit 1; \
	done
	@echo "  [ROQC] src files..."
	cd $(VSTAC_DIR) && for f in $(SRC_FILES); do \
		echo "    $$f"; $(ROQC) $(ROQCFLAGS) $$f || exit 1; \
	done
	@echo "  [ROQC] extraction..."
	cd $(VSTAC_DIR) && $(ROQC) $(ROQCFLAGS) $(EXTRACTION_FILE) || exit 1
	@echo "  [ROQC] All files compiled successfully"

# ================================================================
# Coq → OCaml Extraction
# ================================================================

ROQC_EXTRACT = rocq extract

# 提取 OCaml 代码
extract: coq
	@echo "  [EXTRACT] Extracting OCaml code..."
	cd $(VSTAC_DIR) && $(ROQC) -Q spec vstac_spec -Q src vstac_src $(EXTRACTION_FILE) 2>&1
	@echo "  [EXTRACT] Extraction complete"

# 编译提取后的 OCaml 可执行程序
vstac: extract
	@echo "  [OCAML] Compiling vstac executable..."
	cd $(VSTAC_DIR)/$(EXTRACTION_DIR) && \
		ocamlfind ocamlopt -o vstac -package str -linkpkg \
		extraction.ml vstac_main.ml 2>&1 || \
		ocamlopt -o vstac str.cmxa extraction.ml vstac_main.ml 2>&1
	@echo "  [OCAML] vstac executable built: $(VSTAC_DIR)/$(EXTRACTION_DIR)/vstac"

# ================================================================
# 清理
# ================================================================

clean:
	rm -f $(VM_TEST_BIN)
	rm -f $(SASM_DUMP_BIN)
	rm -f $(VM_CORE_LIB) $(VM_CORE_OBJS)
	rm -f $(VM_IO_LIB) $(VM_IO_OBJS)
	rm -f $(VM_HS_LIB) $(VM_HS_OBJS)
	rm -f $(RTTHREAD_OBJS) $(RTTHREAD_BIN)
	find . -name '*.o' -delete

	rm -f vstac/spec/*.vo vstac/spec/*.glob vstac/src/*.vo vstac/src/*.glob vstac/*.vo vstac/*.glob
	rm -f vstac/extraction/extraction.ml vstac/extraction/extraction.cm*
	rm -f vstac/extraction/vstac vstac/extraction/vstac_main.cm*
	cd vstac && dune clean 2>/dev/null || true