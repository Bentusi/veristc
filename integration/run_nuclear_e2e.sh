#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

. "$ROOT/integration/test_framework.sh"

test_begin "Nuclear ST End-to-End"

make build-nuclear-e2e

step "1/2" "verify ST source size"
line_count="$(wc -l < veri-stc/tests/st-examples/nuclear_rps_esfas_full.st)"
if [ "$line_count" -ge 10000 ]; then
    echo "  ST source ${line_count} lines (>= 10000) ... OK"
    _TF_PASS=$((_TF_PASS + 1))
else
    echo "  ST source ${line_count} lines (< 10000) ... FAIL"
    _TF_FAIL=$((_TF_FAIL + 1))
fi

step "2/2" "run nuclear protection e2e test"
echo "Running nuclear ST end-to-end (${line_count} ST lines)"
assert_ok "nuclear protection e2e" \
    build/bin/test_nuclear_protection_full_e2e \
    build/sasm/nuclear_rps_esfas_full.sasm

check_failures "Nuclear ST -> VeriSTC -> SASM -> VM"
