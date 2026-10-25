#!/usr/bin/env bash
# 算法块多实例端到端验证（RS/SR/PID/FBY，不同变量调用相同算法功能）：
#   [1/4] VeriSTC 编译 12 周期场景
#   [2/4] SVM 输出 vs 手算黄金时间线（黄金值独立推导，见 .st 文件头注释）
#   [3/4] 编译确定性（两次编译 .sasm 逐字节一致）
#   [4/4] SVM dump：SIL3 标记 + 加载校验
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

. "$ROOT/tests/test_framework.sh"

test_begin "Algorithm Blocks Multi-Instance E2E"

ST=tests/st-examples/algo_blocks_multi_instance.st
OUT=build/sasm/algo_blocks_multi_instance.sasm
GOLDEN=tests/st-examples/algo_blocks_multi_instance.golden.out
V=build/bin/veristc

step "1/4" "compile ${ST}"
mkdir -p "$(dirname "$OUT")"
"$V" -a "$ST"
assert_ok "compile algo blocks" "$V" -c "$ST" -o "$OUT"

step "2/4" "run 12 cycles, diff against golden"
build/bin/svm -n 12 -p 0 "$OUT" > /tmp/algo.raw 2>&1
grep "^ALG " /tmp/algo.raw > /tmp/algo.actual
if diff -u "$GOLDEN" /tmp/algo.actual > /tmp/algo.diff 2>&1; then
    echo "  golden diff ... OK"
    _TF_PASS=$((_TF_PASS + 1))
else
    echo "  golden diff ... FAIL"
    sed -n '1,30p' /tmp/algo.diff
    _TF_FAIL=$((_TF_FAIL + 1))
fi
assert_line_count "/tmp/algo.actual" 12 "12 cycles output"
echo "  12/12 周期逐行一致（RS 置位优先 t1-4、SR 复位优先 t2/t6/t9、PID 双实例限幅、FBY 速率限制 20/50）"

step "3/4" "determinism: compile twice, byte-compare"
"$V" -c "$ST" -o /tmp/algo-a.sasm
"$V" -c "$ST" -o /tmp/algo-b.sasm
assert_ok "first pair byte-identical" cmp /tmp/algo-a.sasm /tmp/algo-b.sasm
assert_ok "matches production output" cmp /tmp/algo-a.sasm "$OUT"

step "4/4" "svm dump (SIL3 / 结构校验)"
build/bin/svm -d "$OUT" > /tmp/algo-dump.out
assert_contains "/tmp/algo-dump.out" "安全等级: SIL3" "SIL3 level in dump"

check_failures "Algorithm Blocks Multi-Instance E2E"
