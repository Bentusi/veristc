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

let frontend (source_path : string) =
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
  corest

let compile_st_to_sasm (source_path : string) : string =
  let corest = frontend source_path in
  attach_crc32 (z_bytes_to_string (E.encode_module (G.compile_program_gc corest)))

let write_file (path : string) (data : string) : unit =
  let ch = open_out path in
  output_string ch data;
  close_out ch

let bool_to_string (b : Datatypes.bool) : string =
  match b with
  | Datatypes.Coq_true -> "true"
  | Datatypes.Coq_false -> "false"

(* ================================================================
   P2: 可重定位目标文件 .svobj（主机侧 OCaml 编码）

   布局（小端 / 定宽，无 LEB128；与 .sasm 风格一致）：
     Header(36B) | SYMTAB | RELOC | BLOCKS | IMAGE | CRC32(4B)
   链接器(P3) 为"信任+测试"层（不进安全核），故 .svobj 仅
   把跨模块链接点以相对量记录，不烘焙绝对地址：
     reloc.kind : 0=CALL_IDX  1=INST_BASE_IMM  2=GLOBAL_OFF
     sym.kind   : 0=FB_EXEC   1=INST_DATA      2=GLOBAL_EXT(未定义)
   GLOBAL_OFF 行由 VAR_IN_OUT 逐引用别名的实参地址立即数产生
   （addend = 全局线性地址 - GLOBAL_BASE），对应的全局以
   GLOBAL_EXT 符号登记，aux 恒为 0（重定位只依赖 addend）。
   符号/数据块按名字排序保证字节级确定性 (PRE-2)。
   ================================================================ *)

let rec sv_list_to_ocaml (l : 'a Datatypes.list) : 'a Stdlib.List.t =
  match l with
  | Datatypes.Coq_nil -> []
  | Datatypes.Coq_cons (x, rest) -> x :: sv_list_to_ocaml rest

let svobj_magic = "SOBJ"
let svobj_version = 1
let svobj_header_len = 36
let svobj_reloc_entry_len = 17

(* reloc_row = ((((nat,string),Z),Z),Z) -> (kind, sym, func_idx, off, addend) *)
let decode_reloc (r : G.reloc_row) : int * string * int * int * int =
  let Datatypes.Coq_pair (p3, addend) = r in
  let Datatypes.Coq_pair (p2, off) = p3 in
  let Datatypes.Coq_pair (kn, fidx) = p2 in
  let Datatypes.Coq_pair (kind_n, name_cs) = kn in
  (nat_to_int kind_n, native_of_coq_string name_cs,
   z_to_int fidx, z_to_int off, z_to_int addend)

(* inst = (((string,string),Z),Z) -> (iname, fbname, base, size) *)
let decode_inst c =
  let Datatypes.Coq_pair (xy, size) = c in
  let Datatypes.Coq_pair (ab, base) = xy in
  let Datatypes.Coq_pair (iname, fbname) = ab in
  (native_of_coq_string iname, native_of_coq_string fbname,
   z_to_int base, z_to_int size)

let put_u8 (b : Buffer.t) (v : int) : unit =
  Buffer.add_char b (Char.chr (v land 0xff))
let put_u16 (b : Buffer.t) (v : int) : unit =
  put_u8 b v; put_u8 b ((v lsr 8) land 0xff)
let put_u32 (b : Buffer.t) (v : int) : unit =
  put_u16 b (v land 0xffff); put_u16 b ((v lsr 16) land 0xffff)
let put_name (b : Buffer.t) (s : string) : unit =
  put_u16 b (Stdlib.String.length s); Buffer.add_string b s

(* 自带插入排序（避免与提取模块 List 的命名冲突）；比较器 <=0 时前置 *)
let rec sv_insert cmp x acc =
  match acc with
  | [] -> [x]
  | y :: rest -> if cmp x y <= 0 then x :: acc else y :: sv_insert cmp x rest

let sv_sort cmp l =
  Stdlib.List.fold_left (fun acc x -> sv_insert cmp x acc) [] l

let dedup_sorted (l : string Stdlib.List.t) : string Stdlib.List.t =
  Stdlib.List.fold_left
    (fun acc x -> if Stdlib.List.mem x acc then acc else acc @ [x])
    [] (sv_sort Stdlib.String.compare l)

(* sym_row = ((string,nat),Z) -> (name, kind, aux) *)
let decode_sym (r : G.sym_row) : string * int * int =
  let Datatypes.Coq_pair (kn, aux) = r in
  let Datatypes.Coq_pair (name_cs, kind_n) = kn in
  (native_of_coq_string name_cs, nat_to_int kind_n, z_to_int aux)

let emit_svobj (source_path : string) : string =
  let corest = frontend source_path in
  let relocs =
    Stdlib.List.map decode_reloc
      (sv_list_to_ocaml (G.compile_program_reloc_info corest)) in
  let blocks =
    sv_sort
      (fun (i1, _, _, _) (i2, _, _, _) -> Stdlib.String.compare i1 i2)
      (Stdlib.List.map decode_inst
         (sv_list_to_ocaml (G.compile_program_inst_info corest))) in
  (* SYMTAB 直接来自编译器导出表 (name, kind, aux)：
     kind 0=FB_EXEC(aux=本模块函数索引) 1=INST_DATA(aux=块基址)
     2=GLOBAL_EXT(aux=0)。主机侧不再从 reloc 行反推 aux。 *)
  let sym_rows =
    Stdlib.List.map decode_sym
      (sv_list_to_ocaml (G.compile_program_sym_info corest)) in
  let sym_names =
    dedup_sorted (Stdlib.List.map (fun (n, _, _) -> n) sym_rows) in
  let row_of n =
    try Stdlib.List.find (fun (m, _, _) -> m = n) sym_rows
    with Not_found ->
      failwith (Printf.sprintf "svobj: symbol %s has no info row" n)
  in
  let sym_index = Stdlib.List.mapi (fun i s -> (s, i)) sym_names in
  let sym_idx_of s =
    try Stdlib.List.assoc s sym_index
    with Not_found ->
      failwith (Printf.sprintf "svobj: reloc symbol %s missing from symtab" s) in
  let symtab = Buffer.create 256 in
  Stdlib.List.iter (fun s ->
      let (_, k, a) = row_of s in
      put_name symtab s; put_u8 symtab k; put_u32 symtab a) sym_names;
  let reloc_buf = Buffer.create 256 in
  Stdlib.List.iter (fun (k, s, f, o, a) ->
      put_u8 reloc_buf k;
      put_u32 reloc_buf (sym_idx_of s);
      put_u32 reloc_buf f;
      put_u32 reloc_buf o;
      put_u32 reloc_buf a) relocs;
  let block_buf = Buffer.create 128 in
  Stdlib.List.iter (fun (i, fb, base, sz) ->
      put_name block_buf i; put_name block_buf fb;
      put_u32 block_buf base; put_u32 block_buf sz) blocks;
  let image = z_bytes_to_string (E.encode_module (G.compile_program_gc corest)) in
  let st_s = Buffer.contents symtab in
  let rl_s = Buffer.contents reloc_buf in
  let bl_s = Buffer.contents block_buf in
  let out = Buffer.create 1024 in
  Buffer.add_string out svobj_magic;
  put_u16 out svobj_version;
  put_u16 out 0;
  put_u32 out (Stdlib.List.length sym_names);
  put_u32 out (Stdlib.List.length relocs);
  put_u32 out (Stdlib.List.length blocks);
  put_u32 out (Stdlib.String.length st_s);
  put_u32 out (Stdlib.String.length rl_s);
  put_u32 out (Stdlib.String.length bl_s);
  put_u32 out (Stdlib.String.length image);
  Buffer.add_string out st_s;
  Buffer.add_string out rl_s;
  Buffer.add_string out bl_s;
  Buffer.add_string out image;
  let body = Buffer.contents out in
  let crc = crc32_range body 0 (Stdlib.String.length body) in
  put_u32 out (Int32.to_int crc);
  Buffer.contents out

let verify_svobj (path : string) : unit =
  let data = read_file path in
  let n = Stdlib.String.length data in
  let g8 i = Char.code (Stdlib.String.get data i) in
  let g16 i = g8 i + (g8 (i + 1) lsl 8) in
  let g32 i =
    (g8 i) + (g8 (i + 1) lsl 8) + (g8 (i + 2) lsl 16) + (g8 (i + 3) lsl 24) in
  if n < svobj_header_len + 4 then failwith "svobj: file too short";
  if Stdlib.String.sub data 0 4 <> svobj_magic then failwith "svobj: bad magic";
  let version = g16 4 in
  if version <> svobj_version then
    failwith (Printf.sprintf "svobj: unsupported version %d" version);
  let n_syms = g32 8 in
  let n_relocs = g32 12 in
  let n_blocks = g32 16 in
  let st_len = g32 20 in
  let rl_len = g32 24 in
  let bl_len = g32 28 in
  let img_len = g32 32 in
  let expect_total =
    svobj_header_len + st_len + rl_len + bl_len + img_len + 4 in
  if expect_total <> n then
    failwith (Printf.sprintf "svobj: length mismatch (header %d, file %d)"
                expect_total n);
  if rl_len <> n_relocs * svobj_reloc_entry_len then
    failwith (Printf.sprintf "svobj: reloc size %d != %d*%d"
                rl_len n_relocs svobj_reloc_entry_len);
  let stored_crc = g32 (n - 4) in
  let calc_crc = Int32.to_int (crc32_range data 0 (n - 4)) in
  if (stored_crc land 0xFFFFFFFF) <> (calc_crc land 0xFFFFFFFF) then
    failwith "svobj: CRC32 mismatch";
  let rec walk_symtab off left cnt =
    if left = 0 then cnt
    else if off + 2 > svobj_header_len + st_len then
      failwith "svobj: symtab truncated"
    else
      let nlen = g16 off in
      let entry = 2 + nlen + 1 + 4 in
      if off + entry > svobj_header_len + st_len then
        failwith "svobj: symtab overrun";
      walk_symtab (off + entry) (left - 1) (cnt + 1)
  in
  let got_syms = walk_symtab svobj_header_len n_syms 0 in
  if got_syms <> n_syms then failwith "svobj: symtab count mismatch";
  (* RELOC 段逐条校验：符号索引在范围内，并统计各重定位类型 *)
  let reloc_base = svobj_header_len + st_len in
  let rec walk_reloc off left (c, i, g, bad) =
    if left = 0 then (c, i, g, bad)
    else
      let k = g8 off in
      let sidx = g32 (off + 1) in
      let (c, i, g, bad) =
        match k with
        | 0 -> (c + 1, i, g, bad)
        | 1 -> (c, i + 1, g, bad)
        | 2 -> (c, i, g + 1, bad)
        | _ -> (c, i, g, bad + 1)
        in
      let bad = if sidx >= n_syms then bad + 1 else bad in
      walk_reloc (off + svobj_reloc_entry_len) (left - 1) (c, i, g, bad)
  in
  let n_call, n_inst, n_global, n_bad =
    walk_reloc reloc_base n_relocs (0, 0, 0, 0)
  in
  if n_bad <> 0 then
    failwith (Printf.sprintf "svobj: %d reloc entr(y|ies) invalid (bad kind or symbol index)"
                n_bad);
  Printf.printf
    "svobj OK: syms=%d relocs=%d (call=%d inst=%d global=%d) blocks=%d image=%dB crc=%08x\n"
    n_syms n_relocs n_call n_inst n_global n_blocks img_len
    (stored_crc land 0xFFFFFFFF)

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
      "usage: %s [-a|-c|-g|-x] <input> [-o <output>]\n\
       \  -a  analyze (default)\n\
       \  -c  compile to .sasm\n\
       \  -g  compile to relocatable .svobj\n\
       \  -x  verify a .svobj (structure + CRC round-trip)\n" args.(0)
  in
  if Array.length args < 2 then begin
    usage ();
    exit 1
  end;
  let mode, source_index =
    match args.(1) with
    | "-a" -> `Analyze, 2
    | "-c" -> `Compile, 2
    | "-g" -> `Object, 2
    | "-x" -> `Verify, 2
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
  let out_path default_name =
    if Array.length args >= source_index + 3 &&
       args.(source_index + 1) = "-o" then
      args.(source_index + 2)
    else default_name
  in
  match mode with
  | `Compile ->
      let sasm_data = compile_st_to_sasm source in
      let output = out_path "output.sasm" in
      write_file output sasm_data;
      Printf.printf "compiled: %s -> %s\n" source output
  | `Object ->
      let svobj_data = emit_svobj source in
      let output = out_path "output.svobj" in
      write_file output svobj_data;
      Printf.printf "emitted: %s -> %s\n" source output
  | `Verify ->
      verify_svobj source
  | `Analyze ->
      analyze_st source

