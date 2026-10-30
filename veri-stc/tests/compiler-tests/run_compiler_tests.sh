#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT/../../.."

. integration/test_framework.sh

V=build/bin/veristc

test_begin "Compiler Tests"

# Check prerequisites
if [ ! -x "$V" ]; then
    echo "veristc not built, skipping" >&2
    exit 0
fi

step "1/3" "Negative tests (must be rejected)"
np=0; nf=0
for f in veri-stc/tests/compiler-tests/negative/*.st; do
    name="$(basename "$f" .st)"
    if ! "$V" -c "$f" -o "/tmp/veristc-neg-${name}.sasm" > "/tmp/veristc-neg-${name}.out" 2>&1; then
        echo "  reject $name ... OK"
        np=$((np+1))
    else
        echo "  reject $name ... FAIL (compiler accepted invalid program)"
        nf=$((nf+1))
    fi
done

step "2/3" "Positive tests (must be accepted)"
for f in veri-stc/tests/compiler-tests/positive/*.st; do
    name="$(basename "$f" .st)"
    if "$V" -c "$f" -o "/tmp/veristc-pos-${name}.sasm" > "/tmp/veristc-pos-${name}.out" 2>&1; then
        echo "  accept $name ... OK"
        np=$((np+1))
    else
        echo "  accept $name ... FAIL (compiler rejected valid program)"
        cat "/tmp/veristc-pos-${name}.out" | head -5
        nf=$((nf+1))
    fi
done

step "3/3" "Machine-readable CLI (G0 产出物 1)"

CLI=veri-stc/tests/compiler-tests/cli/two_access_violations.st
SYN=veri-stc/tests/compiler-tests/negative/syntax_error.st
ACT_TEXT=/tmp/veristc-cli-text.out
ACT_JSON=/tmp/veristc-cli-json.jsonl

# 结果计入既有 accepted/failed 汇总，CLI 断言失败同样使本组测试 FAIL
cli_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  $desc ... OK"
        np=$((np + 1))
    else
        echo "  $desc ... FAIL (expected [$expected] got [$actual])"
        nf=$((nf + 1))
    fi
}

cli_rc() {
    local desc="$1" expected="$2"; shift 2
    local rc=0
    "$@" >/dev/null 2>&1 || rc=$?
    cli_eq "$desc (exit=$expected)" "$expected" "$rc"
}

"$V" -c "$CLI" -o /tmp/veristc-cli-text.sasm > "$ACT_TEXT" 2>&1
rc_text=$?
"$V" --json -c "$CLI" -o /tmp/veristc-cli-json.sasm > "$ACT_JSON" 2>&1
rc_json=$?

# 文本协议冻结：POU=/VAR=/KIND=/LOC=-/MSG= 整行逐字不变；--json 是同一
# 诊断的另一份可机读副本，不是替代。
cli_eq "text diagnostic line is byte-identical" \
    "POU=MAIN VAR=a1#C KIND=access LOC=- MSG=instance internal state (VAR) is not visible outside its FUNCTION_BLOCK" \
    "$(cat "$ACT_TEXT")"
cli_eq "both modes reject with the same exit code" "22" "$rc_text"
cli_eq "--json exit code matches text mode" "22" "$rc_json"
cli_eq "--json emits every diagnostic (2)" "2" "$(wc -l < "$ACT_JSON" | tr -d ' ')"
cli_eq "--json first row matches the text row" \
    '{"pou":"MAIN","var":"a1#C","kind":"access","loc":"POU=MAIN VAR=a1#C","msg":"instance internal state (VAR) is not visible outside its FUNCTION_BLOCK"}' \
    "$(head -1 "$ACT_JSON")"
cli_eq "--json second row reports the write violation" \
    '{"pou":"MAIN","var":"a1#Q","kind":"access","loc":"POU=MAIN VAR=a1#Q","msg":"instance field is read-only (or invisible) outside its FUNCTION_BLOCK"}' \
    "$(sed -n '2p' "$ACT_JSON")"

if command -v python3 >/dev/null 2>&1; then
    if python3 -c 'import json,sys
[json.loads(l) for l in open(sys.argv[1]) if l.strip()]' "$ACT_JSON" 2>/dev/null; then
        echo "  --json output parses as NDJSON ... OK"
        np=$((np + 1))
    else
        echo "  --json output parses as NDJSON ... FAIL"
        nf=$((nf + 1))
    fi
else
    echo "  --json output parses as NDJSON ... SKIP (no python3)"
fi

# 退出码约定（见 spec/safest-spec.md 工具链节）
cli_rc "missing -o on -c"           11 "$V" -c veri-stc/tests/st-examples/core_assign.st
cli_rc "unknown option"             11 "$V" -qq veri-stc/tests/st-examples/core_assign.st
cli_rc "missing input file"         11 "$V" -c /tmp/veristc-no-such-file.st -o /tmp/veristc-cli-x.sasm
cli_rc "lexical/syntax failure"     21 "$V" -c "$SYN" -o /tmp/veristc-cli-x.sasm
cli_rc "semantic diagnostic"        22 "$V" -c veri-stc/tests/compiler-tests/negative/qualified_internal_read.st -o /tmp/veristc-cli-x.sasm
cli_rc "unwritable artifact path"   24 "$V" -c veri-stc/tests/st-examples/core_assign.st -o /tmp/veristc-no-such-dir/x.sasm
cli_rc "successful compile"          0 "$V" -c veri-stc/tests/st-examples/core_assign.st -o /tmp/veristc-cli-x.sasm

"$V" -c "$SYN" -o /tmp/veristc-cli-x.sasm > /tmp/veristc-cli-syn-text.out 2>&1
"$V" --json -c "$SYN" -o /tmp/veristc-cli-x.sasm > /tmp/veristc-cli-syn.out 2>&1
cli_eq "syntax diagnostic carries line/col" "ok" \
    "$(if grep -Fq '"kind":"syntax"' /tmp/veristc-cli-syn.out \
           && grep -Eq '"line":[0-9]+,"col":[0-9]+' /tmp/veristc-cli-syn.out; \
        then echo ok; else echo bad; fi)"
cli_eq "syntax msg matches the text-mode line" \
    "$(cat /tmp/veristc-cli-syn-text.out)" \
    "$(sed -n 's/.*"msg":"\([^"]*\)".*/\1/p' /tmp/veristc-cli-syn.out)"

# IOMAP 绑定检查：条目名必须是已声明的全局变量，否则该通道永远填不进
# 程序内存。诊断只用既有 KIND=declaration，不扩词表。
IOMAP_ST=veri-stc/tests/compiler-tests/negative/iomap_unbound_name.st
cli_eq "unbound IOMAP name is rejected" \
    "POU= VAR=ghost KIND=declaration LOC=- MSG=IOMAP entry binds an undeclared global variable" \
    "$("$V" -c "$IOMAP_ST" -o /tmp/veristc-cli-x.sasm 2>&1)"
cli_rc "unbound IOMAP name exits with semantic code" 22 "$V" -c "$IOMAP_ST" -o /tmp/veristc-cli-x.sasm
cli_eq "bound IOMAP entries raise no diagnostic" "" \
    "$("$V" -c veri-stc/tests/st-examples/io_cal.st -o /tmp/veristc-cli-iomap.sasm 2>&1 | grep -F 'KIND=declaration' || true)"

cli_eq "analysis metrics are machine-readable" \
    "ok" \
    "$(if "$V" --json -a veri-stc/tests/st-examples/core_assign.st 2>&1 \
          | grep -Fq '{"kind":"analysis","stack_depth":'; then echo ok; else echo bad; fi)"

# REAL literal truth chain: lexical conversion (lexer.v decimal fast path) ->
# immediate offsets and zero placeholders (encoder.v encode_code_float_rows) ->
# host-side overwrite (veristc_main.ml patch_code_floats). The expected bit
# patterns below were computed independently as IEEE-754 binary32 results.
REAL_ST=veri-stc/tests/compiler-tests/positive/real_literals.st
REAL_SASM=/tmp/veristc-pos-real_literals.sasm
REAL_WIRE=/tmp/veristc-real-wire.out
REAL_EXPECT=/tmp/veristc-real-wire.txt

cat > "$REAL_EXPECT" <<'EXPECT'
f32 3fc00000
f32 3dcccccd
f32 bdcccccd
f32 40490fdb
f32 4b800000
f32 3eaaaaab
f32 49742400
f32 3e800000
f32 bfc00000
f32 33d6bf95
f32 3089705f
f32 42c80000
f32 00000000
f32 c3889333
EXPECT

if command -v python3 >/dev/null 2>&1; then
    cli_rc "REAL literals compile" 0 "$V" -c "$REAL_ST" -o "$REAL_SASM"
    python3 veri-stc/tests/compiler-tests/f32_immediates.py "$REAL_SASM" \
        > "$REAL_WIRE" 2>&1
    cli_eq "REAL literal wire bytes match IEEE-754 binary32" \
        "$(cat "$REAL_EXPECT")" "$(cat "$REAL_WIRE")"
    cli_rc "out-of-range REAL precision is refused" 21 \
        "$V" -c veri-stc/tests/compiler-tests/negative/real_literal_precision.st \
           -o /tmp/veristc-cli-x.sasm
    cli_rc "out-of-range REAL exponent is refused" 21 \
        "$V" -c veri-stc/tests/compiler-tests/negative/real_literal_exponent.st \
           -o /tmp/veristc-cli-x.sasm
else
    echo "  REAL literal wire bytes ... SKIP (no python3)"
fi

# 多租户纪律：-o 缺失即拒绝，绝不回退默认名写进当前工作目录
CLI_CWD="$(mktemp -d)"
( cd "$CLI_CWD" && "$ROOT/../../../build/bin/veristc" \
      -c "$ROOT/../../../veri-stc/tests/st-examples/core_assign.st" >/dev/null 2>&1 )
if [ -z "$(ls -A "$CLI_CWD")" ]; then
    echo "  nothing written to CWD when -o is omitted ... OK"
    np=$((np + 1))
else
    echo "  nothing written to CWD when -o is omitted ... FAIL ($(ls "$CLI_CWD"))"
    nf=$((nf + 1))
fi
rmdir "$CLI_CWD" 2>/dev/null

echo ""
echo "compiler tests: accepted=$np failed=$nf"
if [ "$nf" -gt 0 ]; then
    exit 1
fi
echo "PASS: compiler tests"
exit 0
