#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

if [[ "${VERISTC_SKIP_BUILD:-0}" != "1" ]]; then
    make build-vm-test build-smoke svm
fi

echo "[1/4] minimal VM tests"
tests/vm-tests/test_vm

echo "[2/4] SVM one-cycle, PRINT and CycleCounter"
./vm/svm -n 1 -p 0 tests/veristc-tests/out/core_assign.sasm 42 \
    > /tmp/veristc-svm-once.out
grep -Fq '[cycle_counter] 1' /tmp/veristc-svm-once.out
grep -Fq '[print] 1' /tmp/veristc-svm-once.out
grep -Fq '[print] 42' /tmp/veristc-svm-once.out

echo "[3/4] SVM dump, SIL3 and CRC"
./vm/svm -d tests/veristc-tests/out/core_assign.sasm \
    > /tmp/veristc-svm-dump.out
grep -q '状态:   OK' /tmp/veristc-svm-dump.out
grep -q '安全等级: SIL3' /tmp/veristc-svm-dump.out

echo "[4/4] 1000 ms period and corrupt CRC rejection"
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
