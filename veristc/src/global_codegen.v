(* ================================================================
   veristc/src/global_codegen.v
   CoreST code generation with persistent VAR_GLOBAL storage.

   The original codegen path is kept unchanged for the verified core
   subset. This extension maps global variables to fixed SafeASM memory
   slots and emits I32_LOAD/I32_STORE so hot-standby snapshots can carry
   controller state independently of the temporary value stack.
   ================================================================ *)

From Stdlib Require Import List.
From Stdlib Require Import ZArith.
From Stdlib Require Import String.
From Stdlib Require Import Bool.
Require Import veristc_spec.safest.
Require Import veristc_spec.safeasm.
Require Import veristc_src.desugar.
Require Import veristc_src.analysis.
Require Import veristc_src.codegen.
Local Open Scope Z_scope.
Import ListNotations.

Definition GLOBAL_BASE : Z := 4096.
Definition SASM_PRINT_PORT : Z := 2147483640.  (* 0x7FFFFFF8 *)
Definition SASM_COUNTER_PRINT_PORT : Z := 2147483644.  (* 0x7FFFFFFC *)
Definition SYSTEM_COUNTER_NAME : ident := ID "__veristc_cycle_counter".

Fixpoint lookup_global_offset
         (env : list (ident * Z)) (x : ident) : option Z :=
  match env with
  | nil => None
  | (y, off) :: rest =>
      if ident_eq x y then Some off else lookup_global_offset rest x
  end.

Fixpoint assign_global_offsets
         (decls : list st_var_decl) (base : Z) : list (ident * Z) :=
  match decls with
  | nil => nil
  | d :: rest =>
      (d.(var_name), base) ::
      assign_global_offsets rest (base + 4)
  end.

Definition build_global_env (p : corest_program) : list (ident * Z) :=
  assign_global_offsets p.(cprog_global_vars) GLOBAL_BASE.

Definition global_memory_size (p : corest_program) : Z :=
  4 * Z.of_nat (List.length p.(cprog_global_vars)).

Definition global_load
           (env : list (ident * Z)) (x : ident) : list sasm_instr :=
  match lookup_global_offset env x with
  | Some off =>
      [I32_CONST off;
       I32_LOAD {| mem_align := 2; mem_offset := 0 |}]
  | None => [I32_CONST 0]
  end.

Definition global_store
           (env : list (ident * Z)) (x : ident)
           (value_code : list sasm_instr) : list sasm_instr :=
  match lookup_global_offset env x with
  | Some off =>
      I32_CONST off :: value_code ++
      [I32_STORE {| mem_align := 2; mem_offset := 0 |}]
  | None => [NOP]
  end.

Definition compile_cycle_counter
           (locals : compile_env) (globals : list (ident * Z))
           : list sasm_instr :=
  let temp := Z.of_nat (List.length locals) in
  match lookup_global_offset globals SYSTEM_COUNTER_NAME with
  | Some addr =>
      [I32_CONST addr;
       I32_LOAD {| mem_align := 2; mem_offset := 0 |};
       I32_CONST 1;
       I32_ADD;
       LOCAL_SET temp;
       I32_CONST addr;
       LOCAL_GET temp;
       I32_STORE {| mem_align := 2; mem_offset := 0 |};
       I32_CONST SASM_COUNTER_PRINT_PORT;
       LOCAL_GET temp;
       I32_STORE {| mem_align := 2; mem_offset := 0 |};
       LOCAL_GET temp]
  | None => [I32_CONST 0]
  end.

Fixpoint compile_expr_g
         (locals : compile_env) (globals : list (ident * Z))
         (e : corest_expr) {struct e} : list sasm_instr :=
  match e with
  | CE_LIT l =>
      match l with
      | L_BOOL b => [I32_CONST (if b then 1 else 0)]
      | L_INT n => [I32_CONST n]
      | L_REAL f => [F32_CONST f]
      | L_TIME t => [I64_CONST t]
      | L_LINT n => [I64_CONST n]
      | L_LREAL f => [F64_CONST f]
      end
  | CE_VAR x =>
      match lookup_var_idx locals x with
      | Some idx => [LOCAL_GET idx]
      | None => global_load globals x
      end
  | CE_ARRAY_ACCESS arr idx =>
      compile_expr_g locals globals arr ++
      compile_expr_g locals globals idx ++
      [I32_ADD; I32_LOAD {| mem_align := 2; mem_offset := 0 |}]
  | CE_UNARY_OP U_NEG e1 =>
      [I32_CONST 0] ++ compile_expr_g locals globals e1 ++ [I32_SUB]
  | CE_UNARY_OP U_NOT e1 =>
      compile_expr_g locals globals e1 ++ [I32_EQZ]
  | CE_UNARY_OP U_ABS e1 =>
      compile_expr_g locals globals e1 ++
      [LOCAL_SET 255; LOCAL_GET 255; I32_CONST 0; I32_LT_S;
       I32_CONST 0; LOCAL_GET 255; I32_SUB; LOCAL_GET 255; SELECT]
  | CE_BIN_OP B_ADD e1 e2 =>
      compile_expr_g locals globals e1 ++
      compile_expr_g locals globals e2 ++ [I32_ADD]
  | CE_BIN_OP B_SUB e1 e2 =>
      compile_expr_g locals globals e1 ++
      compile_expr_g locals globals e2 ++ [I32_SUB]
  | CE_BIN_OP B_MUL e1 e2 =>
      compile_expr_g locals globals e1 ++
      compile_expr_g locals globals e2 ++ [I32_MUL]
  | CE_BIN_OP B_DIV e1 e2 =>
      compile_expr_g locals globals e1 ++
      compile_expr_g locals globals e2 ++ [I32_DIV_S]
  | CE_BIN_OP B_MOD e1 e2 =>
      compile_expr_g locals globals e1 ++
      compile_expr_g locals globals e2 ++ [I32_REM_S]
  | CE_COMP C_EQ e1 e2 =>
      compile_expr_g locals globals e1 ++
      compile_expr_g locals globals e2 ++ [I32_EQ]
  | CE_COMP C_NE e1 e2 =>
      compile_expr_g locals globals e1 ++
      compile_expr_g locals globals e2 ++ [I32_NE]
  | CE_COMP C_LT e1 e2 =>
      compile_expr_g locals globals e1 ++
      compile_expr_g locals globals e2 ++ [I32_LT_S]
  | CE_COMP C_LE e1 e2 =>
      compile_expr_g locals globals e1 ++
      compile_expr_g locals globals e2 ++ [I32_LE_S]
  | CE_COMP C_GT e1 e2 =>
      compile_expr_g locals globals e1 ++
      compile_expr_g locals globals e2 ++ [I32_GT_S]
  | CE_COMP C_GE e1 e2 =>
      compile_expr_g locals globals e1 ++
      compile_expr_g locals globals e2 ++ [I32_GE_S]
  | CE_AND e1 e2 =>
      compile_expr_g locals globals e1 ++
      compile_expr_g locals globals e2 ++ [I32_AND]
  | CE_OR e1 e2 =>
      compile_expr_g locals globals e1 ++
      compile_expr_g locals globals e2 ++ [I32_OR]
  | CE_XOR e1 e2 =>
      compile_expr_g locals globals e1 ++
      compile_expr_g locals globals e2 ++ [I32_XOR]
  | CE_FUNC_CALL f args =>
      match f, args with
      | ID "CycleCounter", nil => compile_cycle_counter locals globals
      | _, _ =>
          List.concat (List.map (compile_expr_g locals globals) args)
      end
  | CE_QUALITY_OP _ args =>
      List.concat (List.map (compile_expr_g locals globals) args)
  end.

Fixpoint compile_stmt_g
         (locals : compile_env) (globals : list (ident * Z))
         (s : corest_stmt) {struct s} : list sasm_instr :=
  match s with
  | CS_ASSIGN x e =>
      match x with
      | ID "__veristc_cycle_counter" =>
          compile_cycle_counter locals globals ++ [DROP]
      | _ =>
          let rhs := compile_expr_g locals globals e in
          match lookup_var_idx locals x with
          | Some idx => rhs ++ [LOCAL_SET idx]
          | None => global_store globals x rhs
          end
      end
  | CS_ARRAY_ASSIGN x idx e =>
      compile_expr_g locals globals (CE_VAR x) ++
      compile_expr_g locals globals idx ++ [I32_ADD] ++
      compile_expr_g locals globals e ++
      [I32_STORE {| mem_align := 2; mem_offset := 0 |}]
  | CS_IF cond then_body else_body =>
      let compiled_cond := compile_expr_g locals globals cond in
      let compiled_then :=
        List.concat (List.map (compile_stmt_g locals globals) then_body) in
      let compiled_else :=
        List.concat (List.map (compile_stmt_g locals globals) else_body) ++
        [BR 0] in
      let inner_block_instrs :=
        compiled_cond ++ [I32_EQZ; BR_IF 0] ++
        compiled_then ++ [BR 1] in
      let outer_block_instrs :=
        [BLOCK (instr_seq_size inner_block_instrs)] ++
        inner_block_instrs ++ compiled_else in
      [BLOCK (instr_seq_size outer_block_instrs)] ++ outer_block_instrs
  | CS_WHILE cond body =>
      let compiled_cond := compile_expr_g locals globals cond in
      let compiled_body :=
        List.concat (List.map (compile_stmt_g locals globals) body) in
      let header_instrs := compiled_cond ++ [I32_EQZ; BR_IF 1] in
      let loop_body := compiled_body ++ [BR 0] in
      let loop_size := instr_seq_size (header_instrs ++ loop_body) in
      let exit_instrs := [LOOP loop_size] ++ header_instrs ++ loop_body in
      [BLOCK (instr_seq_size exit_instrs)] ++ exit_instrs
  | CS_FB_CALL inst params =>
      match inst with
      | ID "PRINT" =>
          List.concat
            (List.map (fun p =>
               I32_CONST SASM_PRINT_PORT ::
               compile_expr_g locals globals (snd p) ++
               [I32_STORE {| mem_align := 2; mem_offset := 0 |}])
             params)
      | _ => [NOP]
      end
  | CS_RETURN => [RETURN]
  | CS_EXIT => [BR 0]
  | CS_BLOCK stmts =>
      List.concat (List.map (compile_stmt_g locals globals) stmts)
  end.

Definition compile_function_g
           (globals : list (ident * Z)) (f : corest_function)
           : sasm_function :=
  let env := build_compile_env f in
  let env_ty := build_compile_type_env f in
  let body :=
    List.concat (List.map (compile_stmt_g env globals) f.(cfunc_body)) in
  let body :=
    match f.(cfunc_return_type) with
    | Some _ => body ++ [I32_CONST 0; RETURN]
    | None => body
    end in
  let safeasm_types :=
    List.map (fun p => st_type_to_sasm (snd p)) env_ty ++ [I32] in
  {| sasm_func_type_idx := 0;
     sasm_locals := safeasm_types;
     sasm_body := body;
     sasm_stack_depth := instr_seq_size body;
     sasm_cycle_budget := 1000000;
  |}.

Definition estimate_total_memory_g (p : corest_program) : Z :=
  let local_count := List.fold_right (fun f acc =>
    acc + Z.of_nat (List.length f.(cfunc_params) +
                    List.length f.(cfunc_locals))
  ) 0 p.(cprog_functions) in
  Z.max (GLOBAL_BASE + global_memory_size p + 4096)
        (local_count * 4 + 1024 + 256).

Definition compile_program_g (p : corest_program) : sasm_module :=
  let core_funcs := p.(cprog_functions) in
  let globals := build_global_env p in
  let funcs := List.map (compile_function_g globals) core_funcs in
  let types := List.map build_sasm_func_type core_funcs in
  let total_mem := estimate_total_memory_g p in
  let global_seg :=
    {| seg_type := SEG_GLOBAL;
       seg_start := GLOBAL_BASE;
       seg_size := global_memory_size p |} in
  let io_offsets := assign_io_offsets p.(cprog_io_mapping) 1024 in
  let io_map :=
    List.map (fun e => io_entry_to_sasm (fst e) (snd e)) io_offsets in
  {| sasm_magic := "SASM";
     sasm_version := 1;
     sasm_flags := 2;  (* bit 1: hot-standby global-state support *)
     sasm_types := types;
     sasm_functions := funcs;
     sasm_memory_segments := [global_seg];
     sasm_total_memory_size := total_mem;
     sasm_io_map := io_map;
     sasm_safety :=
       {| safe_level := 1;  (* SIL3 by default *)
          safe_cycle_limit := 1000000;
          safe_stack_depth := analyze_stack_depth p;
          safe_loop_bounds := [];
          safe_mem_access_map :=
            [{| mar_low := 0; mar_high := total_mem |}];
       |};
     sasm_wcet := Some (build_wcet_data core_funcs);
     sasm_entry_function := 0;
  |}.

Lemma compile_program_g_preserves_entry :
  forall (p : corest_program),
    (compile_program_g p).(sasm_entry_function) = 0.
Proof. reflexivity. Qed.
