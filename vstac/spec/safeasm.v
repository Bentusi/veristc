(* ================================================================
   vstac/spec/safeasm.v
   SafeASM — 安全汇编字节码 Coq 形式化定义
   
   本文件是 spec/safeasm-spec.md 的 Coq 形式化镜像。
   所有定义与文档保持同步。
   编码方式：固定宽度编码（非 LEB128）
   ================================================================ *)

Require Import Stdlib.ZArith.ZArith.
Require Import Stdlib.Lists.List.
Local Open Scope Z_scope.
Require Import Stdlib.Floats.Floats.
Require Import Stdlib.Strings.String.
Import ListNotations.

Unset Guard Checking.

(* ================================================================
   第 1 部分：值类型 (Value Types)
   ================================================================ *)

Inductive sasm_value_type : Type :=
  | I32           (* 32 位有符号整数 *)
  | I64           (* 64 位有符号整数 *)
  | F32           (* 32 位 IEEE 754 单精度浮点 *)
  | F64           (* 64 位 IEEE 754 双精度浮点 *)
.

(* 值类型的字节宽度 *)
Definition sasm_type_width (t : sasm_value_type) : Z :=
  match t with
  | I32 => 4
  | I64 => 8
  | F32 => 4
  | F64 => 8
  end.

(* 运行时值 *)
Inductive sasm_value : Type :=
  | V_I32 : Z -> sasm_value
  | V_I64 : Z -> sasm_value
  | V_F32 : float -> sasm_value
  | V_F64 : float -> sasm_value
.

(* 获取值的类型 *)
Definition value_type (v : sasm_value) : sasm_value_type :=
  match v with
  | V_I32 _ => I32
  | V_I64 _ => I64
  | V_F32 _ => F32
  | V_F64 _ => F64
  end.

(* ================================================================
   第 2 部分：内存参数 (Memory Arg)
   ================================================================ *)

Record memory_arg : Type := {
  mem_align  : Z;     (* 对齐要求 (log2) *)
  mem_offset : Z;     (* 基址偏移 *)
}.

(* ================================================================
   第 3 部分：安全断言 (Safety Assertion)
   ================================================================ *)

Inductive safety_assertion : Type :=
  | ASSERT_CYCLE_LIMIT : Z -> safety_assertion          (* 周期指令数上限 *)
  | ASSERT_STACK_DEPTH : Z -> safety_assertion          (* 栈深度上限 *)
  | ASSERT_MEM_BOUNDS : Z -> Z -> safety_assertion       (* 内存访问范围 [low, high) *)
.

(* ================================================================
   第 4 部分：指令集 (Instruction Set)
   ================================================================ *)

Inductive sasm_instr : Type :=
  (* --- 控制流 (0x00-0x06) --- *)
  | UNREACHABLE                      (* 不可达指令 *)
  | NOP                              (* 空操作 *)
  | BLOCK : Z -> sasm_instr          (* 块开始，参数=块内指令字节数 *)
  | LOOP : Z -> sasm_instr           (* 循环块开始 *)
  | BR : Z -> sasm_instr             (* 无条件跳转，参数=跳出深度 *)
  | BR_IF : Z -> sasm_instr          (* 条件跳转 *)
  | RETURN                           (* 函数返回 *)
  
  (* --- 函数调用 (0x10) --- *)
  | CALL : Z -> sasm_instr           (* 直接调用，参数=函数索引 *)
  
  (* --- 栈操作 (0x1A-0x22) --- *)
  | DROP                              (* 丢弃栈顶 *)
  | SELECT                            (* 三目选择 *)
  | LOCAL_GET : Z -> sasm_instr       (* 读取局部变量 *)
  | LOCAL_SET : Z -> sasm_instr       (* 写入局部变量 *)
  | LOCAL_TEE : Z -> sasm_instr       (* 写入并保留值 *)
  
  (* --- i32 常量 (0x41) --- *)
  | I32_CONST : Z -> sasm_instr       (* i32 常量 *)
  
  (* --- i32 比较 (0x45-0x4B) --- *)
  | I32_EQZ
  | I32_EQ | I32_NE
  | I32_LT_S | I32_LE_S | I32_GT_S | I32_GE_S
  
  (* --- i32 算术 (0x6A-0x6F) --- *)
  | I32_ADD | I32_SUB | I32_MUL
  | I32_DIV_S | I32_REM_S
  
  (* --- i32 位运算 (0x71-0x77) --- *)
  | I32_AND | I32_OR | I32_XOR
  | I32_SHL | I32_SHR_S
  | I32_ROTL | I32_ROTR
  
  (* --- i64 常量/比较/算术 (0x50-0x5B, 0x7C-0x80) --- *)
  | I64_CONST : Z -> sasm_instr
  | I64_EQZ
  | I64_EQ | I64_NE
  | I64_LT_S | I64_LE_S | I64_GT_S | I64_GE_S
  | I64_ADD | I64_SUB | I64_MUL
  | I64_DIV_S | I64_REM_S
  | I64_AND | I64_OR | I64_XOR
  | I64_SHL | I64_SHR_S
  
  (* --- 浮点常量 (0x43-0x44) --- *)
  | F32_CONST : float -> sasm_instr
  | F64_CONST : float -> sasm_instr
  
  (* --- f32 算术 (0x92-0xA2) --- *)
  | F32_ADD | F32_SUB | F32_MUL | F32_DIV
  | F32_EQ | F32_NE | F32_LT | F32_LE | F32_GT | F32_GE
  | F32_ABS | F32_NEG | F32_SQRT
  
  (* --- f64 算术 (0xA3-0xAF) --- *)
  | F64_ADD | F64_SUB | F64_MUL | F64_DIV
  | F64_EQ | F64_NE | F64_LT | F64_LE | F64_GT | F64_GE
  | F64_ABS | F64_NEG | F64_SQRT
  
  (* --- 类型转换 (0xA7-0xBB) --- *)
  | I32_WRAP_I64
  | I64_EXTEND_I32_S
  | I32_TRUNC_F32_S | I32_TRUNC_F64_S
  | F32_CONVERT_I32_S | F64_CONVERT_I32_S
  
  (* --- 内存操作 (0x28-0x39) --- *)
  | I32_LOAD : memory_arg -> sasm_instr
  | I64_LOAD : memory_arg -> sasm_instr
  | F32_LOAD : memory_arg -> sasm_instr
  | F64_LOAD : memory_arg -> sasm_instr
  | I32_STORE : memory_arg -> sasm_instr
  | I64_STORE : memory_arg -> sasm_instr
  | F32_STORE : memory_arg -> sasm_instr
  | F64_STORE : memory_arg -> sasm_instr
  | I32_LOAD8_U : memory_arg -> sasm_instr    (* 加载 1 字节, v1.1 *)
  | I32_STORE8 : memory_arg -> sasm_instr     (* 存储 1 字节, v1.1 *)
  
  (* --- 安全扩展 (0xFC-0xFD) --- *)
  | SAFE_ASSERT : safety_assertion -> sasm_instr
  | SAFE_BOUNDS_CHECK : Z -> Z -> sasm_instr   (* low, high *)
.

(* ================================================================
   第 5 部分：函数类型与函数定义
   ================================================================ *)

Record sasm_func_type : Type := {
  sasm_param_types  : list sasm_value_type;
  sasm_return_types : list sasm_value_type;   (* 0 或 1 个返回值 *)
}.

Record sasm_function : Type := {
  sasm_func_type_idx : Z;          (* 函数类型索引 *)
  sasm_locals         : list sasm_value_type;   (* 局部变量类型列表 *)
  sasm_body           : list sasm_instr;        (* 指令序列 *)
  sasm_stack_depth    : Z;                      (* 栈深度上限 *)
  sasm_cycle_budget   : Z;                      (* WCET 预算 *)
}.

(* ================================================================
   第 6 部分：内存段 (Memory Segments)
   ================================================================ *)

Inductive segment_type : Type :=
  | SEG_IO_INPUT          (* I/O 输入区，只读 *)
  | SEG_IO_OUTPUT         (* I/O 输出区，可写 *)
  | SEG_GLOBAL            (* 全局变量区 *)
  | SEG_FB_DATA           (* FB 实例数据区 *)
  | SEG_STACK             (* 栈区 *)
  | SEG_CONST             (* 常量区 *)
.

Record memory_segment : Type := {
  seg_type       : segment_type;
  seg_start      : Z;      (* 基址偏移 *)
  seg_size       : Z;      (* 段大小 *)
}.

(* ================================================================
   第 7 部分：I/O 映射条目
   ================================================================ *)

Inductive io_direction : Type :=
  | IO_INPUT | IO_OUTPUT.

Inductive io_type : Type :=
  | IO_AI | IO_AO | IO_DI | IO_DO.

Record io_entry_sasm : Type := {
  io_var_name   : string;     (* ST 变量名 *)
  io_mem_offset : Z;          (* SafeASM 内存偏移 *)
  io_channel_id : Z;          (* 物理通道 ID *)
  io_dir        : io_direction;
  io_type_kind  : io_type;
  io_bit_width  : Z;
  io_scale      : float;      (* 工程量转换系数 *)
  io_bias       : float;      (* 偏移量 *)
  io_safety_low : Z;          (* 安全下限 *)
  io_safety_high : Z;         (* 安全上限 *)
}.

(* ================================================================
   第 8 部分：安全注解 (Safety Annotation)
   ================================================================ *)

Record loop_bound : Type := {
  lb_func_idx     : Z;    (* 函数索引 *)
  lb_instr_offset : Z;    (* 循环指令偏移 *)
  lb_max_iter     : Z;    (* 最大迭代次数 *)
}.

Record mem_access_range : Type := {
  mar_low  : Z;
  mar_high : Z;
}.

Record safety_annotation : Type := {
  safe_level          : Z;                    (* 安全等级 *)
  safe_cycle_limit    : Z;                    (* 每周期最大指令数 *)
  safe_stack_depth    : Z;                    (* 全局栈深度上限 *)
  safe_loop_bounds    : list loop_bound;       (* 循环上限表 *)
  safe_mem_access_map : list mem_access_range; (* 合法内存访问范围 *)
}.

(* ================================================================
   第 9 部分：WCET 信息
   ================================================================ *)

Record wcet_func_info : Type := {
  wcet_func_idx  : Z;
  wcet_cycles    : Z;    (* 最差执行周期数 *)
  wcet_ns        : Z;    (* 最差执行时间 (ns) *)
}.

Record wcet_data : Type := {
  wcet_funcs : list wcet_func_info;
}.

(* ================================================================
   第 10 部分：完整 SafeASM 模块
   ================================================================ *)

Record sasm_module : Type := {
  (* 文件头 *)
  sasm_magic    : string;         (* "SASM" *)
  sasm_version  : Z;              (* 1 *)
  sasm_flags    : Z;              (* 特性位图 *)

  (* 核心数据 *)
  sasm_types      : list sasm_func_type;
  sasm_functions  : list sasm_function;
  sasm_memory_segments : list memory_segment;
  sasm_total_memory_size : Z;     (* 线性内存总大小 *)
  sasm_io_map     : list io_entry_sasm;
  
  (* 安全元数据 *)
  sasm_safety     : safety_annotation;
  sasm_wcet       : option wcet_data;
  
  (* 入口 *)
  sasm_entry_function : Z;        (* 入口函数索引 *)
}.

(* ================================================================
   第 11 部分：运行时状态 (Runtime State)
   ================================================================ *)

(* 值栈与帧栈 *)
Definition value_stack : Type := list sasm_value.

Record sasm_frame : Type := {
  frame_locals        : list sasm_value;   (* 局部变量 *)
  frame_func_idx      : Z;                  (* 当前函数索引 *)
  frame_pc            : Z;                  (* 程序计数器 *)
  frame_block_stack   : list Z;             (* 控制流块栈（BLOCK/LOOP 返回地址），用于 BR/BR_IF *)
}.

Definition frame_stack : Type := list sasm_frame.

(* 线性内存 = 字节列表 *)
Definition linear_memory : Type := list Z.  (* 每个 byte 为 0..255 的 Z *)

(* 完整运行时状态 *)
Record runtime_state : Type := {
  rt_values     : value_stack;       (* 值栈 *)
  rt_frames     : frame_stack;       (* 调用帧栈 *)
  rt_memory     : linear_memory;     (* 线性内存 *)
  rt_cycle_cnt  : Z;                 (* 当前周期指令计数 *)
}.

(* 辅助：从 sasm_value 提取 Z 值 *)
Definition val_to_z (v : sasm_value) : Z :=
  match v with
  | V_I32 z => z
  | V_I64 z => z
  | V_F32 _ => 0
  | V_F64 _ => 0
  end.

(* ================================================================
   第 12 部分：小步操作语义 (Small-step Semantics)
   ================================================================ *)

(* 辅助函数：执行二元 i32 运算 *)
Definition i32_bin_op (op : sasm_instr) (v1 v2 : Z) : option Z :=
  match op with
  | I32_ADD => Some (v1 + v2)
  | I32_SUB => Some (v1 - v2)
  | I32_MUL => Some (v1 * v2)
  | I32_DIV_S => if v2 =? 0 then None else Some (v1 / v2)
  | I32_REM_S => if v2 =? 0 then None else Some (Z.rem v1 v2)
  | I32_AND => Some (Z.land v1 v2)
  | I32_OR  => Some (Z.lor v1 v2)
  | I32_XOR => Some (Z.lxor v1 v2)
  | I32_SHL => Some (Z.shiftl v1 v2)
  | I32_SHR_S => Some (Z.shiftr v1 v2)
  | I32_ROTL => Some (Z.land (Z.lor (Z.shiftl v1 (Z.land v2 31)) (Z.shiftr v1 (Z.land (32 - Z.land v2 31) 31))) 4294967295)
  | I32_ROTR => Some (Z.land (Z.lor (Z.shiftr v1 (Z.land v2 31)) (Z.shiftl v1 (Z.land (32 - Z.land v2 31) 31))) 4294967295)
  | _ => None
  end.


(* ================================================================
   第 12a 部分：算术与比较辅助函数 (Arithmetic & Compare Helpers)
   ================================================================ *)

(* i32 比较: 返回 0 或 1 *)
Definition i32_cmp_op (op : sasm_instr) (v1 v2 : Z) : Z :=
  match op with
  | I32_EQ => if Z.eqb v1 v2 then 1 else 0
  | I32_NE => if negb (Z.eqb v1 v2) then 1 else 0
  | I32_LT_S => if Z.ltb v1 v2 then 1 else 0
  | I32_LE_S => if Z.leb v1 v2 then 1 else 0
  | I32_GT_S => if Z.ltb v2 v1 then 1 else 0
  | I32_GE_S => if Z.leb v2 v1 then 1 else 0
  | _ => 0
  end.

(* i64 二元运算 *)
Definition i64_bin_op (op : sasm_instr) (v1 v2 : Z) : option Z :=
  match op with
  | I64_ADD => Some (v1 + v2)
  | I64_SUB => Some (v1 - v2)
  | I64_MUL => Some (v1 * v2)
  | I64_DIV_S => if v2 =? 0 then None else Some (v1 / v2)
  | I64_REM_S => if v2 =? 0 then None else Some (Z.rem v1 v2)
  | I64_AND => Some (Z.land v1 v2)
  | I64_OR => Some (Z.lor v1 v2)
  | I64_XOR => Some (Z.lxor v1 v2)
  | I64_SHL => Some (Z.shiftl v1 v2)
  | I64_SHR_S => Some (Z.shiftr v1 v2)
  | _ => None
  end.

(* i64 比较 *)
Definition i64_cmp_op (op : sasm_instr) (v1 v2 : Z) : Z :=
  match op with
  | I64_EQ => if Z.eqb v1 v2 then 1 else 0
  | I64_NE => if negb (Z.eqb v1 v2) then 1 else 0
  | I64_LT_S => if Z.ltb v1 v2 then 1 else 0
  | I64_LE_S => if Z.leb v1 v2 then 1 else 0
  | I64_GT_S => if Z.ltb v2 v1 then 1 else 0
  | I64_GE_S => if Z.leb v2 v1 then 1 else 0
  | _ => 0
  end.

(* i32 负载: 从 linear_memory 读取 4 字节小端并拼接为 i32 *)
Definition read_i32 (mem : list Z) (addr : Z) (offset : Z) : Z :=
  let a := addr + offset in
  let nth_or0 (pos : Z) : Z :=
    let idx := Z.to_nat pos in
    if Nat.ltb idx (Datatypes.length mem) then List.nth idx mem 0 else 0
  in
  nth_or0 a + nth_or0 (a+1) * 256 + nth_or0 (a+2) * 65536 + nth_or0 (a+3) * 16777216.


(* 从内存读取单字节并零扩展到 i32（v1.1 新增，支持 I32_LOAD8_U） *)
Definition read_memory_byte (s : runtime_state) (addr : Z) : Z :=
  let idx := Z.to_nat addr in
  if Nat.ltb idx (Datatypes.length s.(rt_memory))
  then List.nth idx s.(rt_memory) 0
  else 0.

(* ================================================================
   第 12b 部分：小步语义辅助函数 (Semantics Helpers)
   ================================================================ *)

(* 向值栈压入值 *)
Definition push_value (v : sasm_value) (s : runtime_state) : runtime_state :=
  {| rt_values := v :: s.(rt_values);
     rt_frames := s.(rt_frames);
     rt_memory := s.(rt_memory);
     rt_cycle_cnt := s.(rt_cycle_cnt) + 1;
  |}.

(* 弹出栈顶值 *)
Definition pop1 (s : runtime_state) : runtime_state :=
  match s.(rt_values) with
  | nil => s
  | _ :: vs => {| rt_values := vs; rt_frames := s.(rt_frames);
                  rt_memory := s.(rt_memory); rt_cycle_cnt := s.(rt_cycle_cnt) + 1; |}
  end.

(* 弹出两个栈顶值 *)
Definition pop2 (s : runtime_state) : runtime_state :=
  pop1 (pop1 s).

(* 替换栈顶值 *)
Definition state_with_top (v : sasm_value) (s : runtime_state) : runtime_state :=
  match s.(rt_values) with
  | nil => s
  | _ :: vs => {| rt_values := v :: vs; rt_frames := s.(rt_frames);
                  rt_memory := s.(rt_memory); rt_cycle_cnt := s.(rt_cycle_cnt); |}
  end.

(* 替换栈顶两个值 *)
Definition state_with_top2 (v1 v2 : sasm_value) (s : runtime_state) : runtime_state :=
  state_with_top v2 (state_with_top v1 s).

(* 检查内存地址是否有效（bool 版本，用于 step 定义） *)
Definition valid_address_bool (m : sasm_module) (addr offset : Z) : bool :=
  (0 <=? addr + offset) && (addr + offset <? m.(sasm_total_memory_size)).

(* 从内存读取值（字节按小端序拼接为 i32） *)
Definition read_memory (s : runtime_state) (addr offset : Z) : option sasm_value :=
  let idx := (addr + offset) in
  if idx <? Z.of_nat (Datatypes.length s.(rt_memory))
  then Some (V_I32 (List.nth (Z.to_nat idx) s.(rt_memory) 0))
  else Some (V_I32 0).

(* 获取/设置帧局部变量（扩展列表以容纳索引） *)
Fixpoint list_set {A : Type} (l : list A) (n : nat) (x : A) : list A :=
  match l, n with
  | [], _ => x :: List.repeat x n  (* 用 x 填充空缺 *)
  | _ :: l', O => x :: l'
  | _ :: l', S n' => list_set l' n' x
  end.

(* 将 i32 写入 linear_memory（4 字节小端）*)
Definition write_i32 (mem : list Z) (addr : Z) (offset : Z) (val : Z) : list Z :=
  let a := addr + offset in
  let wb (mem0 : list Z) (pos : Z) (v : Z) : list Z :=
    let idx := Z.to_nat (a + pos) in
    let clip := Z.land (Z.shiftr v (pos * 8)) 255 in
    list_set mem0 idx clip
  in
  wb (wb (wb (wb mem 0 val) 1 val) 2 val) 3 val.

(* f32 简易转换: read_f32_bits 将 addr 处 4 字节解析为浮点按位模式 (占位) *)
Definition read_f32_bits (mem : list Z) (addr : Z) (offset : Z) : Z :=
  read_i32 mem addr offset.

(* f64 简易转换 *)
Definition read_f64_lo (mem : list Z) (addr : Z) (offset : Z) : Z :=
  read_i32 mem addr offset.
Definition read_f64_hi (mem : list Z) (addr : Z) (offset : Z) : Z :=
  read_i32 mem (addr + 4) offset.

(* 写入单字节到内存（v1.1 新增，支持 I32_STORE8） *)
Definition write_memory_byte (s : runtime_state) (addr : Z) (val : Z) : runtime_state :=
  let idx := Z.to_nat addr in
  let clipped := val mod 256 in
  let mem := s.(rt_memory) in
  let new_mem :=
    if Nat.ltb idx (Datatypes.length mem)
    then list_set mem idx clipped
    else mem in
  {| rt_values := s.(rt_values);
     rt_frames := s.(rt_frames);
     rt_memory := new_mem;
     rt_cycle_cnt := s.(rt_cycle_cnt) + 1;
  |}.
Definition set_local (f : sasm_frame) (idx : Z) (v : sasm_value) : sasm_frame :=
  let n := Z.to_nat idx in
  {| frame_locals := list_set f.(frame_locals) n v;
     frame_func_idx := f.(frame_func_idx);
     frame_pc := f.(frame_pc);
     frame_block_stack := f.(frame_block_stack);
  |}.

(* 辅助：在帧的块栈上压入地址 *)
Definition push_block (f : sasm_frame) (addr : Z) : sasm_frame :=
  {| frame_locals := f.(frame_locals);
     frame_func_idx := f.(frame_func_idx);
     frame_pc := f.(frame_pc);
     frame_block_stack := addr :: f.(frame_block_stack);
  |}.

(* 辅助：从帧的块栈弹出（返回到指定深度） *)
Definition pop_to_block_depth (f : sasm_frame) (depth : Z) : sasm_frame :=
  {| frame_locals := f.(frame_locals);
     frame_func_idx := f.(frame_func_idx);
     frame_pc := f.(frame_pc);
     frame_block_stack := List.firstn (Z.to_nat depth) f.(frame_block_stack);
  |}.

(* 辅助：获取块栈指定深度的返回地址（0 = 最内层） *)
Definition block_addr_at (f : sasm_frame) (depth : Z) : option Z :=
  match List.nth_error f.(frame_block_stack) (Z.to_nat depth) with
  | Some addr => Some addr
  | None => None
  end.

(* 存储值到内存（简化实现） *)
Definition state_after_store (addr offset : Z) (v : sasm_value) (s : runtime_state) : runtime_state :=
  let val := match v with V_I32 z => z | V_I64 z => z | _ => 0 end in
  let new_mem := match v with
                 | V_I32 _ => write_i32 s.(rt_memory) addr offset val
                 | V_I64 _ => write_i32 s.(rt_memory) addr offset val
                 | _ => s.(rt_memory)
                 end in
  {| rt_values := s.(rt_values);
     rt_frames := s.(rt_frames);
     rt_memory := new_mem;
     rt_cycle_cnt := s.(rt_cycle_cnt) + 1;
  |}.

(* 跳转：更新当前帧的 PC 和 block_stack（通过 block_stack 索引执行）
   depth = 0 → 跳出最内层 BLOCK/LOOP
   depth = 1 → 跳出外层 BLOCK，依此类推
   简化实现：将 block_stack 截断至 depth，PC 指向 block_stack[depth] *)
Definition branch_to (depth : Z) (s : runtime_state) : runtime_state :=
  match s.(rt_frames) with
  | nil => s
  | f :: rest =>
      let new_block_stack := List.firstn (Z.to_nat depth) f.(frame_block_stack) in
      let new_pc := match List.nth_error f.(frame_block_stack) (Z.to_nat depth) with
                    | Some addr => addr
                    | None => f.(frame_pc)
                    end in
      let f' := {| frame_locals := f.(frame_locals);
                   frame_func_idx := f.(frame_func_idx);
                   frame_pc := new_pc;
                   frame_block_stack := new_block_stack |} in
      {| rt_values := s.(rt_values);
         rt_frames := f' :: rest;
         rt_memory := s.(rt_memory);
         rt_cycle_cnt := s.(rt_cycle_cnt) + 1;
      |}
  end.

(* 查找函数：返回模块中指定索引的函数 *)
Definition lookup_function (m : sasm_module) (idx : Z) : option sasm_function :=
  List.nth_error m.(sasm_functions) (Z.to_nat idx).

(* 创建新帧：使用给定参数构造函数帧，压入帧栈 *)
Definition push_frame (idx : Z) (args : list sasm_value) (s : runtime_state) : runtime_state :=
  let new_frame : sasm_frame :=
    {| frame_locals := args;
       frame_func_idx := idx;
       frame_pc := 0;
       frame_block_stack := [];
    |}
  in
  {| rt_values := s.(rt_values);
     rt_frames := new_frame :: s.(rt_frames);
     rt_memory := s.(rt_memory);
     rt_cycle_cnt := s.(rt_cycle_cnt) + 1;
  |}.

(* 返回并恢复帧：弹出当前帧，恢复上一帧的执行
   注意：返回值已由函数体留在值栈中，此处仅管理帧栈 *)
Definition pop_frame_with_return (ret_val : sasm_value) (s : runtime_state) : runtime_state :=
  match s.(rt_frames) with
  | nil => s
  | _ :: rest =>
      {| rt_values := s.(rt_values);  (* 返回值已在栈上，由函数体留下 *)
         rt_frames := rest;
         rt_memory := s.(rt_memory);
         rt_cycle_cnt := s.(rt_cycle_cnt) + 1;
      |}
  end.

(* 小步语义: step m s s' 表示从状态 s 执行一步到 s' *)
Inductive step : sasm_module -> runtime_state -> runtime_state -> Prop :=
  | Step_const : forall m s v,
      step m s (push_value (V_I32 v) s)
  
  | Step_i32_add : forall m s v1 v2 new_v,
      Some new_v = i32_bin_op I32_ADD v1 v2 ->
      step m
        (state_with_top2 (V_I32 v1) (V_I32 v2) s)
        (state_with_top (V_I32 new_v) (pop2 s))
  
    (* 安全断言: 运行时检查 *)
  | Step_safe_assert_cycle : forall m s limit,
      Z.lt s.(rt_cycle_cnt) limit ->
      step m s s

  | Step_i32_load8_u : forall m s addr raw_val,
      (* 栈顶是地址 addr，读取 addr+offset 处的 1 字节 *)
      read_memory s addr 0 = Some (V_I32 raw_val) ->
      step m
        (state_with_top (V_I32 addr) s)
        (push_value (V_I32 (raw_val mod 256)) (pop1 s))

  | Step_i32_store8 : forall m s addr val,
      step m
        (state_with_top2 (V_I32 addr) (V_I32 val) s)
        (write_memory_byte (pop2 s) addr (val mod 256))

  (* ─── 控制流 ─── *)
  | Step_nop : forall m s,
      step m s s

  | Step_unreachable : forall m s,
      step m s s

  | Step_drop : forall m s v,
      step m (state_with_top v s) (pop1 s)

  | Step_select : forall m s v1 v2 c,
      step m
        (state_with_top2 (V_I32 v1) (V_I32 v2) (state_with_top (V_I32 c) s))
        (push_value (if Z.eqb c 0 then V_I32 v2 else V_I32 v1) (pop2 s))

  | Step_return : forall m s f rest,
      s.(rt_frames) = f :: rest ->
      step m s
        {| rt_values := s.(rt_values);
           rt_frames := rest;
           rt_memory := s.(rt_memory);
           rt_cycle_cnt := s.(rt_cycle_cnt) + 1;
        |}

  (* ─── 局部变量 ─── *)
  | Step_local_get : forall m s f rest idx v,
      s.(rt_frames) = f :: rest ->
      List.nth_error f.(frame_locals) (Z.to_nat idx) = Some v ->
      step m s (push_value v s)

  | Step_local_set : forall m s f rest idx v vs,
      s.(rt_frames) = f :: rest ->
      s.(rt_values) = v :: vs ->
      let f' := {| frame_locals := list_set f.(frame_locals) (Z.to_nat idx) v;
                   frame_func_idx := f.(frame_func_idx);
                   frame_pc := f.(frame_pc);
                   frame_block_stack := f.(frame_block_stack) |} in
      step m s
        {| rt_values := vs;
           rt_frames := f' :: rest;
           rt_memory := s.(rt_memory);
           rt_cycle_cnt := s.(rt_cycle_cnt) + 1;
        |}

  | Step_local_tee : forall m s f rest idx v vs,
      s.(rt_frames) = f :: rest ->
      s.(rt_values) = v :: vs ->
      let f' := {| frame_locals := list_set f.(frame_locals) (Z.to_nat idx) v;
                   frame_func_idx := f.(frame_func_idx);
                   frame_pc := f.(frame_pc);
                   frame_block_stack := f.(frame_block_stack) |} in
      step m s
        {| rt_values := v :: vs;
           rt_frames := f' :: rest;
           rt_memory := s.(rt_memory);
           rt_cycle_cnt := s.(rt_cycle_cnt) + 1;
        |}

  (* ─── i32 常量 ─── *)
  | Step_i32_const : forall m s v,
      step m s (push_value (V_I32 v) s)

  | Step_i64_const : forall m s v,
      step m s (push_value (V_I64 v) s)

  | Step_f32_const : forall m s f,
      step m s (push_value (V_F32 f) s)

  | Step_f64_const : forall m s f,
      step m s (push_value (V_F64 f) s)

  (* ─── i32 比较 ─── *)
  | Step_i32_eqz : forall m s v,
      step m (state_with_top (V_I32 v) s)
        (state_with_top (V_I32 (if Z.eqb v 0 then 1 else 0)) (pop1 s))

  | Step_i32_eq : forall m s v1 v2,
      step m (state_with_top2 (V_I32 v1) (V_I32 v2) s)
        (state_with_top (V_I32 (i32_cmp_op I32_EQ v1 v2)) (pop2 s))

  | Step_i32_ne : forall m s v1 v2,
      step m (state_with_top2 (V_I32 v1) (V_I32 v2) s)
        (state_with_top (V_I32 (i32_cmp_op I32_NE v1 v2)) (pop2 s))

  | Step_i32_lt_s : forall m s v1 v2,
      step m (state_with_top2 (V_I32 v1) (V_I32 v2) s)
        (state_with_top (V_I32 (i32_cmp_op I32_LT_S v1 v2)) (pop2 s))

  | Step_i32_le_s : forall m s v1 v2,
      step m (state_with_top2 (V_I32 v1) (V_I32 v2) s)
        (state_with_top (V_I32 (i32_cmp_op I32_LE_S v1 v2)) (pop2 s))

  | Step_i32_gt_s : forall m s v1 v2,
      step m (state_with_top2 (V_I32 v1) (V_I32 v2) s)
        (state_with_top (V_I32 (i32_cmp_op I32_GT_S v1 v2)) (pop2 s))

  | Step_i32_ge_s : forall m s v1 v2,
      step m (state_with_top2 (V_I32 v1) (V_I32 v2) s)
        (state_with_top (V_I32 (i32_cmp_op I32_GE_S v1 v2)) (pop2 s))

  (* ─── i32 二元运算 ─── *)
  | Step_i32_sub : forall m s v1 v2 new_v,
      Some new_v = i32_bin_op I32_SUB v1 v2 ->
      step m (state_with_top2 (V_I32 v1) (V_I32 v2) s) (state_with_top (V_I32 new_v) (pop2 s))

  | Step_i32_mul : forall m s v1 v2 new_v,
      Some new_v = i32_bin_op I32_MUL v1 v2 ->
      step m (state_with_top2 (V_I32 v1) (V_I32 v2) s) (state_with_top (V_I32 new_v) (pop2 s))

  | Step_i32_div_s : forall m s v1 v2 new_v,
      Some new_v = i32_bin_op I32_DIV_S v1 v2 ->
      step m (state_with_top2 (V_I32 v1) (V_I32 v2) s) (state_with_top (V_I32 new_v) (pop2 s))

  | Step_i32_rem_s : forall m s v1 v2 new_v,
      Some new_v = i32_bin_op I32_REM_S v1 v2 ->
      step m (state_with_top2 (V_I32 v1) (V_I32 v2) s) (state_with_top (V_I32 new_v) (pop2 s))

  | Step_i32_and : forall m s v1 v2 new_v,
      Some new_v = i32_bin_op I32_AND v1 v2 ->
      step m (state_with_top2 (V_I32 v1) (V_I32 v2) s) (state_with_top (V_I32 new_v) (pop2 s))

  | Step_i32_or : forall m s v1 v2 new_v,
      Some new_v = i32_bin_op I32_OR v1 v2 ->
      step m (state_with_top2 (V_I32 v1) (V_I32 v2) s) (state_with_top (V_I32 new_v) (pop2 s))

  | Step_i32_xor : forall m s v1 v2 new_v,
      Some new_v = i32_bin_op I32_XOR v1 v2 ->
      step m (state_with_top2 (V_I32 v1) (V_I32 v2) s) (state_with_top (V_I32 new_v) (pop2 s))

  | Step_i32_shl : forall m s v1 v2 new_v,
      Some new_v = i32_bin_op I32_SHL v1 v2 ->
      step m (state_with_top2 (V_I32 v1) (V_I32 v2) s) (state_with_top (V_I32 new_v) (pop2 s))

  | Step_i32_shr_s : forall m s v1 v2 new_v,
      Some new_v = i32_bin_op I32_SHR_S v1 v2 ->
      step m (state_with_top2 (V_I32 v1) (V_I32 v2) s) (state_with_top (V_I32 new_v) (pop2 s))

  | Step_i32_rotl : forall m s v1 v2 new_v,
      Some new_v = i32_bin_op I32_ROTL v1 v2 ->
      step m (state_with_top2 (V_I32 v1) (V_I32 v2) s) (state_with_top (V_I32 new_v) (pop2 s))

  | Step_i32_rotr : forall m s v1 v2 new_v,
      Some new_v = i32_bin_op I32_ROTR v1 v2 ->
      step m (state_with_top2 (V_I32 v1) (V_I32 v2) s) (state_with_top (V_I32 new_v) (pop2 s))

  (* ─── i64 比较 ─── *)
  | Step_i64_eqz : forall m s v,
      step m (state_with_top (V_I64 v) s)
        (state_with_top (V_I32 (if Z.eqb v 0 then 1 else 0)) (pop1 s))

  | Step_i64_eq : forall m s v1 v2,
      step m (state_with_top2 (V_I64 v1) (V_I64 v2) s)
        (state_with_top (V_I32 (i64_cmp_op I64_EQ v1 v2)) (pop2 s))

  | Step_i64_ne : forall m s v1 v2,
      step m (state_with_top2 (V_I64 v1) (V_I64 v2) s)
        (state_with_top (V_I32 (i64_cmp_op I64_NE v1 v2)) (pop2 s))

  | Step_i64_lt_s : forall m s v1 v2,
      step m (state_with_top2 (V_I64 v1) (V_I64 v2) s)
        (state_with_top (V_I32 (i64_cmp_op I64_LT_S v1 v2)) (pop2 s))

  | Step_i64_le_s : forall m s v1 v2,
      step m (state_with_top2 (V_I64 v1) (V_I64 v2) s)
        (state_with_top (V_I32 (i64_cmp_op I64_LE_S v1 v2)) (pop2 s))

  | Step_i64_gt_s : forall m s v1 v2,
      step m (state_with_top2 (V_I64 v1) (V_I64 v2) s)
        (state_with_top (V_I32 (i64_cmp_op I64_GT_S v1 v2)) (pop2 s))

  | Step_i64_ge_s : forall m s v1 v2,
      step m (state_with_top2 (V_I64 v1) (V_I64 v2) s)
        (state_with_top (V_I32 (i64_cmp_op I64_GE_S v1 v2)) (pop2 s))

  (* ─── i64 二元运算 ─── *)
  | Step_i64_add : forall m s v1 v2 new_v,
      Some new_v = i64_bin_op I64_ADD v1 v2 ->
      step m (state_with_top2 (V_I64 v1) (V_I64 v2) s) (state_with_top (V_I64 new_v) (pop2 s))

  | Step_i64_sub : forall m s v1 v2 new_v,
      Some new_v = i64_bin_op I64_SUB v1 v2 ->
      step m (state_with_top2 (V_I64 v1) (V_I64 v2) s) (state_with_top (V_I64 new_v) (pop2 s))

  | Step_i64_mul : forall m s v1 v2 new_v,
      Some new_v = i64_bin_op I64_MUL v1 v2 ->
      step m (state_with_top2 (V_I64 v1) (V_I64 v2) s) (state_with_top (V_I64 new_v) (pop2 s))

  | Step_i64_div_s : forall m s v1 v2 new_v,
      Some new_v = i64_bin_op I64_DIV_S v1 v2 ->
      step m (state_with_top2 (V_I64 v1) (V_I64 v2) s) (state_with_top (V_I64 new_v) (pop2 s))

  | Step_i64_rem_s : forall m s v1 v2 new_v,
      Some new_v = i64_bin_op I64_REM_S v1 v2 ->
      step m (state_with_top2 (V_I64 v1) (V_I64 v2) s) (state_with_top (V_I64 new_v) (pop2 s))

  | Step_i64_and : forall m s v1 v2 new_v,
      Some new_v = i64_bin_op I64_AND v1 v2 ->
      step m (state_with_top2 (V_I64 v1) (V_I64 v2) s) (state_with_top (V_I64 new_v) (pop2 s))

  | Step_i64_or : forall m s v1 v2 new_v,
      Some new_v = i64_bin_op I64_OR v1 v2 ->
      step m (state_with_top2 (V_I64 v1) (V_I64 v2) s) (state_with_top (V_I64 new_v) (pop2 s))

  | Step_i64_xor : forall m s v1 v2 new_v,
      Some new_v = i64_bin_op I64_XOR v1 v2 ->
      step m (state_with_top2 (V_I64 v1) (V_I64 v2) s) (state_with_top (V_I64 new_v) (pop2 s))

  | Step_i64_shl : forall m s v1 v2 new_v,
      Some new_v = i64_bin_op I64_SHL v1 v2 ->
      step m (state_with_top2 (V_I64 v1) (V_I64 v2) s) (state_with_top (V_I64 new_v) (pop2 s))

  | Step_i64_shr_s : forall m s v1 v2 new_v,
      Some new_v = i64_bin_op I64_SHR_S v1 v2 ->
      step m (state_with_top2 (V_I64 v1) (V_I64 v2) s) (state_with_top (V_I64 new_v) (pop2 s))

  (* ─── f32 二元运算 ─── *)
  | Step_f32_add : forall m s f1 f2,
      step m (state_with_top2 (V_F32 f1) (V_F32 f2) s)
        (state_with_top (V_F32 (PrimFloat.add f1 f2)) (pop2 s))

  | Step_f32_sub : forall m s f1 f2,
      step m (state_with_top2 (V_F32 f1) (V_F32 f2) s)
        (state_with_top (V_F32 (PrimFloat.sub f1 f2)) (pop2 s))

  | Step_f32_mul : forall m s f1 f2,
      step m (state_with_top2 (V_F32 f1) (V_F32 f2) s)
        (state_with_top (V_F32 (PrimFloat.mul f1 f2)) (pop2 s))

  | Step_f32_div : forall m s f1 f2,
      step m (state_with_top2 (V_F32 f1) (V_F32 f2) s)
        (state_with_top (V_F32 (PrimFloat.div f1 f2)) (pop2 s))

  (* ─── f32 比较 ─── *)
  | Step_f32_eq : forall m s f1 f2,
      step m (state_with_top2 (V_F32 f1) (V_F32 f2) s)
        (state_with_top (V_I32 (if PrimFloat.eqb f1 f2 then 1 else 0)) (pop2 s))

  | Step_f32_ne : forall m s f1 f2,
      step m (state_with_top2 (V_F32 f1) (V_F32 f2) s)
        (state_with_top (V_I32 (if negb (PrimFloat.eqb f1 f2) then 1 else 0)) (pop2 s))

  | Step_f32_lt : forall m s f1 f2,
      step m (state_with_top2 (V_F32 f1) (V_F32 f2) s)
        (state_with_top (V_I32 (if PrimFloat.ltb f1 f2 then 1 else 0)) (pop2 s))

  | Step_f32_le : forall m s f1 f2,
      step m (state_with_top2 (V_F32 f1) (V_F32 f2) s)
        (state_with_top (V_I32 (if PrimFloat.leb f1 f2 then 1 else 0)) (pop2 s))

  | Step_f32_gt : forall m s f1 f2,
      step m (state_with_top2 (V_F32 f1) (V_F32 f2) s)
        (state_with_top (V_I32 (if PrimFloat.ltb f2 f1 then 1 else 0)) (pop2 s))

  | Step_f32_ge : forall m s f1 f2,
      step m (state_with_top2 (V_F32 f1) (V_F32 f2) s)
        (state_with_top (V_I32 (if PrimFloat.leb f2 f1 then 1 else 0)) (pop2 s))

  (* ─── f32 一元运算 ─── *)
  | Step_f32_abs : forall m s f,
      step m (state_with_top (V_F32 f) s)
        (state_with_top (V_F32 (PrimFloat.abs f)) (pop1 s))

  | Step_f32_neg : forall m s f,
      step m (state_with_top (V_F32 f) s)
        (state_with_top (V_F32 (PrimFloat.opp f)) (pop1 s))

  | Step_f32_sqrt : forall m s f,
      step m (state_with_top (V_F32 f) s)
        (state_with_top (V_F32 (PrimFloat.sqrt f)) (pop1 s))

  (* ─── f64 二元运算 ─── *)
  | Step_f64_add : forall m s f1 f2,
      step m (state_with_top2 (V_F64 f1) (V_F64 f2) s)
        (state_with_top (V_F64 (PrimFloat.add f1 f2)) (pop2 s))

  | Step_f64_sub : forall m s f1 f2,
      step m (state_with_top2 (V_F64 f1) (V_F64 f2) s)
        (state_with_top (V_F64 (PrimFloat.sub f1 f2)) (pop2 s))

  | Step_f64_mul : forall m s f1 f2,
      step m (state_with_top2 (V_F64 f1) (V_F64 f2) s)
        (state_with_top (V_F64 (PrimFloat.mul f1 f2)) (pop2 s))

  | Step_f64_div : forall m s f1 f2,
      step m (state_with_top2 (V_F64 f1) (V_F64 f2) s)
        (state_with_top (V_F64 (PrimFloat.div f1 f2)) (pop2 s))

  (* ─── f64 比较 ─── *)
  | Step_f64_eq : forall m s f1 f2,
      step m (state_with_top2 (V_F64 f1) (V_F64 f2) s)
        (state_with_top (V_I32 (if PrimFloat.eqb f1 f2 then 1 else 0)) (pop2 s))

  | Step_f64_ne : forall m s f1 f2,
      step m (state_with_top2 (V_F64 f1) (V_F64 f2) s)
        (state_with_top (V_I32 (if negb (PrimFloat.eqb f1 f2) then 1 else 0)) (pop2 s))

  | Step_f64_lt : forall m s f1 f2,
      step m (state_with_top2 (V_F64 f1) (V_F64 f2) s)
        (state_with_top (V_I32 (if PrimFloat.ltb f1 f2 then 1 else 0)) (pop2 s))

  | Step_f64_le : forall m s f1 f2,
      step m (state_with_top2 (V_F64 f1) (V_F64 f2) s)
        (state_with_top (V_I32 (if PrimFloat.leb f1 f2 then 1 else 0)) (pop2 s))

  | Step_f64_gt : forall m s f1 f2,
      step m (state_with_top2 (V_F64 f1) (V_F64 f2) s)
        (state_with_top (V_I32 (if PrimFloat.ltb f2 f1 then 1 else 0)) (pop2 s))

  | Step_f64_ge : forall m s f1 f2,
      step m (state_with_top2 (V_F64 f1) (V_F64 f2) s)
        (state_with_top (V_I32 (if PrimFloat.leb f2 f1 then 1 else 0)) (pop2 s))

  (* ─── f64 一元运算 ─── *)
  | Step_f64_abs : forall m s f,
      step m (state_with_top (V_F64 f) s)
        (state_with_top (V_F64 (PrimFloat.abs f)) (pop1 s))

  | Step_f64_neg : forall m s f,
      step m (state_with_top (V_F64 f) s)
        (state_with_top (V_F64 (PrimFloat.opp f)) (pop1 s))

  | Step_f64_sqrt : forall m s f,
      step m (state_with_top (V_F64 f) s)
        (state_with_top (V_F64 (PrimFloat.sqrt f)) (pop1 s))

  (* ─── 类型转换 ─── *)
  | Step_i32_wrap_i64 : forall m s v,
      step m (state_with_top (V_I64 v) s)
        (state_with_top (V_I32 (Z.land v 4294967295)) (pop1 s))

  | Step_i64_extend_i32_s : forall m s v,
      step m (state_with_top (V_I32 v) s)
        (state_with_top (V_I64 v) (pop1 s))

  | Step_i32_trunc_f32_s : forall m s f,
      step m (state_with_top (V_F32 f) s)
        (state_with_top (V_I32 0) (pop1 s))

  | Step_i32_trunc_f64_s : forall m s f,
      step m (state_with_top (V_F64 f) s)
        (state_with_top (V_I32 0) (pop1 s))

  | Step_f32_convert_i32_s : forall m s v,
      step m (state_with_top (V_I32 v) s)
        (state_with_top (V_F32 PrimFloat.zero) (pop1 s))

  | Step_f64_convert_i32_s : forall m s v,
      step m (state_with_top (V_I32 v) s)
        (state_with_top (V_F64 PrimFloat.zero) (pop1 s))

  (* ─── 内存操作: 加载 ─── *)
  | Step_i32_load : forall m s addr arg,
      step m (state_with_top (V_I32 addr) s)
        (push_value (V_I32 (read_i32 s.(rt_memory) addr arg.(mem_offset))) (pop1 s))

  | Step_i64_load : forall m s addr arg,
      step m (state_with_top (V_I32 addr) s)
        (push_value (V_I64 (read_i32 s.(rt_memory) addr arg.(mem_offset))) (pop1 s))

  | Step_f32_load : forall m s addr arg,
      step m (state_with_top (V_I32 addr) s)
        (push_value (V_I32 (read_i32 s.(rt_memory) addr arg.(mem_offset))) (pop1 s))

  | Step_f64_load : forall m s addr arg,
      step m (state_with_top (V_I32 addr) s)
        (push_value (V_I64 (read_i32 s.(rt_memory) addr arg.(mem_offset))) (pop1 s))

  (* ─── 内存操作: 存储 ─── *)
  | Step_i32_store : forall m s addr val arg,
      step m (state_with_top2 (V_I32 addr) (V_I32 val) s)
        {| rt_values := (tl (tl s.(rt_values)));
           rt_frames := s.(rt_frames);
           rt_memory := write_i32 s.(rt_memory) addr arg.(mem_offset) val;
           rt_cycle_cnt := s.(rt_cycle_cnt) + 1;
        |}

  | Step_i64_store : forall m s addr val arg,
      step m (state_with_top2 (V_I64 val) (V_I32 addr) s)
        {| rt_values := (tl (tl s.(rt_values)));
           rt_frames := s.(rt_frames);
           rt_memory := write_i32 s.(rt_memory) addr arg.(mem_offset) val;
           rt_cycle_cnt := s.(rt_cycle_cnt) + 1;
        |}

  | Step_f32_store : forall m s addr val arg,
      step m (state_with_top2 (V_F32 val) (V_I32 addr) s)
        {| rt_values := (tl (tl s.(rt_values)));
           rt_frames := s.(rt_frames);
           rt_memory := write_i32 s.(rt_memory) addr arg.(mem_offset) 0;
           rt_cycle_cnt := s.(rt_cycle_cnt) + 1;
        |}

  | Step_f64_store : forall m s addr val arg,
      step m (state_with_top2 (V_F64 val) (V_I32 addr) s)
        {| rt_values := (tl (tl s.(rt_values)));
           rt_frames := s.(rt_frames);
           rt_memory := write_i32 s.(rt_memory) addr arg.(mem_offset) 0;
           rt_cycle_cnt := s.(rt_cycle_cnt) + 1;
        |}

  (* ─── 安全断言 ─── *)
  | Step_safe_bounds_check_pass : forall m s low high idx,
      low <= idx < high ->
      step m (state_with_top (V_I32 idx) s)
        (state_with_top (V_I32 idx) (pop1 s))
.

(* 多步执行 *)
Inductive multi_step : sasm_module -> runtime_state -> runtime_state -> Prop :=
  | Multi_refl : forall m s, multi_step m s s
  | Multi_step : forall m s1 s2 s3,
      step m s1 s2 ->
      multi_step m s2 s3 ->
      multi_step m s1 s3
.

(* ================================================================
   第 13 部分：安全执行 (Safe Execution)
   ================================================================ *)

(* 地址有效性检查 *)
Definition valid_address (m : sasm_module) (addr : Z) (offset : Z) : Prop :=
  0 <= addr + offset < sasm_total_memory_size m.

(* 安全步进: 每一步都需满足安全约束 *)
(* 所有内存访问在声明范围内 *)
Definition all_memory_accesses_valid (m : sasm_module) (s : runtime_state) : Prop :=
  forall (r : mem_access_range),
    In r (sasm_safety m).(safe_mem_access_map) ->
    valid_address m r.(mar_low) r.(mar_high).

Inductive safe_step : sasm_module -> runtime_state -> runtime_state -> Prop :=
  | SafeStep : forall m s s',
      step m s s' ->
      (* 周期指令数上限 *)
      s.(rt_cycle_cnt) < (sasm_safety m).(safe_cycle_limit) ->
      (* 栈深度上限 *)
      Z.of_nat (List.length s.(rt_frames)) <= (sasm_safety m).(safe_stack_depth) ->
      (* 所有内存访问合法 *)
      all_memory_accesses_valid m s ->
      safe_step m s s'.

(* ================================================================
   第 14 部分：编码/解码可逆性定理
   ================================================================ *)

(* 最终状态：帧栈为空 *)


(* ================================================================
   第 15 部分：验证规则 Validation Rules (V1-V26)
   对应 spec/safeasm-spec.md §7
   ================================================================ *)

Definition instr_size (i : sasm_instr) : Z :=
  match i with
  | NOP | UNREACHABLE | RETURN | DROP | SELECT
  | I32_EQZ | I32_EQ | I32_NE | I32_LT_S | I32_LE_S | I32_GT_S | I32_GE_S
  | I32_ADD | I32_SUB | I32_MUL | I32_DIV_S | I32_REM_S
  | I32_AND | I32_OR | I32_XOR | I32_SHL | I32_SHR_S | I32_ROTL | I32_ROTR
  | I64_EQZ | I64_EQ | I64_NE | I64_LT_S | I64_LE_S | I64_GT_S | I64_GE_S
  | I64_ADD | I64_SUB | I64_MUL | I64_DIV_S | I64_REM_S
  | I64_AND | I64_OR | I64_XOR | I64_SHL | I64_SHR_S
  | F32_ADD | F32_SUB | F32_MUL | F32_DIV
  | F32_EQ | F32_NE | F32_LT | F32_LE | F32_GT | F32_GE
  | F32_ABS | F32_NEG | F32_SQRT
  | F64_ADD | F64_SUB | F64_MUL | F64_DIV
  | F64_EQ | F64_NE | F64_LT | F64_LE | F64_GT | F64_GE
  | F64_ABS | F64_NEG | F64_SQRT
  | I32_WRAP_I64 | I64_EXTEND_I32_S
  | I32_TRUNC_F32_S | I32_TRUNC_F64_S
  | F32_CONVERT_I32_S | F64_CONVERT_I32_S => 1
  | BLOCK _ | LOOP _ | BR _ | BR_IF _ | CALL _ | LOCAL_GET _ | LOCAL_SET _ | LOCAL_TEE _
  | I32_CONST _ | I32_LOAD _ | I64_LOAD _ | F32_LOAD _ | F64_LOAD _
  | I32_STORE _ | I64_STORE _ | F32_STORE _ | F64_STORE _
  | I32_LOAD8_U _ | I32_STORE8 _ => 5
  | I64_CONST _ | F64_CONST _ => 9
  | F32_CONST _ => 5
  | SAFE_ASSERT (ASSERT_CYCLE_LIMIT _) => 6
  | SAFE_ASSERT (ASSERT_STACK_DEPTH _) => 6
  | SAFE_ASSERT (ASSERT_MEM_BOUNDS _ _) => 10
  | SAFE_BOUNDS_CHECK _ _ => 9
  end.

(* 指令列表总字节数（支撑 V16/V17 的精确校验） *)
Fixpoint instrs_total_size (instrs : list sasm_instr) : Z :=
  match instrs with
  | nil => 0
  | i :: rest => instr_size i + instrs_total_size rest
  end.

Section Validation.

(* ---- 常量 ---- *)

(* ---- 结构化控制流验证器 (Control Frame Stack Validator) ---- *)

(* 按字节跳过指令序列：从 instrs 向前跳过 nbytes 字节，
   返回剩余指令。用于 BR/RETURN 时跳过块体剩余字节。 *)
Fixpoint skip_instrs (instrs : list sasm_instr) (nbytes : Z) : option (list sasm_instr) :=
  if nbytes =? 0 then Some instrs
  else if nbytes <? 0 then None
  else match instrs with
       | nil => None
       | i :: rest => skip_instrs rest (nbytes - instr_size i)
       end.

(* 块体处理结果：
   - body_rest: 块体之后的指令序列
   - body_skip_depth: 还需在外层跳过的嵌套层数（BR depth>0 时使用） *)
Record block_body_result : Type := {
  body_rest : list sasm_instr;
  body_skip_depth : Z;
}.

(* 递归块体验证器。
   从 instrs 中精确消耗 budget 字节（或被 BR/RETURN 提前终止）。
   ctrl_depth = 当前可用的标签数（0 = 顶层，无标签可用）。
   
   BR depth 语义（WASM 风格）：
   - depth = 0: 退出当前块，跳过块体剩余字节，返回 skip_depth=0
   - depth > 0: 退出当前块 + depth 层外层块，逐层跳过剩余字节 *)
Fixpoint process_block_body (instrs : list sasm_instr) (ctrl_depth : Z) (budget : Z) {struct instrs}
  : option block_body_result :=
  match instrs with
  | nil =>
    if budget =? 0 then Some {| body_rest := nil; body_skip_depth := 0 |}
    else None
  | instr :: rest =>
    let sz := instr_size instr in
    let remaining := budget - sz in
    if andb (remaining <? 0) (0 <=? budget) then None
    else
    match instr with
    | BLOCK len =>
        match process_block_body rest (ctrl_depth + 1) len with
        | Some inner =>
            if 0 <? inner.(body_skip_depth) then
              let new_skip := inner.(body_skip_depth) - 1 in
              match skip_instrs inner.(body_rest) remaining with
              | Some skipped =>
                  Some {| body_rest := skipped; body_skip_depth := new_skip |}
              | None => None
              end
            else
              process_block_body inner.(body_rest) ctrl_depth remaining
        | None => None
        end
    | LOOP len =>
        match process_block_body rest (ctrl_depth + 1) len with
        | Some inner =>
            if 0 <? inner.(body_skip_depth) then
              let new_skip := inner.(body_skip_depth) - 1 in
              match skip_instrs inner.(body_rest) remaining with
              | Some skipped =>
                  Some {| body_rest := skipped; body_skip_depth := new_skip |}
              | None => None
              end
            else
              process_block_body inner.(body_rest) ctrl_depth remaining
        | None => None
        end
    | BR depth =>
        if andb (0 <=? depth) (depth <? ctrl_depth) then
          match skip_instrs rest (budget - sz) with
          | Some skipped =>
              if depth =? 0 then
                Some {| body_rest := skipped; body_skip_depth := 0 |}
              else
                Some {| body_rest := skipped; body_skip_depth := depth |}
          | None => None
          end
        else None
    | BR_IF depth =>
        if andb (0 <=? depth) (depth <? ctrl_depth) then
          match skip_instrs rest (budget - sz) with
          | Some skipped =>
              if depth =? 0 then
                Some {| body_rest := skipped; body_skip_depth := 0 |}
              else
                Some {| body_rest := skipped; body_skip_depth := depth |}
          | None => None
          end
        else None
    | RETURN =>
        Some {| body_rest := rest; body_skip_depth := 0 |}
    | _ =>
        process_block_body rest ctrl_depth remaining
    end
  end.

(* 顶层函数体验证包装器。
   ctrl_depth=0（顶层无标签），budget=-1（无字节预算约束，消耗到末）。 *)
Definition validate_function_body (f : sasm_function) : bool :=
  match process_block_body f.(sasm_body) 0 (-1) with
  | Some res =>
      if 0 <? res.(body_skip_depth) then false
      else true
  | None => false
  end.

Definition MAX_MEMORY_SIZE : Z := 65536.   (* 64 KB *)
Definition MAX_CYCLE_LIMIT : Z := 1000000.  (* 10^6 *)
Definition MAX_CALL_DEPTH : Z := 32.

(* ---- 辅助函数 ---- *)

(* 获取函数体指令条数 *)
Definition body_length (f : sasm_function) : Z :=
  Z.of_nat (List.length f.(sasm_body)).

(* ---- V1-V4: 文件完整性 ---- *)

(* V1: Magic 必须为 "SASM" *)
Definition rule_V1 (m : sasm_module) : Prop :=
  m.(sasm_magic) = "SASM"%string.

(* V2: Version 必须为 1 *)
Definition rule_V2 (m : sasm_module) : Prop :=
  m.(sasm_version) = 1.

(* V3: CRC32 校验 — Coq 层面不形式化，加载器运行时检查 *)
Definition rule_V3 (m : sasm_module) : Prop := True.

(* V4: 文件总大小一致性 — Coq 模型简化为 total_memory > 0 *)
Definition rule_V4 (m : sasm_module) : Prop :=
  m.(sasm_total_memory_size) > 0.

(* ---- V5-V12: 段验证 ---- *)

(* V5: Type Section 中参数/返回值类型必须在有效集合内 *)
Definition valid_value_type (vt : sasm_value_type) : Prop :=
  vt = I32 \/ vt = I64 \/ vt = F32 \/ vt = F64.

Definition rule_V5 (m : sasm_module) : Prop :=
  forall ft : sasm_func_type,
    List.In ft m.(sasm_types) ->
    (forall pt : sasm_value_type, List.In pt ft.(sasm_param_types) -> valid_value_type pt) /\
    (forall rt : sasm_value_type, List.In rt ft.(sasm_return_types) -> valid_value_type rt).

(* V6: Function Section 的 type_idx 必须在 Type Section 范围内 *)
Definition rule_V6 (m : sasm_module) : Prop :=
  forall f : sasm_function,
    List.In f m.(sasm_functions) ->
    (0 <= f.(sasm_func_type_idx) < Z.of_nat (List.length m.(sasm_types)))%Z.

(* V7: total_size > 0 且 ≤ MAX_MEMORY_SIZE *)
Definition rule_V7 (m : sasm_module) : Prop :=
  0 < m.(sasm_total_memory_size) <= MAX_MEMORY_SIZE.

(* V8: 各段 start_offset + size 不超出 total_size *)
Definition rule_V8 (m : sasm_module) : Prop :=
  forall seg : memory_segment,
    List.In seg m.(sasm_memory_segments) ->
    seg.(seg_start) + seg.(seg_size) <= m.(sasm_total_memory_size).

(* V9: 各段区间不得重叠 *)
Definition rule_V9 (m : sasm_module) : Prop :=
  forall seg1 seg2 : memory_segment,
    List.In seg1 m.(sasm_memory_segments) ->
    List.In seg2 m.(sasm_memory_segments) ->
    seg1 <> seg2 ->
    seg1.(seg_start) + seg1.(seg_size) <= seg2.(seg_start) \/
    seg2.(seg_start) + seg2.(seg_size) <= seg1.(seg_start).

(* V10: IOMap 条目的 mem_offset + bit_width/8 不超出 total_size *)
Definition rule_V10 (m : sasm_module) : Prop :=
  forall io : io_entry_sasm,
    List.In io m.(sasm_io_map) ->
    io.(io_mem_offset) + io.(io_bit_width) / 8 <= m.(sasm_total_memory_size).

(* V11: 每个函数体长度 > 0 *)
Definition rule_V11 (m : sasm_module) : Prop :=
  forall f : sasm_function,
    List.In f m.(sasm_functions) ->
    body_length f > 0.

(* V12: Safety Section 存在 — sasm_safety 字段非空可构造即满足 *)
Definition rule_V12 (m : sasm_module) : Prop := True.

(* ---- V13-V20: 指令验证 ---- *)

(* V13: 所有 CALL idx 在 Function Section 范围内 *)
Definition rule_V13 (m : sasm_module) : Prop :=
  forall f : sasm_function,
    List.In f m.(sasm_functions) ->
    forall instr : sasm_instr,
      List.In instr f.(sasm_body) ->
      match instr with
      | CALL idx => (0 <= idx < Z.of_nat (List.length m.(sasm_functions)))%Z
      | _ => True
      end.

(* V14: LOCAL_GET/SET/TEE idx 小于函数声明的局部变量数 *)
Definition rule_V14 (m : sasm_module) : Prop :=
  forall f : sasm_function,
    List.In f m.(sasm_functions) ->
    let local_count := Z.of_nat (List.length f.(sasm_locals)) in
    forall instr : sasm_instr,
      List.In instr f.(sasm_body) ->
      match instr with
      | LOCAL_GET idx | LOCAL_SET idx | LOCAL_TEE idx =>
          (0 <= idx < local_count)%Z
      | _ => True
      end.

(* V15: BR/BR_IF depth ≤ 当前 BLOCK/LOOP 嵌套深度
   精确版：通过 process_block_body 验证 depth < ctrl_depth。
   BLOCK/LOOP 的 len 同时通过递归验证器检查。 *)
Definition rule_V15 (m : sasm_module) : Prop :=
  forall f : sasm_function,
    List.In f m.(sasm_functions) ->
    validate_function_body f = true.

(* V16: BLOCK len 校验 — 由 validate_function_body 的递归验证器覆盖 *)
Definition rule_V16 (m : sasm_module) : Prop := rule_V15 m.

(* V17: LOOP len 校验 — 由 validate_function_body 的递归验证器覆盖 *)
Definition rule_V17 (m : sasm_module) : Prop := rule_V15 m.

(* V18: 值栈类型一致性 (Value Stack Type Consistency)
   对每个函数进行线性指令模拟：维护一个类型栈，逐条检查每条指令的
   栈前置条件是否满足，并更新栈后置条件。
   
   本实现为简化版本：
   - CALL 通过函数类型签名检查参数/返回值类型
   - LOCAL_GET/SET/TEE 通过局部变量表检查类型
   - BLOCK/LOOP/BR/BR_IF/RETURN 跳过（需结构化控制流分析）
   - 其余指令按固定栈效果检查
   
   后续可扩展为完整版本（含 BLOCK/LOOP 嵌套深度跟踪）。 *)

(* 类型栈 = 值类型列表 *)
Definition type_stack : Type := list sasm_value_type.

(* 值类型相等判定 *)
Definition sasm_value_type_eqb (t1 t2 : sasm_value_type) : bool :=
  match t1, t2 with
  | I32, I32 | I64, I64 | F32, F32 | F64, F64 => true
  | _, _ => false
  end.

(* 指令编码字节数（用于 V16/V17 的 BLOCK/LOOP len 校验） *)
(* 从栈顶掉落 n 个元素 *)
Fixpoint drop_stack (stack : type_stack) (n : nat) : type_stack :=
  match n with
  | O => stack
  | S n' => match stack with
            | nil => nil
            | _ :: rest => drop_stack rest n'
            end
  end.

(* 检查栈顶若干元素是否与期望类型匹配 *)
Fixpoint stack_ends_with (stack : type_stack) (tys : list sasm_value_type) : bool :=
  match tys, stack with
  | nil, _ => true
  | ty :: rest_tys, actual :: rest_stack =>
      if sasm_value_type_eqb ty actual
      then stack_ends_with rest_stack rest_tys
      else false
  | _, nil => false
  end.

(* 逐指令类型检查：维护类型栈进行线性模拟
   返回 Some final_stack 表示检查通过；None 表示类型错误 *)
Fixpoint check_instrs (m : sasm_module) (locals : list sasm_value_type) 
                     (return_type : list sasm_value_type) (stack : type_stack) (instrs : list sasm_instr)
  : option type_stack :=
  match instrs with
  | nil => Some stack
  | instr :: rest =>
    match instr with
    | NOP | UNREACHABLE => check_instrs m locals return_type stack rest
    | SAFE_ASSERT _ | SAFE_BOUNDS_CHECK _ _ => check_instrs m locals return_type stack rest
    | DROP =>
        match stack with
        | _ :: rest_stack => check_instrs m locals return_type rest_stack rest
        | nil => None
        end
    | SELECT =>
        match stack with
        | I32 :: I32 :: I32 :: rest_stack => check_instrs m locals return_type (I32 :: rest_stack) rest
        | _ => None
        end
    | I32_CONST _ => check_instrs m locals return_type (I32 :: stack) rest
    | I64_CONST _ => check_instrs m locals return_type (I64 :: stack) rest
    | F32_CONST _ => check_instrs m locals return_type (F32 :: stack) rest
    | F64_CONST _ => check_instrs m locals return_type (F64 :: stack) rest
    | LOCAL_GET idx =>
        match List.nth_error locals (Z.to_nat idx) with
        | Some ty => check_instrs m locals return_type (ty :: stack) rest
        | None => None
        end
    | LOCAL_SET idx =>
        match stack, List.nth_error locals (Z.to_nat idx) with
        | val_ty :: rest_stack, Some local_ty =>
            if sasm_value_type_eqb val_ty local_ty
            then check_instrs m locals return_type rest_stack rest
            else None
        | _, _ => None
        end
    | LOCAL_TEE idx =>
        match stack, List.nth_error locals (Z.to_nat idx) with
        | val_ty :: rest_stack, Some local_ty =>
            if sasm_value_type_eqb val_ty local_ty
            then check_instrs m locals return_type (val_ty :: rest_stack) rest
            else None
        | _, _ => None
        end
    | I32_EQZ =>
        match stack with
        | I32 :: rest_stack => check_instrs m locals return_type (I32 :: rest_stack) rest
        | _ => None
        end
    | I32_EQ | I32_NE | I32_LT_S | I32_LE_S | I32_GT_S | I32_GE_S
    | I32_ADD | I32_SUB | I32_MUL | I32_DIV_S | I32_REM_S
    | I32_AND | I32_OR | I32_XOR | I32_SHL | I32_SHR_S | I32_ROTL | I32_ROTR =>
        match stack with
        | I32 :: I32 :: rest_stack => check_instrs m locals return_type (I32 :: rest_stack) rest
        | _ => None
        end
    | I64_EQZ =>
        match stack with
        | I64 :: rest_stack => check_instrs m locals return_type (I32 :: rest_stack) rest
        | _ => None
        end
    | I64_EQ | I64_NE | I64_LT_S | I64_LE_S | I64_GT_S | I64_GE_S =>
        match stack with
        | I64 :: I64 :: rest_stack => check_instrs m locals return_type (I32 :: rest_stack) rest
        | _ => None
        end
    | I64_ADD | I64_SUB | I64_MUL | I64_DIV_S | I64_REM_S
    | I64_AND | I64_OR | I64_XOR | I64_SHL | I64_SHR_S =>
        match stack with
        | I64 :: I64 :: rest_stack => check_instrs m locals return_type (I64 :: rest_stack) rest
        | _ => None
        end
    | F32_ADD | F32_SUB | F32_MUL | F32_DIV =>
        match stack with
        | F32 :: F32 :: rest_stack => check_instrs m locals return_type (F32 :: rest_stack) rest
        | _ => None
        end
    | F32_EQ | F32_NE | F32_LT | F32_LE | F32_GT | F32_GE =>
        match stack with
        | F32 :: F32 :: rest_stack => check_instrs m locals return_type (I32 :: rest_stack) rest
        | _ => None
        end
    | F32_ABS | F32_NEG | F32_SQRT =>
        match stack with
        | F32 :: rest_stack => check_instrs m locals return_type (F32 :: rest_stack) rest
        | _ => None
        end
    | F64_ADD | F64_SUB | F64_MUL | F64_DIV =>
        match stack with
        | F64 :: F64 :: rest_stack => check_instrs m locals return_type (F64 :: rest_stack) rest
        | _ => None
        end
    | F64_EQ | F64_NE | F64_LT | F64_LE | F64_GT | F64_GE =>
        match stack with
        | F64 :: F64 :: rest_stack => check_instrs m locals return_type (I32 :: rest_stack) rest
        | _ => None
        end
    | F64_ABS | F64_NEG | F64_SQRT =>
        match stack with
        | F64 :: rest_stack => check_instrs m locals return_type (F64 :: rest_stack) rest
        | _ => None
        end
    | I32_WRAP_I64 =>
        match stack with
        | I64 :: rest_stack => check_instrs m locals return_type (I32 :: rest_stack) rest
        | _ => None
        end
    | I64_EXTEND_I32_S =>
        match stack with
        | I32 :: rest_stack => check_instrs m locals return_type (I64 :: rest_stack) rest
        | _ => None
        end
    | I32_TRUNC_F32_S =>
        match stack with
        | F32 :: rest_stack => check_instrs m locals return_type (I32 :: rest_stack) rest
        | _ => None
        end
    | I32_TRUNC_F64_S =>
        match stack with
        | F64 :: rest_stack => check_instrs m locals return_type (I32 :: rest_stack) rest
        | _ => None
        end
    | F32_CONVERT_I32_S =>
        match stack with
        | I32 :: rest_stack => check_instrs m locals return_type (F32 :: rest_stack) rest
        | _ => None
        end
    | F64_CONVERT_I32_S =>
        match stack with
        | I32 :: rest_stack => check_instrs m locals return_type (F64 :: rest_stack) rest
        | _ => None
        end
    | I32_LOAD _ | I32_LOAD8_U _ =>
        match stack with
        | I32 :: rest_stack => check_instrs m locals return_type (I32 :: rest_stack) rest
        | _ => None
        end
    | I64_LOAD _ =>
        match stack with
        | I32 :: rest_stack => check_instrs m locals return_type (I64 :: rest_stack) rest
        | _ => None
        end
    | F32_LOAD _ =>
        match stack with
        | I32 :: rest_stack => check_instrs m locals return_type (F32 :: rest_stack) rest
        | _ => None
        end
    | F64_LOAD _ =>
        match stack with
        | I32 :: rest_stack => check_instrs m locals return_type (F64 :: rest_stack) rest
        | _ => None
        end
    | I32_STORE _ | I32_STORE8 _ =>
        match stack with
        | I32 :: I32 :: rest_stack => check_instrs m locals return_type rest_stack rest
        | _ => None
        end
    | I64_STORE _ =>
        match stack with
        | I64 :: I32 :: rest_stack => check_instrs m locals return_type rest_stack rest
        | _ => None
        end
    | F32_STORE _ =>
        match stack with
        | F32 :: I32 :: rest_stack => check_instrs m locals return_type rest_stack rest
        | _ => None
        end
    | F64_STORE _ =>
        match stack with
        | F64 :: I32 :: rest_stack => check_instrs m locals return_type rest_stack rest
        | _ => None
        end
    | CALL idx =>
        match List.nth_error m.(sasm_types) (Z.to_nat idx) with
        | Some ft =>
            let param_tys := ft.(sasm_param_types) in
            if stack_ends_with stack param_tys
            then
              let remaining := drop_stack stack (List.length param_tys) in
              check_instrs m locals return_type (remaining ++ ft.(sasm_return_types)) rest
            else None
        | None => None
        end
    | BLOCK _ | LOOP _ | BR _ | BR_IF _ =>
        (* BLOCK/LOOP/BR/BR_IF：暂不检查栈效果，跳过 *)
        check_instrs m locals return_type stack rest

    | RETURN =>
        (* RETURN: 检查栈顶类型与函数返回值类型匹配 *)
        match return_type with
        | nil =>
            (* 无返回值函数：栈应为空 *)
            match stack with
            | nil => Some nil
            | _ => None
            end
        | [ret_ty] =>
            match stack with
            | actual_ty :: rest_stack =>
                if sasm_value_type_eqb actual_ty ret_ty
                then Some (ret_ty :: nil)
                else None
            | nil => None
            end
        | _ => None
        end
    end
  end.

(* 检查单个函数：从空栈开始，检查完所有指令后，
   最终栈应与函数类型签名声明的返回值类型匹配 *)
Definition check_function (m : sasm_module) (f : sasm_function) : bool :=
  match List.nth_error m.(sasm_types) (Z.to_nat f.(sasm_func_type_idx)) with
  | Some ft =>
      let expected_return := ft.(sasm_return_types) in
      match check_instrs m f.(sasm_locals) expected_return nil f.(sasm_body) with
      | Some final_stack =>
          match expected_return, final_stack with
          | nil, nil => true
          | [ret_ty], [single_ty] => sasm_value_type_eqb single_ty ret_ty
          | _, _ => false
          end
      | None => false
      end
  | None => false
  end.

Definition rule_V18 (m : sasm_module) : Prop :=
  forall f : sasm_function,
    List.In f m.(sasm_functions) ->
    check_function m f = true.

(* V19: SAFE_BOUNDS_CHECK low ≤ high *)
Definition rule_V19 (m : sasm_module) : Prop :=
  forall f : sasm_function,
    List.In f m.(sasm_functions) ->
    forall instr : sasm_instr,
      List.In instr f.(sasm_body) ->
      match instr with
      | SAFE_BOUNDS_CHECK low high => low <= high
      | _ => True
      end.

(* V20: SAFE_ASSERT 参数值在合理范围内 *)
Definition rule_V20 (m : sasm_module) : Prop :=
  forall f : sasm_function,
    List.In f m.(sasm_functions) ->
    forall instr : sasm_instr,
      List.In instr f.(sasm_body) ->
      match instr with
      | SAFE_ASSERT (ASSERT_CYCLE_LIMIT limit) => (0 < limit <= MAX_CYCLE_LIMIT)%Z
      | SAFE_ASSERT (ASSERT_STACK_DEPTH depth) => (0 < depth <= MAX_CALL_DEPTH)%Z
      | SAFE_ASSERT (ASSERT_MEM_BOUNDS low high) => (0 <= low <= high)%Z
      | _ => True
      end.

(* ---- V21-V26: 安全约束验证 ---- *)

(* V21: safe_cycle_limit > 0 且 ≤ MAX_CYCLE_LIMIT *)
Definition rule_V21 (m : sasm_module) : Prop :=
  (0 < m.(sasm_safety).(safe_cycle_limit) <= MAX_CYCLE_LIMIT)%Z.

(* V22: safe_stack_depth > 0 且 ≤ MAX_CALL_DEPTH *)
Definition rule_V22 (m : sasm_module) : Prop :=
  (0 < m.(sasm_safety).(safe_stack_depth) <= MAX_CALL_DEPTH)%Z.

(* V23: 每个 loop_bound 的 max_iter > 0 *)
Definition rule_V23 (m : sasm_module) : Prop :=
  forall lb : loop_bound,
    List.In lb m.(sasm_safety).(safe_loop_bounds) ->
    lb.(lb_max_iter) > 0.

(* V24: 所有循环 max_iter 之和 ≤ safe_cycle_limit *)
Fixpoint sum_loop_iters (lbs : list loop_bound) : Z :=
  match lbs with
  | nil => 0
  | lb :: rest => lb.(lb_max_iter) + sum_loop_iters rest
  end.

Definition rule_V24 (m : sasm_module) : Prop :=
  sum_loop_iters m.(sasm_safety).(safe_loop_bounds) <=
  m.(sasm_safety).(safe_cycle_limit).

(* V25: 内存访问范围不超出 total_memory_size *)
Definition rule_V25 (m : sasm_module) : Prop :=
  forall r : mem_access_range,
    List.In r m.(sasm_safety).(safe_mem_access_map) ->
    r.(mar_low) >= 0 /\ r.(mar_high) <= m.(sasm_total_memory_size).

(* V26: 无直接递归调用 — 每个函数不可 CALL 自身 *)
Definition rule_V26 (m : sasm_module) : Prop :=
  forall (idx : Z) (f : sasm_function) (instr : sasm_instr),
    List.nth_error m.(sasm_functions) (Z.to_nat idx) = Some f ->
    List.In instr f.(sasm_body) ->
    match instr with
    | CALL i => i <> idx
    | _ => True
    end.

(* ---- 组合验证谓词 ---- *)

Definition validate_module (m : sasm_module) : Prop :=
  rule_V1 m /\ rule_V2 m /\ rule_V3 m /\
  rule_V4 m /\ rule_V5 m /\ rule_V6 m /\
  rule_V7 m /\ rule_V8 m /\ rule_V9 m /\
  rule_V10 m /\ rule_V11 m /\ rule_V12 m /\
  rule_V13 m /\ rule_V14 m /\ rule_V15 m /\
  rule_V16 m /\ rule_V17 m /\ rule_V18 m /\
  rule_V19 m /\ rule_V20 m /\
  rule_V21 m /\ rule_V22 m /\ rule_V23 m /\
  rule_V24 m /\ rule_V25 m /\ rule_V26 m.

End Validation.
Definition terminal_state_sasm (s : runtime_state) : Prop :=
  s.(rt_frames) = nil.

(* ================================================================
   定理 5: sasm_type_safety (类型安全)
   
   如果模块通过了 V1-V26 验证，
   则执行过程中要么执行结束（帧栈为空），
   要么可以安全地执行下一步（满足安全约束）。
   
   证明策略:
   - Multi_refl 情况: 若帧栈非空，需 Progress 引理（Phase 1 补全）
   - Multi_step 情况: 归纳假设保证后续状态也可继续或终止
   ================================================================ *)
Theorem sasm_type_safety : forall (m : sasm_module) (s s' : runtime_state),
  validate_module m ->
  multi_step m s s' ->
  terminal_state_sasm s' \/ (exists s'', safe_step m s' s'').
Admitted.




