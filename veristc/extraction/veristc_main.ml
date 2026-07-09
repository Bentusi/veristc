(* ================================================================
   veristc/extraction/veristc_main.ml
   veristc 编译器命令行入口 — 提取后的 OCaml 代码
   
   用法:
     veristc compile input.st -o output.sasm
     veristc compile input.st --dump > output.txt
     veristc analyze input.st
   ================================================================ *)

(* 从 Coq Extraction 生成的模块 *)
module L = Lexer
module P = Parser
module D = Desugar
module T = Typechecker
module C = Codegen
module A = Analysis
module E = Encoder

(* 简单文件读取 *)
let read_file (path : string) : string =
  let ch = open_in path in
  let n = in_channel_length ch in
  let s = really_input_string ch n in
  close_in ch;
  s

(* 编译流程: .st → .sasm *)
let compile_st_to_sasm (source_path : string) : string =
  let source = read_file source_path in

  (* Step 1: 词法分析 *)
  let tokens = match L.lex source with
    | Some ts -> ts
    | None -> failwith "词法分析失败"
  in

  (* Step 2: 语法分析 *)
  let ast = match P.parse tokens with
    | Some p -> p
    | None -> failwith "语法分析失败"
  in

  (* Step 3: 脱糖 *)
  let corest = D.desugar_program ast in

  (* Step 4: 类型检查（可选，可注释掉以跳过） *)
  let _ = match T.type_check_program ast with
    | Some _ -> ()  (* 类型检查通过 *)
    | None -> failwith "类型检查失败"
  in

  (* Step 5: 静态分析 *)
  let _analysis = A.analyze corest in

  (* Step 6: 代码生成 *)
  let sasm_module = C.compile_program corest in

  (* Step 7: 编码为二进制 *)
  let encoded = E.encode_module sasm_module in
  encoded

(* 保存 .sasm 文件 *)
let write_sasm (path : string) (data : string) : unit =
  let ch = open_out path in
  output_string ch data;
  close_out ch

(* 主入口 *)
let () =
  let args = Sys.argv in
  if Array.length args < 3 then begin
    Printf.eprintf "用法: %s compile <input.st> -o <output.sasm>\n" args.(0);
    Printf.eprintf "       %s compile <input.st> --dump\n" args.(0);
    Printf.eprintf "       %s analyze <input.st>\n" args.(0);
    exit 1
  end;
  match args.(1) with
  | "compile" ->
    let source = args.(2) in
    if Array.length args >= 4 && args.(3) = "-o" then begin
      let output = if Array.length args >= 5 then args.(4) else "output.sasm" in
      let sasm_data = compile_st_to_sasm source in
      write_sasm output sasm_data;
      Printf.printf "✓ 编译成功: %s → %s\n" source output
    end else if Array.length args >= 4 && args.(3) = "--dump" then begin
      let sasm_data = compile_st_to_sasm source in
      (* 以十六进制转储 *)
      String.iter (fun c -> Printf.printf "%02x " (Char.code c)) sasm_data;
      print_newline ()
    end else begin
      let _ = compile_st_to_sasm source in
      Printf.printf "✓ 编译成功: %s\n" source
    end
  | "analyze" ->
    let source = read_file args.(2) in
    let tokens = match L.lex source with
      | Some ts -> ts
      | None -> failwith "词法分析失败"
    in
    let ast = match P.parse tokens with
      | Some p -> p
      | None -> failwith "语法分析失败"
    in
    let corest = D.desugar_program ast in
    let result = A.analyze corest in
    Printf.printf "分析结果:\n";
    Printf.printf "  最大栈深度: %d\n" result.A.ar_max_stack_depth;
    Printf.printf "  预估 WCET:  %d\n" result.A.ar_estimated_wcet;
    Printf.printf "  循环有界:   %b\n" result.A.ar_all_loops_bounded
  | _ ->
    Printf.eprintf "未知命令: %s\n" args.(1);
    exit 1
