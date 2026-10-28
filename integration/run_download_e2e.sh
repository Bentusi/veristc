#!/usr/bin/env bash
# 下装帧协议端到端验证（G0 产出物 5）：
#   [1/5] 构建 agent 与两份真实镜像
#   [2/5] 正向：Python 发送端 → 管道 → agent 收帧 → 周期边界切换 → 程序真的换了
#   [3/5] 拒绝矩阵：篡改/CRC/截断/超限/序号缺口/错钥，一律拒收且活动镜像不动
#   [4/5] 健康检查回滚：新镜像超出自身周期预算 ⇒ 切换后回切旧槽
#   [5/5] agent 命令行契约 + 状态帧 JSON 可解析
#
# 发送端用 Python（integration/dl_frames.py）而不是复用 C 代码：
# 两侧实现相互独立，MAC 约定写错不可能自己印证自己。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

. "$ROOT/integration/test_framework.sh"

test_begin "Download Protocol E2E"

KEY=0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20
WRONG_KEY=0000000000000000000000000000000000000000000000000000000000000000
IMG_A=build/sasm/core_assign.sasm
IMG_B=build/sasm/algo_blocks_fb.sasm
AGENT=build/bin/veristc-agent
SENDER="integration/dl_frames.py"
OUT=/tmp/veristc-dl-e2e.out
FR=/tmp/veristc-dl-frames.bin

step "1/5" "build agent and two real images"
assert_ok "make agent" make agent
assert_ok "make build-smoke" make build-smoke
assert_ok "make build-function-tests" make build-function-tests
assert_file_exists "$AGENT" "veristc-agent present"
[ -f "$IMG_A" ] && [ -f "$IMG_B" ] && {
    echo "  both images present ... OK"; _TF_PASS=$((_TF_PASS + 1))
} || {
    echo "  both images present ... FAIL"; _TF_FAIL=$((_TF_FAIL + 1))
}
if ! command -v python3 > /dev/null 2>&1; then
    skip "python3 absent: sender is Python, nothing to run (15 checks skipped)"
    check_failures "Download Protocol E2E"
    exit 0
fi

# status 帧单独抽出来，便于逐条断言（程序自己的 PRINT 也走 stdout）
statuses() { grep -F '{"frame":"status"' "$1"; }

step "2/5" "happy path: frames in through a pipe, program actually changes"
python3 "$SENDER" --key "$KEY" --image "$IMG_B" > "$FR"
set +e
"$AGENT" --cycles 6 --key "$KEY" --download-from "$FR" \
    --download-at 3 --health-cycles 2 "$IMG_A" > "$OUT" 2>&1
rc=$?
set -e
[ "$rc" -eq 0 ] && { echo "  agent exits 0 ... OK"; _TF_PASS=$((_TF_PASS + 1)); } \
                || { echo "  agent exits 0 ... FAIL (exit=$rc)"; _TF_FAIL=$((_TF_FAIL + 1)); \
                     cat "$OUT"; }
assert_contains "$OUT" '"event":"download_staged"' "stream reassembles and stages"
assert_contains "$OUT" "\"bytes\":$(wc -c < "$IMG_B")" \
    "staged byte count equals the image file size"
assert_contains "$OUT" '"event":"switch","role":"active","node":0,"version":1' \
    "switch takes effect at the cycle boundary"
assert_contains "$OUT" '"event":"health_ok"' "new image survives the health window"
assert_contains "$OUT" '"event":"end"' "end frame reported"
if statuses "$OUT" | grep -F '"event":"download_rejected"' -q; then
    echo "  no refusal on the clean path ... FAIL"; _TF_FAIL=$((_TF_FAIL + 1))
else
    echo "  no refusal on the clean path ... OK"; _TF_PASS=$((_TF_PASS + 1))
fi
# 切换的判据不是状态帧自说自话，而是程序输出真的换了形状
if awk '/"event":"switch"/{s=1;next} s && /^FB /{found=1} END{exit !found}' "$OUT"; then
    echo "  the running program is the new image after the switch ... OK"
    _TF_PASS=$((_TF_PASS + 1))
else
    echo "  the running program is the new image after the switch ... FAIL"
    _TF_FAIL=$((_TF_FAIL + 1))
fi

step "3/5" "refusal matrix: nothing bad ever reaches the active image"
#  说明: 拒绝码来自 DlResult（-7 HMAC -6 CRC -9 截断 -4 超限 -5 序号）
refusal() {
    local desc="$1" want_rc="$2"; shift 2
    rm -f "$FR"
    if ! python3 "$SENDER" --key "$KEY" "$@" --image "$IMG_B" > "$FR" 2>/dev/null; then
        echo "  $desc ... FAIL (sender refused to build the stream)"
        _TF_FAIL=$((_TF_FAIL + 1))
        return
    fi
    local key="$KEY"
    if [ "${want_rc}" = "wrongkey" ]; then key="$WRONG_KEY"; want_rc=-7; fi
    set +e
    "$AGENT" --cycles 4 --key "$key" --download-from "$FR" \
        --download-at 2 "$IMG_A" > "$OUT" 2>&1
    local rc=$?
    set -e
    if grep -F "{\"frame\":\"status\",\"event\":\"download_rejected\"" "$OUT" \
        | grep -F "\"rc\":${want_rc}" -q; then
        echo "  $desc reports rc=${want_rc} ... OK"
        _TF_PASS=$((_TF_PASS + 1))
    else
        echo "  $desc reports rc=${want_rc} ... FAIL"
        _TF_FAIL=$((_TF_FAIL + 1))
        statuses "$OUT" || true
    fi
    # 每条被拒的下装都必须"活动镜像不动"：版本仍是 0、没有切换、程序照跑、退出码 0
    if grep -F '"event":"end"' "$OUT" | grep -F '"version":0' -q \
        && grep -F '"event":"end"' "$OUT" | grep -F '"switches":0' -q \
        && grep -F '"event":"end"' "$OUT" | grep -F '"ran":4' -q \
        && [ "$rc" -eq 0 ]; then
        echo "  $desc leaves the running image untouched ... OK"
        _TF_PASS=$((_TF_PASS + 1))
    else
        echo "  $desc leaves the running image untouched ... FAIL"
        _TF_FAIL=$((_TF_FAIL + 1))
        statuses "$OUT" || true
    fi
}

refusal "tampered payload byte"          -7 --tamper 40
refusal "wrong CRC field, valid MAC"     -6 --bad-crc
refusal "stream truncated mid-image"     -9 --drop-last
refusal "declared image over the limit"  -4 --image-len 1048577
refusal "frame sequence gap"             -5 --seq-start 1
refusal "signed with the wrong key"      wrongkey

step "4/5" "health check: an image over its own cycle budget is rolled back"
# 把新镜像 SAFE 段的 cycle_limit 改成 2（结构上合法，运行必然超预算），
# 再重新封口 CRC —— 这就是"能装载、能校验、跑起来就炸"的那一类下装事故。
python3 - "$IMG_B" /tmp/veristc-dl-trap.sasm <<'PY'
import struct, sys, zlib
src, dst = sys.argv[1], sys.argv[2]
d = bytearray(open(src, 'rb').read())
off, end = 6, len(d) - 4
while off + 8 <= end:
    sec = d[off]
    ln = struct.unpack_from('<I', d, off + 1)[0]
    if sec == 5:                    # SEC_SAFE: u8 level, u32 cycle_limit, ...
        struct.pack_into('<I', d, off + 9, 2)
        break
    off += 8 + ln
else:
    sys.exit("SAFE section not found")
struct.pack_into('<I', d, len(d) - 4,
                 zlib.crc32(bytes(d[6:len(d) - 4])) & 0xffffffff)
open(dst, 'wb').write(bytes(d))
PY
python3 "$SENDER" --key "$KEY" --image /tmp/veristc-dl-trap.sasm > "$FR"
set +e
"$AGENT" --cycles 6 --key "$KEY" --download-from "$FR" \
    --download-at 2 --health-cycles 3 "$IMG_A" > "$OUT" 2>&1
rc=$?
set -e
[ "$rc" -eq 0 ] && { echo "  agent survives a rolled-back download ... OK"
    _TF_PASS=$((_TF_PASS + 1)); } \
  || { echo "  agent survives a rolled-back download ... FAIL (exit=$rc)"
    _TF_FAIL=$((_TF_FAIL + 1)); cat "$OUT"; }
assert_contains "$OUT" '"event":"switch"' "the trap image is staged and switched"
assert_contains "$OUT" '"rc":-5,"rolled_back_to":0' \
    "cycle-budget failure inside the health window triggers rollback"
assert_contains "$OUT" '"event":"end","role":"active","node":0,"version":0' \
    "the active version is the old image again"
assert_contains "$OUT" '"switches":1,"rollbacks":1' "both counts are reported"
# 回滚之后旧镜像必须还能继续跑（周期计数从 1 重新开始 = 冷启动语义）
if awk '/"event":"rollback"/{r=1;next} r && /^counter=/{found=1} END{exit !found}' "$OUT"; then
    echo "  the old image keeps scanning after rollback ... OK"
    _TF_PASS=$((_TF_PASS + 1))
else
    echo "  the old image keeps scanning after rollback ... FAIL"
    _TF_FAIL=$((_TF_FAIL + 1))
fi

step "5/5" "agent command line contract"
set +e
"$AGENT" --download-from "$FR" "$IMG_A" > /dev/null 2>&1; rc=$?
"$AGENT" --key "$KEY" --download-from /nonexistent "$IMG_A" > /dev/null 2>&1; rc2=$?
"$AGENT" --key deadbeef --download-from "$FR" "$IMG_A" > /dev/null 2>&1; rc3=$?
"$AGENT" --role 'bad role' "$IMG_A" > /dev/null 2>&1; rc4=$?
"$AGENT" --bogus "$IMG_A" > /dev/null 2>&1; rc5=$?
"$AGENT" "$IMG_A" "$IMG_B" > /dev/null 2>&1; rc6=$?
"$AGENT" --cycles 2 --role standby --node-id 1 "$IMG_A" > "$OUT" 2>&1; rc7=$?
set -e
if [ "$rc" -eq 4 ] && [ "$rc2" -eq 6 ] && [ "$rc3" -eq 4 ] && [ "$rc4" -eq 4 ] \
    && [ "$rc5" -eq 2 ] && [ "$rc6" -eq 2 ] && [ "$rc7" -eq 0 ]; then
    echo "  exit codes for bad arguments ... OK"
    _TF_PASS=$((_TF_PASS + 1))
else
    echo "  exit codes for bad arguments ... FAIL ($rc $rc2 $rc3 $rc4 $rc5 $rc6 $rc7)"
    _TF_FAIL=$((_TF_FAIL + 1))
fi
assert_contains "$OUT" '"role":"standby","node":1' "role and node id are reported"
if statuses "$OUT" | python3 -c '
import json, sys
for line in sys.stdin:
    json.loads(line)
' ; then
    echo "  every status frame is valid JSON ... OK"
    _TF_PASS=$((_TF_PASS + 1))
else
    echo "  every status frame is valid JSON ... FAIL"
    _TF_FAIL=$((_TF_FAIL + 1))
fi

check_failures "Download Protocol E2E"
