(* ================================================================
   VeriSTC/extraction/extraction.v
   Coq → OCaml Extraction 配置
   
   将 VeriSTC 编译器的核心组件提取为 OCaml 可执行程序。
   提取内容:
     1. lexer / parser — 源代码解析
     2. desugar — AST → CoreST 脱糖
     3. typechecker — 类型检查
     4. codegen — CoreST → SafeASM 代码生成
     5. encoder — SafeASM 二进制编码
   
   提取后的 OCaml 程序可通过命令行:
     VeriSTC compile input.st -o output.sasm
   将 IEC 61131-3 Structured Text 编译为 SafeASM 字节码。
   ================================================================ *)

Require Import Stdlib.Strings.String.
Require Import Stdlib.Lists.List.

Require Extraction.

(* 设定提取输出目录 *)
Set Extraction Output Directory "./extraction".

(* 提取所有编译器核心模块 *)
Require Import veristc_src.lexer.
Require Import veristc_src.parser.
Require Import veristc_src.desugar.
Require Import veristc_src.typechecker.
Require Import veristc_src.codegen.
Require Import veristc_src.analysis.
Require Import veristc_src.encoder.

(* 提取 OCaml 代码 *)
Separate Extraction
  veristc_src.lexer.lex
  veristc_src.parser.parse
  veristc_src.desugar.desugar_program
  veristc_src.typechecker.type_check_program
  veristc_src.codegen.compile_program
  veristc_src.analysis.analyze
  veristc_src.encoder.encode_sasm_instr
  veristc_src.encoder.encode_module
.
