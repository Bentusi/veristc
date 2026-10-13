#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

. "$ROOT/tests/test_framework.sh"

test_begin "VM/SVM Checks"

make build-vm-test build-io-test build-hs-test build-smoke build-function-tests

step "1/6" "minimal VM tests"
assert_ok "VM unit tests" tests/vm-tests/test_vm

step "2/6" "I/O mapping unit tests"
assert_ok "I/O mapping tests" tests/vm-tests/test_io_mapping

step "3/6" "Hotstandby unit tests"
assert_ok "Hotstandby tests" tests/vm-tests/test_hotstandby

step "4/6" "SVM one-cycle, PRINT and CycleCounter"
./vm/svm -n 1 -p 0 tests/veristc-tests/out/core_assign.sasm 42 \
    > /tmp/veristc-svm-once.out
assert_contains "/tmp/veristc-svm-once.out" "[cycle_counter] 1" "cycle_counter present"
assert_contains "/tmp/veristc-svm-once.out" "counter=" "counter output"
assert_contains "/tmp/veristc-svm-once.out" " x=" "x variable output"
assert_contains "/tmp/veristc-svm-once.out" "1, " "value 1 output"
assert_contains "/tmp/veristc-svm-once.out" "42, " "value 42 output"

step "5/6" "full FUNCTION control flow, nested CALL and safety gates"
./vm/svm -n 6 -p 0 tests/veristc-tests/out/function_control_flow.sasm \
    > /tmp/veristc-function.out
assert_contains "/tmp/veristc-function.out" "tick=1,  y=2," "tick=1 output"
assert_contains "/tmp/veristc-function.out" "tick=4,  y=5," "tick=4 output"
assert_contains "/tmp/veristc-function.out" "tick=6,  y=5," "tick=6 output"

V=./veristc/extraction/veristc

# impure FUNCTION rejection
if "$V" -c tests/st-examples/function_impure.st \
    -o /tmp/veristc-function-impure.sasm \
    > /tmp/veristc-function-impure.out 2>&1; then
    echo "  impure FUNCTION rejection ... FAIL (compiler accepted it)"
    _TF_FAIL=$((_TF_FAIL + 1))
else
    assert_contains "/tmp/veristc-function-impure.out" "purity violation" "impure FUNCTION error message"
fi

# recursive FUNCTION rejection
if "$V" -c tests/st-examples/function_recursive.st \
    -o /tmp/veristc-function-recursive.sasm \
    > /tmp/veristc-function-recursive.out 2>&1; then
    echo "  recursive FUNCTION rejection ... FAIL (compiler accepted it)"
    _TF_FAIL=$((_TF_FAIL + 1))
else
    assert_contains "/tmp/veristc-function-recursive.out" "recursive calls are not supported" "recursive FUNCTION error message"
fi

# FUNCTION with loop (should compile and run)
"$V" -c tests/st-examples/function_loop.st \
    -o /tmp/veristc-function-loop.sasm \
    > /tmp/veristc-function-loop.out
./vm/svm -n 1 -p 0 /tmp/veristc-function-loop.sasm \
    > /tmp/veristc-function-loop-run.out
assert_contains "/tmp/veristc-function-loop-run.out" "y=11," "FUNCTION loop result"

# FUNCTION with local initializer (should compile and run)
"$V" -c tests/st-examples/function_local_initializer.st \
    -o /tmp/veristc-function-local-initializer.sasm \
    > /tmp/veristc-function-local-initializer.out
./vm/svm -n 1 -p 0 /tmp/veristc-function-local-initializer.sasm \
    > /tmp/veristc-function-local-initializer-run.out
assert_contains "/tmp/veristc-function-local-initializer-run.out" "y=11," "FUNCTION local initializer result"

# WHILE inside FUNCTION rejection
if "$V" -c tests/st-examples/function_while.st \
    -o /tmp/veristc-function-while.sasm \
    > /tmp/veristc-function-while.out 2>&1; then
    echo "  WHILE in FUNCTION rejection ... FAIL (compiler accepted it)"
    _TF_FAIL=$((_TF_FAIL + 1))
else
    assert_contains "/tmp/veristc-function-while.out" "unsupported control flow" "WHILE in FUNCTION error message"
fi

step "6/6" "SVM dump, SIL3, CRC, period and corrupt CRC rejection"
./vm/svm -d tests/veristc-tests/out/core_assign.sasm \
    > /tmp/veristc-svm-dump.out
assert_contains "/tmp/veristc-svm-dump.out" "状态:   OK" "dump status OK"
assert_contains "/tmp/veristc-svm-dump.out" "安全等级: SIL3" "SIL3 level"

start="$(date +%s%N)"
./vm/svm -n 2 -p 1000 tests/veristc-tests/out/core_assign.sasm 42 \
    > /tmp/veristc-svm-period.out
end="$(date +%s%N)"
elapsed_ms="$(( (end - start) / 1000000 ))"
if [ "$elapsed_ms" -ge 900 ]; then
    echo "  period timing (${elapsed_ms}ms) ... OK"
    _TF_PASS=$((_TF_PASS + 1))
else
    echo "  period timing (${elapsed_ms}ms) ... FAIL (< 900ms)"
    _TF_FAIL=$((_TF_FAIL + 1))
fi
assert_contains "/tmp/veristc-svm-period.out" "[cycle_counter] 1" "period cycle 1"
assert_contains "/tmp/veristc-svm-period.out" "[cycle_counter] 2" "period cycle 2"

cp tests/veristc-tests/out/core_assign.sasm /tmp/veristc-bad-crc.sasm
size="$(wc -c < /tmp/veristc-bad-crc.sasm)"
printf '\377' | dd of=/tmp/veristc-bad-crc.sasm bs=1 \
    seek="$((size - 5))" count=1 conv=notrunc status=none
if ./vm/svm -n 1 -p 0 /tmp/veristc-bad-crc.sasm \
    > /tmp/veristc-bad-crc.out 2>&1; then
    echo "  corrupt CRC rejected ... FAIL (SVM accepted bad CRC)"
    _TF_FAIL=$((_TF_FAIL + 1))
else
    echo "  corrupt CRC rejected ... OK"
    _TF_PASS=$((_TF_PASS + 1))
fi
assert_contains "/tmp/veristc-bad-crc.out" "sasm_load failed: -2" "CRC error code correct"

check_failures "VM/SVM checks (period ${elapsed_ms}ms)"
