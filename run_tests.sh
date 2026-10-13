#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

# 全量构建：Coq 编译 + veristc 提取 + C 库/工具 + 测试二进制 + SASM 生成
make all build-tests

# 分别执行测试套件（子脚本内的 make 会因目标已最新而跳过）
"$ROOT/run_vm_checks.sh"
"$ROOT/run_feature_probes.sh"
"$ROOT/run_channel_e2e.sh"
"$ROOT/run_nuclear_e2e.sh"

# P2: ASan/UBSan 内存安全检测（可选，需要 gcc 支持）
if echo 'int main(void){return 0;}' | gcc -fsanitize=address,undefined -x c - -o /dev/null 2>/dev/null; then
    "$ROOT/run_sanitizer.sh"
else
    echo "[SKIP] ASan/UBSan not supported by gcc, skipping sanitizer tests"
fi

echo "All tests passed"
