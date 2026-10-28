#!/usr/bin/env bash
# run_misra_check.sh — MISRA-C 静态合规检查（独立脚本）
#
# 本脚本由 Makefile 的 misra-check 目标拆分而来：改为逐文件运行 cppcheck 的
# MISRA addon，并输出与其它 run_*.sh 测试脚本一致的“用例式”结果，便于统计
# 违规数量、按规则维度聚合，以及定位需要修改的文件。
#
# 用法（可从仓库根或 veri-runtime/ 目录调用，脚本自身会切到仓库根）：
#   ./veri-runtime/run_misra_check.sh                    # 检查全部 VM C 源文件
#   ./veri-runtime/run_misra_check.sh veri-runtime/core/loader.c veri-runtime/core/svm.c   # 只检查指定文件（修改时快速回归）
#   make misra-check                                     # 等价转发（根 Makefile → veri-runtime/Makefile）
#
# cppcheck 或 misra addon 缺失时本脚本判定 FAIL 并以非零退出：门禁不可静默通过。
#
# 判定口径：
#   - “MISRA 违规”仅指 misra addon 报出的 [misra-c2012-*] 条目（必需/建议规则）。
#   - cppcheck --enable=all 的其他诊断（nullPointerRedundantCheck / variableScope /
#     unreadVariable / misra-config 等）不计入违规，仅作为 info 提示展示。
#
# 退出码：0 = 所有被检文件 MISRA 违规为 0；1 = 至少一个文件仍有 MISRA 违规。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# shellcheck source=integration/test_framework.sh
. "$ROOT/integration/test_framework.sh"

# ── 默认检查范围（原 Makefile VM_C_FILES，现以本脚本为准）──
DEFAULT_FILES=(
    veri-runtime/core/safeasm_interp.c
    veri-runtime/core/loader.c
    veri-runtime/core/svm.c
    veri-runtime/core/sasm_dump.c
    veri-runtime/core/sasm_info.c
    veri-runtime/io/io_mapping.c
    veri-runtime/hotstandby/snapshot.c
    veri-runtime/hotstandby/sync.c
    veri-runtime/hotstandby/state_machine.c
    veri-runtime/hotstandby/download.c
    veri-runtime/hotstandby/hmac_sha256.c
    veri-runtime/hotstandby/download_wire.c
    veri-runtime/agent/agent_main.c
    veri-runtime/sim/plant.c
    veri-runtime/sim/sim_io.c
    veri-runtime/sim/watch.c
    veri-runtime/sim/sim_main.c
)

if [ "$#" -gt 0 ]; then
    FILES=("$@")
else
    FILES=("${DEFAULT_FILES[@]}")
fi

SUPPRESSIONS="misra-suppressions.txt"
AGGREGATE=".misra_report.txt"
OUTDIR=".misra_reports"

test_begin "MISRA-C Static Analysis"

# ── 前置检查：cppcheck 必须可用，缺失即判失败（不得静默跳过后报绿）──
if ! command -v cppcheck >/dev/null 2>&1; then
    summary_fail "MISRA-C: cppcheck not installed (install: sudo apt-get install cppcheck); gate cannot be verified"
fi

# ── 前置检查：抑制清单必须存在，否则统计口径不完整 ──
if [ ! -f "$SUPPRESSIONS" ]; then
    summary_fail "MISRA-C: suppressions list not found: $SUPPRESSIONS"
fi

# ── 前置检查：misra addon 是否可用（缺失则不能谎报全 OK）──
probe="$(mktemp --suffix=.c 2>/dev/null || echo .misra_probe.c)"
echo 'int main(void){return 0;}' > "$probe"
probe_out="$(cppcheck --addon=misra -q "$probe" 2>&1 || true)"
rm -f "$probe"
if printf '%s' "$probe_out" | grep -qiE "could not find|not found|no such|importerror|traceback|addon.*(missing|unavailable)"; then
    summary_fail "MISRA-C: cppcheck misra addon not available (install cppcheck addons / misra.json)"
fi

mkdir -p "$OUTDIR"
rm -f "$OUTDIR"/*.log
: > "$AGGREGATE"

# ── [1/2] 逐文件运行 cppcheck MISRA addon ──
step "1/2" "run cppcheck MISRA addon (per-file)"
for f in "${FILES[@]}"; do
    if [ ! -f "$f" ]; then
        printf '  %-34s ... %sFAIL (file not found)%s\n' "$f" "${_TF_C_RED}" "${_TF_C_RESET}"
        _TF_FAIL=$((_TF_FAIL + 1))
        continue
    fi

    # 生成 per-file 日志名：目录分隔符转下划线，避免同名冲突 (io_mapping vs hotstandby)
    base="${f##*/}"; base="${base%.c}"
    dirn="$(dirname "$f")"; dirn="${dirn#./}"
    [ "$dirn" = "." ] && dirn=""
    key="${dirn:+${dirn}_}"; key="${key//\//_}${base}"
    perlog="$OUTDIR/${key}.log"

    cppcheck --enable=all --std=c11 \
        --suppress=missingIncludeSystem \
        --suppress=unmatchedSuppression \
        --suppressions-list="$SUPPRESSIONS" \
        --addon=misra \
        -I. -Iveri-runtime/core \
        "$f" > "$perlog" 2>&1 || true

    {
        printf '===== %s =====\n' "$f"
        cat "$perlog"
        printf '\n'
    } >> "$AGGREGATE"

    misra="$(grep -cE '\[misra-c2012-[0-9]+(\.[0-9]+)?\]' "$perlog" || true)"
    info="$(grep -E '^[^ ].*: (error|warning|style|portability):' "$perlog" | grep -vcE '\[misra-c2012-' || true)"
    misra="${misra:-0}"; info="${info:-0}"

    if [ "$misra" -eq 0 ]; then
        printf '  %-34s ... %sOK%s   (violations=0, info=%s)\n' \
            "$f" "${_TF_C_GREEN}" "${_TF_C_RESET}" "$info"
        _TF_PASS=$((_TF_PASS + 1))
    else
        printf '  %-34s ... %sFAIL%s (%s violation(s), info=%s)\n' \
            "$f" "${_TF_C_RED}" "${_TF_C_RESET}" "$misra" "$info"
        _TF_FAIL=$((_TF_FAIL + 1))
    fi
done

# ── [2/2] 按规则维度聚合统计 ──
step "2/2" "aggregate MISRA violation breakdown"
total="$(grep -cE '\[misra-c2012-[0-9]+(\.[0-9]+)?\]' "$AGGREGATE" || true)"
total="${total:-0}"

if [ "$total" -gt 0 ]; then
    echo "  违规规则分布 (rule : 次数):"
    grep -oE '\[misra-c2012-[0-9]+(\.[0-9]+)?\]' "$AGGREGATE" \
        | sed -E 's/\[misra-c2012-([0-9.]+)\]/\1/' \
        | sort | uniq -c | sort -rn \
        | sed -E 's/^ *([0-9]+) ([0-9.]+)/      rule \2 : \1/'
else
    echo "  违规规则分布: 无 (MISRA 全部清零)"
fi

info_total="$(grep -E '^[^ ].*: (error|warning|style|portability):' "$AGGREGATE" | grep -vcE '\[misra-c2012-' || true)"
info_total="${info_total:-0}"
if [ "$info_total" -gt 0 ]; then
    echo "  非 MISRA 诊断 (cppcheck --enable=all, 不计入违规):"
    grep -E '^[^ ].*: (error|warning|style|portability):' "$AGGREGATE" \
        | grep -oE '\[[a-zA-Z][a-zA-Z0-9]*\]' | grep -vE '\[misra-c2012-' \
        | sort | uniq -c | sort -rn \
        | sed -E 's/^ *([0-9]+) (\[[a-zA-Z0-9]+\])/      \2 : \1/'
fi

echo ""
echo "  被检文件: ${#FILES[@]}   MISRA 违规合计: ${total}   非 MISRA 诊断: ${info_total}"
echo "  汇总报告: ${AGGREGATE}"
echo "  分文件日志: ${OUTDIR}/*.log"

check_failures "MISRA-C Static Analysis"
