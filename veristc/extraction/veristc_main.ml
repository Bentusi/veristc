(* ================================================================
   veristc/extraction/veristc_main.ml
   Compiler command line: -c .st -> .sasm, -a analyzes .st

   This file is compiled after the OCaml code extracted from Coq.
   The extracted modules shadow several Stdlib names, so all native
   list/string operations use Stdlib.List / Stdlib.String.
   ================================================================ *)

module L = Lexer
module P = Parser
module I = Inline
module D = Desugar
module T = Typechecker
module F = Function_check
module C = Codegen
module G = Global_codegen
module A = Analysis
module E = Encoder

(* Ascii constructor bit order: Ascii a0..a7, a0 is the low bit. *)
let ascii_of_char (c : char) : Ascii.ascii =
  let n = Char.code c in
  let bit i = (n lsr i) land 1 <> 0 in
  let cb b = if b then Datatypes.Coq_true else Datatypes.Coq_false in
  Ascii.Ascii (cb (bit 0), cb (bit 1), cb (bit 2), cb (bit 3),
               cb (bit 4), cb (bit 5), cb (bit 6), cb (bit 7))

let rec coq_string_of_native (s : string) : String.string =
  let len = Stdlib.String.length s in
  let rec go i acc =
    if i < 0 then acc
    else
      let c = Stdlib.String.get s i in
      go (i - 1) (String.String (ascii_of_char c, acc))
  in
  go (len - 1) String.EmptyString

let char_of_ascii (a : Ascii.ascii) : char =
  match a with
  | Ascii.Ascii (a0, a1, a2, a3, a4, a5, a6, a7) ->
      let bit (b : Datatypes.bool) : int =
        match b with
        | Datatypes.Coq_true -> 1
        | Datatypes.Coq_false -> 0
      in
      Char.chr
        (bit a0 + 2 * bit a1 + 4 * bit a2 + 8 * bit a3 +
         16 * bit a4 + 32 * bit a5 + 64 * bit a6 + 128 * bit a7)

let rec native_of_coq_string (s : String.string) : string =
  match s with
  | String.EmptyString -> ""
  | String.String (c, rest) ->
      Stdlib.String.make 1 (char_of_ascii c) ^ native_of_coq_string rest

let read_file (path : string) : string =
  let ch = open_in path in
  let n = in_channel_length ch in
  let s = really_input_string ch n in
  close_in ch;
  s

let rec pos_to_int (p : BinNums.positive) : int =
  match p with
  | BinNums.Coq_xI rest -> 1 + 2 * pos_to_int rest
  | BinNums.Coq_xO rest -> 2 * pos_to_int rest
  | BinNums.Coq_xH -> 1

let z_to_int (z : BinNums.coq_Z) : int =
  match z with
  | BinNums.Z0 -> 0
  | BinNums.Zpos p -> pos_to_int p
  | BinNums.Zneg p -> - pos_to_int p

let rec z_bytes_to_string (zs : BinNums.coq_Z Datatypes.list) : string =
  match zs with
  | Datatypes.Coq_nil -> ""
  | Datatypes.Coq_cons (z, rest) ->
      let c = Char.chr (z_to_int z land 0xff) in
      let tail = z_bytes_to_string rest in
      Stdlib.String.make 1 c ^ tail

let rec coq_list_len (l : 'a Datatypes.list) : int =
  match l with
  | Datatypes.Coq_nil -> 0
  | Datatypes.Coq_cons (_, rest) -> 1 + coq_list_len rest

let rec coq_list_exists (predicate : 'a -> bool) : 'a Datatypes.list -> bool =
  function
  | Datatypes.Coq_nil -> false
  | Datatypes.Coq_cons (value, rest) ->
      predicate value || coq_list_exists predicate rest

let analysis_has_recursion (result : Analysis.analysis_result) : bool =
  coq_list_exists
    (function
      | Datatypes.Coq_pair (_, Datatypes.Coq_true) -> true
      | Datatypes.Coq_pair (_, Datatypes.Coq_false) -> false)
    result.Analysis.ar_has_recursion

let max_call_depth = 256

(* WS-F：把字节偏移映射回源文件的行/列，用于定位解析错误。 *)
let rec nat_to_int (n : Datatypes.nat) : int =
  match n with
  | Datatypes.O -> 0
  | Datatypes.S rest -> 1 + nat_to_int rest

let offset_to_line_col (src : string) (off : int) : int * int =
  let len = Stdlib.String.length src in
  let stop = if off > len then len else if off < 0 then 0 else off in
  let line = ref 1 in
  let col = ref 1 in
  for i = 0 to stop - 1 do
    if Stdlib.String.get src i = '\n' then (incr line; col := 1)
    else incr col
  done;
  (!line, !col)

let nth_nat (l : Datatypes.nat Datatypes.list) (idx : int) : int option =
  let rec go i l =
    match l with
    | Datatypes.Coq_cons (n, rest) -> if i = 0 then Some (nat_to_int n) else go (i - 1) rest
    | Datatypes.Coq_nil -> None
  in
  if idx < 0 then None else go idx l

(* Lex + parse; on failure report a source location instead of the
   generic "parser failed" message. *)
let parse_or_fail (native_src : string) (coq_src : String.string) =
  let tokens = match L.lex coq_src with
    | Some ts -> ts
    | None -> failwith "lexer failed"
  in
  match P.parse tokens with
  | Some p -> p
  | None ->
      let msg =
        match P.parse_fail_pos tokens, L.lex_offsets coq_src with
        | Some z, Some offs ->
            (match nth_nat offs (z_to_int z) with
             | Some off ->
                 let (ln, col) = offset_to_line_col native_src off in
                 Printf.sprintf "parser failed at line %d, col %d" ln col
             | None -> "parser failed")
        | _ -> "parser failed"
      in
      failwith msg

let crc32_table =
  Array.init 256 (fun n ->
      let crc = ref n in
      for _ = 0 to 7 do
        crc :=
          if (!crc land 1) <> 0 then
            0xEDB88320 lxor (!crc lsr 1)
          else
            !crc lsr 1
      done;
      !crc)

let crc32_range (data : string) (offset : int) (length : int) : int32 =
  let crc = ref 0xFFFFFFFF in
  for i = offset to offset + length - 1 do
    let index = (!crc lxor Char.code (Stdlib.String.get data i)) land 0xFF in
    crc := (!crc lsr 8) lxor crc32_table.(index)
  done;
  Int32.of_int ((!crc lxor 0xFFFFFFFF) land 0xFFFFFFFF)

let attach_crc32 (data : string) : string =
  let len = Stdlib.String.length data in
  if len < 10 then failwith "encoded module is too short for CRC32";
  let bytes = Bytes.of_string data in
  let crc = crc32_range data 6 (len - 10) in
  let value = Int32.to_int crc in
  Bytes.set bytes (len - 4) (Char.chr (value land 0xFF));
  Bytes.set bytes (len - 3) (Char.chr ((value lsr 8) land 0xFF));
  Bytes.set bytes (len - 2) (Char.chr ((value lsr 16) land 0xFF));
  Bytes.set bytes (len - 1) (Char.chr ((value lsr 24) land 0xFF));
  Bytes.to_string bytes

let compile_st_to_sasm (source_path : string) : string =
  let native_src = read_file source_path in
  let source = coq_string_of_native native_src in
  let parsed = parse_or_fail native_src source in
  (* 命名冲突 = 编译错误：上游库展开后的扁平命名空间中，
     重复的全局变量/POU 声明会导致两个逻辑变量静默共享内存 *)
  if T.check_no_duplicate_declarations parsed = Datatypes.Coq_false then
    failwith "duplicate global variable or POU name (naming conflict)";
  let prepared = match F.prepare_program parsed with
    | Some p -> p
    | None -> failwith "invalid FUNCTION declaration or missing PROGRAM"
  in
  begin match F.check_program_full_diag prepared with
  | None -> ()
  | Some msg -> failwith (native_of_coq_string msg)
  end;
  let normalized = match I.normalize_program prepared with
    | Some p -> p
    | None -> failwith "function normalization failed"
  in
  let ast = I.optimize_inline_program normalized in
  if coq_list_len ast.Safest.pou_list = 0 then
    failwith "parser produced empty program";
  let corest = D.desugar_program ast in
  if coq_list_len corest.Desugar.cprog_functions = 0 then
    failwith "desugar produced empty function list";
  let analysis = A.analyze corest in
  if analysis_has_recursion analysis then
    failwith "recursive calls are not supported";
  let stack_depth = z_to_int analysis.Analysis.ar_max_stack_depth in
  if stack_depth > max_call_depth then
    failwith
      (Printf.sprintf "static stack depth %d exceeds limit %d"
         stack_depth max_call_depth);
  let sasm_module = G.compile_program_gc corest in
  attach_crc32 (z_bytes_to_string (E.encode_module sasm_module))

let write_file (path : string) (data : string) : unit =
  let ch = open_out path in
  output_string ch data;
  close_out ch

let bool_to_string (b : Datatypes.bool) : string =
  match b with
  | Datatypes.Coq_true -> "true"
  | Datatypes.Coq_false -> "false"

let analyze_st (source_path : string) : unit =
  let native_src = read_file source_path in
  let source = coq_string_of_native native_src in
  let parsed = parse_or_fail native_src source in
  if T.check_no_duplicate_declarations parsed = Datatypes.Coq_false then
    failwith "duplicate global variable or POU name (naming conflict)";
  let prepared = match F.prepare_program parsed with
    | Some p -> p
    | None -> failwith "invalid FUNCTION declaration or missing PROGRAM"
  in
  begin match F.check_program_full_diag prepared with
  | None -> ()
  | Some msg -> failwith (native_of_coq_string msg)
  end;
  let normalized = match I.normalize_program prepared with
    | Some p -> p
    | None -> failwith "function normalization failed"
  in
  let ast = I.optimize_inline_program normalized in
  if coq_list_len ast.Safest.pou_list = 0 then
    failwith "parser produced empty program";
  let result = A.analyze (D.desugar_program ast) in
  Printf.printf "stack depth: %d\n" (z_to_int result.A.ar_max_stack_depth);
  Printf.printf "recursive calls: %s\n"
    (bool_to_string
       (if analysis_has_recursion result then Datatypes.Coq_true
        else Datatypes.Coq_false));
  Printf.printf "estimated wcet: %d\n" (z_to_int result.A.ar_estimated_wcet);
  Printf.printf "loops bounded: %s\n"
    (bool_to_string result.A.ar_all_loops_bounded)

let () =
  let args = Sys.argv in
  let usage () =
    Printf.eprintf
      "usage: %s [-a|-c] <input.st> [-o <output.sasm>]\n\
       \  -a  analyze (default)\n\
       \  -c  compile to .sasm\n" args.(0)
  in
  if Array.length args < 2 then begin
    usage ();
    exit 1
  end;
  let mode, source_index =
    match args.(1) with
    | "-a" -> `Analyze, 2
    | "-c" -> `Compile, 2
    | "-h" | "--help" -> usage (); exit 0
    | arg when Stdlib.String.length arg > 0 &&
               Stdlib.String.get arg 0 = '-' ->
        Printf.eprintf "unknown option: %s\n" arg;
        usage ();
        exit 1
    | _ -> `Analyze, 1
  in
  if Array.length args <= source_index then begin
    usage ();
    exit 1
  end;
  let source = args.(source_index) in
  match mode with
  | `Compile ->
      let sasm_data = compile_st_to_sasm source in
      let output =
        if Array.length args >= source_index + 3 &&
           args.(source_index + 1) = "-o" then
          args.(source_index + 2)
        else "output.sasm"
      in
      write_file output sasm_data;
      Printf.printf "compiled: %s -> %s\n" source output
  | `Analyze ->
      analyze_st source

