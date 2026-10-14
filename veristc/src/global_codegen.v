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
Definition SASM_CHAR_PRINT_PORT : Z := 2147483636.  (* 0x7FFFFFF4 *)
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
      let temp := Z.of_nat (List.length locals) in
      compile_expr_g locals globals e1 ++
      [LOCAL_SET temp; LOCAL_GET temp; I32_CONST 0; I32_LT_S;
       I32_CONST 0; LOCAL_GET temp; I32_SUB; LOCAL_GET temp; SELECT]
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
               let port :=
                 match fst p with
                 | ID "__print_char" => SASM_CHAR_PRINT_PORT
                 | _ => SASM_PRINT_PORT
                 end in
               I32_CONST port ::
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

(* ================================================================
   Call-aware global code generation

   This is the engineering path for full stateless FUNCTION support.
   User functions are kept as SafeASM functions and calls become CALL.
   The old compile_program_g path is preserved for existing proofs and
   compatibility while the new pipeline is stabilized.
   ================================================================ *)

Definition func_index_env : Type := list (ident * Z).

Fixpoint lookup_func_index
         (fenv : func_index_env) (x : ident) : option Z :=
  match fenv with
  | nil => None
  | (y, idx) :: rest =>
      if ident_eq x y then Some idx else lookup_func_index rest x
  end.

Fixpoint assign_func_indices
         (funcs : list corest_function) (base : Z) : func_index_env :=
  match funcs with
  | nil => nil
  | f :: rest =>
      (f.(cfunc_name), base) :: assign_func_indices rest (base + 1)
  end.

Definition is_entry_function (entry : ident) (f : corest_function) : bool :=
  ident_eq f.(cfunc_name) entry.

Definition entry_first_functions (p : corest_program) : list corest_function :=
  let parts :=
    List.partition (is_entry_function p.(cprog_entry)) p.(cprog_functions)
  in
  fst parts ++ snd parts.

(* ================================================================
   原生 FB 支持辅助（self 相对寻址 + 调用点表）
   ================================================================ *)

(* FB 函数 = 含合成 __self 首参的 corest_function *)
Definition is_self_param (f : corest_function) : bool :=
  List.existsb (fun pv => ident_eq (fst pv) (ID "__self")) f.(cfunc_params).

(* __self 在帧局部环境的槽位 *)
Definition self_slot (locals : compile_env) : option Z :=
  lookup_var_idx locals (ID "__self").

(* 可写字段 → self 相对字节偏移（声明序，每字段 4 字节） *)
Fixpoint assign_field_offsets
         (fields : list (ident * st_type)) (base : Z) : list (ident * Z) :=
  match fields with
  | nil => nil
  | (n, _) :: rest => (n, base) :: assign_field_offsets rest (base + 4)
  end.

Definition resolve_fb_field (fb_fields : list (ident * Z)) (x : ident) : option Z :=
  lookup_global_offset fb_fields x.

(* 按名查找调用绑定的实参表达式；缺失 → 常量 0 *)
Fixpoint find_bound (params : list (ident * corest_expr)) (nm : ident)
         : corest_expr :=
  match params with
  | nil => CE_LIT (L_INT 0)
  | (k, e) :: rest => if ident_eq k nm then e else find_bound rest nm
  end.

(* 调用点表：实例名 → (self 基址, FB 名, 声明序输入端口) *)
Definition call_site : Type := list (ident * (Z * ident * list ident)).

Fixpoint lookup_call (cs : call_site) (x : ident)
         : option (Z * ident * list ident) :=
  match cs with
  | nil => None
  | (y, v) :: rest => if ident_eq x y then Some v else lookup_call rest x
  end.

(* FB 输入端口 = __self 之后的参数（desugar_pou 保序） *)
Definition fb_inputs (f : corest_function) : list ident :=
  match f.(cfunc_params) with
  | _ :: rest => List.map (fun pv => fst pv) rest
  | nil => nil
  end.

Definition first_writable (f : corest_function) : option ident :=
  match f.(cfunc_locals) with
  | (n, _) :: _ => Some n
  | nil => None
  end.

Definition cat_ident (a b : ident) : ident :=
  match a, b with ID x, ID y => ID (x ++ "_" ++ y) end.

Fixpoint find_fb_func (nm : ident) (funcs : list corest_function)
         : option corest_function :=
  match funcs with
  | nil => None
  | f :: rest =>
      if andb (ident_eq f.(cfunc_name) nm) (is_self_param f)
      then Some f else find_fb_func nm rest
  end.

(* 遍历实例标记声明 (T_FB fbname)，解析其首字段全局地址为 self 基址 *)
Fixpoint build_call_sites
         (genv : list (ident * Z)) (funcs : list corest_function)
         (gs : list st_var_decl) : call_site :=
  match gs with
  | nil => nil
  | d :: rest =>
      match d.(var_type) with
      | T_FB fbname =>
          match find_fb_func (ID fbname) funcs with
          | Some f =>
              match first_writable f with
              | Some fld0 =>
                  match lookup_global_offset genv (cat_ident d.(var_name) fld0) with
                  | Some base =>
                      (d.(var_name), (base, ID fbname, fb_inputs f))
                      :: build_call_sites genv funcs rest
                  | None => build_call_sites genv funcs rest
                  end
              | None => build_call_sites genv funcs rest
              end
          | None => build_call_sites genv funcs rest
          end
      | _ => build_call_sites genv funcs rest
      end
  end.

Fixpoint compile_expr_gc
         (fbctx : option (Z * list (ident * Z)))
         (locals : compile_env) (globals : list (ident * Z))
         (fidx : func_index_env) (result_idx : option Z)
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
      match fbctx with
      | Some (slot, fields) =>
          match lookup_global_offset fields x with
          | Some off =>
              [LOCAL_GET slot;
               I32_LOAD {| mem_align := 2; mem_offset := off |}]
          | None =>
              match lookup_var_idx locals x with
              | Some idx => [LOCAL_GET idx]
              | None => global_load globals x
              end
          end
      | None =>
          match lookup_var_idx locals x with
          | Some idx => [LOCAL_GET idx]
          | None => global_load globals x
          end
      end
  | CE_ARRAY_ACCESS arr idx =>
      compile_expr_gc fbctx locals globals fidx result_idx arr ++
      compile_expr_gc fbctx locals globals fidx result_idx idx ++
      [I32_ADD; I32_LOAD {| mem_align := 2; mem_offset := 0 |}]
  | CE_UNARY_OP U_NEG e1 =>
      [I32_CONST 0] ++ compile_expr_gc fbctx locals globals fidx result_idx e1 ++ [I32_SUB]
  | CE_UNARY_OP U_NOT e1 =>
      compile_expr_gc fbctx locals globals fidx result_idx e1 ++ [I32_EQZ]
  | CE_UNARY_OP U_ABS e1 =>
      let temp := Z.of_nat (List.length locals) in
      compile_expr_gc fbctx locals globals fidx result_idx e1 ++
      [LOCAL_SET temp; LOCAL_GET temp; I32_CONST 0; I32_LT_S;
       I32_CONST 0; LOCAL_GET temp; I32_SUB; LOCAL_GET temp; SELECT]
  | CE_BIN_OP B_ADD e1 e2 =>
      compile_expr_gc fbctx locals globals fidx result_idx e1 ++
      compile_expr_gc fbctx locals globals fidx result_idx e2 ++ [I32_ADD]
  | CE_BIN_OP B_SUB e1 e2 =>
      compile_expr_gc fbctx locals globals fidx result_idx e1 ++
      compile_expr_gc fbctx locals globals fidx result_idx e2 ++ [I32_SUB]
  | CE_BIN_OP B_MUL e1 e2 =>
      compile_expr_gc fbctx locals globals fidx result_idx e1 ++
      compile_expr_gc fbctx locals globals fidx result_idx e2 ++ [I32_MUL]
  | CE_BIN_OP B_DIV e1 e2 =>
      compile_expr_gc fbctx locals globals fidx result_idx e1 ++
      compile_expr_gc fbctx locals globals fidx result_idx e2 ++ [I32_DIV_S]
  | CE_BIN_OP B_MOD e1 e2 =>
      compile_expr_gc fbctx locals globals fidx result_idx e1 ++
      compile_expr_gc fbctx locals globals fidx result_idx e2 ++ [I32_REM_S]
  | CE_COMP C_EQ e1 e2 =>
      compile_expr_gc fbctx locals globals fidx result_idx e1 ++
      compile_expr_gc fbctx locals globals fidx result_idx e2 ++ [I32_EQ]
  | CE_COMP C_NE e1 e2 =>
      compile_expr_gc fbctx locals globals fidx result_idx e1 ++
      compile_expr_gc fbctx locals globals fidx result_idx e2 ++ [I32_NE]
  | CE_COMP C_LT e1 e2 =>
      compile_expr_gc fbctx locals globals fidx result_idx e1 ++
      compile_expr_gc fbctx locals globals fidx result_idx e2 ++ [I32_LT_S]
  | CE_COMP C_LE e1 e2 =>
      compile_expr_gc fbctx locals globals fidx result_idx e1 ++
      compile_expr_gc fbctx locals globals fidx result_idx e2 ++ [I32_LE_S]
  | CE_COMP C_GT e1 e2 =>
      compile_expr_gc fbctx locals globals fidx result_idx e1 ++
      compile_expr_gc fbctx locals globals fidx result_idx e2 ++ [I32_GT_S]
  | CE_COMP C_GE e1 e2 =>
      compile_expr_gc fbctx locals globals fidx result_idx e1 ++
      compile_expr_gc fbctx locals globals fidx result_idx e2 ++ [I32_GE_S]
  | CE_AND e1 e2 =>
      compile_expr_gc fbctx locals globals fidx result_idx e1 ++
      compile_expr_gc fbctx locals globals fidx result_idx e2 ++ [I32_AND]
  | CE_OR e1 e2 =>
      compile_expr_gc fbctx locals globals fidx result_idx e1 ++
      compile_expr_gc fbctx locals globals fidx result_idx e2 ++ [I32_OR]
  | CE_XOR e1 e2 =>
      compile_expr_gc fbctx locals globals fidx result_idx e1 ++
      compile_expr_gc fbctx locals globals fidx result_idx e2 ++ [I32_XOR]
  | CE_FUNC_CALL f args =>
      match f, args with
      | ID "CycleCounter", nil => compile_cycle_counter locals globals
      | _, _ =>
          match lookup_func_index fidx f with
          | Some idx =>
              List.concat
                (List.map (compile_expr_gc fbctx locals globals fidx result_idx) args) ++
              [CALL idx]
          | None => [UNREACHABLE]
          end
      end
  | CE_QUALITY_OP _ args =>
      List.concat
        (List.map (compile_expr_gc fbctx locals globals fidx result_idx) args)
  end.

Fixpoint compile_stmt_gc
         (fbctx : option (Z * list (ident * Z))) (csites : call_site)
         (locals : compile_env) (globals : list (ident * Z))
         (fidx : func_index_env) (result_idx : option Z)
         (s : corest_stmt) : list sasm_instr :=
  match s with
  | CS_ASSIGN x e =>
      match x with
      | ID "__veristc_cycle_counter" =>
          compile_cycle_counter locals globals ++ [DROP]
      | _ =>
          let rhs := compile_expr_gc fbctx locals globals fidx result_idx e in
          match fbctx with
          | Some (slot, fields) =>
              match lookup_global_offset fields x with
              | Some off =>
                  LOCAL_GET slot :: rhs ++
                  [I32_STORE {| mem_align := 2; mem_offset := off |}]
              | None =>
                  match lookup_var_idx locals x with
                  | Some idx => rhs ++ [LOCAL_SET idx]
                  | None => global_store globals x rhs
                  end
              end
          | None =>
              match lookup_var_idx locals x with
              | Some idx => rhs ++ [LOCAL_SET idx]
              | None => global_store globals x rhs
              end
          end
      end
  | CS_ARRAY_ASSIGN x idx e =>
      compile_expr_gc fbctx locals globals fidx result_idx (CE_VAR x) ++
      compile_expr_gc fbctx locals globals fidx result_idx idx ++ [I32_ADD] ++
      compile_expr_gc fbctx locals globals fidx result_idx e ++
      [I32_STORE {| mem_align := 2; mem_offset := 0 |}]
  | CS_IF cond then_body else_body =>
      let compiled_cond :=
        compile_expr_gc fbctx locals globals fidx result_idx cond in
      let compiled_then :=
        List.concat
          (List.map (compile_stmt_gc fbctx csites locals globals fidx result_idx) then_body) in
      let compiled_else :=
        List.concat
          (List.map (compile_stmt_gc fbctx csites locals globals fidx result_idx) else_body) ++
        [BR 0] in
      let inner_block_instrs :=
        compiled_cond ++ [I32_EQZ; BR_IF 0] ++
        compiled_then ++ [BR 1] in
      let outer_block_instrs :=
        [BLOCK (instr_seq_size inner_block_instrs)] ++
        inner_block_instrs ++ compiled_else in
      [BLOCK (instr_seq_size outer_block_instrs)] ++ outer_block_instrs
  | CS_WHILE cond body =>
      let compiled_cond :=
        compile_expr_gc fbctx locals globals fidx result_idx cond in
      let compiled_body :=
        List.concat
          (List.map (compile_stmt_gc fbctx csites locals globals fidx result_idx) body) in
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
               let port :=
                 match fst p with
                 | ID "__print_char" => SASM_CHAR_PRINT_PORT
                 | _ => SASM_PRINT_PORT
                 end in
               I32_CONST port ::
               compile_expr_gc fbctx locals globals fidx result_idx (snd p) ++
               [I32_STORE {| mem_align := 2; mem_offset := 0 |}])
             params)
      | _ =>
          match lookup_call csites inst with
          | Some (base, fbname, inputs) =>
              match lookup_func_index fidx fbname with
              | Some idx =>
                  I32_CONST base ::
                  List.concat
                    (List.map
                       (fun nm =>
                          compile_expr_gc fbctx locals globals fidx result_idx
                            (find_bound params nm))
                       inputs) ++
                  [CALL idx]
              | None => [UNREACHABLE]
              end
          | None => [UNREACHABLE]
          end
      end
  | CS_RETURN =>
      match result_idx with
      | Some idx => [LOCAL_GET idx; RETURN]
      | None => [RETURN]
      end
  | CS_EXIT => [BR 0]
  | CS_BLOCK stmts =>
      List.concat
        (List.map (compile_stmt_gc fbctx csites locals globals fidx result_idx) stmts)
  end.

Definition compile_function_gc
           (globals : list (ident * Z))
           (fidx : func_index_env)
           (csites : call_site)
           (idx : Z)
           (f : corest_function)
           : sasm_function :=
  let env := build_compile_env f in
  let env_ty := build_compile_type_env f in
  let fbctx :=
      if is_self_param f then
        match self_slot env with
        | Some slot => Some (slot, assign_field_offsets f.(cfunc_locals) 0)
        | None => None
        end
      else None in
  let result_idx :=
    match f.(cfunc_return_type) with
    | Some _ => lookup_var_idx env f.(cfunc_name)
    | None => None
    end in
  let body :=
    List.concat
      (List.map (compile_stmt_gc fbctx csites env globals fidx result_idx)
                f.(cfunc_body)) in
  let body :=
    match result_idx with
    | Some r => body ++ [LOCAL_GET r; RETURN]
    | None =>
        match f.(cfunc_return_type) with
        | Some _ => body ++ [I32_CONST 0; RETURN]
        | None =>
            if is_self_param f then body ++ [RETURN] else body
        end
    end in
  let safeasm_types :=
    List.map (fun p => st_type_to_sasm (snd p)) env_ty ++ [I32] in
  {| sasm_func_type_idx := idx;
     sasm_locals := safeasm_types;
     sasm_body := body;
     sasm_stack_depth := instr_seq_size body;
     sasm_cycle_budget := 1000000;
  |}.

Fixpoint compile_functions_gc
         (globals : list (ident * Z))
         (fidx : func_index_env)
         (csites : call_site)
         (idx : Z)
         (funcs : list corest_function)
         : list sasm_function :=
  match funcs with
  | nil => nil
  | f :: rest =>
      compile_function_gc globals fidx csites idx f ::
      compile_functions_gc globals fidx csites (idx + 1) rest
  end.

Definition compile_program_gc (p : corest_program) : sasm_module :=
  let core_funcs := entry_first_functions p in
  let globals := build_global_env p in
  let fidx := assign_func_indices core_funcs 0 in
  let csites := build_call_sites globals core_funcs p.(cprog_global_vars) in
  let funcs := compile_functions_gc globals fidx csites 0 core_funcs in
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
     sasm_flags := 2;
     sasm_types := types;
     sasm_functions := funcs;
     sasm_memory_segments := [global_seg];
     sasm_total_memory_size := total_mem;
     sasm_io_map := io_map;
     sasm_safety :=
       {| safe_level := 1;
          safe_cycle_limit := 1000000;
          safe_stack_depth := Z.max 1 (analyze_stack_depth p);
          safe_loop_bounds := [];
          safe_mem_access_map :=
            [{| mar_low := 0; mar_high := total_mem |}];
       |};
     sasm_wcet := Some (build_wcet_data core_funcs);
     sasm_entry_function := 0;
  |}.

Lemma compile_program_gc_preserves_entry :
  forall (p : corest_program),
    (compile_program_gc p).(sasm_entry_function) = 0.
Proof. reflexivity. Qed.

(* ================================================================
   P2: 可重定位元数据导出 (供主机侧 OCaml .svobj 编码器消费)

   链接器正确性为"信任+测试"（不进安全核），故本层仅把已链接的
   .sasm 镜像中属于跨模块链接点的指令位置提取为扁平表：
     - CALL_IDX      : 对某 FB __exec 函数目标的 CALL（可重编号）
     - INST_BASE_IMM : CS_FB_CALL 降级压入的实例 self 基址立即数
     - GLOBAL_OFF    : (预留) VAR_IN_OUT 端口对调用方全局的别名
   返回类型均为可提取的扁平类型，不触碰任何已证明结构。
   ================================================================ *)

(* reloc kind: 0=CALL_IDX, 1=INST_BASE_IMM, 2=GLOBAL_OFF
   row = (kind, symbol_name, func_idx, site_byte_offset, addend) *)
Definition reloc_row : Type := (nat * String.string * Z * Z * Z).

Definition ident_str (x : ident) : String.string :=
  match x with ID s => s end.

Definition fname_str (f : corest_function) : String.string :=
  ident_str f.(cfunc_name).

(* 实例名 → 基址（自 csites 抽取） *)
Definition cs_base_list (cs : call_site) : list (ident * Z) :=
  List.map
    (fun (p : ident * (Z * ident * list ident)) =>
       match p with (i, (b, _, _)) => (i, b) end)
    cs.

Fixpoint inst_by_base (bl : list (ident * Z)) (v : Z) : option ident :=
  match bl with
  | nil => None
  | (i, b) :: rest => if Z.eqb b v then Some i else inst_by_base rest v
  end.

(* 函数索引表：(名字, 是否 FB __exec) *)
Definition ftab (funcs : list corest_function) : list (String.string * bool) :=
  List.map (fun f => (fname_str f, is_self_param f)) funcs.

(* 逐指令扫描一个函数体，产生该函数内的重定位行。
   采用"基址候选 + 遇 FB CALL 配对"的前向扫描：CS_FB_CALL 降级恰以
   I32_CONST base 开始、以 CALL exec 结束，故自 base 到 CALL 之间的
   输入表达式常量不会误配。 *)
Fixpoint scan_instrs
         (ft : list (String.string * bool))
         (bl : list (ident * Z))
         (fidx : Z)
         (body : list sasm_instr)
         (off : Z)
         (cand : option (ident * Z)) : list reloc_row :=
  match body with
  | nil => nil
  | i :: rest =>
      let next_off := off + instr_size i in
      match i with
      | I32_CONST v =>
          match inst_by_base bl v with
          | Some iname => scan_instrs ft bl fidx rest next_off (Some (iname, off))
          | None => scan_instrs ft bl fidx rest next_off cand
          end
      | CALL idx =>
          match List.nth_error ft (Z.to_nat idx) with
          | Some (nm, true) =>
              let base_row :=
                match cand with
                | Some (iname, ioff) => (1%nat, ident_str iname, fidx, ioff, 0%Z) :: nil
                | None => nil
                end in
              base_row ++
                ((0%nat, nm, fidx, off, 0%Z) :: scan_instrs ft bl fidx rest next_off None)
          | _ => scan_instrs ft bl fidx rest next_off cand
          end
      | _ => scan_instrs ft bl fidx rest next_off cand
      end
  end.

Fixpoint enumerate_funcs (idx : Z) (fs : list sasm_function) : list (Z * sasm_function) :=
  match fs with
  | nil => nil
  | f :: rest => (idx, f) :: enumerate_funcs (idx + 1) rest
  end.

Definition compile_program_reloc_info
           (p : corest_program) : list reloc_row :=
  let funcs := entry_first_functions p in
  let globals := build_global_env p in
  let csites := build_call_sites globals funcs p.(cprog_global_vars) in
  let bl := cs_base_list csites in
  let ft := ftab funcs in
  let bodies := enumerate_funcs 0 (compile_program_gc p).(sasm_functions) in
  List.concat
    (List.map
       (fun pf =>
          scan_instrs ft bl (fst pf) (snd pf).(sasm_body) 0 None)
       bodies).

(* 实例数据块信息：(inst, fb_name, base, size)，size = 4 * 可写字段数 *)
Definition compile_program_inst_info
           (p : corest_program) : list (String.string * String.string * Z * Z) :=
  let funcs := entry_first_functions p in
  let globals := build_global_env p in
  let csites := build_call_sites globals funcs p.(cprog_global_vars) in
  List.map
    (fun (c : ident * (Z * ident * list ident)) =>
       match c with
       | (iname, (base, fbname, _)) =>
           let sz :=
             match find_fb_func fbname funcs with
             | Some f => 4 * Z.of_nat (List.length f.(cfunc_locals))
             | None => 0%Z
             end in
           (ident_str iname, ident_str fbname, base, sz)
       end)
    csites.
