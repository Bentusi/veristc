#!/usr/bin/env bash
# 闭环仿真端到端验证（G0 产出物 3 + 4）：
#   [1/6] 编译 ST + 构建 sim
#   [2/6] 12 周期时间线 vs 黄金文件（被控对象 <-> 控制器 真实闭环）
#   [3/6] 确定性：两次仿真逐字节一致、两次编译逐字节一致
#   [4/6] .plant 契约：畸形配置一律拒绝启动，不静默降级
#   [5/6] 程序与对象表一致性：通道缺失/方向不符即拒绝
#   [6/6] watch 帧：名字 -> 段 7 地址 -> 数值，逐周期与黄金时间线/`svm -l` 交叉核对
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

. "$ROOT/integration/test_framework.sh"

test_begin "Closed-Loop Simulation E2E"

ST=veri-stc/tests/st-examples/sim_closed_loop.st
OUT=build/sasm/sim_closed_loop.sasm
PLANT=veri-runtime/sim/plants/closed_loop.plant
GOLDEN=veri-stc/tests/st-examples/sim_closed_loop.golden.timeline
V=build/bin/veristc
SIM=build/bin/sim
SVM=build/bin/svm

step "1/6" "compile ${ST} and build sim"
assert_ok "make build-sim" make build-sim
assert_ok "make build-smoke" make build-smoke
mkdir -p "$(dirname "$OUT")"
assert_ok "compile closed loop" "$V" -c "$ST" -o "$OUT"
assert_file_exists "$SIM" "sim binary present"

step "2/6" "run 12 cycles, diff against golden timeline"
"$SIM" -n 12 -t 100 "$OUT" "$PLANT" > /tmp/sim.run.out
grep "cycle=" /tmp/sim.run.out > /tmp/sim.run.timeline
if diff -u "$GOLDEN" /tmp/sim.run.timeline > /tmp/sim.run.diff 2>&1; then
    echo "  golden timeline diff ... OK"
    _TF_PASS=$((_TF_PASS + 1))
else
    echo "  golden timeline diff ... FAIL"
    sed -n '1,30p' /tmp/sim.run.diff
    _TF_FAIL=$((_TF_FAIL + 1))
fi
assert_line_count "/tmp/sim.run.timeline" 12 "12 cycles reported"
assert_contains "/tmp/sim.run.out" "violations=0 read_errors=0 write_errors=0" \
    "clean cycle accounting"
# 闭环成立的最小证据：被控量随周期变化（对象->程序），执行器随后回落
# （程序->对象），二者都不是常量。
assert_not_contains "/tmp/sim.run.out" "ch0=0 ch1=0" "plant output is not stuck at zero"

step "3/6" "determinism"
"$SIM" -n 12 -t 100 "$OUT" "$PLANT" > /tmp/sim.run2.out
assert_ok "second run byte-identical" cmp /tmp/sim.run.out /tmp/sim.run2.out
"$V" -c "$ST" -o /tmp/sim-a.sasm
"$V" -c "$ST" -o /tmp/sim-b.sasm
assert_ok "recompile byte-identical" cmp /tmp/sim-a.sasm /tmp/sim-b.sasm
assert_ok "matches production artifact" cmp /tmp/sim-a.sasm "$OUT"

step "4/6" ".plant contract rejects malformed tables"
mk_plant() { printf '%s\n' "$@" > /tmp/sim-bad.plant; }

mk_plant '0 INPUT LAG 0.125 0 0 1000 0 1' \
         '1 OUTPUT ACTUATOR 0 0 0 1000 0 -1' \
         '0 INPUT CONST 0 0 0 1000 5 -1'
assert_exit_code 2 "duplicate channel id rejected" \
    "$SIM" -n 1 -q "$OUT" /tmp/sim-bad.plant

mk_plant '0 INPUT LAG 0.125 0 0 1000 0 1' \
         '1 OUTPUT ACTUATOR 0 0 0 1000 0 -1' \
         '2 INPUT CONST 0 0 0 1000 500 -1' \
         '3 OUTPUT LAG 0.5 0 0 100 0 1'
assert_exit_code 2 "OUTPUT must be ACTUATOR" \
    "$SIM" -n 1 -q "$OUT" /tmp/sim-bad.plant

mk_plant '0 INPUT LAG 0.125 0 0 1000 0 7' \
         '1 OUTPUT ACTUATOR 0 0 0 1000 0 -1' \
         '2 INPUT CONST 0 0 0 1000 500 -1'
assert_exit_code 2 "driver channel must exist" \
    "$SIM" -n 1 -q "$OUT" /tmp/sim-bad.plant

mk_plant '0 INPUT LAG 0.125 0 1000 0 500 -1' \
         '1 OUTPUT ACTUATOR 0 0 0 1000 0 -1' \
         '2 INPUT CONST 0 0 0 1000 500 -1'
assert_exit_code 2 "min greater than max rejected" \
    "$SIM" -n 1 -q "$OUT" /tmp/sim-bad.plant

mk_plant '0 INPUT LAG 0.125 0 0 1000 0' \
         '1 OUTPUT ACTUATOR 0 0 0 1000 0 -1' \
         '2 INPUT CONST 0 0 0 1000 500 -1'
assert_exit_code 2 "wrong field count rejected" \
    "$SIM" -n 1 -q "$OUT" /tmp/sim-bad.plant

mk_plant '0 INPUT LAG nan 0 0 1000 0 1' \
         '1 OUTPUT ACTUATOR 0 0 0 1000 0 -1' \
         '2 INPUT CONST 0 0 0 1000 500 -1'
assert_exit_code 2 "non-finite gain rejected" \
    "$SIM" -n 1 -q "$OUT" /tmp/sim-bad.plant

step "5/6" "program and plant must agree on the channel set"
mk_plant '5 INPUT CONST 0 0 0 1000 0 -1' \
         '6 OUTPUT ACTUATOR 0 0 0 1000 0 -1' \
         '7 INPUT CONST 0 0 0 1000 500 -1'
assert_exit_code 2 "missing channel rejected" \
    "$SIM" -n 1 -q "$OUT" /tmp/sim-bad.plant

mk_plant '0 INPUT LAG 0.125 0 0 1000 0 1' \
         '1 INPUT CONST 0 0 0 1000 0 -1' \
         '2 INPUT CONST 0 0 0 1000 500 -1'
assert_exit_code 2 "direction mismatch rejected" \
    "$SIM" -n 1 -q "$OUT" /tmp/sim-bad.plant

# 没有 I/O 映射的程序不该用仿真跑（用 svm），否则时间线是一排常量
assert_exit_code 2 "program without I/O mapping rejected" \
    "$SIM" -n 1 -q build/sasm/core_assign.sasm "$PLANT"

step "6/6" "watch frames: section 7 name -> address -> value, per cycle"
WATCH_NAMES='sp,pv,mv,integ,cnt#N,cnt#ACC'
"$SIM" -n 12 -t 100 --watch "$WATCH_NAMES" "$OUT" "$PLANT" \
    > /tmp/sim.watch.out 2> /tmp/sim.watch.err
# 帧行以 {"frame" 起始；程序自身的 PRINT 输出混在同一 stdout 里，按前缀过滤
grep '^{"frame"' /tmp/sim.watch.out > /tmp/sim.watch.frames
assert_line_count /tmp/sim.watch.frames 13 "12 cycle frames plus one done frame"
"$SVM" -l "$OUT" > /tmp/sim.watch.svml

if command -v python3 > /dev/null 2>&1; then
    assert_ok "watch frame cross-check" python3 - \
        /tmp/sim.watch.frames "$GOLDEN" /tmp/sim.watch.svml <<'PY'
import json, re, sys

frames_path, golden_path, svml_path = sys.argv[1:4]
fail = []


def check(cond, msg):
    if not cond:
        fail.append(msg)


rows = []
for line in open(frames_path):
    try:
        rows.append(json.loads(line))
    except ValueError as exc:
        check(False, "frame line is not JSON (%s): %r" % (exc, line))

cycles = [r for r in rows if r.get("frame") == "cycle"]
done = [r for r in rows if r.get("frame") == "done"]
check(len(cycles) == 12, "expected 12 cycle frames, got %d" % len(cycles))
check(len(done) == 1, "expected exactly one done frame, got %d" % len(done))

NAMES = ["sp", "pv", "mv", "integ", "cnt#N", "cnt#ACC"]

# svm -l 是地址的另一半真值：两处必须逐条相等
svm = {}
for line in open(svml_path):
    m = re.match(r"^(\S+) (0x[0-9A-Fa-f]+) (\S+) size=(\d+)\s*$", line)
    if m is None:
        check(False, "unparsable svm -l line: %r" % line)
        continue
    svm[m.group(1)] = (int(m.group(2), 16), m.group(3), int(m.group(4)))

for i, r in enumerate(cycles, start=1):
    check([v["name"] for v in r.get("values", [])] == NAMES,
          "frame %d column order is %r" % (i, [v.get("name") for v in r.get("values", [])]))
    check(r.get("cycle") == i, "frame %d cycle numbering" % i)
    check(r.get("t_ms") == (i - 1) * 100, "frame %d virtual time" % i)
    check(r.get("status") == 0, "frame %d status" % i)
    check(r.get("violations") == 0, "frame %d violations" % i)
    for v in r.get("values", []):
        want = svm.get(v["name"])
        if want is None:
            check(False, "symbol absent from svm -l: %s" % v["name"])
            continue
        got = (v["addr"], v["type"], v["size"])
        check(got == want, "frame %d %s: watch %r != svm -l %r" % (i, v["name"], got, want))

# 按符号地址读出的值 == 黄金时间线（W2 推迟到这里的最后一条断言）
gold = {}
for line in open(golden_path):
    m = re.match(r"^\s*cycle=(\d+)\s+t=\d+\s+ch0=(-?\d+) ch1=(-?\d+) ch2=(-?\d+)", line)
    if m is None:
        check(False, "unparsable golden line: %r" % line)
        continue
    gold[int(m.group(1))] = {"pv": int(m.group(2)), "mv": int(m.group(3)),
                             "sp": int(m.group(4))}

CHANNEL = {"pv": 0, "mv": 1, "sp": 2}
for r in cycles:
    vals = {v["name"]: v for v in r.get("values", [])}
    expected = gold.get(r["cycle"], {})
    for name, want in expected.items():
        check(vals[name]["value"] == want,
              "cycle %d %s: watch value %r != golden %r" %
              (r["cycle"], name, vals[name]["value"], want))
    # 实例字段（派生名）也是可监视的活槽位：每周期 +1
    check(vals["cnt#N"]["value"] == r["cycle"],
          "cycle %d cnt#N = %r, expected %d" % (r["cycle"], vals["cnt#N"]["value"], r["cycle"]))
    check(vals["cnt#ACC"]["value"] == r["cycle"],
          "cycle %d cnt#ACC = %r, expected %d" % (r["cycle"], vals["cnt#ACC"]["value"], r["cycle"]))
    for name, v in vals.items():
        if name in CHANNEL:
            check(v["channel"] == CHANNEL[name],
                  "cycle %d %s: channel %r != %d" % (r["cycle"], name, v["channel"], CHANNEL[name]))
            check(v["raw"] == v["value"],
                  "cycle %d %s: raw %r != value %r at scale 1 bias 0" %
                  (r["cycle"], name, v["raw"], v["value"]))
        else:
            check(v["channel"] is None and v["raw"] is None,
                  "cycle %d %s: non-I/O symbol must carry null channel/raw" % (r["cycle"], name))

if done:
    d = done[0]
    check((d.get("cycles"), d.get("violations"), d.get("read_errors"),
           d.get("write_errors")) == (12, 0, 0, 0),
          "done frame counters = %r" % (d,))

if fail:
    for f in fail[:12]:
        print("  " + f)
    if len(fail) > 12:
        print("  ... %d more" % (len(fail) - 12))
    sys.exit(1)
print("  watch frames cross-checked: 12 cycles x 6 symbols against svm -l "
      "and the golden timeline")
PY
else
    skip "python3 absent: watch frame JSON cross-check not run"
fi

"$SIM" -n 12 -t 100 --watch "$WATCH_NAMES" "$OUT" "$PLANT" 2>/dev/null \
    | grep '^{"frame"' > /tmp/sim.watch.frames2
assert_ok "second watch run byte-identical" \
    cmp /tmp/sim.watch.frames /tmp/sim.watch.frames2

assert_exit_code 2 "unknown watch name rejected at startup" \
    "$SIM" -n 1 --watch ghost "$OUT" "$PLANT"
assert_exit_code 2 "instance base name (FB, no single value) rejected" \
    "$SIM" -n 1 --watch cnt "$OUT" "$PLANT"
assert_exit_code 2 "duplicate watch name rejected" \
    "$SIM" -n 1 --watch sp,sp "$OUT" "$PLANT"

check_failures "Closed-Loop Simulation E2E"
