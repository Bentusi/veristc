#!/usr/bin/env bash
# run_fuzzer.sh — .sasm 加载器模糊测试
# P2 改进：验证 sasm_load() 对畸形输入的鲁棒性
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

FUZZER_BIN="tests/fuzz/sasm_fuzzer"
CORPUS_DIR="tests/fuzz/corpus"
ITERATIONS="${1:-100000}"

echo "=== VeriSTC .sasm 加载器模糊测试 ==="
echo ""

# ── 前置检查 ──
if [ ! -f "$FUZZER_BIN" ]; then
    echo "构建 fuzzer..."
    make build-fuzzer
fi

# ── 确保语料目录存在 ──
mkdir -p "$CORPUS_DIR"

# ── 复制种子文件到语料目录 ──
if [ -f tests/veristc-tests/out/core_assign.sasm ]; then
    cp tests/veristc-tests/out/core_assign.sasm "$CORPUS_DIR/"
fi
if [ -f tests/veristc-tests/out/function_control_flow.sasm ]; then
    cp tests/veristc-tests/out/function_control_flow.sasm "$CORPUS_DIR/"
fi

# ── 运行 fuzzer ──
echo "运行 fuzzer ($ITERATIONS 次迭代)..."
echo ""

# 设置 ASan 选项：检测到错误时立即中止
export ASAN_OPTIONS="abort_on_error=1:detect_leaks=0"
export UBSAN_OPTIONS="print_stacktrace=1:halt_on_error=1"

if "$FUZZER_BIN" "$CORPUS_DIR" "$ITERATIONS"; then
    echo ""
    echo "=== Fuzzing 完成：未检测到崩溃 ==="
    exit 0
else
    echo ""
    echo "=== Fuzzing 失败：检测到崩溃！==="
    echo "请检查 ASan/UBSan 输出获取详细信息"
    exit 1
fi
