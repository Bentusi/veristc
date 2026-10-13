#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT/../.."

. "$ROOT/../test_framework.sh"

V=veristc/extraction/veristc

test_begin "Compiler Tests"

# Check prerequisites
if [ ! -x "$V" ]; then
    echo "veristc not built, skipping" >&2
    exit 0
fi

step "1/2" "Negative tests (must be rejected)"
np=0; nf=0
for f in tests/compiler-tests/negative/*.st; do
    name="$(basename "$f" .st)"
    if ! "$V" -c "$f" -o "/tmp/veristc-neg-${name}.sasm" > "/tmp/veristc-neg-${name}.out" 2>&1; then
        echo "  reject $name ... OK"
        np=$((np+1))
    else
        echo "  reject $name ... FAIL (compiler accepted invalid program)"
        nf=$((nf+1))
    fi
done

step "2/2" "Positive tests (must be accepted)"
for f in tests/compiler-tests/positive/*.st; do
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

echo ""
echo "compiler tests: accepted=$np failed=$nf"
if [ "$nf" -gt 0 ]; then
    exit 1
fi
echo "PASS: compiler tests"
exit 0
