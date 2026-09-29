#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

make build-vm-test build-smoke build-function-tests

echo "[1/4] minimal VM tests"
tests/vm-tests/test_vm

echo "[2/4] SVM one-cycle, PRINT and CycleCounter"
./vm/svm -n 1 -p 0 tests/veristc-tests/out/core_assign.sasm 42 \
    > /tmp/veristc-svm-once.out
grep -Fq '[cycle_counter] 1' /tmp/veristc-svm-once.out
grep -Fq 'counter=' /tmp/veristc-svm-once.out
grep -Fq ' x=' /tmp/veristc-svm-once.out
grep -Fq '1, ' /tmp/veristc-svm-once.out
grep -Fq '42, ' /tmp/veristc-svm-once.out

echo "[3/4] full FUNCTION control flow, nested CALL and safety gates"
./vm/svm -n 6 -p 0 tests/veristc-tests/out/function_control_flow.sasm \
    > /tmp/veristc-function.out
grep -Fq 'tick=1,  y=2,' /tmp/veristc-function.out
grep -Fq 'tick=4,  y=5,' /tmp/veristc-function.out
grep -Fq 'tick=6,  y=5,' /tmp/veristc-function.out

if ./veristc/extraction/veristc -c tests/st-examples/function_impure.st \
    -o /tmp/veristc-function-impure.sasm \
    > /tmp/veristc-function-impure.out 2>&1; then
    echo "compiler accepted an impure FUNCTION" >&2
    exit 1
fi
grep -Fq 'type check failed' /tmp/veristc-function-impure.out

if ./veristc/extraction/veristc -c tests/st-examples/function_recursive.st \
    -o /tmp/veristc-function-recursive.sasm \
    > /tmp/veristc-function-recursive.out 2>&1; then
    echo "compiler accepted a recursive FUNCTION" >&2
    exit 1
fi
grep -Fq 'recursive calls are not supported' /tmp/veristc-function-recursive.out

if ./veristc/extraction/veristc -c tests/st-examples/function_loop.st \
    -o /tmp/veristc-function-loop.sasm \
    > /tmp/veristc-function-loop.out 2>&1; then
    echo "compiler accepted a loop inside FUNCTION" >&2
    exit 1
fi
grep -Fq 'type check failed' /tmp/veristc-function-loop.out

if ./veristc/extraction/veristc -c tests/st-examples/function_local_initializer.st \
    -o /tmp/veristc-function-local-initializer.sasm \
    > /tmp/veristc-function-local-initializer.out 2>&1; then
    echo "compiler accepted an unimplemented FUNCTION local initializer" >&2
    exit 1
fi
grep -Fq 'type check failed' /tmp/veristc-function-local-initializer.out

echo "[4/4] SVM dump, SIL3, CRC, period and corrupt CRC rejection"
./vm/svm -d tests/veristc-tests/out/core_assign.sasm \
    > /tmp/veristc-svm-dump.out
grep -q '状态:   OK' /tmp/veristc-svm-dump.out
grep -q '安全等级: SIL3' /tmp/veristc-svm-dump.out

start="$(date +%s%N)"
./vm/svm -n 2 -p 1000 tests/veristc-tests/out/core_assign.sasm 42 \
    > /tmp/veristc-svm-period.out
end="$(date +%s%N)"
elapsed_ms="$(( (end - start) / 1000000 ))"
test "$elapsed_ms" -ge 900
grep -Fq '[cycle_counter] 1' /tmp/veristc-svm-period.out
grep -Fq '[cycle_counter] 2' /tmp/veristc-svm-period.out

cp tests/veristc-tests/out/core_assign.sasm /tmp/veristc-bad-crc.sasm
size="$(wc -c < /tmp/veristc-bad-crc.sasm)"
printf '\377' | dd of=/tmp/veristc-bad-crc.sasm bs=1 \
    seek="$((size - 5))" count=1 conv=notrunc status=none
if ./vm/svm -n 1 -p 0 /tmp/veristc-bad-crc.sasm \
    > /tmp/veristc-bad-crc.out 2>&1; then
    echo "SVM accepted a file with a bad CRC" >&2
    exit 1
fi
grep -q 'sasm_load failed: -2' /tmp/veristc-bad-crc.out

echo "VM/SVM checks passed (period ${elapsed_ms} ms)"
