# VeriSTC - 形式化验证编译器

VeriSTC 是一个形式化验证的编译器，将 SafeST 源代码转换为 SafeASM 字节码，具有机器检查的语义保持证明。

## 构建系统

### 依赖项

- **Coq/Rocq** (>= 8.18): 形式化验证
- **OCaml** (>= 5.0): 提取后的代码编译
- **dune** (>= 3.16): 构建系统
- **GCC**: C 虚拟机编译
- **cppcheck**: MISRA-C 静态分析（可选）

### 使用 dune 构建（推荐）

```bash
# 进入 veristc 目录
cd veristc

# 构建所有 Coq 库
dune build

# 提取 OCaml 代码
dune build @extraction

# 构建 veristc 可执行程序
dune build extraction/veristc.exe

# 清理构建
dune clean
```

### 使用 Make 构建

```bash
# 构建所有目标
make all

# 仅构建 Coq 库
make coq

# 构建 VM 库
make vm-lib vm-io vm-hs

# 构建 SVM
make svm

# 构建测试
make build-tests
```

### MISRA-C 检查

```bash
# 运行完整的 MISRA-C 检查
make misra-check

# 运行基本检查
make misra-check-basic
```

## 项目结构

```
veristc/
├── spec/           # Coq 规范文件
│   ├── safeasm.v
│   ├── safest.v
│   ├── st_semantics.v
│   ├── function_semantics.v
│   ├── asm_semantics.v
│   └── compiler_correctness.v
├── src/            # Coq 实现文件
│   ├── encoder.v
│   ├── lexer.v
│   ├── parser.v
│   ├── inline.v
│   ├── desugar.v
│   ├── analysis.v
│   ├── typechecker.v
│   ├── function_check.v
│   ├── codegen.v
│   └── global_codegen.v
└── extraction/     # OCaml 提取代码
    └── veristc_main.ml

vm/                 # C 虚拟机
├── safeasm_interp.c
├── loader.c
├── svm.c
├── io/
└── hotstandby/
```

## CI/CD

项目使用 GitHub Actions 进行持续集成。每次提交和 PR 都会自动触发：

1. Coq 库构建
2. OCaml 代码提取
3. veristc 可执行程序构建
4. VM 库编译
5. 测试执行
6. MISRA-C 检查

## 许可证

MIT License
