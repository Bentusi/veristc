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

(* I/O 映射条目的内存偏移 = 该变量在 build_global_env 里的**真实全局槽位地址**。

   旧实现另起一套从 1024 递增的编号（codegen.assign_io_offsets），于是运行站
   io_mapping_read_all 写进去的位置和程序读写的变量根本不是同一块内存：
   物理输入进不了程序、程序输出到不了通道，且全程不报错。
   地址唯一来源与 global_load / debug_rows_of 相同 —— 不做第二份地址真相。

   查不到名字 ⇒ -1（编码为 0xFFFFFFFF）：function_check 已在编译期拒绝该程序，
   运行期写内存的边界判断也会跳过它，不会踩到别的变量。 *)
Definition resolve_io_map (globals : list (ident * Z))
                          (entries : list io_entry) : list io_entry_sasm :=
  List.map
    (fun e =>
       let 'Build_io_entry name_ _ _ _ := e in
       match lookup_global_offset globals name_ with
       | Some addr => io_entry_to_sasm addr e
       | None => io_entry_to_sasm (-1) e
       end)
    entries.

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
  let io_map := resolve_io_map globals p.(cprog_io_mapping) in
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

(* 调用点表：实例名 → (self 基址, FB 名, 形参端口表[(名, 是否别名)]) *)
Definition call_site : Type :=
  list (ident * (Z * ident * list (ident * bool))).

Fixpoint lookup_call (cs : call_site) (x : ident)
         : option (Z * ident * list (ident * bool)) :=
  match cs with
  | nil => None
  | (y, v) :: rest => if ident_eq x y then Some v else lookup_call rest x
  end.

(* FB 形参端口表 = __self 之后的参数，逐项标注是否 VAR_IN_OUT 别名端口
   （desugar_pou 保持声明序，故调用点压栈顺序与 callee 形参槽位一一对应）。 *)
Definition fb_ports (f : corest_function) : list (ident * bool) :=
  match f.(cfunc_params) with
  | _ :: rest =>
      List.map
        (fun pv => (fst pv, List.existsb (ident_eq (fst pv)) f.(cfunc_ptr_params)))
        rest
  | nil => nil
  end.

(* VAR_IN_OUT 形参名 → 其本地槽位（槽内保存调用方存储的地址） *)
Fixpoint collect_ptr_slots
         (env : compile_env) (names : list ident) : list (ident * Z) :=
  match names with
  | nil => nil
  | n :: rest =>
      match lookup_var_idx env n with
      | Some idx => (n, idx) :: collect_ptr_slots env rest
      | None => collect_ptr_slots env rest
      end
  end.

Definition first_writable (f : corest_function) : option ident :=
  match f.(cfunc_locals) with
  | (n, _) :: _ => Some n
  | nil => None
  end.

(* 实例字段扁平全局名 = inst ++ derived_field_sep ++ field，
   必须与 function_check.inst_field_global 的构造逐字一致，
   否则这里的地址解析会查不到刚展开出来的全局。 *)
Definition cat_ident (a b : ident) : ident :=
  match a, b with ID x, ID y => ID (x ++ derived_field_sep ++ y) end.

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
                      (d.(var_name), (base, ID fbname, fb_ports f))
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
         (fbctx : option (Z * list (ident * Z) * list (ident * Z)))
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
      | Some (slot, fields, ptrs) =>
          match lookup_global_offset fields x with
          | Some off =>
              [LOCAL_GET slot;
               I32_LOAD {| mem_align := 2; mem_offset := off |}]
          | None =>
              match lookup_global_offset ptrs x with
              (* VAR_IN_OUT 端口：槽位里是调用方存储的地址，解引用取值 *)
              | Some pslot =>
                  [LOCAL_GET pslot;
                   I32_LOAD_PTR {| mem_align := 2; mem_offset := 0 |}]
              | None =>
                  match lookup_var_idx locals x with
                  | Some idx => [LOCAL_GET idx]
                  | None => global_load globals x
                  end
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

(* VAR_IN_OUT 实参 → 地址实参代码。
   function_check 已保证实参形状只有两种合法来源：
     - 调用方自身的 IN_OUT 端口（透传）：其形参槽已持有地址，
       直接 LOCAL_GET 转发；
     - 全局变量（VAR_GLOBAL 或实例展开的 inst#field）：压入其
       线性地址常量，链接期由 GLOBAL_OFF 重定位（见 P2）。
   其余形状（字面量/表达式/局部变量）在检查层已被拒绝，这里以
   UNREACHABLE 保守落地，保证不会静默生成错误别名。 *)
Definition alias_actual_code
           (fbctx : option (Z * list (ident * Z) * list (ident * Z)))
           (globals : list (ident * Z)) (actual : corest_expr)
           : list sasm_instr :=
  match actual with
  | CE_VAR g =>
      match fbctx with
      | Some (_, _, ptrs) =>
          match lookup_global_offset ptrs g with
          | Some pslot => [LOCAL_GET pslot]
          | None =>
              match lookup_global_offset globals g with
              | Some addr => [I32_CONST addr]
              | None => [UNREACHABLE]
              end
          end
      | None =>
          match lookup_global_offset globals g with
          | Some addr => [I32_CONST addr]
          | None => [UNREACHABLE]
          end
      end
  | _ => [UNREACHABLE]
  end.

Fixpoint compile_stmt_gc
         (fbctx : option (Z * list (ident * Z) * list (ident * Z))) (csites : call_site)
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
          | Some (slot, fields, ptrs) =>
              match lookup_global_offset fields x with
              | Some off =>
                  LOCAL_GET slot :: rhs ++
                  [I32_STORE {| mem_align := 2; mem_offset := off |}]
              | None =>
                  match lookup_global_offset ptrs x with
                  (* VAR_IN_OUT 端口写：先压地址（槽内值），再压值，
                     与 Pc_i32_store_ptr / C VM 的操作数约定一致 *)
                  | Some pslot =>
                      LOCAL_GET pslot :: rhs ++
                      [I32_STORE_PTR {| mem_align := 2; mem_offset := 0 |}]
                  | None =>
                      match lookup_var_idx locals x with
                      | Some idx => rhs ++ [LOCAL_SET idx]
                      | None => global_store globals x rhs
                      end
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
          | Some (base, fbname, ports) =>
              match lookup_func_index fidx fbname with
              | Some idx =>
                  I32_CONST base ::
                  List.concat
                    (List.map
                       (fun port =>
                          match port with
                          | (nm, true) =>
                              alias_actual_code fbctx globals
                                (find_bound params nm)
                          | (nm, false) =>
                              compile_expr_gc fbctx locals globals fidx result_idx
                                (find_bound params nm)
                          end)
                       ports) ++
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
        | Some slot =>
            Some (slot, assign_field_offsets f.(cfunc_locals) 0,
                  collect_ptr_slots env f.(cfunc_ptr_params))
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
  let io_map := resolve_io_map globals p.(cprog_io_mapping) in
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
     - GLOBAL_OFF    : VAR_IN_OUT 端口实参对调用方全局的别名地址立即数
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
    (fun (p : ident * (Z * ident * list (ident * bool))) =>
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

(* ---------------- GLOBAL_OFF 所需的别名实参表 ----------------
   从调用点**结构**推导"哪些全局被绑到了某个 VAR_IN_OUT 端口"，
   再解析其线性地址。这样扫描器只需判断 I32_CONST 的立即数是否
   落在这张表里，无需猜测代码形状。
   透传实参（绑定到调用方自身的端口）压的是 LOCAL_GET 槽位、不产生
   立即数，且 lookup_global_offset 对端口名返回 None，故自然不入表。 *)

Definition alias_var_of_expr (e : corest_expr) : option ident :=
  match e with CE_VAR g => Some g | _ => None end.

Fixpoint alias_actuals_of_ports
         (params : list (ident * corest_expr))
         (ports : list (ident * bool)) : list ident :=
  match ports with
  | nil => nil
  | (nm, is_alias) :: rest =>
      if is_alias
      then match alias_var_of_expr (find_bound params nm) with
           | Some g => g :: alias_actuals_of_ports params rest
           | None => alias_actuals_of_ports params rest
           end
      else alias_actuals_of_ports params rest
  end.

Fixpoint alias_names_of_stmt (csites : call_site) (s : corest_stmt) : list ident :=
  match s with
  | CS_FB_CALL inst params =>
      (* csites 只登记实例调用，PRINT 等内建名自然查不到 → 不入表 *)
      match lookup_call csites inst with
      | Some (_, _, ports) => alias_actuals_of_ports params ports
      | None => nil
      end
  | CS_IF _ t e =>
      List.concat
        (List.map (alias_names_of_stmt csites) t ++
         List.map (alias_names_of_stmt csites) e)
  | CS_WHILE _ b => List.concat (List.map (alias_names_of_stmt csites) b)
  | CS_BLOCK b => List.concat (List.map (alias_names_of_stmt csites) b)
  | _ => nil
  end.

(* 别名表：(全局名, 线性地址)，按名字去重（同一地址/名字只留一条） *)
Fixpoint add_alias_pairs
         (globals : list (ident * Z)) (gs : list ident)
         (acc : list (ident * Z)) : list (ident * Z) :=
  match gs with
  | nil => acc
  | g :: rest =>
      match lookup_global_offset globals g with
      | Some addr =>
          if existsb (fun gp => ident_eq (fst gp) g) acc
          then add_alias_pairs globals rest acc
          else add_alias_pairs globals rest ((g, addr) :: acc)
      | None => add_alias_pairs globals rest acc
      end
  end.

Definition build_alias_table
           (globals : list (ident * Z))
           (funcs : list corest_function)
           (csites : call_site) : list (ident * Z) :=
  add_alias_pairs
    globals
    (List.concat
       (List.map
          (fun f =>
             List.concat (List.map (alias_names_of_stmt csites) f.(cfunc_body)))
          funcs))
    [].

(* 逐指令扫描一个函数体，产生该函数内的重定位行。
   采用"基址候选 + 遇 FB CALL 配对"的前向扫描：CS_FB_CALL 降级恰以
   I32_CONST base 开始、以 CALL exec 结束，故自 base 到 CALL 之间的
   输入表达式常量不会误配。
   pl 为别名表：同一窗口内落在 pl 上的 I32_CONST 记为 GLOBAL_OFF 候选，
   随该 CALL 一起落地（addend = 地址 - GLOBAL_BASE），窗口外（无基址
   候选）的全局地址常量不入行——它们不属于跨模块链接点。
   别名判定**优先于**基址判定：实例字段派生名全局（如 a1#LAST）的地址
   恰是该实例的 self 基址，窗口内出现时必须按别名处理，否则会把别名
   实参误认成下一次调用的基址、同时丢掉了真正的基址行。
   精度：窗口内若有"值端口读某个被别名过的全局"（codegen 也压该全局
   地址），会多出一条 GLOBAL_OFF 行——该行声明"此立即数是该符号的地
   址"，对被多记的站点同样成立，链接期回写结果一致，故不影响正确性。 *)
Fixpoint scan_instrs
         (ft : list (String.string * bool))
         (bl pl : list (ident * Z))
         (fidx : Z)
         (body : list sasm_instr)
         (off : Z)
         (cand : option (ident * Z))
         (pend : list (ident * Z * Z)) : list reloc_row :=
  match body with
  | nil => nil
  | i :: rest =>
      let next_off := off + instr_size i in
      match i with
      | I32_CONST v =>
          match inst_by_base pl v with
          | Some g =>
              match cand with
              | Some _ =>
                  scan_instrs ft bl pl fidx rest next_off cand ((g, off, v) :: pend)
              | None =>
                  match inst_by_base bl v with
                  | Some iname => scan_instrs ft bl pl fidx rest next_off (Some (iname, off)) nil
                  | None => scan_instrs ft bl pl fidx rest next_off cand pend
                  end
              end
          | None =>
              match inst_by_base bl v with
              | Some iname => scan_instrs ft bl pl fidx rest next_off (Some (iname, off)) nil
              | None => scan_instrs ft bl pl fidx rest next_off cand pend
              end
          end
      | CALL idx =>
          match List.nth_error ft (Z.to_nat idx) with
          | Some (nm, true) =>
              let base_row :=
                match cand with
                | Some (iname, ioff) => (1%nat, ident_str iname, fidx, ioff, 0%Z) :: nil
                | None => nil
                end in
              let alias_rows :=
                List.map
                  (fun (t : ident * Z * Z) =>
                     match t with
                     | (g, goff, addr) => (2%nat, ident_str g, fidx, goff, addr - GLOBAL_BASE)
                     end)
                  (rev pend) in
              base_row ++ alias_rows ++
                ((0%nat, nm, fidx, off, 0%Z) ::
                   scan_instrs ft bl pl fidx rest next_off None nil)
          | _ => scan_instrs ft bl pl fidx rest next_off cand pend
          end
      | _ => scan_instrs ft bl pl fidx rest next_off cand pend
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
  let pl := build_alias_table globals funcs csites in
  let ft := ftab funcs in
  let bodies := enumerate_funcs 0 (compile_program_gc p).(sasm_functions) in
  List.concat
    (List.map
       (fun pf =>
          scan_instrs ft bl pl (fst pf) (snd pf).(sasm_body) 0 None nil)
       bodies).

(* 实例数据块信息：(inst, fb_name, base, size)，size = 4 * 可写字段数 *)
Definition compile_program_inst_info
           (p : corest_program) : list (String.string * String.string * Z * Z) :=
  let funcs := entry_first_functions p in
  let globals := build_global_env p in
  let csites := build_call_sites globals funcs p.(cprog_global_vars) in
  List.map
    (fun (c : ident * (Z * ident * list (ident * bool))) =>
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

(* ---------------- 符号表导出（.svobj SYMTAB，见 spec 附录 D.2）----------------
   row = (名字, kind, aux)
     kind 0 = FB_EXEC     aux = 该 __exec 在本模块中的函数索引
     kind 1 = INST_DATA   aux = 实例数据块基址
     kind 2 = GLOBAL_EXT  aux = 0（被 VAR_IN_OUT 别名、定义在他处的全局）
   与 reloc 行**分开**导出：主机侧不再从"调用点所在函数索引"反推
   FB_EXEC 的 aux（那是调用方而非目标，会得到错误值）。
   排序/去重仍归 OCaml 编码器负责，以保字节级确定性。 *)
Definition sym_row : Type := (String.string * nat * Z).

Fixpoint enumerate_cfuncs (idx : Z) (fs : list corest_function)
         : list (Z * corest_function) :=
  match fs with
  | nil => nil
  | f :: rest => (idx, f) :: enumerate_cfuncs (idx + 1) rest
  end.

Definition compile_program_sym_info
           (p : corest_program) : list sym_row :=
  let funcs := entry_first_functions p in
  let globals := build_global_env p in
  let csites := build_call_sites globals funcs p.(cprog_global_vars) in
  let exec_rows :=
    List.map
      (fun (pf : Z * corest_function) => (fname_str (snd pf), 0%nat, fst pf))
      (List.filter (fun pf => is_self_param (snd pf))
                   (enumerate_cfuncs 0 funcs)) in
  let inst_rows :=
    List.map
      (fun (c : ident * (Z * ident * list (ident * bool))) =>
         match c with
         | (iname, (base, _, _)) => (ident_str iname, 1%nat, base)
         end)
      csites in
  let alias_rows :=
    List.map
      (fun (gp : ident * Z) =>
         match gp with (g, _) => (ident_str g, 2%nat, 0%Z) end)
      (build_alias_table globals funcs csites) in
  exec_rows ++ inst_rows ++ alias_rows.

(* ---------------- Debug 符号表导出（.sasm 段 7，见 safeasm-spec §4.8）--------
   row = (名字, 绝对内存地址, type_tag)

   地址**只**取自 build_global_env —— 脱糖后 corest_program 上的全局槽位表
   是地址的唯一权威来源。本函数不重算偏移：在别处另算一套地址会产生第二份
   "地址真相"，上位工具据此监视错槽位比查不到符号更危险。
   名字与槽位表一旦对不上即停止发射（宁可少符号，不发错地址）。

   type_tag 是 st_type 的枚举序号（编号表见 spec §4.8），仅供上位工具展示；
   运行期每个全局槽恒是一个 int32 单字，size/flags 由主机侧编码器补齐。
   排序、去重与字节编码归 OCaml 侧 emit_debug_section，与 .svobj SYMTAB 同纪律。 *)

Definition debug_row : Type := (String.string * Z * nat).

Definition st_type_tag (t : st_type) : nat :=
  match t with
  | T_BOOL    => 0
  | T_INT     => 1
  | T_DINT    => 2
  | T_REAL    => 3
  | T_LINT    => 4
  | T_LREAL   => 5
  | T_TIME    => 6
  | T_QUALITY => 7
  | T_BYTE    => 8
  | T_WORD    => 9
  | T_DWORD   => 10
  | T_SINT    => 11
  | T_QBOOL   => 12
  | T_QBYTE   => 13
  | T_QWORD   => 14
  | T_QDWORD  => 15
  | T_QSINT   => 16
  | T_QINT    => 17
  | T_QDINT   => 18
  | T_QLINT   => 19
  | T_QREAL   => 20
  | T_QLREAL  => 21
  | T_QTIME   => 22
  | T_ARRAY _ _ _ => 23
  | T_FB _        => 24
  end.

Fixpoint debug_rows_of (decls : list st_var_decl)
         (env : list (ident * Z)) : list debug_row :=
  match decls with
  | nil => nil
  | d :: rest =>
      match env with
      | nil => nil
      | (g, addr) :: env' =>
          if ident_eq d.(var_name) g
          then (ident_str g, addr, st_type_tag d.(var_type)) ::
                 debug_rows_of rest env'
          else nil
      end
  end.

Definition compile_program_debug_info
           (p : corest_program) : list debug_row :=
  debug_rows_of p.(cprog_global_vars) (build_global_env p).

(* ---------------- IOMAP 工程量标尺导出（段 3 的 scale/bias 两个 float64）----
   `float` 的 IEEE-754 位在 Coq 内拿不到（PrimFloat 靠提取期实现，与 encoder.v
   里 F32/F64_CONST 立即数编码为全零是同一个缺口），所以本函数只出行、
   那 16 字节由主机侧 OCaml 覆盖到段 3 的对应槽位（字节编码不进 Coq）。

   行序与编码序**逐条一致**：encode_io_entries 用 fold_right，不重排。
   主机侧按序写入并在条数不符时拒绝产出，绝不静默错位。

   今天这三列全是 io_entry_to_sasm 里的常量（scale=1.0 / bias=0.0 / 满量程限值）：
   SafeST 的 IOMAP 语法还没有承载量程/偏置的字段（safest.v 的 io_entry 只有
   名字/通道/方向/类型）。本导出的意义是让**字节流与 IR 一致**——
   此前编码器写的是全零占位，加载器又无视字节流硬写 1.0/0.0，两边各自假装。 *)
Definition io_cal_row : Type := (Z * PrimFloat.float * PrimFloat.float).

Definition compile_module_io_cal_info
           (m : sasm_module) : list io_cal_row :=
  List.map (fun e : io_entry_sasm => (e.(io_channel_id), e.(io_scale), e.(io_bias)))
           m.(sasm_io_map).
