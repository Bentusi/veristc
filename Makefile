# Makefile — VeriSTC 平台聚合构建
#
#   veri-stc/      编译器组件（Coq 实现+证明 → OCaml 可执行文件）  → make -C veri-stc
#   veri-runtime/  运行站组件（C11 SafeASM VM + I/O + 热备 + 仿真）  → make -C veri-runtime
#   veri-ide/      工程站组件（Web IDE，Phase 6 规划中）
#   integration/   跨组件系统级端到端验证
#
# 根 Makefile 只做两件事：向组件转发目标；构建必须由两组件共同产出的制品
# （.sasm 黄金用例 + 核电端到端测试二进制）。脚本一律从仓库根调用 `make <目标>`。

include Makefile.common

STC_MAKE     = $(MAKE) -C $(STC_DIR)
RUNTIME_MAKE = $(MAKE) -C $(RUNTIME_DIR)

VERISTC_BIN       = $(BUILD_BIN)/veristc
NUCLEAR_TEST_BIN  = $(BUILD_BIN)/test_nuclear_protection_full_e2e

SMOKE_ST         = $(STC_DIR)/tests/st-examples/core_assign.st
SMOKE_SASM       = $(BUILD_SASM)/core_assign.sasm
FUNCTION_ST      = $(STC_DIR)/tests/st-examples/function_control_flow.st
FUNCTION_SASM    = $(BUILD_SASM)/function_control_flow.sasm
NUCLEAR_FULL_ST  = $(STC_DIR)/tests/st-examples/nuclear_rps_esfas_full.st
NUCLEAR_FULL_SASM = $(BUILD_SASM)/nuclear_rps_esfas_full.sasm
CHANNEL_ST       = $(STC_DIR)/tests/st-examples/nuclear_rps_channel.st
CHANNEL_SASM     = $(BUILD_SASM)/nuclear_rps_channel.sasm
IO_CAL_ST        = $(STC_DIR)/tests/st-examples/io_cal.st
IO_CAL_SASM      = $(BUILD_SASM)/io_cal.sasm
SIM_LOOP_ST      = $(STC_DIR)/tests/st-examples/sim_closed_loop.st
SIM_LOOP_SASM    = $(BUILD_SASM)/sim_closed_loop.sasm
NUCLEAR_TEST_SRC = $(RUNTIME_DIR)/tests/vm-tests/test_nuclear_protection_full_e2e.c

.PHONY: all build-tests coq extract veristc dune-build dune-extract dune-veristc
.PHONY: vm-lib vm-io vm-hs svm build-vm-test build-io-test build-hs-test \
        build-dlwire-test build-dlswitch-test agent rtthread
.PHONY: build-smoke build-function-tests build-nuclear-e2e build-channel-e2e
.PHONY: build-io-cal build-sim sim-demo sim-watch
.PHONY: sanitize-svm sanitize-test sanitize-dl run-sanitize build-fuzzer misra-check clean
.PHONY: stc-libs runtime-libs

all:
	@$(STC_MAKE) all
	@$(RUNTIME_MAKE) all

build-tests: build-vm-test build-io-test build-hs-test \
             build-dlwire-test build-dlswitch-test build-smoke \
             build-function-tests build-io-cal build-sim build-nuclear-e2e

# ================================================================
# 组件转发（编译器侧）
# ================================================================

coq:        ; @$(STC_MAKE) coq
extract:    ; @$(STC_MAKE) extract
veristc:    ; @$(STC_MAKE) veristc
dune-build:   ; @$(STC_MAKE) dune-build
dune-extract: ; @$(STC_MAKE) dune-extract
dune-veristc: ; @$(STC_MAKE) dune-veristc

stc-libs:
	@$(STC_MAKE) veristc

# ================================================================
# 组件转发（运行站侧）
# ================================================================

vm-lib:          ; @$(RUNTIME_MAKE) vm-lib
vm-io:           ; @$(RUNTIME_MAKE) vm-io
vm-hs:           ; @$(RUNTIME_MAKE) vm-hs
svm:             ; @$(RUNTIME_MAKE) svm
build-vm-test:   ; @$(RUNTIME_MAKE) build-vm-test
build-io-test:   ; @$(RUNTIME_MAKE) build-io-test
build-hs-test:   ; @$(RUNTIME_MAKE) build-hs-test
agent:             ; @$(RUNTIME_MAKE) agent
build-dlwire-test:   ; @$(RUNTIME_MAKE) build-dlwire-test
build-dlswitch-test: ; @$(RUNTIME_MAKE) build-dlswitch-test
sanitize-svm:    ; @$(RUNTIME_MAKE) sanitize-svm
sanitize-test:   ; @$(RUNTIME_MAKE) sanitize-test
sanitize-dl:     ; @$(RUNTIME_MAKE) sanitize-dl
build-fuzzer:    ; @$(RUNTIME_MAKE) build-fuzzer
build-sim:       ; @$(RUNTIME_MAKE) build-sim
rtthread:        ; @$(RUNTIME_MAKE) rtthread
misra-check:     ; @$(RUNTIME_MAKE) misra-check

runtime-libs:
	@$(RUNTIME_MAKE) all

# ================================================================
# 跨组件制品：ST 语料（veri-stc）→ .sasm（build/sasm）→ 端到端测试（veri-runtime）
# ================================================================

$(SMOKE_SASM): $(SMOKE_ST) | stc-libs
	@mkdir -p $(BUILD_SASM)
	$(VERISTC_BIN) -c $< -o $@

build-smoke: $(SMOKE_SASM)

$(FUNCTION_SASM): $(FUNCTION_ST) | stc-libs
	@mkdir -p $(BUILD_SASM)
	$(VERISTC_BIN) -c $< -o $@

build-function-tests: $(FUNCTION_SASM)

# 单组 RPS 4 通道保护 + ESFAS 顺序器（golden 由 integration/run_channel_e2e.sh 比对）
$(CHANNEL_SASM): $(CHANNEL_ST) | stc-libs
	@mkdir -p $(BUILD_SASM)
	$(VERISTC_BIN) -c $< -o $@

build-channel-e2e: $(CHANNEL_SASM)

# IOMAP 标定用例：唯一带 I/O 映射段的黄金制品（veri-runtime 的 -m 门禁消费它）
$(IO_CAL_SASM): $(IO_CAL_ST) | stc-libs
	@mkdir -p $(BUILD_SASM)
	$(VERISTC_BIN) -c $< -o $@

build-io-cal: $(IO_CAL_SASM)

# 闭环仿真制品：sim 门禁与 sim-demo 都用它
$(SIM_LOOP_SASM): $(SIM_LOOP_ST) | stc-libs
	@mkdir -p $(BUILD_SASM)
	$(VERISTC_BIN) -c $< -o $@

# 一眼可看的演示：控制器在合成被控对象里追设定值
sim-demo: $(SIM_LOOP_SASM) build-sim
	@$(BUILD_BIN)/sim -n 12 -t 100 $(SIM_LOOP_SASM) $(RUNTIME_DIR)/sim/plants/closed_loop.plant

# 同一闭环的机器可读侧：每周期一行 watch 帧（名字 -> 段 7 地址 -> 数值）
sim-watch: $(SIM_LOOP_SASM) build-sim
	@$(BUILD_BIN)/sim -n 12 -t 100 --watch sp,pv,mv,integ,cnt#N,cnt#ACC \
		$(SIM_LOOP_SASM) $(RUNTIME_DIR)/sim/plants/closed_loop.plant 2>/dev/null \
		| grep '^{"frame"'

$(NUCLEAR_FULL_SASM): $(NUCLEAR_FULL_ST) | stc-libs
	@mkdir -p $(BUILD_SASM)
	$(VERISTC_BIN) -a $<
	$(VERISTC_BIN) -c $< -o $@

build-nuclear-e2e: $(NUCLEAR_FULL_SASM) $(NUCLEAR_TEST_BIN)

$(NUCLEAR_TEST_BIN): $(NUCLEAR_TEST_SRC) $(NUCLEAR_FULL_SASM) | runtime-libs
	@mkdir -p $(BUILD_BIN)
	$(CC) $(CFLAGS) -o $@ $< -L$(BUILD_LIB) -L$(RUNTIME_DIR)/io -lvm_io -lvm_core -lm

# ================================================================
# Sanitizer 回归（需要跨组件的 .sasm 用例）
# ================================================================

run-sanitize: sanitize-svm sanitize-test sanitize-dl build-smoke build-function-tests
	@$(MAKE) -C $(RUNTIME_DIR) run-sanitize

# ================================================================
# 清理
# ================================================================

clean:
	@echo "  [CLEAN] Removing build directory..."
	rm -rf $(BUILD_DIR)
	@$(STC_MAKE) clean-component
	@$(RUNTIME_MAKE) clean-component
	@echo "  [CLEAN] Removing temporary files..."
	rm -f output.sasm output.txt .lia.cache .test_fix.aux .misra_report.txt
	rm -rf .misra_reports
	find . -type d ! -path './.git*' ! -path './.venv*' -name '__pycache__' \
		-exec rm -rf {} + 2>/dev/null || true
	@echo "  [CLEAN] Clean complete"
