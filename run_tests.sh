#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

make all build-tests
export VERISTC_SKIP_BUILD=1

"$ROOT/run_vm_checks.sh"
"$ROOT/run_nuclear_e2e.sh"

echo "All tests passed"
