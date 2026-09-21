#!/usr/bin/env bash
# 单组 RPS 4 通道保护 + ESFAS 顺序器端到端验证：
#   [1/4] VeriSTC 编译 38 周期场景
#   [2/4] SVM 输出 vs 手算黄金时间线（黄金值独立推导自设计文档，非捕获）
#   [3/4] 编译确定性（两次编译 .sasm 逐字节一致）
#   [4/4] SVM dump：SIL3 标记 + 加载校验（CRC 路径由 run_vm_checks 覆盖）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

ST=tests/st-examples/nuclear_rps_channel.st
OUT=tests/veristc-tests/out/nuclear_rps_channel.sasm
GOLDEN=tests/st-examples/nuclear_rps_channel.golden.out
V=veristc/extraction/veristc

echo "[1/4] compile ${ST}"
mkdir -p "$(dirname "$OUT")"
"$V" -a "$ST"
"$V" -c "$ST" -o "$OUT"

echo "[2/4] run 38 cycles, diff against golden"
vm/svm -n 38 -p 0 "$OUT" > /tmp/chan.raw 2>&1
grep "^CHAN " /tmp/chan.raw > /tmp/chan.actual
if ! diff -u "$GOLDEN" /tmp/chan.actual > /tmp/chan.diff; then
  echo "channel e2e 输出与黄金时间线不符：" >&2
  sed -n '1,30p' /tmp/chan.diff >&2
  exit 1
fi
test "$(wc -l < /tmp/chan.actual)" -eq 38
echo "  38/38 周期逐行一致（跳闸 t17/19、母线 t19、SI t24、HPI t28、RESET t30、D 再跳闸 t33、母线保持释放）"

echo "[3/4] determinism: compile twice, byte-compare"
"$V" -c "$ST" -o /tmp/chan-a.sasm
"$V" -c "$ST" -o /tmp/chan-b.sasm
cmp /tmp/chan-a.sasm /tmp/chan-b.sasm
cmp /tmp/chan-a.sasm "$OUT"

echo "[4/4] svm dump (SIL3 / 结构校验)"
vm/svm -d "$OUT" > /tmp/chan-dump.out
grep -q '安全等级: SIL3' /tmp/chan-dump.out

echo "nuclear RPS channel e2e passed"
