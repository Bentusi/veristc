#!/usr/bin/env bash
# run_sanitizer.sh — ASan/UBSan 构建变体测试
# P2 改进：在 CI 中捕获内存安全漏洞
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

echo "=== VeriSTC ASan/UBSan 内存安全检测 ==="
echo ""

# ── 前置检查：gcc 是否支持 sanitizer ──
if ! echo 'int main(void){return 0;}' | gcc -fsanitize=address,undefined -x c - -o /dev/null 2>/dev/null; then
    echo "ERROR: gcc 不支持 ASan/UBSan，请安装 libasan 和 libubsan"
    echo "  Ubuntu/Debian: sudo apt-get install libasan8 libubsan1"
    exit 1
fi

# ── 前置条件：需要正常构建 .sasm 测试文件 ──
echo "[0/4] 构建 .sasm 测试文件..."
make build-smoke build-function-tests

# ── [1/4] ASan/UBSan VM 单元测试 ──
echo "[1/4] ASan/UBSan VM 单元测试..."
make sanitize-test
tests/vm-tests/test_vm-asan
echo "  ✓ test_vm-asan passed"

# ── [2/4] ASan/UBSan SVM 单周期运行 ──
echo "[2/4] ASan/UBSan SVM 单周期运行..."
make sanitize-svm
vm/svm-asan -n 1 -p 0 tests/veristc-tests/out/core_assign.sasm 42 \
    > /tmp/veristc-sanitize-once.out
grep -Fq '[cycle_counter] 1' /tmp/veristc-sanitize-once.out
echo "  ✓ svm-asan single cycle passed"

# ── [3/4] ASan/UBSan SVM FUNCTION 控制流 ──
echo "[3/4] ASan/UBSan SVM FUNCTION 控制流..."
vm/svm-asan -n 6 -p 0 tests/veristc-tests/out/function_control_flow.sasm \
    > /tmp/veristc-sanitize-func.out
grep -Fq 'tick=1,  y=2,' /tmp/veristc-sanitize-func.out
echo "  ✓ svm-asan FUNCTION control flow passed"

# ── [4/4] ASan/UBSan CRC 损坏拒绝 ──
echo "[4/4] ASan/UBSan CRC 损坏拒绝..."
cp tests/veristc-tests/out/core_assign.sasm /tmp/veristc-sanitize-bad-crc.sasm
size="$(wc -c < /tmp/veristc-sanitize-bad-crc.sasm)"
printf '\377' | dd of=/tmp/veristc-sanitize-bad-crc.sasm bs=1 \
    seek="$((size - 5))" count=1 conv=notrunc status=none
if vm/svm-asan -n 1 -p 0 /tmp/veristc-sanitize-bad-crc.sasm \
    > /tmp/veristc-sanitize-bad-crc.out 2>&1; then
    echo "ERROR: svm-asan accepted a file with a bad CRC" >&2
    exit 1
fi
grep -q 'sasm_load failed: -2' /tmp/veristc-sanitize-bad-crc.out
echo "  ✓ svm-asan CRC rejection passed"

echo ""
echo "=== ASan/UBSan 检测全部通过 ==="
