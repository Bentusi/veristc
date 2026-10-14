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

# 原生 FUNCTION_BLOCK 多实体：库逻辑一份 + 每实例 self 相对独立上下文
# （不经前端文本预处理器展开，直接由 veristc 编译）
"$V" -c tests/st-examples/native_fb_multi_instance.st \
    -o /tmp/native_fb.sasm > /tmp/native_fb_compile.out 2>&1
assert_contains "/tmp/native_fb_compile.out" "compiled:" "native FB compile OK"
./vm/svm -n 8 -p 0 /tmp/native_fb.sasm > /tmp/native_fb_run.out
# rs1: S@2 R@6 -> 周期2 置位; rs2: S@4 R@8 -> 周期4 置位
grep -q "tick2, 1, 0," /tmp/native_fb_run.out \
    && { echo "  native FB rs1 set / rs2 idle @cycle2 ... OK"; _TF_PASS=$((_TF_PASS + 1)); } \
    || { echo "  native FB rs1 set / rs2 idle @cycle2 ... FAIL"; _TF_FAIL=$((_TF_FAIL + 1)); }
grep -q "tick4, 1, 1," /tmp/native_fb_run.out \
    && { echo "  native FB both instances set @cycle4 ... OK"; _TF_PASS=$((_TF_PASS + 1)); } \
    || { echo "  native FB both instances set @cycle4 ... FAIL"; _TF_FAIL=$((_TF_FAIL + 1)); }
grep -q "tick6, 0, 1," /tmp/native_fb_run.out \
    && { echo "  native FB rs1 reset / rs2 held @cycle6 ... OK"; _TF_PASS=$((_TF_PASS + 1)); } \
    || { echo "  native FB rs1 reset / rs2 held @cycle6 ... FAIL"; _TF_FAIL=$((_TF_FAIL + 1)); }
grep -q "tick8, 0, 0," /tmp/native_fb_run.out \
    && { echo "  native FB rs2 reset @cycle8 ... OK"; _TF_PASS=$((_TF_PASS + 1)); } \
    || { echo "  native FB rs2 reset @cycle8 ... FAIL"; _TF_FAIL=$((_TF_FAIL + 1)); }

# P2 可重定位对象 .svobj：编译器导出跨模块链接元数据 + 主机侧结构/CRC round-trip
"$V" -g tests/st-examples/native_fb_multi_instance.st \
    -o /tmp/native_fb.svobj > /tmp/native_fb_svobj.out 2>&1
assert_contains "/tmp/native_fb_svobj.out" "emitted:" "svobj emit OK"
"$V" -x /tmp/native_fb.svobj > /tmp/native_fb_svobj_verify.out 2>&1
assert_contains "/tmp/native_fb_svobj_verify.out" "svobj OK:" "svobj verify OK"
# 预期链接元数据：符号=RS_V1+rs1+rs2(3)；重定位=2 CALL_IDX+2 INST_BASE_IMM(4)；数据块=rs1,rs2(2)
assert_contains "/tmp/native_fb_svobj_verify.out" "syms=3" "svobj symtab count"
assert_contains "/tmp/native_fb_svobj_verify.out" "relocs=4" "svobj reloc count"
assert_contains "/tmp/native_fb_svobj_verify.out" "blocks=2" "svobj data block count"
# 篡改 section 长度字段 → 结构/CRC 校验必须拒绝
cp /tmp/native_fb.svobj /tmp/native_fb_bad.svobj
printf '\xAA' | dd of=/tmp/native_fb_bad.svobj bs=1 seek=20 count=1 conv=notrunc 2>/dev/null
if "$V" -x /tmp/native_fb_bad.svobj >/dev/null 2>&1; then
    echo "  svobj corrupt rejection ... FAIL"; _TF_FAIL=$((_TF_FAIL + 1))
else
    echo "  svobj corrupt rejection ... OK"; _TF_PASS=$((_TF_PASS + 1))
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
