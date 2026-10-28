#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

. "$ROOT/integration/test_framework.sh"

test_begin "VeriSTC Full Test Suite"

# 全量构建：Coq 编译 + veristc 提取 + C 库/工具 + 测试二进制 + SASM 生成
step "1/10" "full build (Coq + C + tests)"
assert_ok "make all build-tests" make all build-tests

# 分别执行测试套件（子脚本内的 make 会因目标已最新而跳过）
step "2/10" "VM/SVM checks"
assert_ok "run_vm_checks.sh" "$ROOT/veri-runtime/run_vm_checks.sh"

step "3/10" "SafeST feature probes"
assert_ok "run_feature_probes.sh" "$ROOT/integration/run_feature_probes.sh"

step "4/10" "Nuclear RPS channel E2E"
assert_ok "run_channel_e2e.sh" "$ROOT/integration/run_channel_e2e.sh"

step "5/10" "Algorithm blocks multi-instance E2E"
assert_ok "run_algo_e2e.sh" "$ROOT/integration/run_algo_e2e.sh"

step "6/10" "Algorithm blocks native FB E2E"
assert_ok "run_algo_fb_e2e.sh" "$ROOT/integration/run_algo_fb_e2e.sh"

step "7/10" "Nuclear ST end-to-end"
assert_ok "run_nuclear_e2e.sh" "$ROOT/integration/run_nuclear_e2e.sh"

step "8/10" "Closed-loop simulation E2E"
assert_ok "run_sim_e2e.sh" "$ROOT/integration/run_sim_e2e.sh"

step "9/10" "Download protocol + agent E2E"
assert_ok "run_download_e2e.sh" "$ROOT/integration/run_download_e2e.sh"

step "10/10" "Compiler negative/positive tests"
assert_ok "run_compiler_tests.sh" "$ROOT/veri-stc/tests/compiler-tests/run_compiler_tests.sh"

# P2: ASan/UBSan 内存安全检测（可选，需要 gcc 支持）
if echo 'int main(void){return 0;}' | gcc -fsanitize=address,undefined -x c - -o /dev/null 2>/dev/null; then
    step "+/10" "ASan/UBSan memory safety"
    assert_ok "run_sanitizer.sh" "$ROOT/veri-runtime/run_sanitizer.sh"
else
    skip "ASan/UBSan not supported by gcc, skipping sanitizer tests"
fi

check_failures "VeriSTC Full Test Suite"
