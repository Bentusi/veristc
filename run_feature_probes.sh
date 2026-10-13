#!/usr/bin/env bash
# 特性面探针矩阵：ST → VeriSTC → SASM → SVM，stdout 与 golden/ 逐行比对。
# 语义：
#   pass 组 FAIL = 编译/VM 回归      → 非零退出
#   xfail 组维持 XFAIL = 后端缺口仍在 → 绿
#   xfail 组 RESOLVED = 缺口被修复    → 非零退出（强制升级 golden/README，防漂移）
set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

. "$ROOT/tests/test_framework.sh"

test_begin "SafeST Feature Probes"

V=veristc/extraction/veristc
SVM=vm/svm
SRC=tests/st-examples/feature-probes
S=tests/veristc-tests/out/probes
G=$SRC/golden

[ -x "$V" ] || { echo "veristc 未构建：先执行 make veristc" >&2; exit 2; }
[ -x "$SVM" ] || { echo "svm 未构建：先执行 make svm" >&2; exit 2; }
mkdir -p "$S"

PROBES=(
  "p01_case|p01|7|pass"
  "p02_for|p02|1|pass"
  "p03_while_repeat|p03|1|pass"
  "p04_div_mod|p04|2|pass"
  "p05_xor_bits|p05|2|pass"
  "p06_latch_state|p06|8|pass"
  "p07_real_arith|p07|1|xfail"
  "p08_lint_arith|p08|1|xfail"
  "p09_array_ops|p09|1|xfail"
  "p10_quality_ops|p10|1|xfail"
  "p11_nested_fn|p11|2|pass"
  "p12_divzero_trap|p12|5|trap"
)

np=0; nx=0; nf=0
for entry in "${PROBES[@]}"; do
  IFS='|' read -r name tag cycles status <<< "$entry"
  out="$S/$name.sasm"
  if ! "$V" -c "$SRC/$name.st" -o "$out" >/dev/null 2>&1; then
    if [ "$status" = xfail ]; then
      echo "XFAIL-C  $name  (编译期拒绝——记录中的前端/类型缺口)"
      nx=$((nx+1)); continue
    fi
    echo "FAIL      $name  编译失败"; nf=$((nf+1)); continue
  fi
  raw=/tmp/vp-$name.raw
  "$SVM" -n "$cycles" -p 0 "$out" > "$raw" 2>&1
  rc=$?
  if [ "$status" = trap ]; then
    if [ "$rc" = 0 ]; then
      echo "FAIL      $name  期望运行时陷阱但正常退出"; nf=$((nf+1)); continue
    fi
    rc=0
  elif [ "$rc" != 0 ]; then
    if [ "$status" = xfail ]; then
      echo "XFAIL-R  $name  (VM 运行期拒绝 rc=$rc)"; nx=$((nx+1)); continue
    fi
    echo "FAIL      $name  VM 异常退出 rc=$rc"; nf=$((nf+1)); continue
  fi
  grep "^$tag " "$raw" > /tmp/vp-$name.actual || true
  if diff -u "$G/$name.out" /tmp/vp-$name.actual > /tmp/vp-$name.diff 2>&1; then
    case "$status" in
      pass|trap) echo "PASS      $name"; np=$((np+1)) ;;
      xfail)     echo "RESOLVED  $name  ← spec 行为已达成：请升级为 pass 并复核 golden"
                 nf=$((nf+1)) ;;
    esac
  else
    case "$status" in
      pass|trap) echo "FAIL      $name  输出与 golden 不符（$(head -3 /tmp/vp-$name.diff | tail -1)）"
                 cat /tmp/vp-$name.diff | sed -n '4,14p'
                 nf=$((nf+1)) ;;
      xfail)     echo "XFAIL-R  $name  (输出偏离 spec 期望——后端缺口仍在)"; nx=$((nx+1)) ;;
    esac
  fi
done

echo "----"
echo "probes: PASS=$np XFAIL=$nx FAIL=$nf"

# Map to framework counters for check_failures
_TF_PASS=$np
_TF_FAIL=$nf
check_failures "SafeST Feature Probes"
