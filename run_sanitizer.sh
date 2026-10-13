#!/usr/bin/env bash
# run_sanitizer.sh — ASan/UBSan 构建变体测试
# P2 改进：在 CI 中捕获内存安全漏洞
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

. "$ROOT/tests/test_framework.sh"

test_begin "ASan/UBSan Memory Safety"

# ── 前置检查：gcc 是否支持 sanitizer ──
if ! echo 'int main(void){return 0;}' | gcc -fsanitize=address,undefined -x c - -o /dev/null 2>/dev/null; then
    skip "gcc does not support ASan/UBSan (install libasan and libubsan)"
    summary_pass "ASan/UBSan skipped (gcc support unavailable)"
fi

# ── 前置条件：需要正常构建 .sasm 测试文件 ──
step "0/4" "build .sasm test files"
make build-smoke build-function-tests

# ── [1/4] ASan/UBSan VM 单元测试 ──
step "1/4" "ASan/UBSan VM unit tests"
make sanitize-test
assert_ok "test_vm-asan" tests/vm-tests/test_vm-asan

# ── [2/4] ASan/UBSan SVM 单周期运行 ──
step "2/4" "ASan/UBSan SVM single cycle"
make sanitize-svm
vm/svm-asan -n 1 -p 0 tests/veristc-tests/out/core_assign.sasm 42 \
    > /tmp/veristc-sanitize-once.out
assert_contains "/tmp/veristc-sanitize-once.out" "[cycle_counter] 1" "svm-asan single cycle output"

# ── [3/4] ASan/UBSan SVM FUNCTION 控制流 ──
step "3/4" "ASan/UBSan SVM FUNCTION control flow"
vm/svm-asan -n 6 -p 0 tests/veristc-tests/out/function_control_flow.sasm \
    > /tmp/veristc-sanitize-func.out
assert_contains "/tmp/veristc-sanitize-func.out" "tick=1,  y=2," "svm-asan FUNCTION control flow"

# ── [4/4] ASan/UBSan CRC 损坏拒绝 ──
step "4/4" "ASan/UBSan CRC corruption rejection"
cp tests/veristc-tests/out/core_assign.sasm /tmp/veristc-sanitize-bad-crc.sasm
size="$(wc -c < /tmp/veristc-sanitize-bad-crc.sasm)"
printf '\377' | dd of=/tmp/veristc-sanitize-bad-crc.sasm bs=1 \
    seek="$((size - 5))" count=1 conv=notrunc status=none
if vm/svm-asan -n 1 -p 0 /tmp/veristc-sanitize-bad-crc.sasm \
    > /tmp/veristc-sanitize-bad-crc.out 2>&1; then
    echo "  corrupt CRC rejected ... FAIL (svm-asan accepted bad CRC)"
    _TF_FAIL=$((_TF_FAIL + 1))
else
    echo "  corrupt CRC rejected ... OK"
    _TF_PASS=$((_TF_PASS + 1))
fi
assert_contains "/tmp/veristc-sanitize-bad-crc.out" "sasm_load failed: -2" "CRC error code correct"

check_failures "ASan/UBSan Memory Safety"
