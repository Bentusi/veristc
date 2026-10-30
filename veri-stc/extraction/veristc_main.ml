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

let rec sv_list_to_ocaml (l : 'a Datatypes.list) : 'a Stdlib.List.t =
  match l with
  | Datatypes.Coq_nil -> []
  | Datatypes.Coq_cons (x, rest) -> x :: sv_list_to_ocaml rest

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

(* ================================================================
   G0 产出物 1 —— 机器可读接口
   ------------------------------------------------------------
   退出码约定（协议表见 spec/safest-spec.md 工具链节）：
     0  成功
     11 CLI 用法错误（含缺少 -o、输入文件不可读）
     21 词法/语法失败
     22 语义诊断（KIND=type/purity/declaration/... 任一）
     23 资源上限拒绝（栈深/WCET/循环上界）
     24 制品读写或校验失败
     25 内部异常（不应出现；出现即编译器 bug）
   旧实现没有任何顶层 handler，30 处 failwith 全部以未捕获异常出栈，
   退出码恒为 2、并把 OCaml 运行时栈打到 stderr。现在所有拒绝路径
   显式携带类别，文本输出逐字不变（既有 71 项断言依赖 KIND=/VAR= 子串）。
   ================================================================ *)

let exit_ok = 0
let exit_usage = 11
let exit_syntax = 21
let exit_semantic = 22
let exit_resource = 23
let exit_artifact = 24
let exit_internal = 25

exception Fatal of int * string

let die (code : int) (msg : string) : 'a = raise (Fatal (code, msg))

(* --json：stdout 只出 NDJSON，拒绝路径不再打印 OCaml 运行时栈。 *)
let json_mode = ref false

(* --json 时把解析失败的行列带出来（当前唯一有真实源位置的路径）。 *)
let syntax_loc : (int * int) option ref = ref None

let json_escape (s : string) : string =
  let buf = Buffer.create (Stdlib.String.length s + 8) in
  Stdlib.String.iter
    (fun c ->
      let code = Char.code c in
      match c with
      | '"' -> Buffer.add_string buf "\\\""
      | '\\' -> Buffer.add_string buf "\\\\"
      | '\n' -> Buffer.add_string buf "\\n"
      | '\r' -> Buffer.add_string buf "\\r"
      | '\t' -> Buffer.add_string buf "\\t"
      | _ when code < 0x20 ->
          Buffer.add_string buf (Printf.sprintf "\\u%04x" code)
      | _ -> Buffer.add_char buf c)
    s;
  Buffer.contents buf

(* diag_row = ((pou, var), kind, msg)，Coq 元组左结合。 *)
let decode_diag_row (r : F.diag_row) :
      string * string option * string * string =
  let Datatypes.Coq_pair (p2, msg_cs) = r in
  let Datatypes.Coq_pair (p1, kind_cs) = p2 in
  let Datatypes.Coq_pair (pou_cs, var_opt) = p1 in
  let var =
    match var_opt with
    | None -> None
    | Some v -> Some (native_of_coq_string v)
  in
  (native_of_coq_string pou_cs, var,
   native_of_coq_string kind_cs, native_of_coq_string msg_cs)

(* NDJSON：一行一条诊断，字段固定 pou/var/kind/loc/msg。
   var 为派生名（实例#字段），IDE 侧据此反查画布上的块与端口。
   loc 沿用文本模式的 POU=/VAR= 词汇，前端可直接显示。 *)
let emit_json_diag (pou, var, kind, msg) : unit =
  let var_text = match var with Some v -> v | None -> "-" in
  Printf.printf "{\"pou\":\"%s\",\"var\":%s,\"kind\":\"%s\",\"loc\":\"POU=%s VAR=%s\",\"msg\":\"%s\"}\n"
    (json_escape pou)
    (match var with
     | Some v -> "\"" ^ json_escape v ^ "\""
     | None -> "null")
    (json_escape kind)
    (json_escape pou) (json_escape var_text) (json_escape msg)

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
    | None -> die exit_syntax "lexer failed"
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
                 syntax_loc := Some (ln, col);
                 Printf.sprintf "parser failed at line %d, col %d" ln col
             | None -> "parser failed")
        | _ -> "parser failed"
      in
      die exit_syntax msg

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
  if len < 10 then die exit_internal "encoded module is too short for CRC32";
  let bytes = Bytes.of_string data in
  let crc = crc32_range data 6 (len - 10) in
  let value = Int32.to_int crc in
  Bytes.set bytes (len - 4) (Char.chr (value land 0xFF));
  Bytes.set bytes (len - 3) (Char.chr ((value lsr 8) land 0xFF));
  Bytes.set bytes (len - 2) (Char.chr ((value lsr 16) land 0xFF));
  Bytes.set bytes (len - 1) (Char.chr ((value lsr 24) land 0xFF));
  Bytes.to_string bytes

(* ---------------- 定宽小端写入（.sasm 段 7 与 .svobj 共用）---------------- *)

let put_u8 (b : Buffer.t) (v : int) : unit =
  Buffer.add_char b (Char.chr (v land 0xff))
let put_u16 (b : Buffer.t) (v : int) : unit =
  put_u8 b v; put_u8 b ((v lsr 8) land 0xff)
let put_u32 (b : Buffer.t) (v : int) : unit =
  put_u16 b (v land 0xffff); put_u16 b ((v lsr 16) land 0xffff)

(* ================================================================
   段 7 Debug：名字 → 地址符号表（协议见 spec/safeasm-spec.md §4.8）

   字节布局（段体，段头与其他段同格式）：
     STRPOOL : u32 count | { u32 len | byte[len] }*
     SYMTAB  : u32 count | { u32 name_off | u32 mem_addr | u8 tag | u8 size | u16 flags }*
   name_off 以 STRPOOL 首个条目的 u32 len 字段为偏移 0（即 count 之后）。
   行来源为 Coq 的 compile_program_debug_info（地址唯一权威 = build_global_env）；
   本侧只做排序/去重/编码，不重算任何偏移。
   ================================================================ *)

(* debug_row = ((name, addr), type_tag) —— Coq 元组左结合 *)
let decode_debug_row (r : G.debug_row) : string * int * int =
  let Datatypes.Coq_pair (na, tag_n) = r in
  let Datatypes.Coq_pair (name_cs, addr) = na in
  (native_of_coq_string name_cs, z_to_int addr, nat_to_int tag_n)

let emit_debug_section (rows : (string * int * int) Stdlib.List.t) : string =
  if Stdlib.List.length rows = 0 then ""
  else begin
    (* 名字升序 + 相邻去重：地址全部来自 Coq 侧，本侧不裁决同名冲突 *)
    let by_name (a, _, _) (b, _, _) = Stdlib.String.compare a b in
    let rec drop_dup = function
      | ([] | [_]) as l -> l
      | ((n1, _, _) as x) :: (((n2, _, _) :: _) as rest) ->
          if Stdlib.String.equal n1 n2 then drop_dup rest else x :: drop_dup rest
    in
    let syms = drop_dup (Stdlib.List.sort by_name rows) in
    let pool = Buffer.create 1024 in
    let offs =
      Stdlib.List.map
        (fun (name, _, _) ->
           let off = Buffer.length pool in
           put_u32 pool (Stdlib.String.length name);
           Buffer.add_string pool name;
           (name, off))
        syms
    in
    let tab = Buffer.create (8 + 14 * Stdlib.List.length syms) in
    put_u32 tab (Stdlib.List.length syms);
    Stdlib.List.iter
      (fun (name, addr, tag) ->
         put_u32 tab (Stdlib.List.assoc name offs);
         put_u32 tab addr;
         put_u8 tab tag;
         put_u8 tab 4;   (* size：每个全局槽恒为一个 int32 单字 *)
         put_u16 tab 0)  (* flags：保留，必须为 0 *)
      syms;
    let body = Buffer.create (Buffer.length pool + Buffer.length tab) in
    put_u32 body (Stdlib.List.length syms);
    Buffer.add_buffer body pool;
    Buffer.add_buffer body tab;
    let sec = Buffer.create (Buffer.length body + 8) in
    put_u8 sec 7;                          (* SEC_DEBUG *)
    put_u32 sec (Buffer.length body);
    put_u8 sec 0;                          (* reserved *)
    put_u16 sec 0;                         (* flags *)
    Buffer.add_buffer sec body;
    Buffer.contents sec
  end

let splice_debug (image : string) (body : string) : string =
  let n = Stdlib.String.length image in
  if Stdlib.String.length body = 0 || n < 4 then image
  else
    Stdlib.String.sub image 0 (n - 4) ^ body
    ^ Stdlib.String.make 4 '\x00'

(* ================================================================
   段 3 IOMAP 的工程量标尺（scale / bias，两个 float64）

   Coq 拿不到 float 的 IEEE-754 位（PrimFloat 靠提取期实现；与 encoder.v 里
   F32/F64_CONST 立即数写成全零是同一个缺口），所以这 16 字节由主机侧覆盖，
   值逐条取自 compile_module_io_cal_info。条目布局见 spec/safeasm-spec.md §4.4：
   条目长 42，scale 在 [18-25]，bias 在 [26-33]。
   写序与 encode_io_entries 一致（fold_right，不重排）；条数或段长对不上即拒绝产出，
   绝不错位缩放。
   ================================================================ *)

let iomap_sec_id = 3
let iomap_entry_len = 42
let iomap_count_len = 4
let iomap_scale_off = 18
let iomap_bias_off = 26

(* float64 -> 8 little-endian bytes. Shifts stay in int64: truncating the bit
   pattern to an OCaml `int` drops bit 63, which would silently turn every
   negative value positive. *)
let put_f64 (b : Bytes.t) (off : int) (v : float) : unit =
  let raw = Stdlib.Int64.bits_of_float v in
  for i = 0 to 7 do
    Bytes.set b (off + i)
      (Char.chr
         (Stdlib.Int64.to_int
            (Stdlib.Int64.logand
               (Stdlib.Int64.shift_right_logical raw (8 * i)) 255L)))
  done

(* float -> IEEE-754 binary32, 4 little-endian bytes (REAL is single
   precision on the wire; safeasm_interp.c reads it back as a float).
   The lexer builds real literals as binary64, so narrowing happens here.
   OCaml's stdlib has no Float32 module, hence the explicit
   round-to-nearest-even conversion: the result is bit-identical to what a
   C compiler produces for a `(float)` cast of the same literal. *)
let f32_bits_of_float (v : float) : Stdlib.Int64.t =
  let open Stdlib.Int64 in
  let raw = bits_of_float v in
  (* the binary64 sign bit is moved down to the binary32 sign position first,
     so every branch below ORs into a 32-bit value *)
  let sign = shift_right_logical (logand raw 0x8000000000000000L) 32 in
  let exp = to_int (logand (shift_right_logical raw 52) 0x7FFL) in
  let frac = logand raw 0x000FFFFFFFFFFFFFL in
  let inf = logor sign 0x7F800000L in
  (* round (s / 2^shift) to nearest, ties to even; s is a positive int64 and
     the caller guarantees 0 < shift < 53 *)
  let round_shift s shift =
    let q = shift_right_logical s shift in
    let rem = logand s (sub (shift_left 1L shift) 1L) in
    let half = shift_left 1L (shift - 1) in
    match compare rem half with
    | 1 -> add q 1L
    | 0 -> if compare (logand q 1L) 0L = 0 then q else add q 1L
    | _ -> q
  in
  let bits =
    if exp = 0x7FF then
      (* +-Inf stays, any NaN becomes a quiet NaN *)
      if frac = 0L then inf else logor sign 0x7FC00000L
    else if exp = 0 then
      (* binary64 subnormals are all far below half of the smallest binary32
         subnormal, so they narrow to signed zero *)
      sign
    else
      let e = exp - 1023 in
      let s = logor 0x0010000000000000L frac in
      if e >= 128 then inf
      else if e >= -126 then
        let t = round_shift s 29 in
        if compare t 0x1000000L = 0 then
          (* rounding carried into the next binade *)
          if e + 1 >= 128 then inf
          else logor sign (shift_left (of_int (e + 1 + 127)) 23)
        else
          logor sign
            (logor (shift_left (of_int (e + 127)) 23)
               (sub t 0x800000L))
      else
        (* binary32 subnormal: mantissa = s / 2^(-e-97) *)
        let shift = -e - 97 in
        if shift >= 54 then sign else logor sign (round_shift s shift)
  in
  logand bits 0xFFFFFFFFL

let put_f32 (b : Bytes.t) (off : int) (v : float) : unit =
  let raw = f32_bits_of_float v in
  for i = 0 to 3 do
    Bytes.set b (off + i)
      (Char.chr
         (Stdlib.Int64.to_int
            (Stdlib.Int64.logand
               (Stdlib.Int64.shift_right_logical raw (8 * i)) 255L)))
  done

(* Little-endian u32 read; `label` names the caller in the bounds message. *)
let get_u32_le (b : Bytes.t) (label : string) (off : int) : int =
  if off + 4 > Bytes.length b then
    die exit_internal (Printf.sprintf "%s: short read" label)
  else
    Char.code (Bytes.get b off)
    lor (Char.code (Bytes.get b (off + 1)) lsl 8)
    lor (Char.code (Bytes.get b (off + 2)) lsl 16)
    lor (Char.code (Bytes.get b (off + 3)) lsl 24)

(* Walk the section list of an encoded image and return (data_start, length) of
   the section with the given id. The trailing 4-byte CRC placeholder is not
   covered, so a section claiming to run past it is refused. *)
let find_section (b : Bytes.t) (label : string) (sec_id : int) : int * int =
  let sections_end = Bytes.length b - 4 in
  let rec go off =
    if off + 8 > sections_end then None
    else
      let sec_len = get_u32_le b label (off + 1) in
      if sec_len > sections_end - off - 8 then None
      else if Char.code (Bytes.get b off) = sec_id then Some (off + 8, sec_len)
      else go (off + 8 + sec_len)
  in
  match go 6 with
  | Some r -> r
  | None ->
      die exit_internal
        (Printf.sprintf "%s section (%d) not found in encoded module" label sec_id)

(* io_cal_row = ((channel, scale), bias) —— Coq 元组左结合 *)
let decode_io_cal (r : G.io_cal_row) : int * float * float =
  let Datatypes.Coq_pair (cb, bias) = r in
  let Datatypes.Coq_pair (ch, scale) = cb in
  (z_to_int ch, scale, bias)

let patch_iomap_cal (image : string)
                    (rows : (int * float * float) Stdlib.List.t) : string =
  let b = Bytes.of_string image in
  let get_u32 = get_u32_le b "iomap" in
  let (body, sec_len) = find_section b "IOMAP" iomap_sec_id in
  let count = get_u32 body in
  if Stdlib.List.length rows <> count then
    die exit_internal
      (Printf.sprintf "iomap calibration count %d != encoded entries %d"
         (Stdlib.List.length rows) count)
  (* 段长度必须正好容纳 count 个定宽条目，否则条目边界不可信 *)
  else if sec_len <> iomap_count_len + count * iomap_entry_len then
    die exit_internal "iomap section length does not match its entry count"
  else begin
    Stdlib.List.iteri
      (fun i (ch, scale, bias) ->
         let e = body + iomap_count_len + (i * iomap_entry_len) in
         (* 逐条核对通道号：行序与编码序必须一致，否则缩放会写到别的通道上 *)
         if get_u32 (e + 8) <> ch then
           die exit_internal
             (Printf.sprintf
                "iomap calibration row %d: channel %d != encoded channel %d"
                i ch (get_u32 (e + 8)));
         put_f64 b (e + iomap_scale_off) scale;
         put_f64 b (e + iomap_bias_off) bias)
      rows;
    Bytes.to_string b
  end

(* ================================================================
   Section 4 (CODE) float immediates

   encoder.v writes zero placeholders because Coq cannot reach IEEE-754 bits
   (the same gap as section 3's scale/bias); Encoder.encode_code_float_rows
   supplies the offsets and the host writes the real values back: F32_CONST
   gets 4 single-precision bytes, F64_CONST 8 double-precision bytes, which is
   exactly what safeasm_interp.c reads. Row order is encoding order (each
   function is prefixed by 8 bytes of index + body length).

   Every row is checked three ways and the artifact is refused on any mismatch
   instead of patching the wrong slot:
     1 the offset lies inside the section and that byte really is 0x43/0x44;
     2 the following width bytes are still the zero placeholder (non-zero means
       the rows no longer line up with the layout, or were already written);
     3 offsets increase and each row starts at or after the previous row's end,
       so rows cannot overlap.
   ================================================================ *)

let code_sec_id = 4

(* float_imm_row = (offset, value) *)
let decode_float_imm (r : E.float_imm_row) : int * float =
  let Datatypes.Coq_pair (off, v) = r in
  (z_to_int off, v)

let patch_code_floats (image : string)
                      (rows : (int * float) Stdlib.List.t) : string =
  if Stdlib.List.length rows = 0 then image
  else
    let b = Bytes.of_string image in
    let (body, sec_len) = find_section b "CODE" code_sec_id in
    let prev_end = ref 0 in
    Stdlib.List.iter
      (fun (off, v) ->
         let at = body + off in
         if off < 0 || at + 1 >= body + sec_len then
           die exit_internal
             (Printf.sprintf "code float row offset %d outside the %d-byte code section"
                off sec_len);
         let width =
           match Char.code (Bytes.get b at) with
           | 0x43 -> 4
           | 0x44 -> 8
           | op ->
               die exit_internal
                 (Printf.sprintf
                    "code float row at %d: opcode 0x%02x is not F32/F64_CONST"
                    off op)
         in
         if at + 1 + width > body + sec_len then
           die exit_internal
             (Printf.sprintf "code float row at %d: immediate runs past the code section" off);
         if off < !prev_end then
           die exit_internal
             (Printf.sprintf
                "code float row at %d out of order or overlapping (previous row ends at %d)"
                off !prev_end);
         prev_end := off + 1 + width;
         for i = 1 to width do
           if Bytes.get b (at + i) <> '\x00' then
             die exit_internal
               (Printf.sprintf
                  "code float row at %d: immediate is not the zero placeholder" off)
         done;
         if width = 4 then put_f32 b (at + 1) v else put_f64 b (at + 1) v)
      rows;
    Bytes.to_string b

(* The encoded image with every host-side truth patched in: section 3 scale/bias
   and section 4 float immediates. `-c` and `-g` must both go through here, or
   the IMAGE embedded in a .svobj drifts from the standalone .sasm. *)
let encode_patched_image module_ir =
  let bytes = z_bytes_to_string (E.encode_module module_ir) in
  let with_cal =
    patch_iomap_cal
      bytes
      (Stdlib.List.map decode_io_cal
         (sv_list_to_ocaml (G.compile_module_io_cal_info module_ir)))
  in
  patch_code_floats
    with_cal
    (Stdlib.List.map decode_float_imm
       (sv_list_to_ocaml (E.encode_code_float_rows module_ir)))

let frontend (source_path : string) =
  let native_src =
    try read_file source_path
    with Sys_error e -> die exit_usage e
  in
  let source = coq_string_of_native native_src in
  let parsed = parse_or_fail native_src source in
  (* 命名冲突 = 编译错误：上游库展开后的扁平命名空间中，
     重复的全局变量/POU 声明会导致两个逻辑变量静默共享内存 *)
  if T.check_no_duplicate_declarations parsed = Datatypes.Coq_false then
    die exit_semantic
      "duplicate global variable or POU name (naming conflict)";
  let prepared = match F.prepare_program parsed with
    | Some p -> p
    | None -> die exit_semantic "invalid FUNCTION declaration or missing PROGRAM"
  in
  (* prepare_program 会 expand_instances 派生实例字段名（如 a1#LAST）。
     派生名与用户声明同名时二者落到同一全局槽位、互相覆盖，而展开前的
     检查看不到派生名，故必须在展开之后再查一次，并报出冲突的名字。
     （派生名连接符 `#` 不在标识符文法内 ⇒ 用户已无法书写派生名，本检查
       现在兜住的是 FB 内部同名字段等展开自身产生的重名。） *)
  begin match T.duplicate_declaration_msg prepared with
  | Some nm ->
      die exit_semantic
        (Printf.sprintf
           "duplicate global variable or POU name '%s' after instance \
            expansion (naming conflict)"
           (native_of_coq_string nm))
  | None -> ()
  end;
  (* 文本模式沿用单条渲染 API（既有断言依赖其逐字输出）；--json 走全量行。 *)
  if !json_mode then begin
    let rows =
      Stdlib.List.map decode_diag_row (sv_list_to_ocaml (F.check_program_full_diag_rows prepared))
    in
    Stdlib.List.iter emit_json_diag rows;
    if Stdlib.List.length rows > 0 then die exit_semantic ""
  end else begin match F.check_program_full_diag prepared with
    | None -> ()
    | Some msg -> die exit_semantic (native_of_coq_string msg)
  end;
  let normalized = match I.normalize_program prepared with
    | Some p -> p
    | None -> die exit_internal "function normalization failed"
  in
  let ast = I.optimize_inline_program normalized in
  if coq_list_len ast.Safest.pou_list = 0 then
    die exit_internal "parser produced empty program";
  let corest = D.desugar_program ast in
  if coq_list_len corest.Desugar.cprog_functions = 0 then
    die exit_internal "desugar produced empty function list";
  let analysis = A.analyze corest in
  if analysis_has_recursion analysis then
    die exit_semantic "recursive calls are not supported";
  let stack_depth = z_to_int analysis.Analysis.ar_max_stack_depth in
  if stack_depth > max_call_depth then
    die exit_resource
      (Printf.sprintf "static stack depth %d exceeds limit %d"
         stack_depth max_call_depth);
  corest

let compile_st_to_sasm (source_path : string) : string =
  let corest = frontend source_path in
  let module_ir = G.compile_program_gc corest in
  let image = encode_patched_image module_ir in
  let debug =
    emit_debug_section
      (Stdlib.List.map decode_debug_row
         (sv_list_to_ocaml (G.compile_program_debug_info corest)))
  in
  (* 段 7 插在尾部 CRC 占位之前，CRC 覆盖 [6, len-4) 自动把它算进去 *)
  attach_crc32 (splice_debug image debug)

let write_file (path : string) (data : string) : unit =
  let ch =
    try open_out path
    with Sys_error e -> die exit_artifact e
  in
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
      die exit_internal (Printf.sprintf "svobj: symbol %s has no info row" n)
  in
  let sym_index = Stdlib.List.mapi (fun i s -> (s, i)) sym_names in
  let sym_idx_of s =
    try Stdlib.List.assoc s sym_index
    with Not_found ->
      die exit_internal (Printf.sprintf "svobj: reloc symbol %s missing from symtab" s) in
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
  let module_ir = G.compile_program_gc corest in
  (* svobj 内嵌的 IMAGE 与 -c 产物同源，量程同样必须是真值：
     否则 P3 链接出来的 .sasm 会带着 scale=0 的 IOMAP 条目 *)
  let image = encode_patched_image module_ir in
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
  if n < svobj_header_len + 4 then die exit_artifact "svobj: file too short";
  if Stdlib.String.sub data 0 4 <> svobj_magic then die exit_artifact "svobj: bad magic";
  let version = g16 4 in
  if version <> svobj_version then
    die exit_artifact (Printf.sprintf "svobj: unsupported version %d" version);
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
    die exit_artifact (Printf.sprintf "svobj: length mismatch (header %d, file %d)"
                expect_total n);
  if rl_len <> n_relocs * svobj_reloc_entry_len then
    die exit_artifact (Printf.sprintf "svobj: reloc size %d != %d*%d"
                rl_len n_relocs svobj_reloc_entry_len);
  let stored_crc = g32 (n - 4) in
  let calc_crc = Int32.to_int (crc32_range data 0 (n - 4)) in
  if (stored_crc land 0xFFFFFFFF) <> (calc_crc land 0xFFFFFFFF) then
    die exit_artifact "svobj: CRC32 mismatch";
  let rec walk_symtab off left cnt =
    if left = 0 then cnt
    else if off + 2 > svobj_header_len + st_len then
      die exit_artifact "svobj: symtab truncated"
    else
      let nlen = g16 off in
      let entry = 2 + nlen + 1 + 4 in
      if off + entry > svobj_header_len + st_len then
        die exit_artifact "svobj: symtab overrun";
      walk_symtab (off + entry) (left - 1) (cnt + 1)
  in
  let got_syms = walk_symtab svobj_header_len n_syms 0 in
  if got_syms <> n_syms then die exit_artifact "svobj: symtab count mismatch";
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
    die exit_artifact (Printf.sprintf "svobj: %d reloc entr(y|ies) invalid (bad kind or symbol index)"
                n_bad);
  Printf.printf
    "svobj OK: syms=%d relocs=%d (call=%d inst=%d global=%d) blocks=%d image=%dB crc=%08x\n"
    n_syms n_relocs n_call n_inst n_global n_blocks img_len
    (stored_crc land 0xFFFFFFFF)

let analyze_st (source_path : string) : unit =
  let native_src =
    try read_file source_path
    with Sys_error e -> die exit_usage e
  in
  let source = coq_string_of_native native_src in
  let parsed = parse_or_fail native_src source in
  if T.check_no_duplicate_declarations parsed = Datatypes.Coq_false then
    die exit_semantic "duplicate global variable or POU name (naming conflict)";
  let prepared = match F.prepare_program parsed with
    | Some p -> p
    | None -> die exit_semantic "invalid FUNCTION declaration or missing PROGRAM"
  in
  begin match T.duplicate_declaration_msg prepared with
  | Some nm ->
      die exit_semantic
        (Printf.sprintf
           "duplicate global variable or POU name '%s' after instance \
            expansion (naming conflict)"
           (native_of_coq_string nm))
  | None -> ()
  end;
  if !json_mode then begin
    let rows =
      Stdlib.List.map decode_diag_row (sv_list_to_ocaml (F.check_program_full_diag_rows prepared))
    in
    Stdlib.List.iter emit_json_diag rows;
    if Stdlib.List.length rows > 0 then die exit_semantic ""
  end else begin match F.check_program_full_diag prepared with
    | None -> ()
    | Some msg -> die exit_semantic (native_of_coq_string msg)
  end;
  let normalized = match I.normalize_program prepared with
    | Some p -> p
    | None -> die exit_internal "function normalization failed"
  in
  let ast = I.optimize_inline_program normalized in
  if coq_list_len ast.Safest.pou_list = 0 then
    die exit_internal "parser produced empty program";
  let result = A.analyze (D.desugar_program ast) in
  (* -a 只报告、不拒绝：递归与栈深在这里是指标，不是错误。 *)
  if !json_mode then
    Printf.printf
      "{\"kind\":\"analysis\",\"stack_depth\":%d,\"recursive\":%s,\"wcet\":%d,\"loops_bounded\":%s}\n"
      (z_to_int result.A.ar_max_stack_depth)
      (bool_to_string
         (if analysis_has_recursion result then Datatypes.Coq_true
          else Datatypes.Coq_false))
      (z_to_int result.A.ar_estimated_wcet)
      (bool_to_string result.A.ar_all_loops_bounded)
  else begin
    Printf.printf "stack depth: %d\n" (z_to_int result.A.ar_max_stack_depth);
    Printf.printf "recursive calls: %s\n"
      (bool_to_string
         (if analysis_has_recursion result then Datatypes.Coq_true
          else Datatypes.Coq_false));
    Printf.printf "estimated wcet: %d\n" (z_to_int result.A.ar_estimated_wcet);
    Printf.printf "loops bounded: %s\n"
      (bool_to_string result.A.ar_all_loops_bounded)
  end

(* ================================================================
   命令行
   ------------------------------------------------------------
   旧解析只认 args.(1) 上的动作选项，且 -o 必须紧跟输入文件后的固定
   槽位，位置不对就静默忽略、回退默认相对名并写进当前工作目录。现在
   选项可在任意位置；-c/-g 缺少 -o 直接判用法错误，编译器不再往 CWD
   落盘（IDE 后端按请求建独立工作目录，不依赖这一行为）。
   ================================================================ *)

type action = Analyze | Compile | Object | Verify | Help

let kind_of_code (code : int) : string =
  match code with
  | 11 -> "usage" | 21 -> "syntax" | 22 -> "semantic"
  | 23 -> "resource" | 24 -> "artifact" | _ -> "internal"

let usage_text (prog : string) : string =
  Printf.sprintf
    "usage: %s [-a|-c|-g|-x] [--json] <input> [-o <output>]\n\
     \  -a  analyze (default)\n\
     \  -c  compile to .sasm (requires -o)\n\
     \  -g  compile to relocatable .svobj (requires -o)\n\
     \  -x  verify a .svobj (structure + CRC round-trip)\n\
     \  --json  one NDJSON object per line on stdout\n"
    prog

let parse_args (args : string array) : action * string option * string option =
  let mode = ref None in
  let input = ref None in
  let out = ref None in
  let set_mode m =
    match !mode with
    | None -> mode := Some m
    | Some m' -> if m' <> m then die exit_usage "multiple action options given"
  in
  let i = ref 1 in
  while !i < Array.length args do
    let a = args.(!i) in
    (match a with
     | "-a" -> set_mode Analyze
     | "-c" -> set_mode Compile
     | "-g" -> set_mode Object
     | "-x" -> set_mode Verify
     | "-h" | "--help" -> set_mode Help
     | "--json" -> json_mode := true
     | "-o" ->
         if !i + 1 >= Array.length args then die exit_usage "-o requires a path";
         if !out <> None then die exit_usage "duplicate -o option";
         out := Some args.(!i + 1);
         incr i
     | s when Stdlib.String.length s > 0 && Stdlib.String.get s 0 = '-' ->
         die exit_usage (Printf.sprintf "unknown option: %s" s)
     | s ->
         if !input <> None then
           die exit_usage (Printf.sprintf "unexpected argument: %s" s);
         input := Some s);
    incr i
  done;
  let m = match !mode with None -> Analyze | Some m -> m in
  (m, !input, !out)

let require_output (out : string option) : string =
  match out with
  | Some d -> d
  | None -> die exit_usage "this action writes an artifact and requires -o <output>"

let run () : unit =
  let args = Sys.argv in
  let mode, input, out = parse_args args in
  match mode with
  | Help -> Printf.eprintf "%s" (usage_text args.(0))
  | _ ->
      let src =
        match input with
        | Some s -> s
        | None -> Printf.eprintf "%s" (usage_text args.(0));
                  die exit_usage "no input file"
      in
      match mode with
      | Compile ->
          let dst = require_output out in
          let data = compile_st_to_sasm src in
          write_file dst data;
          if !json_mode then
            Printf.printf "{\"kind\":\"output\",\"path\":\"%s\",\"bytes\":%d}\n"
              (json_escape dst) (Stdlib.String.length data)
          else
            Printf.printf "compiled: %s -> %s\n" src dst
      | Object ->
          let dst = require_output out in
          let data = emit_svobj src in
          write_file dst data;
          if !json_mode then
            Printf.printf "{\"kind\":\"output\",\"path\":\"%s\",\"bytes\":%d}\n"
              (json_escape dst) (Stdlib.String.length data)
          else
            Printf.printf "emitted: %s -> %s\n" src dst
      | Verify -> verify_svobj src
      | Analyze -> analyze_st src
      | Help -> ()

let () =
  try run ()
  with
  | Fatal (code, msg) ->
      if Stdlib.String.length msg > 0 then
        if !json_mode then
          Printf.printf "{\"kind\":\"%s\",\"msg\":\"%s\"%s}\n"
            (kind_of_code code) (json_escape msg)
            (match !syntax_loc with
             | Some (ln, col) ->
                 Printf.sprintf ",\"line\":%d,\"col\":%d" ln col
             | None -> "")
        else
          output_string Stdlib.stderr (msg ^ "\n");
      exit code
  | Sys_error e ->
      if !json_mode then
        Printf.printf "{\"kind\":\"artifact\",\"msg\":\"%s\"}\n" (json_escape e)
      else
        output_string Stdlib.stderr (e ^ "\n");
      exit exit_artifact
  | e ->
      if !json_mode then
        Printf.printf "{\"kind\":\"internal\",\"msg\":\"%s\"}\n"
          (json_escape (Printexc.to_string e))
      else
        Printf.eprintf "Fatal error: %s\n%!" (Printexc.to_string e);
      exit exit_internal


