(* Minimal encoder — Rocq 9.1 compatible *)
Require Import Stdlib.Lists.List.
Require Import Stdlib.ZArith.ZArith.
Require Import Stdlib.Strings.String.
Require Import Stdlib.Floats.Floats.
Require Import Stdlib.Strings.Ascii.
Local Open Scope Z_scope.
Require Import vstac_spec.safeasm.
Import ListNotations.

Definition encode_u8 (v : Z) : list Z := [Z.land v 255].
Definition encode_u16 (v : Z) : list Z := [Z.land v 255; Z.land (Z.shiftr v 8) 255].
Definition encode_u32 (v : Z) : list Z := [Z.land v 255; Z.land (Z.shiftr v 8) 255; Z.land (Z.shiftr v 16) 255; Z.land (Z.shiftr v 24) 255].
Definition encode_s32 (v : Z) : list Z := encode_u32 (Z.land v 4294967295).
Definition encode_u64 (v : Z) : list Z := [Z.land v 255; Z.land (Z.shiftr v 8) 255; Z.land (Z.shiftr v 16) 255; Z.land (Z.shiftr v 24) 255; Z.land (Z.shiftr v 32) 255; Z.land (Z.shiftr v 40) 255; Z.land (Z.shiftr v 48) 255; Z.land (Z.shiftr v 56) 255].
Definition encode_s64 (v : Z) : list Z := encode_u64 (Z.land v 18446744073709551615).
Definition encode_section_header (sec_type : Z) (length : Z) : list Z := encode_u8 sec_type ++ encode_u32 length ++ encode_u8 0.

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
  | F32_CONST _ => 0x43 :: encode_u32 0 | F64_CONST _ => 0x44 :: encode_u64 0
  | F32_ADD => [0x92] | F32_SUB => [0x93] | F32_MUL => [0x94] | F32_DIV => [0x95]
  | F32_EQ => [0x9A] | F32_NE => [0x9B] | F32_LT => [0x9C] | F32_LE => [0x9D] | F32_GT => [0x9E] | F32_GE => [0x9F]
  | F32_ABS => [0xA0] | F32_NEG => [0xA1] | F32_SQRT => [0xA2]
  | F64_ADD => [0xA3] | F64_SUB => [0xA4] | F64_MUL => [0xA5] | F64_DIV => [0xA6]
  | F64_EQ => [0xAA] | F64_NE => [0xAB] | F64_LT => [0xAC] | F64_LE => [0xAD] | F64_GT => [0xAE] | F64_GE => [0xAF]
  | F64_ABS => [0xB0] | F64_NEG => [0xB1] | F64_SQRT => [0xB2]
  | I32_WRAP_I64 => [0xA7] | I64_EXTEND_I32_S => [0xA8]
  | I32_TRUNC_F32_S => [0xB3] | I32_TRUNC_F64_S => [0xB4]
  | F32_CONVERT_I32_S => [0xB7] | F64_CONVERT_I32_S => [0xBB]
  | I32_LOAD _ => 0x28 :: encode_u32 0 | I64_LOAD _ => 0x29 :: encode_u32 0
  | F32_LOAD _ => 0x2A :: encode_u32 0 | F64_LOAD _ => 0x2B :: encode_u32 0
  | I32_STORE _ => 0x36 :: encode_u32 0 | I64_STORE _ => 0x37 :: encode_u32 0
  | I32_LOAD8_U _ => 0x2C :: encode_u32 0 | I32_STORE8 _ => 0x3A :: encode_u32 0
  | F32_STORE _ => 0x38 :: encode_u32 0 | F64_STORE _ => 0x39 :: encode_u32 0
  | SAFE_ASSERT _ => [0xFC; 0x00; 0x00; 0x00; 0x00; 0x00]
  | SAFE_BOUNDS_CHECK _ _ => 0xFD :: encode_u32 0 ++ encode_u32 0
  end.

Definition encode_sasm (m : sasm_module) : list Z :=
  [0x53; 0x41; 0x53; 0x4D; 0x01; 0x00].

Theorem encode_starts_with_magic : forall (m : sasm_module),
    exists rest, encode_sasm m = [0x53; 0x41; 0x53; 0x4D] ++ rest.
Proof.
  intros m. unfold encode_sasm. simpl. eexists. reflexivity.
Qed.
