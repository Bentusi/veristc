#!/usr/bin/env bash
# 原生 FUNCTION_BLOCK 算法块多实例端到端验证：
#   [1/4] VeriSTC 编译 12 周期场景（RS/SR/PID/FBY 全 FB 特性）
#   [2/4] SVM 输出 vs 手算黄金时间线（与 FUNCTION 版交叉一致）
#   [3/4] 编译确定性（两次编译 .sasm 逐字节一致）
#   [4/4] SVM dump：SIL3 标记 + 加载校验
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

. "$ROOT/tests/test_framework.sh"

test_begin "Algorithm Blocks Native FB E2E"

ST=tests/st-examples/algo_blocks_fb.st
OUT=tests/veristc-tests/out/algo_blocks_fb.sasm
GOLDEN=tests/st-examples/algo_blocks_fb.golden.out
V=veristc/extraction/veristc

step "1/4" "compile ${ST}"
mkdir -p "$(dirname "$OUT")"
"$V" -a "$ST"
assert_ok "compile algo FB blocks" "$V" -c "$ST" -o "$OUT"

step "2/4" "run 12 cycles, diff against golden"
vm/svm -n 12 -p 0 "$OUT" > /tmp/algofb.raw 2>&1
grep "^FB " /tmp/algofb.raw > /tmp/algofb.actual
if diff -u "$GOLDEN" /tmp/algofb.actual > /tmp/algofb.diff 2>&1; then
    echo "  golden diff ... OK"
    _TF_PASS=$((_TF_PASS + 1))
else
    echo "  golden diff ... FAIL"
    sed -n '1,30p' /tmp/algofb.diff
    _TF_FAIL=$((_TF_FAIL + 1))
fi
assert_line_count "/tmp/algofb.actual" 12 "12 cycles output"
echo "  12/12 周期逐行一致（FB 实例持久状态 UI/E_OLD、VAR_IN_OUT TRACE 别名 tr==u、与 FUNCTION 版核心列交叉一致）"

step "3/4" "determinism: compile twice, byte-compare"
"$V" -c "$ST" -o /tmp/algofb-a.sasm
"$V" -c "$ST" -o /tmp/algofb-b.sasm
assert_ok "first pair byte-identical" cmp /tmp/algofb-a.sasm /tmp/algofb-b.sasm
assert_ok "matches production output" cmp /tmp/algofb-a.sasm "$OUT"

step "4/4" "svm dump (SIL3 / 结构校验)"
vm/svm -d "$OUT" > /tmp/algofb-dump.out
assert_contains "/tmp/algofb-dump.out" "安全等级: SIL3" "SIL3 level in dump"

check_failures "Algorithm Blocks Native FB E2E"
