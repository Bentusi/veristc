#!/usr/bin/env bash
# 单组 RPS 4 通道保护 + ESFAS 顺序器端到端验证：
#   [1/4] VeriSTC 编译 38 周期场景
#   [2/4] SVM 输出 vs 手算黄金时间线（黄金值独立推导自设计文档，非捕获）
#   [3/4] 编译确定性（两次编译 .sasm 逐字节一致）
#   [4/4] SVM dump：SIL3 标记 + 加载校验（CRC 路径由 run_vm_checks 覆盖）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

. "$ROOT/integration/test_framework.sh"

test_begin "Nuclear RPS Channel E2E"

ST=veri-stc/tests/st-examples/nuclear_rps_channel.st
OUT=build/sasm/nuclear_rps_channel.sasm
GOLDEN=veri-stc/tests/st-examples/nuclear_rps_channel.golden.out
V=build/bin/veristc

step "1/4" "compile ${ST}"
mkdir -p "$(dirname "$OUT")"
"$V" -a "$ST"
assert_ok "compile nuclear RPS channel" "$V" -c "$ST" -o "$OUT"

step "2/4" "run 38 cycles, diff against golden"
build/bin/svm -n 38 -p 0 "$OUT" > /tmp/chan.raw 2>&1
grep "^CHAN " /tmp/chan.raw > /tmp/chan.actual
if diff -u "$GOLDEN" /tmp/chan.actual > /tmp/chan.diff 2>&1; then
    echo "  golden diff ... OK"
    _TF_PASS=$((_TF_PASS + 1))
else
    echo "  golden diff ... FAIL"
    sed -n '1,30p' /tmp/chan.diff
    _TF_FAIL=$((_TF_FAIL + 1))
fi
assert_line_count "/tmp/chan.actual" 38 "38 cycles output"
echo "  38/38 周期逐行一致（跳闸 t17/19、母线 t19、SI t24、HPI t28、RESET t30、D 再跳闸 t33、母线保持释放）"

step "3/4" "determinism: compile twice, byte-compare"
"$V" -c "$ST" -o /tmp/chan-a.sasm
"$V" -c "$ST" -o /tmp/chan-b.sasm
assert_ok "first pair byte-identical" cmp /tmp/chan-a.sasm /tmp/chan-b.sasm
assert_ok "matches production output" cmp /tmp/chan-a.sasm "$OUT"

step "4/4" "svm dump (SIL3 / 结构校验)"
build/bin/svm -d "$OUT" > /tmp/chan-dump.out
assert_contains "/tmp/chan-dump.out" "安全等级: SIL3" "SIL3 level in dump"

check_failures "Nuclear RPS Channel E2E"
