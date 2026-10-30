#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

. "$ROOT/integration/test_framework.sh"

test_begin "VM/SVM Checks"

V=./build/bin/veristc

make build-vm-test build-io-test build-hs-test \
     build-dlwire-test build-dlswitch-test build-smoke build-function-tests

step "1/10" "minimal VM tests"
assert_ok "VM unit tests" build/bin/test_vm

step "2/10" "I/O mapping unit tests"
assert_ok "I/O mapping tests" build/bin/test_io_mapping

step "3/10" "Hotstandby unit tests"
assert_ok "Hotstandby tests" build/bin/test_hotstandby

step "4/10" "SVM one-cycle, PRINT and CycleCounter"
./build/bin/svm -n 1 -p 0 build/sasm/core_assign.sasm 42 \
    > /tmp/veristc-svm-once.out
assert_contains "/tmp/veristc-svm-once.out" "[cycle_counter] 1" "cycle_counter present"
assert_contains "/tmp/veristc-svm-once.out" "counter=" "counter output"
assert_contains "/tmp/veristc-svm-once.out" " x=" "x variable output"
assert_contains "/tmp/veristc-svm-once.out" "1, " "value 1 output"
assert_contains "/tmp/veristc-svm-once.out" "42, " "value 42 output"

# REAL literal reaches the runtime station: the single-precision pattern the
# compiler writes for F32_CONST is what the interpreter keeps in the local slot,
# and `svm <sasm> <expected> <local>` compares them as raw int32 bit patterns.
# 1069547520 = 0x3FC00000 = 1.5f (local 0),
# 1232348160 = 0x49742400 = 1000000.0f (local 6).
"$V" -c veri-stc/tests/compiler-tests/positive/real_literals.st \
    -o /tmp/veristc-real-chain.sasm > /tmp/veristc-real-chain.out
assert_exit_code 0 "REAL literal 1.5 stored as 0x3FC00000" \
    ./build/bin/svm -n 1 -p 0 /tmp/veristc-real-chain.sasm 1069547520 0
assert_exit_code 0 "REAL literal 1.0e6 stored as 0x49742400" \
    ./build/bin/svm -n 1 -p 0 /tmp/veristc-real-chain.sasm 1232348160 6

step "5/10" "full FUNCTION control flow, nested CALL and safety gates"
./build/bin/svm -n 6 -p 0 build/sasm/function_control_flow.sasm \
    > /tmp/veristc-function.out
assert_contains "/tmp/veristc-function.out" "tick=1,  y=2," "tick=1 output"
assert_contains "/tmp/veristc-function.out" "tick=4,  y=5," "tick=4 output"
assert_contains "/tmp/veristc-function.out" "tick=6,  y=5," "tick=6 output"

# impure FUNCTION rejection
if "$V" -c veri-stc/tests/st-examples/function_impure.st \
    -o /tmp/veristc-function-impure.sasm \
    > /tmp/veristc-function-impure.out 2>&1; then
    echo "  impure FUNCTION rejection ... FAIL (compiler accepted it)"
    _TF_FAIL=$((_TF_FAIL + 1))
else
    assert_contains "/tmp/veristc-function-impure.out" "purity violation" "impure FUNCTION error message"
fi

# recursive FUNCTION rejection
if "$V" -c veri-stc/tests/st-examples/function_recursive.st \
    -o /tmp/veristc-function-recursive.sasm \
    > /tmp/veristc-function-recursive.out 2>&1; then
    echo "  recursive FUNCTION rejection ... FAIL (compiler accepted it)"
    _TF_FAIL=$((_TF_FAIL + 1))
else
    assert_contains "/tmp/veristc-function-recursive.out" "recursive calls are not supported" "recursive FUNCTION error message"
fi

# FUNCTION with loop (should compile and run)
"$V" -c veri-stc/tests/st-examples/function_loop.st \
    -o /tmp/veristc-function-loop.sasm \
    > /tmp/veristc-function-loop.out
./build/bin/svm -n 1 -p 0 /tmp/veristc-function-loop.sasm \
    > /tmp/veristc-function-loop-run.out
assert_contains "/tmp/veristc-function-loop-run.out" "y=11," "FUNCTION loop result"

# FUNCTION with local initializer (should compile and run)
"$V" -c veri-stc/tests/st-examples/function_local_initializer.st \
    -o /tmp/veristc-function-local-initializer.sasm \
    > /tmp/veristc-function-local-initializer.out
./build/bin/svm -n 1 -p 0 /tmp/veristc-function-local-initializer.sasm \
    > /tmp/veristc-function-local-initializer-run.out
assert_contains "/tmp/veristc-function-local-initializer-run.out" "y=11," "FUNCTION local initializer result"

# WHILE inside FUNCTION rejection
if "$V" -c veri-stc/tests/st-examples/function_while.st \
    -o /tmp/veristc-function-while.sasm \
    > /tmp/veristc-function-while.out 2>&1; then
    echo "  WHILE in FUNCTION rejection ... FAIL (compiler accepted it)"
    _TF_FAIL=$((_TF_FAIL + 1))
else
    assert_contains "/tmp/veristc-function-while.out" "unsupported control flow" "WHILE in FUNCTION error message"
fi

# 原生 FUNCTION_BLOCK 多实体：库逻辑一份 + 每实例 self 相对独立上下文
# （不经前端文本预处理器展开，直接由 veristc 编译）
"$V" -c veri-stc/tests/st-examples/native_fb_multi_instance.st \
    -o /tmp/native_fb.sasm > /tmp/native_fb_compile.out 2>&1
assert_contains "/tmp/native_fb_compile.out" "compiled:" "native FB compile OK"
./build/bin/svm -n 8 -p 0 /tmp/native_fb.sasm > /tmp/native_fb_run.out
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

# v1.5 VAR_IN_OUT 逐引用别名：端口编译为"调用方存储的地址"形参，
# 体内读写走 I32_LOAD_PTR / I32_STORE_PTR ⇒ 两实例共享同一 shared，
# 且同周期双向可见（调用方写→被调读得到；被调写→调用方立即读到）
"$V" -c veri-stc/tests/st-examples/native_fb_in_out.st \
    -o /tmp/native_fb_inout.sasm > /tmp/native_fb_inout_compile.out 2>&1
assert_contains "/tmp/native_fb_inout_compile.out" "compiled:" "native FB VAR_IN_OUT compile OK"
./build/bin/svm -d /tmp/native_fb_inout.sasm > /tmp/native_fb_inout_dump.out
assert_contains "/tmp/native_fb_inout_dump.out" "I32_LOAD_PTR" "VAR_IN_OUT alias load emitted"
assert_contains "/tmp/native_fb_inout_dump.out" "I32_STORE_PTR" "VAR_IN_OUT alias store emitted"
./build/bin/svm -n 4 -p 0 /tmp/native_fb_inout.sasm > /tmp/native_fb_inout_run.out
# t: shared=t; a1(ACC=&shared,K=10)  -> LAST=t,   shared=t+10
#    a2(ACC=&shared,K=100)           -> LAST=t+10, shared=t+110
# ⇒ 单点累加(111) 证明别名；LAST 不同(1/11) 证明实例数据仍分离
assert_contains "/tmp/native_fb_inout_run.out" "tick1, 111, 1, 11," "VAR_IN_OUT alias shared @cycle1"
assert_contains "/tmp/native_fb_inout_run.out" "tick2, 112, 2, 12," "VAR_IN_OUT alias shared @cycle2"
assert_contains "/tmp/native_fb_inout_run.out" "tick4, 114, 4, 14," "VAR_IN_OUT alias shared @cycle4"

# VAR_IN_OUT 非法绑定必须拒绝（局部无地址 / 表达式无地址 / 未绑定 /
# 类型或宽度不符 / 端口名不在声明中）
for neg in in_out_local in_out_expr in_out_unbound in_out_type in_out_unknown_port; do
    if "$V" -c "veri-stc/tests/compiler-tests/negative/${neg}.st" \
        -o "/tmp/veristc-inout-${neg}.sasm" \
        > "/tmp/veristc-inout-${neg}.out" 2>&1; then
        echo "  VAR_IN_OUT ${neg} rejection ... FAIL (compiler accepted it)"
        _TF_FAIL=$((_TF_FAIL + 1))
    else
        echo "  VAR_IN_OUT ${neg} rejection ... OK"
        _TF_PASS=$((_TF_PASS + 1))
    fi
done

# 派生名分隔符 '#' 不在标识符文法内 ⇒ 用户写不出 a1#Q，静态冲突只剩下
# "expand_instances 自身产出重名"这一条路径：同一 FB 的两个可写字段重名
# （VAR_OUTPUT Q 与实例状态 VAR Q）⇒ 两条 a1#Q 声明落到同一全局槽位。
# 展开前的重复名检查看不到派生名，故 GATE-1 必须在 prepare_program 后再跑
# 一次，并让诊断报出冲突的名字。
if "$V" -c veri-stc/tests/compiler-tests/negative/name_collision_expanded.st \
    -o /tmp/veristc-name-collision.sasm \
    > /tmp/veristc-name-collision.out 2>&1; then
    echo "  instance-field name collision rejection ... FAIL (compiler accepted it)"
    _TF_FAIL=$((_TF_FAIL + 1))
else
    echo "  instance-field name collision rejection ... OK"
    _TF_PASS=$((_TF_PASS + 1))
fi
assert_contains /tmp/veristc-name-collision.out "'a1#Q'" \
    "collision diagnostic names the offending declaration"

# 封装规则（KIND=access）：qualified 访问 inst.field 体外只允许**读**
# VAR_OUTPUT；读/写 FB 内部 VAR、体外写 VAR_OUTPUT 一律 KIND=access 拒绝。
# （VAR_INPUT / VAR_IN_OUT 不生成派生全局，走下面的 KIND=type 路径。）
# 违规诊断带 VAR=<派生名> 定位。
for neg in qualified_internal_read qualified_output_write; do
    if "$V" -c "veri-stc/tests/compiler-tests/negative/${neg}.st" \
        -o "/tmp/veristc-access-${neg}.sasm" \
        > "/tmp/veristc-access-${neg}.out" 2>&1; then
        echo "  access rule ${neg} rejection ... FAIL (compiler accepted it)"
        _TF_FAIL=$((_TF_FAIL + 1))
    else
        echo "  access rule ${neg} rejection ... OK"
        _TF_PASS=$((_TF_PASS + 1))
    fi
    assert_contains "/tmp/veristc-access-${neg}.out" "KIND=access" \
        "access rule ${neg} diagnostic is marked KIND=access"
done
assert_contains /tmp/veristc-access-qualified_internal_read.out "VAR=a1#C" \
    "internal-state leak names the hidden field"
assert_contains /tmp/veristc-access-qualified_output_write.out "VAR=a1#Q" \
    "output write-back violation names the field"

# 方向表另一行（spec 6.5.1）：VAR_INPUT / VAR_IN_OUT 根本不生成派生全局，
# 体外用点号引用它们 = 引用不存在的名，由类型检查阶段以 KIND=type 拒绝。
# 该路径的诊断不指认名字（通用类型错误，无 VAR=），这是已知精度取舍。
for neg in qualified_input_read qualified_in_out_read; do
    if "$V" -c "veri-stc/tests/compiler-tests/negative/${neg}.st" \
        -o "/tmp/veristc-port-ref-${neg}.sasm" \
        > "/tmp/veristc-port-ref-${neg}.out" 2>&1; then
        echo "  port field reference ${neg} rejection ... FAIL (compiler accepted it)"
        _TF_FAIL=$((_TF_FAIL + 1))
    else
        echo "  port field reference ${neg} rejection ... OK"
        _TF_PASS=$((_TF_PASS + 1))
    fi
    assert_contains "/tmp/veristc-port-ref-${neg}.out" "KIND=type" \
        "port field reference ${neg} is rejected as a type/undeclared-name error"
done

# 点号访问与扁平全局分离：l1.Q（融合为派生名 l1#Q）与用户声明的普通
# 全局 l1_Q 可以同时存在且各自独立演化 ⇒ 派生名不可书写确实消除了别名
"$V" -c veri-stc/tests/st-examples/qualified_access_field.st \
    -o /tmp/qaf.sasm > /tmp/qaf_compile.out 2>&1
assert_contains "/tmp/qaf_compile.out" "compiled:" "qualified access compile OK"
./build/bin/svm -n 4 -p 0 /tmp/qaf.sasm > /tmp/qaf_run.out
# t: l1_Q = 100t（用户全局）；l1.Q = t+1（实例输出）
assert_contains "/tmp/qaf_run.out" "tick1, 100, 2," "qualified access @cycle1 separates names"
assert_contains "/tmp/qaf_run.out" "tick2, 200, 3," "qualified access @cycle2 separates names"
assert_contains "/tmp/qaf_run.out" "tick4, 400, 5," "qualified access @cycle4 separates names"

# 字面 '#' 不可书写：派生名只能由编译器产生，用户手写 a1#Q 在词法即报错
if "$V" -c veri-stc/tests/compiler-tests/negative/literal_derived_name.st \
    -o /tmp/veristc-literal-derived.sasm \
    > /tmp/veristc-literal-derived.out 2>&1; then
    echo "  literal derived name rejection ... FAIL (compiler accepted it)"
    _TF_FAIL=$((_TF_FAIL + 1))
else
    echo "  literal derived name rejection ... OK"
    _TF_PASS=$((_TF_PASS + 1))
fi
assert_contains /tmp/veristc-literal-derived.out "lexer failed" \
    "literal derived name is rejected at the lexer (unwritable by design)"

# P2 可重定位对象 .svobj：编译器导出跨模块链接元数据 + 主机侧结构/CRC round-trip
"$V" -g veri-stc/tests/st-examples/native_fb_multi_instance.st \
    -o /tmp/native_fb.svobj > /tmp/native_fb_svobj.out 2>&1
assert_contains "/tmp/native_fb_svobj.out" "emitted:" "svobj emit OK"
"$V" -x /tmp/native_fb.svobj > /tmp/native_fb_svobj_verify.out 2>&1
assert_contains "/tmp/native_fb_svobj_verify.out" "svobj OK:" "svobj verify OK"
# 预期链接元数据：符号=RS_V1+rs1+rs2(3)；重定位=2 CALL_IDX+2 INST_BASE_IMM(4)；数据块=rs1,rs2(2)
assert_contains "/tmp/native_fb_svobj_verify.out" "syms=3" "svobj symtab count"
assert_contains "/tmp/native_fb_svobj_verify.out" "relocs=4" "svobj reloc count"
assert_contains "/tmp/native_fb_svobj_verify.out" "blocks=2" "svobj data block count"
# 无 VAR_IN_OUT ⇒ 不得产出 GLOBAL_OFF 行
assert_contains "/tmp/native_fb_svobj_verify.out" "global=0)" "svobj no GLOBAL_OFF without IN_OUT"
# v1.5 VAR_IN_OUT ⇒ 每个别名实参地址立即数产出一条 GLOBAL_OFF（指向 GLOBAL_EXT 符号）
# 预期：a1/a2 两次调用 ⇒ 2 CALL_IDX + 2 INST_BASE_IMM + 2 GLOBAL_OFF(shared)=6；
#       符号 = ACCUM(FB_EXEC) + a1 + a2(INST_DATA) + shared(GLOBAL_EXT) = 4
"$V" -g veri-stc/tests/st-examples/native_fb_in_out.st \
    -o /tmp/native_fb_inout.svobj > /tmp/native_fb_inout_svobj.out 2>&1
assert_contains "/tmp/native_fb_inout_svobj.out" "emitted:" "svobj (IN_OUT) emit OK"
"$V" -x /tmp/native_fb_inout.svobj > /tmp/native_fb_inout_svobj_verify.out 2>&1
assert_contains "/tmp/native_fb_inout_svobj_verify.out" "svobj OK:" "svobj (IN_OUT) verify OK"
assert_contains "/tmp/native_fb_inout_svobj_verify.out" "relocs=6" "svobj (IN_OUT) reloc count"
assert_contains "/tmp/native_fb_inout_svobj_verify.out" "syms=4" "svobj (IN_OUT) symtab count"
assert_contains "/tmp/native_fb_inout_svobj_verify.out" "global=2)" "svobj (IN_OUT) GLOBAL_OFF rows"
# 跨实例字段别名：实参地址等于实例基址，必须按别名而非基址处理
"$V" -g veri-stc/tests/compiler-tests/positive/in_out_alias_field.st \
    -o /tmp/in_out_alias_field.svobj > /tmp/in_out_alias_field_svobj.out 2>&1
assert_contains "/tmp/in_out_alias_field_svobj.out" "emitted:" "svobj (alias field) emit OK"
"$V" -x /tmp/in_out_alias_field.svobj > /tmp/in_out_alias_field_verify.out 2>&1
assert_contains "/tmp/in_out_alias_field_verify.out" "relocs=6 (call=2 inst=2 global=2)" \
    "svobj (alias field) base/alias not confused"
# 篡改 section 长度字段 → 结构/CRC 校验必须拒绝
cp /tmp/native_fb.svobj /tmp/native_fb_bad.svobj
printf '\xAA' | dd of=/tmp/native_fb_bad.svobj bs=1 seek=20 count=1 conv=notrunc 2>/dev/null
if "$V" -x /tmp/native_fb_bad.svobj >/dev/null 2>&1; then
    echo "  svobj corrupt rejection ... FAIL"; _TF_FAIL=$((_TF_FAIL + 1))
else
    echo "  svobj corrupt rejection ... OK"; _TF_PASS=$((_TF_PASS + 1))
fi

step "6/10" "SVM dump, SIL3, CRC, period and corrupt CRC rejection"
./build/bin/svm -d build/sasm/core_assign.sasm \
    > /tmp/veristc-svm-dump.out
assert_contains "/tmp/veristc-svm-dump.out" "状态:   OK" "dump status OK"
assert_contains "/tmp/veristc-svm-dump.out" "安全等级: SIL3" "SIL3 level"

start="$(date +%s%N)"
./build/bin/svm -n 2 -p 1000 build/sasm/core_assign.sasm 42 \
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

cp build/sasm/core_assign.sasm /tmp/veristc-bad-crc.sasm
size="$(wc -c < /tmp/veristc-bad-crc.sasm)"
printf '\377' | dd of=/tmp/veristc-bad-crc.sasm bs=1 \
    seek="$((size - 5))" count=1 conv=notrunc status=none
if ./build/bin/svm -n 1 -p 0 /tmp/veristc-bad-crc.sasm \
    > /tmp/veristc-bad-crc.out 2>&1; then
    echo "  corrupt CRC rejected ... FAIL (load succeeded)"
    _TF_FAIL=$((_TF_FAIL + 1))
else
    echo "  corrupt CRC rejected ... OK"
    _TF_PASS=$((_TF_PASS + 1))
fi
assert_contains "/tmp/veristc-bad-crc.out" "sasm_load failed: -2" "CRC error code correct"

# 全零 CRC 尾部（旧的"未计算即放行"后门）同样必须拒绝
cp build/sasm/core_assign.sasm /tmp/veristc-zero-crc.sasm
size="$(wc -c < /tmp/veristc-zero-crc.sasm)"
printf '\0\0\0\0' | dd of=/tmp/veristc-zero-crc.sasm bs=1 \
    seek="$((size - 4))" count=4 conv=notrunc status=none
if ./build/bin/svm -n 1 -p 0 /tmp/veristc-zero-crc.sasm \
    > /tmp/veristc-zero-crc.out 2>&1; then
    echo "  uncomputed (zero) CRC rejected ... FAIL (load succeeded)"
    _TF_FAIL=$((_TF_FAIL + 1))
else
    echo "  uncomputed (zero) CRC rejected ... OK"
    _TF_PASS=$((_TF_PASS + 1))
fi
assert_contains "/tmp/veristc-zero-crc.out" "sasm_load failed: -2" "zero CRC error code correct"

step "7/10" "Debug symbol table (section 7, spec 4.8)"
SYM_ST=veri-stc/tests/st-examples/algo_blocks_fb.st
SYM_SASM=build/sasm/algo_blocks_fb.sasm
"$V" -c "$SYM_ST" -o /tmp/veristc-sym-a.sasm > /dev/null 2>&1
"$V" -c "$SYM_ST" -o /tmp/veristc-sym-b.sasm > /dev/null 2>&1
assert_ok "symbol section is byte-deterministic" \
    cmp -s /tmp/veristc-sym-a.sasm /tmp/veristc-sym-b.sasm

./build/bin/svm -s 'pid1#U' "$SYM_SASM" > /tmp/veristc-sym-u.out 2>&1
assert_contains "/tmp/veristc-sym-u.out" "pid1#U 0x" \
    "derived instance field resolves to an address"
assert_contains "/tmp/veristc-sym-u.out" "DINT size=4" "symbol carries its IEC type"
assert_fail "unknown symbol is rejected" \
    ./build/bin/svm -s no_such_symbol "$SYM_SASM"

# The reported address must be a real global slot: inside [GLOBAL_BASE, memory).
addr_hex="$(sed -n 's/^pid1#U 0x\([0-9A-Fa-f]*\) .*$/\1/p' /tmp/veristc-sym-u.out)"
addr="$(( 16#${addr_hex:-0} ))"
total_mem="$(./build/bin/svm -i "$SYM_SASM" |
    sed -n 's/.*Memory:[[:space:]]*\([0-9]*\) bytes total.*/\1/p')"
if [ "$addr" -ge 4096 ] && [ "$addr" -lt "${total_mem:-0}" ]; then
    echo "  address $addr inside [$((4096)), ${total_mem}) ... OK"
    _TF_PASS=$((_TF_PASS + 1))
else
    echo "  address $addr inside [4096, ${total_mem}) ... FAIL"
    _TF_FAIL=$((_TF_FAIL + 1))
fi

# -l and -i must agree on the symbol count, and instance fields must be listed.
n_list="$(./build/bin/svm -l "$SYM_SASM" | wc -l)"
n_info="$(./build/bin/svm -i "$SYM_SASM" |
    sed -n 's/.*Symbols:[[:space:]]*\([0-9]*\).*/\1/p')"
n_field="$(./build/bin/svm -l "$SYM_SASM" | grep -c '#')"
if [ "$n_list" -gt 0 ] && [ "$n_list" = "$n_info" ] && [ "$n_field" -gt 0 ]; then
    echo "  symbol listing (${n_list} rows, ${n_field} fields) matches info" \
        "... OK"
    _TF_PASS=$((_TF_PASS + 1))
else
    echo "  symbol listing (list=${n_list} info=${n_info} fields=${n_field})" \
        "... FAIL"
    _TF_FAIL=$((_TF_FAIL + 1))
fi

step "8/10" "IOMAP calibration: scale/bias read from the file, not hardcoded"
make build-io-cal > /dev/null
./build/bin/svm -m build/sasm/io_cal.sasm > /tmp/veristc-iomap-id.out 2>&1
assert_contains "/tmp/veristc-iomap-id.out" "I/O map (loaded): 2 channels" \
    "both mappings reach the runtime table"
assert_contains "/tmp/veristc-iomap-id.out" "scale=1 bias=0" \
    "compiler identity calibration survives the loader"

# 单一地址真值：IOMAP 的 mem_offset 必须是该全局变量在符号段里的真实槽位
# 地址。两侧编号曾经不同源（映射用 1024 起的私有编号，变量用 4096 起的全局
# 槽），运行站写进去的位置和程序读写的变量不是同一块内存。
./build/bin/svm -l build/sasm/io_cal.sasm > /tmp/veristc-iomap-sym.out 2>&1
iomap_offsets=$(sed -n 's/.*mem=\(0x[0-9A-Fa-f]*\).*/\1/p' /tmp/veristc-iomap-id.out \
                | tr 'A-F' 'a-f' | sort -u)
sym_offsets=$(awk '{print $2}' /tmp/veristc-iomap-sym.out | tr 'A-F' 'a-f' | sort -u)
orphan=$(comm -23 <(echo "$iomap_offsets") <(echo "$sym_offsets") | tr -d '[:space:]')
if [ -z "$orphan" ]; then
    echo "  every mapped address names a declared global slot ... OK"
    _TF_PASS=$((_TF_PASS + 1))
else
    echo "  every mapped address names a declared global slot ... FAIL (orphan: $orphan)"
    _TF_FAIL=$((_TF_FAIL + 1))
fi

if command -v python3 > /dev/null 2>&1; then
python3 - build/sasm/io_cal.sasm \
    /tmp/veristc-iomap-cal.sasm /tmp/veristc-iomap-nan.sasm <<'PY'
import struct, sys, zlib
src, cal_out, nan_out = sys.argv[1], sys.argv[2], sys.argv[3]
d = bytearray(open(src, 'rb').read())

# locate the IOMAP section body (8-byte header, then u32 count, 42-byte entries)
off, end, body = 6, len(d) - 4, None
while off + 8 <= end:
    sec, ln = d[off], struct.unpack_from('<I', d, off + 1)[0]
    if sec == 3:
        body = off + 8
        break
    off += 8 + ln
assert body is not None, "IOMAP section missing"
first = body + 4

def seal(buf):
    struct.pack_into('<I', buf, len(buf) - 4, zlib.crc32(bytes(buf[6:len(buf) - 4])) & 0xffffffff)
    return bytes(buf)

cal = bytearray(d)
struct.pack_into('<dd', cal, first + 18, 0.5, 100.0)
struct.pack_into('<dd', cal, first + 42 + 18, -2.0, 3.25)
open(cal_out, 'wb').write(seal(cal))

nan = bytearray(d)
struct.pack_into('<Q', nan, first + 18, 0x7FF8000000000000)
open(nan_out, 'wb').write(seal(nan))
PY
    ./build/bin/svm -m /tmp/veristc-iomap-cal.sasm > /tmp/veristc-iomap-cal.out 2>&1
    assert_contains "/tmp/veristc-iomap-cal.out" "scale=0.5 bias=100" \
        "channel 0 calibration comes from the file bytes"
    assert_contains "/tmp/veristc-iomap-cal.out" "scale=-2 bias=3.25" \
        "channel 1 calibration is read independently"
    assert_fail "non-finite scale is rejected" \
        ./build/bin/svm -m /tmp/veristc-iomap-nan.sasm
    ./build/bin/svm -m /tmp/veristc-iomap-nan.sasm \
        > /tmp/veristc-iomap-nan.out 2>&1 || true
    assert_contains "/tmp/veristc-iomap-nan.out" "sasm_load failed: -1" \
        "NaN rejection reports the loader error code"
else
    skip "python3 missing: scale/bias fixture editing skipped (4 checks)"
fi

step "9/10" "Download wire protocol (frames, HMAC-SHA256, receiver state machine)"
if ./build/bin/test_download_wire > /tmp/veristc-dlwire.out 2>&1; then
    assert_contains "/tmp/veristc-dlwire.out" "sha256 matches FIPS vectors" \
        "SHA-256 matches published vectors"
    assert_contains "/tmp/veristc-dlwire.out" "hmac-sha256 matches RFC 4231" \
        "HMAC-SHA256 matches RFC 4231 test vectors"
    assert_contains "/tmp/veristc-dlwire.out" "multi-frame image reassembles" \
        "multi-frame image reassembly (incl. byte-drip)"
    assert_contains "/tmp/veristc-dlwire.out" "every malformed frame class is refused" \
        "each malformed-frame class refused at the right step"
    assert_contains "/tmp/veristc-dlwire.out" "sender reports transport failure" \
        "sender reports transport failure instead of dropping frames"
else
    echo "  download wire tests ... ${_TF_C_RED}FAIL${_TF_C_RESET}"
    _TF_FAIL=$((_TF_FAIL + 1))
    cat /tmp/veristc-dlwire.out
fi

step "10/10" "Full-image download: stage, cycle-boundary switch, rollback"
DL_A=build/sasm/core_assign.sasm
DL_B=build/sasm/algo_blocks_fb.sasm
if ./build/bin/test_download_switch "$DL_A" "$DL_B" \
    > /tmp/veristc-dlswitch.out 2>&1; then
    assert_contains "/tmp/veristc-dlswitch.out" "cold load" \
        "initial image loads and runs"
    assert_contains "/tmp/veristc-dlswitch.out" "takes effect at the cycle boundary" \
        "switch applies at the cycle boundary with cold-start state"
    assert_contains "/tmp/veristc-dlswitch.out" "rollback returns to the previous slot" \
        "rollback returns to the previous slot, one level only"
    assert_contains "/tmp/veristc-dlswitch.out" "never touch the active slot" \
        "corrupt / oversize / zero-CRC images never touch the active slot"
    assert_contains "/tmp/veristc-dlswitch.out" "reassemble into an image the VM actually runs" \
        "frames reassemble into an image the VM actually runs"
    assert_contains "/tmp/veristc-dlswitch.out" "never reaches the download layer" \
        "a tampered frame is refused before the download layer"
else
    echo "  full-image download switch tests ... ${_TF_C_RED}FAIL${_TF_C_RESET}"
    _TF_FAIL=$((_TF_FAIL + 1))
    cat /tmp/veristc-dlswitch.out
fi

check_failures "VM/SVM checks (period ${elapsed_ms}ms)"
