#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

make build-nuclear-e2e

line_count="$(wc -l < tests/st-examples/nuclear_rps_esfas_full.st)"
test "$line_count" -ge 10000

echo "Running nuclear ST end-to-end (${line_count} ST lines)"
tests/vm-tests/test_nuclear_protection_full_e2e \
    tests/veristc-tests/out/nuclear_rps_esfas_full.sasm

echo "Nuclear ST -> VeriSTC -> SASM -> VM passed"
