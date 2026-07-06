(* ================================================================
   vstac/src/encoder.v
   SafeASM 二进制编码器 — v1.1 full encoder

   Usage (after OCaml extraction):
     vstac compile input.st -o output.sasm

   Binary format (matching vm/loader.c):
     [Magic]     "SASM"             4 bytes
     [Version]   uint8              1 byte
     [Flags]     uint8              1 byte
     [Sections]  (8-byte header + body), one per section type
     [CRC32]     uint32             4 bytes (placeholder 0)

   Section header: type(1) + length(4) + reserved(1) + flags(2) = 8 bytes
   ================================================================ *)

Require Import Stdlib.Lists.List.
Require Import Stdlib.ZArith.ZArith.
Require Import Stdlib.Strings.String.
Require Import Stdlib.Floats.Floats.
Require Import Stdlib.Strings.Ascii.
Local Open Scope Z_scope.
Require Import vstac_spec.safeasm.
Import ListNotations.

(* ================================================================
   第 1 部分：基本编码函数 (Fixed-width Encoding)
   ================================================================ *)

Definition encode_u8 (v : Z) : list Z := [Z.land v 255].

Definition encode_u16 (v : Z) : list Z :=
  [Z.land v 255;
   Z.land (Z.shiftr v 8) 255].

Definition encode_u32 (v : Z) : list Z :=
  [Z.land v 255;
   Z.land (Z.shiftr v 8) 255;
   Z.land (Z.shiftr v 16) 255;
   Z.land (Z.shiftr v 24) 255].

Definition encode_s32 (v : Z) : list Z :=
  encode_u32 (Z.land v 4294967295).

Definition encode_u64 (v : Z) : list Z :=
  [Z.land v 255;
   Z.land (Z.shiftr v 8) 255;
   Z.land (Z.shiftr v 16) 255;
   Z.land (Z.shiftr v 24) 255;
   Z.land (Z.shiftr v 32) 255;
   Z.land (Z.shiftr v 40) 255;
   Z.land (Z.shiftr v 48) 255;
   Z.land (Z.shiftr v 56) 255].

Definition encode_s64 (v : Z) : list Z :=
  encode_u64 (Z.land v 18446744073709551615).

(* ================================================================
   第 2 部分：Section 编码
   ================================================================ *)

Definition encode_section_header (sec_type : Z) (length : Z) (flags : Z) : list Z :=
  encode_u8 sec_type ++ encode_u32 length ++ encode_u8 0 ++ encode_u16 flags.

Definition encode_section (sec_type : Z) (data : list Z) : list Z :=
  encode_section_header sec_type (Z.of_nat (List.length data)) 0 ++ data.

(* ---- 2a. TYPE Section (0) ---- *)

Definition encode_value_type (vt : sasm_value_type) : Z :=
  match vt with
  | I32 => 0x7F
  | I64 => 0x7E
  | F32 => 0x7D
  | F64 => 0x7C
  end.

Fixpoint encode_value_type_list (tys : list sasm_value_type) : list Z :=
  match tys with
  | nil => nil
  | ty :: rest => encode_u8 (encode_value_type ty) ++ encode_value_type_list rest
  end.

Definition encode_func_type (ft : sasm_func_type) : list Z :=
  encode_u32 (Z.of_nat (List.length ft.(sasm_param_types))) ++
  encode_value_type_list ft.(sasm_param_types) ++
  encode_u32 (Z.of_nat (List.length ft.(sasm_return_types))) ++
  encode_value_type_list ft.(sasm_return_types).

Fixpoint encode_type_section_data (types : list sasm_func_type) : list Z :=
  match types with
  | nil => nil
  | ft :: rest => encode_func_type ft ++ encode_type_section_data rest
  end.

Definition encode_type_section (m : sasm_module) : list Z :=
  encode_section 0 (encode_type_section_data m.(sasm_types)).

(* ---- 2b. FUNC Section (1) ---- *)

Definition encode_func_decl (f : sasm_function) : list Z :=
  encode_u32 f.(sasm_func_type_idx) ++
  encode_u32 (Z.of_nat (List.length f.(sasm_locals))) ++
  encode_value_type_list f.(sasm_locals).

Fixpoint encode_func_section_data (funcs : list sasm_function) : list Z :=
  match funcs with
  | nil => nil
  | f :: rest => encode_func_decl f ++ encode_func_section_data rest
  end.

Definition encode_func_section (m : sasm_module) : list Z :=
  encode_section 1 (encode_func_section_data m.(sasm_functions)).

(* ---- 2c. MEM Section (2) ---- *)

Definition encode_segment_type (st : segment_type) : Z :=
  match st with
  | SEG_IO_INPUT  => 0
  | SEG_IO_OUTPUT => 1
  | SEG_GLOBAL    => 2
  | SEG_FB_DATA   => 3
  | SEG_STACK     => 4
  | SEG_CONST     => 5
  end.

Definition encode_mem_segment (seg : memory_segment) : list Z :=
  encode_u8 (encode_segment_type seg.(seg_type)) ++
  encode_u32 seg.(seg_start) ++
  encode_u32 seg.(seg_size).

Fixpoint encode_mem_segments (segs : list memory_segment) : list Z :=
  match segs with
  | nil => nil
  | seg :: rest => encode_mem_segment seg ++ encode_mem_segments rest
  end.

Definition encode_mem_section_data (m : sasm_module) : list Z :=
  encode_u32 m.(sasm_total_memory_size) ++
  encode_u32 (Z.of_nat (List.length m.(sasm_memory_segments))) ++
  encode_mem_segments m.(sasm_memory_segments).

Definition encode_mem_section (m : sasm_module) : list Z :=
  encode_section 2 (encode_mem_section_data m).

(* ---- 2d. IOMAP Section (3) ---- *)

Definition encode_io_direction (dir : io_direction) : Z :=
  match dir with IO_INPUT => 0 | IO_OUTPUT => 1 end.

Definition encode_io_type (t : io_type) : Z :=
  match t with IO_AI => 0 | IO_AO => 1 | IO_DI => 2 | IO_DO => 3 end.

Definition encode_io_entry (e : io_entry_sasm) : list Z :=
  encode_u32 0 ++                            (* st_var_name_offset — placeholder *)
  encode_u32 e.(io_mem_offset) ++
  encode_u32 e.(io_channel_id) ++
  encode_u8 (encode_io_direction e.(io_dir)) ++
  encode_u8 (encode_io_type e.(io_type_kind)) ++
  encode_u32 e.(io_bit_width) ++
  encode_u64 0 ++ encode_u64 0 ++            (* scale / bias — placeholder (float64) *)
  encode_s32 e.(io_safety_low) ++
  encode_s32 e.(io_safety_high).

Definition encode_io_entries (entries : list io_entry_sasm) : list Z :=
  List.fold_right (fun e acc => encode_io_entry e ++ acc) [] entries.

Definition encode_iomap_section_data (m : sasm_module) : list Z :=
  encode_u32 (Z.of_nat (List.length m.(sasm_io_map))) ++
  encode_io_entries m.(sasm_io_map).

Definition encode_iomap_section (m : sasm_module) : list Z :=
  encode_section 3 (encode_iomap_section_data m).

(* ---- 2e. CODE Section (4) ---- *)

(* 指令编码所需尺寸（用于填充 BLOCK/LOOP len），与 vm/loader.c 保持一致 *)
Definition memory_arg_size : Z := 4.  (* align(2) + offset(2) *)

(* 编码 memory_arg: align(2) + offset(2) = 4 bytes *)
Definition encode_memory_arg (arg : memory_arg) : list Z :=
  encode_u16 arg.(mem_align) ++ encode_u16 arg.(mem_offset).

Definition encode_safety_assertion (sa : safety_assertion) : list Z :=
  match sa with
  | ASSERT_CYCLE_LIMIT limit => encode_u8 0 ++ encode_u32 limit
  | ASSERT_STACK_DEPTH depth => encode_u8 1 ++ encode_u32 depth
  | ASSERT_MEM_BOUNDS low high => encode_u8 2 ++ encode_u32 low ++ encode_u32 high
  end.

Definition encode_sasm_instr (instr : sasm_instr) : list Z :=
  match instr with
  | UNREACHABLE => [0x00] | NOP => [0x01]
  | BLOCK len => 0x02 :: encode_u32 len
  | LOOP len => 0x03 :: encode_u32 len
  | BR depth => 0x04 :: encode_u32 depth
  | BR_IF depth => 0x05 :: encode_u32 depth
  | RETURN => [0x06]
  | CALL idx => 0x10 :: encode_u32 idx
  | DROP => [0x1A] | SELECT => [0x1B]
  | LOCAL_GET idx => 0x20 :: encode_u32 idx
  | LOCAL_SET idx => 0x21 :: encode_u32 idx
  | LOCAL_TEE idx => 0x22 :: encode_u32 idx
  | I32_CONST v => 0x41 :: encode_s32 v
  | I32_EQZ => [0x45] | I32_EQ => [0x46] | I32_NE => [0x47]
  | I32_LT_S => [0x48] | I32_LE_S => [0x49] | I32_GT_S => [0x4A] | I32_GE_S => [0x4B]
  | I32_ADD => [0x6A] | I32_SUB => [0x6B] | I32_MUL => [0x6C] | I32_DIV_S => [0x6D] | I32_REM_S => [0x6F]
  | I32_AND => [0x71] | I32_OR => [0x72] | I32_XOR => [0x73]
  | I32_SHL => [0x74] | I32_SHR_S => [0x75] | I32_ROTL => [0x76] | I32_ROTR => [0x77]
  | I64_CONST v => 0x50 :: encode_s64 v
  | I64_EQZ => [0x53] | I64_EQ => [0x54] | I64_NE => [0x55]
  | I64_LT_S => [0x56] | I64_LE_S => [0x57] | I64_GT_S => [0x58] | I64_GE_S => [0x59]
  | I64_ADD => [0x7C] | I64_SUB => [0x7D] | I64_MUL => [0x7E] | I64_DIV_S => [0x7F] | I64_REM_S => [0x80]
  | I64_AND => [0x81] | I64_OR => [0x82] | I64_XOR => [0x83] | I64_SHL => [0x84] | I64_SHR_S => [0x85]
  | F32_CONST _ => 0x43 :: encode_u32 0    (* NOTE: float32 bits not available in Coq; post-process with OCaml *)
  | F64_CONST _ => 0x44 :: encode_u64 0    (* NOTE: float64 bits not available in Coq; post-process with OCaml *)
  | F32_ADD => [0x92] | F32_SUB => [0x93] | F32_MUL => [0x94] | F32_DIV => [0x95]
  | F32_EQ => [0x9A] | F32_NE => [0x9B] | F32_LT => [0x9C] | F32_LE => [0x9D] | F32_GT => [0x9E] | F32_GE => [0x9F]
  | F32_ABS => [0xA0] | F32_NEG => [0xA1] | F32_SQRT => [0xA2]
  | F64_ADD => [0xA3] | F64_SUB => [0xA4] | F64_MUL => [0xA5] | F64_DIV => [0xA6]
  | F64_EQ => [0xAA] | F64_NE => [0xAB] | F64_LT => [0xAC] | F64_LE => [0xAD] | F64_GT => [0xAE] | F64_GE => [0xAF]
  | F64_ABS => [0xB0] | F64_NEG => [0xB1] | F64_SQRT => [0xB2]
  | I32_WRAP_I64 => [0xA7] | I64_EXTEND_I32_S => [0xA8]
  | I32_TRUNC_F32_S => [0xB3] | I32_TRUNC_F64_S => [0xB4]
  | F32_CONVERT_I32_S => [0xB7] | F64_CONVERT_I32_S => [0xBB]
  | I32_LOAD arg => 0x28 :: encode_memory_arg arg
  | I64_LOAD arg => 0x29 :: encode_memory_arg arg
  | F32_LOAD arg => 0x2A :: encode_memory_arg arg
  | F64_LOAD arg => 0x2B :: encode_memory_arg arg
  | I32_LOAD8_U arg => 0x2C :: encode_memory_arg arg
  | I32_STORE arg => 0x36 :: encode_memory_arg arg
  | I64_STORE arg => 0x37 :: encode_memory_arg arg
  | F32_STORE arg => 0x38 :: encode_memory_arg arg
  | F64_STORE arg => 0x39 :: encode_memory_arg arg
  | I32_STORE8 arg => 0x3A :: encode_memory_arg arg
  | SAFE_ASSERT sa => 0xFC :: encode_safety_assertion sa
  | SAFE_BOUNDS_CHECK low high => 0xFD :: encode_u32 low ++ encode_u32 high
  end.

Fixpoint encode_instrs (instrs : list sasm_instr) : list Z :=
  match instrs with
  | nil => nil
  | i :: rest => encode_sasm_instr i ++ encode_instrs rest
  end.

Fixpoint encode_codes (funcs : list sasm_function) (idx : Z) : list Z :=
  match funcs with
  | nil => nil
  | f :: rest =>
      let body := encode_instrs f.(sasm_body) in
      encode_u32 idx ++
      encode_u32 (Z.of_nat (List.length body)) ++
      body ++
      encode_codes rest (idx + 1)
  end.

Definition encode_code_section_data (m : sasm_module) : list Z :=
  encode_codes m.(sasm_functions) 0.

Definition encode_code_section (m : sasm_module) : list Z :=
  encode_section 4 (encode_code_section_data m).

(* ---- 2f. SAFE Section (5) ---- *)

Definition encode_loop_bound (lb : loop_bound) : list Z :=
  encode_u32 lb.(lb_func_idx) ++
  encode_u32 lb.(lb_instr_offset) ++
  encode_u32 lb.(lb_max_iter).

Definition encode_loop_bounds (lbs : list loop_bound) : list Z :=
  List.fold_right (fun lb acc => encode_loop_bound lb ++ acc) [] lbs.

Definition encode_mem_access_range (r : mem_access_range) : list Z :=
  encode_u32 r.(mar_low) ++ encode_u32 r.(mar_high).

Definition encode_mem_access_ranges (rs : list mem_access_range) : list Z :=
  List.fold_right (fun r acc => encode_mem_access_range r ++ acc) [] rs.

Definition encode_safety_section_data (m : sasm_module) : list Z :=
  let sa := m.(sasm_safety) in
  encode_u8 (Z.land sa.(safe_level) 255) ++
  encode_u32 sa.(safe_cycle_limit) ++
  encode_u32 sa.(safe_stack_depth) ++
  encode_u32 (Z.of_nat (List.length sa.(safe_loop_bounds))) ++
  encode_loop_bounds sa.(safe_loop_bounds) ++
  encode_u32 (Z.of_nat (List.length sa.(safe_mem_access_map))) ++
  encode_mem_access_ranges sa.(safe_mem_access_map).

Definition encode_safe_section (m : sasm_module) : list Z :=
  encode_section 5 (encode_safety_section_data m).

(* ---- 2g. 综合汇编 section 清单 ---- *)

Definition concat_sections (secs : list (list Z)) : list Z :=
  List.fold_right (fun a b => a ++ b) [] secs.

(* ================================================================
   第 3 部分：模块编码 (Module Encoding)
   ================================================================ *)

Definition encode_module (m : sasm_module) : list Z :=
  let header := [0x53; 0x41; 0x53; 0x4D;     (* Magic "SASM" *)
                 Z.land m.(sasm_version) 255;  (* Version *)
                 Z.land m.(sasm_flags) 255]    (* Flags *)
  in
  let type_sec  := encode_type_section m in
  let func_sec  := encode_func_section m in
  let mem_sec   := encode_mem_section m in
  let iomap_sec := encode_iomap_section m in
  let code_sec  := encode_code_section m in
  let safe_sec  := encode_safe_section m in
  let sections := type_sec ++ func_sec ++ mem_sec ++ iomap_sec ++ code_sec ++ safe_sec in
  let crc := [0x00; 0x00; 0x00; 0x00] in      (* CRC32 — placeholder, loader treats mismatch as non-fatal *)
  header ++ sections ++ crc.

(* ================================================================
   第 4 部分：正确性定理
   ================================================================ *)
Theorem encode_starts_with_magic : forall (m : sasm_module),
    exists rest, encode_module m = [0x53; 0x41; 0x53; 0x4D] ++ rest.
Proof.
  intros m. unfold encode_module. eexists. reflexivity.
Qed.

Theorem encode_module_nonempty : forall (m : sasm_module),
    encode_module m <> [].
Proof.
  intros m H. unfold encode_module in H. discriminate H.
Qed.
