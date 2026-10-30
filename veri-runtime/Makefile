# veri-runtime — SafeASM 虚拟机运行站组件（C11 / MISRA-C 子集）
#
# 可独立构建：make -C veri-runtime [all|svm|build-vm-test|misra-check|build-fuzzer]
# 产物：build/lib/libvm_{core,io,hs}.a 与 build/bin/{svm,test_*,sasm_fuzzer}
# 依赖规则：本组件不依赖 veri-stc 源码，只消费其产物（.sasm 由根 Makefile 生成）

include ../Makefile.common

CORE_SRCS = core/safeasm_interp.c core/loader.c
CORE_OBJS = $(CORE_SRCS:.c=.o)
CORE_LIB  = $(BUILD_LIB)/libvm_core.a

IO_SRCS   = io/io_mapping.c
IO_OBJS   = $(IO_SRCS:.c=.o)
IO_LIB    = $(BUILD_LIB)/libvm_io.a

HS_SRCS   = hotstandby/snapshot.c hotstandby/sync.c \
            hotstandby/state_machine.c hotstandby/download.c \
            hotstandby/hmac_sha256.c hotstandby/download_wire.c
HS_OBJS   = $(HS_SRCS:.c=.o)
HS_LIB    = $(BUILD_LIB)/libvm_hs.a

SVM_SRC     = core/svm.c
SVM_BIN     = $(BUILD_BIN)/svm
HS_SNAPSHOT_SRC = hotstandby/snapshot.c

SIM_DIR      = sim
SIM_SRCS     = $(SIM_DIR)/plant.c $(SIM_DIR)/sim_io.c $(SIM_DIR)/watch.c \
               $(SIM_DIR)/force.c
SIM_MAIN_SRC = $(SIM_DIR)/sim_main.c
SIM_BIN      = $(BUILD_BIN)/sim

AGENT_DIR      = agent
AGENT_SRC      = $(AGENT_DIR)/agent_main.c
AGENT_BIN      = $(BUILD_BIN)/veristc-agent

TEST_DIR       = tests/vm-tests
VM_TEST_BIN    = $(BUILD_BIN)/test_vm
IO_TEST_BIN    = $(BUILD_BIN)/test_io_mapping
HS_TEST_BIN    = $(BUILD_BIN)/test_hotstandby
DLWIRE_TEST_BIN   = $(BUILD_BIN)/test_download_wire
DLSWITCH_TEST_BIN = $(BUILD_BIN)/test_download_switch

FUZZ_DIR         = tests/fuzz
FUZZ_SRC         = $(FUZZ_DIR)/sasm_fuzzer.c
SANITIZE_SVM_BIN      = $(BUILD_BIN)/svm-asan
SANITIZE_TEST_VM_BIN  = $(BUILD_BIN)/test_vm-asan
SANITIZE_FUZZER_BIN   = $(BUILD_BIN)/sasm_fuzzer
SANITIZE_DLWIRE_BIN   = $(BUILD_BIN)/test_download_wire-asan
SANITIZE_DLSWITCH_BIN = $(BUILD_BIN)/test_download_switch-asan

# RT-Thread 适配层（需要外部 SDK；本地仅做语法检查）
RTTHREAD_DIR  = rtos/rtthread
RTTHREAD_OBJS = $(RTTHREAD_DIR)/vm_rtthread.o

.PHONY: all vm-lib vm-io vm-hs svm build-vm-test build-io-test build-hs-test \
        build-dlwire-test build-dlswitch-test agent \
        sanitize-svm sanitize-test sanitize-dl run-sanitize build-fuzzer \
        misra-check rtthread \
        build-sim clean-component

all: vm-lib vm-io vm-hs svm build-sim agent

# ================================================================
# VM 核心库
# ================================================================

vm-lib: $(CORE_LIB)

$(CORE_LIB): $(CORE_OBJS)
	@mkdir -p $(BUILD_LIB)
	$(AR) $(ARFLAGS) $@ $^

core/%.o: core/%.c core/vm.h
	$(CC) $(CFLAGS) -c -o $@ $<

# ================================================================
# I/O 映射层
# ================================================================

vm-io: vm-lib $(IO_LIB)

$(IO_LIB): $(IO_OBJS)
	@mkdir -p $(BUILD_LIB)
	$(AR) $(ARFLAGS) $@ $^

io/%.o: io/%.c io/io_mapping.h core/vm.h rtos/abstract.h
	$(CC) $(CFLAGS) -c -o $@ $<

# ================================================================
# 双机热备模块
# ================================================================

vm-hs: vm-lib $(HS_LIB)

$(HS_LIB): $(HS_OBJS)
	@mkdir -p $(BUILD_LIB)
	$(AR) $(ARFLAGS) $@ $^

hotstandby/%.o: hotstandby/%.c hotstandby/hotstandby.h core/vm.h
	$(CC) $(CFLAGS) -c -o $@ $<

# ================================================================
# VM 单元测试二进制
# ================================================================

build-vm-test: $(VM_TEST_BIN)

$(VM_TEST_BIN): $(TEST_DIR)/test_vm.c $(CORE_SRCS) core/vm.h $(CORE_LIB) $(IO_LIB)
	@mkdir -p $(BUILD_BIN)
	$(CC) $(CFLAGS) -o $@ $< -L$(BUILD_LIB) -Lio -lvm_io -lvm_core -lm

build-io-test: $(IO_TEST_BIN)

$(IO_TEST_BIN): $(TEST_DIR)/test_io_mapping.c io/io_mapping.h core/vm.h $(CORE_LIB) $(IO_LIB)
	@mkdir -p $(BUILD_BIN)
	$(CC) $(CFLAGS) -o $@ $< -L$(BUILD_LIB) -Lio -lvm_io -lvm_core -lm

build-hs-test: $(HS_TEST_BIN)

$(HS_TEST_BIN): $(TEST_DIR)/test_hotstandby.c $(CORE_SRCS) core/vm.h hotstandby/hotstandby.h
	@mkdir -p $(BUILD_BIN)
	$(CC) $(CFLAGS) -o $@ $< -lm

# 下装帧 + HMAC：新目录单独开 -Werror（§8 构建纪律）
build-dlwire-test: $(DLWIRE_TEST_BIN)

$(DLWIRE_TEST_BIN): $(TEST_DIR)/test_download_wire.c \
		hotstandby/hmac_sha256.c hotstandby/hmac_sha256.h \
		hotstandby/download_wire.c hotstandby/download_wire.h \
		core/crc32_table.inc
	@mkdir -p $(BUILD_BIN)
	$(CC) $(CFLAGS) -Werror -o $@ $(TEST_DIR)/test_download_wire.c \
		hotstandby/hmac_sha256.c hotstandby/download_wire.c -lm

# 全量镜像下装链路：收帧 → 装槽 → 周期边界重绑 → 回滚（运行时需两个 .sasm 制品）
build-dlswitch-test: $(DLSWITCH_TEST_BIN)

$(DLSWITCH_TEST_BIN): $(TEST_DIR)/test_download_switch.c \
		hotstandby/download.c hotstandby/download_wire.c hotstandby/hmac_sha256.c \
		hotstandby/hotstandby.h hotstandby/download_wire.h hotstandby/hmac_sha256.h \
		core/loader.c core/safeasm_interp.c core/vm.h core/crc32_table.inc
	@mkdir -p $(BUILD_BIN)
	$(CC) $(CFLAGS) -Werror -o $@ $< -lm

# ================================================================
# SVM 可执行程序：默认周期运行; -d dump; -i info
# ================================================================

svm: vm-lib $(SVM_BIN)

$(SVM_BIN): $(SVM_SRC) core/sasm_dump.c core/sasm_dump.h \
		core/sasm_info.c core/sasm_info.h $(CORE_LIB) core/vm.h
	@mkdir -p $(BUILD_BIN)
	$(CC) $(CFLAGS) -o $@ core/svm.c core/sasm_dump.c core/sasm_info.c \
		-L$(BUILD_LIB) -lvm_core -lm

# ================================================================
# 仿真后端：软件 I/O + 被控对象 + watch 帧 + 激励强制，走完整 I/O 扫描路径
# core/sasm_info.c 提供段 7 符号解析（watch 与 force 的地址唯一来源）
# ================================================================

build-sim: vm-io $(SIM_BIN)

$(SIM_BIN): $(SIM_MAIN_SRC) $(SIM_SRCS) $(SIM_DIR)/plant.h $(SIM_DIR)/sim_io.h \
            $(SIM_DIR)/watch.h $(SIM_DIR)/force.h \
            core/sasm_info.c core/sasm_info.h \
            $(CORE_LIB) $(IO_LIB)
	@mkdir -p $(BUILD_BIN)
	$(CC) $(CFLAGS) -Werror -o $@ $(SIM_MAIN_SRC) $(SIM_SRCS) core/sasm_info.c \
		-L$(BUILD_LIB) -lvm_io -lvm_core -lm

# ================================================================
# 目标端 agent：装载 + 周期执行 + 下装服务 + 状态上报
# 链 libvm_hs（download/download_wire/hmac）与 libvm_core（loader/interp）
# ================================================================

agent: vm-lib vm-hs $(AGENT_BIN)

$(AGENT_BIN): $(AGENT_SRC) $(HS_LIB) $(CORE_LIB) \
		hotstandby/hotstandby.h hotstandby/download_wire.h hotstandby/hmac_sha256.h core/vm.h
	@mkdir -p $(BUILD_BIN)
	$(CC) $(CFLAGS) -Werror -o $@ $(AGENT_SRC) \
		-L$(BUILD_LIB) -lvm_hs -lvm_core -lm

# ================================================================
# Sanitizer 变体 (P2: ASan/UBSan)
# ================================================================

sanitize-svm: $(SVM_SRC) core/sasm_dump.c core/sasm_info.c core/loader.c core/safeasm_interp.c core/vm.h
	@echo "  [SANITIZE] Building SVM with ASan/UBSan..."
	@mkdir -p $(BUILD_BIN)
	$(CC) $(CFLAGS) $(SANITIZE_FLAGS) -o $(SANITIZE_SVM_BIN) \
		core/svm.c core/sasm_dump.c core/sasm_info.c core/loader.c core/safeasm_interp.c \
		$(SANITIZE_LDFLAGS) -lm
	@echo "  [SANITIZE] SVM (ASan/UBSan) built: $(SANITIZE_SVM_BIN)"

sanitize-test: $(SANITIZE_TEST_VM_BIN)

$(SANITIZE_TEST_VM_BIN): $(TEST_DIR)/test_vm.c $(CORE_SRCS) core/vm.h $(CORE_LIB) $(IO_LIB)
	@echo "  [SANITIZE] Building test_vm with ASan/UBSan..."
	@mkdir -p $(BUILD_BIN)
	$(CC) $(CFLAGS) $(SANITIZE_FLAGS) -o $@ $< \
		-L$(BUILD_LIB) -Lio -lvm_io -lvm_core $(SANITIZE_LDFLAGS) -lm
	@echo "  [SANITIZE] test_vm (ASan/UBSan) built: $@"

# 下装路径的 sanitizer 变体：帧重组与镜像拷贝是本项目里 memcpy 最密的地方
sanitize-dl: $(SANITIZE_DLWIRE_BIN) $(SANITIZE_DLSWITCH_BIN)

$(SANITIZE_DLWIRE_BIN): $(TEST_DIR)/test_download_wire.c \
		hotstandby/hmac_sha256.c hotstandby/download_wire.c \
		hotstandby/hmac_sha256.h hotstandby/download_wire.h core/crc32_table.inc
	@echo "  [SANITIZE] Building test_download_wire with ASan/UBSan..."
	@mkdir -p $(BUILD_BIN)
	$(CC) $(CFLAGS) -Werror $(SANITIZE_FLAGS) -o $@ $(TEST_DIR)/test_download_wire.c \
		hotstandby/hmac_sha256.c hotstandby/download_wire.c \
		$(SANITIZE_LDFLAGS) -lm

$(SANITIZE_DLSWITCH_BIN): $(TEST_DIR)/test_download_switch.c \
		hotstandby/download.c hotstandby/download_wire.c hotstandby/hmac_sha256.c \
		core/loader.c core/safeasm_interp.c core/vm.h \
		hotstandby/hotstandby.h hotstandby/download_wire.h hotstandby/hmac_sha256.h \
		core/crc32_table.inc
	@echo "  [SANITIZE] Building test_download_switch with ASan/UBSan..."
	@mkdir -p $(BUILD_BIN)
	$(CC) $(CFLAGS) -Werror $(SANITIZE_FLAGS) -o $@ $< $(SANITIZE_LDFLAGS) -lm

# 本组件内的 sanitizer 回归（.sasm 用例由根 Makefile 的 build-smoke/build-function-tests 提供）
run-sanitize: sanitize-svm sanitize-test sanitize-dl
	@echo "  [SANITIZE] Running test_vm under ASan/UBSan..."
	@$(SANITIZE_TEST_VM_BIN)
	@echo "  [SANITIZE] Running SVM under ASan/UBSan..."
	@$(SANITIZE_SVM_BIN) -n 1 -p 0 $(BUILD_SASM)/core_assign.sasm 42 > /dev/null
	@$(SANITIZE_SVM_BIN) -n 6 -p 0 $(BUILD_SASM)/function_control_flow.sasm > /dev/null
	@echo "  [SANITIZE] All sanitizer checks passed"

# ================================================================
# Fuzz 测试 (P2: .sasm 加载器模糊测试)
# ================================================================

build-fuzzer: $(SANITIZE_FUZZER_BIN)

$(SANITIZE_FUZZER_BIN): $(FUZZ_SRC) core/loader.c core/vm.h core/crc32_table.inc
	@echo "  [FUZZ] Building .sasm fuzzer..."
	@mkdir -p $(FUZZ_DIR)/corpus $(BUILD_BIN)
	$(CC) $(CFLAGS) $(SANITIZE_FLAGS) -I. \
		-o $@ $< $(SANITIZE_LDFLAGS) -lm
	@echo "  [FUZZ] Fuzzer built: $@"

# ================================================================
# MISRA-C 静态检查
# ================================================================

misra-check:
	@./run_misra_check.sh

# ================================================================
# RT-Thread 适配层 (需要 RT-Thread SDK)
# ================================================================
# 在目标硬件上编译时需指定:
#   make -C veri-runtime rtthread RTTHREAD_SDK=/path/to/rt-thread RTTHREAD_INC=-I/path/to/rt-thread/include

rtthread: $(CORE_LIB) $(IO_LIB)
	@echo "  [RTTHREAD] Compiling RT-Thread port (requires RT-Thread SDK)..."
	@if [ -n "$(RTTHREAD_SDK)" ]; then \
		$(CC) $(CFLAGS) $(RTTHREAD_INC) -c -o $(RTTHREAD_DIR)/vm_rtthread.o \
			$(RTTHREAD_DIR)/vm_rtthread.c && \
		echo "  [RTTHREAD] Compilation OK"; \
	else \
		echo "  [RTTHREAD] Skip (set RTTHREAD_SDK to the RT-Thread root)"; \
	fi

# ================================================================
# 清理（组件自身产物；build/ 由根 Makefile 负责）
# ================================================================

clean-component:
	@echo "  [CLEAN] veri-runtime: removing object files..."
	rm -f $(CORE_OBJS) $(IO_OBJS) $(HS_OBJS) $(RTTHREAD_OBJS)
