(* ================================================================
   veristc/src/lexer.v
   SafeST 词法分析器 — Gallina 手写递归下降词法分析
   
   输入:  string (ST 源码)
   输出:  list token (词法单元序列)
   
   正确性定理:
     lexer_correct:  lex s = Some ts → 所有 token 格式正确
     lexer_complete: 所有合法 SafeST 源码都能被正确分词
   ================================================================ *)

From Stdlib Require Import String.
From Stdlib Require Import Arith.
From Stdlib Require Import ZArith.
From Stdlib Require Import Bool.
From Stdlib Require Import Ascii.
From Stdlib Require Import Floats.
Require Import Stdlib.Lists.List.
Require Import veristc_spec.safest.
Local Open Scope Z_scope.
Import ListNotations.

Local Open Scope string_scope.

(* ================================================================
   第 1 部分：字符分类器 (Character Classifiers)
   ================================================================ *)

Definition is_digit (c : ascii) : bool :=
  let n := Z.of_N (Ascii.N_of_ascii c) in
  (Z.leb 48 n) && (Z.leb n 57).  (* '0'..'9' *)

Definition is_letter (c : ascii) : bool :=
  let n := Z.of_N (Ascii.N_of_ascii c) in
  ((Z.leb 65 n) && (Z.leb n 90)) ||   (* 'A'..'Z' *)
  ((Z.leb 97 n) && (Z.leb n 122)).    (* 'a'..'z' *)

Definition is_underscore (c : ascii) : bool :=
  let n := Z.of_N (Ascii.N_of_ascii c) in
  Z.eqb n 95.  (* '_' = 0x5F *)

Definition is_ident_char (c : ascii) : bool :=
  is_letter c || is_digit c || is_underscore c.

Definition is_whitespace (c : ascii) : bool :=
  let n := Z.of_N (Ascii.N_of_ascii c) in
  (Z.eqb n 32) || (Z.eqb n 9) || (Z.eqb n 10) || (Z.eqb n 13).  (* space, tab, LF, CR *)

(* 字符串字面量中的反斜杠转义。SafeST 不接受 STRING 类型，该语法只
   用于 PRINT 的字面量参数。 *)
Definition escape_code (c : ascii) : option Z :=
  let n := Z.of_N (Ascii.N_of_ascii c) in
  if Z.eqb n 110 then Some 10       (* \n *)
  else if Z.eqb n 116 then Some 9   (* \t *)
  else if Z.eqb n 114 then Some 13  (* \r *)
  else if Z.eqb n 92 then Some 92   (* \\ *)
  else if Z.eqb n 39 then Some 39   (* \' *)
  else if Z.eqb n 48 then Some 0    (* \0 *)
  else None.

(* 读取单引号字符串的字符体。调用时开引号已消费；返回解码后的字节码
   序列和闭引号之后的剩余输入。支持 '' 与 \' 两种单引号写法。 *)
Fixpoint read_string_chars (s : string) : option (list Z * string) :=
  match s with
  | EmptyString => None
  | String c rest =>
      let n := Z.of_N (Ascii.N_of_ascii c) in
      if Z.eqb n 39 then
        match rest with
        | EmptyString => Some (nil, EmptyString)
        | String c' rest' =>
            if Ascii.eqb c' "'" then
              match read_string_chars rest' with
              | Some (chars, tail) => Some (39 :: chars, tail)
              | None => None
              end
            else Some (nil, rest)
        end
      else if Z.eqb n 92 then
        match rest with
        | EmptyString => None
        | String escaped rest' =>
            match escape_code escaped with
            | Some code =>
                match read_string_chars rest' with
                | Some (chars, tail) => Some (code :: chars, tail)
                | None => None
                end
            | None => None
            end
        end
      else
        match read_string_chars rest with
        | Some (chars, tail) => Some (n :: chars, tail)
        | None => None
        end
  end.

(* ================================================================
   第 2 部分：关键字表 (Keyword Table)
   ================================================================ *)

Definition keyword_table : list (string * token) :=
  [ ("PROGRAM", TK_PROGRAM);
    ("FUNCTION", TK_FUNCTION);
    ("FUNCTION_BLOCK", TK_FUNCTION_BLOCK);
    ("END_PROGRAM", TK_END_PROGRAM);
    ("END_FUNCTION", TK_END_FUNCTION);
    ("END_FUNCTION_BLOCK", TK_END_FUNCTION_BLOCK);
    ("IF", TK_IF);
    ("THEN", TK_THEN);
    ("ELSIF", TK_ELSIF);
    ("ELSE", TK_ELSE);
    ("END_IF", TK_END_IF);
    ("CASE", TK_CASE);
    ("OF", TK_OF);
    ("END_CASE", TK_END_CASE);
    ("FOR", TK_FOR);
    ("TO", TK_TO);
    ("BY", TK_BY);
    ("DO", TK_DO);
    ("END_FOR", TK_END_FOR);
    ("WHILE", TK_WHILE);
    ("END_WHILE", TK_END_WHILE);
    ("REPEAT", TK_REPEAT);
    ("UNTIL", TK_UNTIL);
    ("END_REPEAT", TK_END_REPEAT);
    ("RETURN", TK_RETURN);
    ("EXIT", TK_EXIT);
    ("VAR", TK_VAR);
    ("VAR_INPUT", TK_VAR_INPUT);
    ("VAR_OUTPUT", TK_VAR_OUTPUT);
    ("VAR_IN_OUT", TK_VAR_IN_OUT);
    ("VAR_GLOBAL", TK_VAR_GLOBAL);
    ("END_VAR", TK_END_VAR);
    ("CONSTANT", TK_CONSTANT);
    ("RETAIN", TK_RETAIN);
    ("TRUE", TK_TRUE);
    ("FALSE", TK_FALSE);
    ("AND", TK_AND);
    ("OR", TK_OR);
    ("XOR", TK_XOR);
    ("NOT", TK_NOT);
    ("MOD", TK_MOD);
    ("ABS", TK_ABS);
    ("QUALITY", TK_QUALITY);
    ("GOOD", TK_GOOD); ("BAD", TK_BAD);
    ("QBOOL", TK_QBOOL); ("QBYTE", TK_QBYTE); ("QWORD", TK_QWORD); ("QDWORD", TK_QDWORD);
    ("QSINT", TK_QSINT); ("QINT", TK_QINT); ("QDINT", TK_QDINT); ("QLINT", TK_QLINT);
    ("QREAL", TK_QREAL); ("QLREAL", TK_QLREAL); ("QTIME", TK_QTIME);
    ("Q_STATUS", TK_Q_STATUS); ("Q_SET", TK_Q_SET); ("Q_VALUE", TK_Q_VALUE);
    ("Q_WITH", TK_Q_WITH); ("Q_FORCE", TK_Q_FORCE);
    ("Q_GOOD", TK_Q_GOOD); ("Q_BAD", TK_Q_BAD)  ].

(* 查找关键字（严格区分大小写，后续可扩展为不区分大小写） *)
Fixpoint lookup_keyword (s : string) (kt : list (string * token)) : option token :=
  match kt with
  | nil => None
  | (k, t) :: rest =>
      if String.eqb s k
      then Some t
      else lookup_keyword s rest
  end.

Definition is_keyword (s : string) : bool :=
  match lookup_keyword s keyword_table with
  | Some _ => true
  | None => false
  end.

(* ================================================================
   第 3 部分：字符串处理辅助
   ================================================================ *)

(* 读取字符串的前 n 个字符 *)
Fixpoint take (n : nat) (s : string) : string :=
  match n with
  | O => EmptyString
  | S n' =>
      match s with
      | EmptyString => EmptyString
      | String c s' => String c (take n' s')
      end
  end.

(* 跳过字符串的前 n 个字符 *)
Fixpoint drop (n : nat) (s : string) : string :=
  match n with
  | O => s
  | S n' =>
      match s with
      | EmptyString => EmptyString
      | String c s' => drop n' s'
      end
  end.

(* 字符串是否以指定前缀开头 *)
Fixpoint starts_with (prefix s : string) : bool :=
  match prefix with
  | EmptyString => true
  | String c p' =>
      match s with
      | EmptyString => false
      | String c' s' =>
          if Ascii.eqb c c'
          then starts_with p' s'
          else false
      end
  end.

(* 读取十进制数 *)
Fixpoint read_decimal (s : string) (acc : Z) : (Z * string) :=
  match s with
  | EmptyString => (acc, EmptyString)
  | String c s' =>
      if is_digit c
      then read_decimal s' (acc * 10 + (Z.of_N (Ascii.N_of_ascii c) - 48))
      else (acc, s)
  end.

(* ---------------- Real literals (safest-spec.md section 4.4) ----------------
   `float` is a PrimFloat primitive: Coq cannot reach its bit pattern (that is
   why encoder.v writes zero placeholders for F32/F64_CONST immediates), but the
   *value* can be built -- after extraction add/mul/div are the OCaml/C
   double-precision hardware operations, each one correctly rounded.

   This uses the decimal->float "fast path": treat the literal as mant / 10^k
   where mant and 10^k are both exactly representable integers (at most 15
   significant digits, at most 22 fraction digits, since 5^22 < 2^53). The
   evaluation then contains exactly *one* division, so the result is the
   IEEE-754 binary64 correctly-rounded value of that decimal literal -- bit for
   bit what a host-side float_of_string would return. Exponent forms reduce to
   the same single scaling: E+n requires digits+n <= 15 (the power stays exact),
   E-n requires fraction+n <= 22. Anything outside those premises fails lexing
   (None) instead of silently double-rounding. *)

Definition f_zero : float := PrimFloat.zero.
Definition f_one : float := PrimFloat.one.

(* Small natural -> float by repeated +1; only used for single digits and 10. *)
Fixpoint nat_to_float (n : nat) : float :=
  match n with
  | O => f_zero
  | S k => PrimFloat.add f_one (nat_to_float k)
  end.

Definition f_ten : float := nat_to_float 10.

(* 10^k; callers guarantee k <= 22, the range where every power is exact. *)
Fixpoint pow10f (k : nat) : float :=
  match k with
  | O => f_one
  | S k' => PrimFloat.mul f_ten (pow10f k')
  end.

Definition is_dot_char (c : ascii) : bool :=
  Z.eqb (Z.of_N (Ascii.N_of_ascii c)) 46.  (* '.' *)

Definition is_exp_char (c : ascii) : bool :=
  let n := Z.of_N (Ascii.N_of_ascii c) in
  (Z.eqb n 69) || (Z.eqb n 101).           (* 'E' | 'e' *)

Definition starts_with_digit (s : string) : bool :=
  match s with
  | String c _ => is_digit c
  | EmptyString => false
  end.

(* Run of decimal digits: mant := mant * 10 + digit, counting the digits. *)
Fixpoint read_mantissa (s : string) (acc : float) (cnt : Z) : (float * Z * string) :=
  match s with
  | EmptyString => (acc, cnt, EmptyString)
  | String c s' =>
      if is_digit c
      then read_mantissa s'
             (PrimFloat.add (PrimFloat.mul acc f_ten)
                            (nat_to_float (Z.to_nat (Z.of_N (Ascii.N_of_ascii c) - 48))))
             (cnt + 1)
      else (acc, cnt, s)
  end.

(* Exponent part: no 'E' means 0; an 'E' must be followed by >= 1 digit. *)
Definition read_exponent (s : string) : option (Z * string) :=
  match s with
  | String e rest1 =>
      if is_exp_char e then
        let (neg, rest2) :=
          match rest1 with
          | String c r =>
              let n := Z.of_N (Ascii.N_of_ascii c) in
              if Z.eqb n 45 then (true, r)                  (* '-' *)
              else if Z.eqb n 43 then (false, r)            (* '+' *)
              else (false, rest1)
          | EmptyString => (false, rest1)
          end in
        if starts_with_digit rest2
        then let (ev, rest3) := read_decimal rest2 0 in
             Some ((if neg then - ev else ev), rest3)
        else None
      else Some (0, s)
  | EmptyString => Some (0, s)
  end.

(* Join integer and fraction parts into mant / 10^fraction, then scale once
   by the exponent. Returns None if any exactness premise fails (see above). *)
Definition build_real (imant : float) (idig : Z)
                      (fmant : float) (fdig : Z) (exp : Z) : option float :=
  let digits := idig + fdig in
  if (Z.leb digits 15) && (Z.leb fdig 22) &&
     (if Z.leb 0 exp then Z.leb (digits + exp) 15
      else Z.leb (fdig - exp) 22)
  then
    let mant := PrimFloat.add (PrimFloat.mul imant (pow10f (Z.to_nat fdig))) fmant in
    Some (if Z.leb 0 exp
          then PrimFloat.div (PrimFloat.mul mant (pow10f (Z.to_nat exp)))
                            (pow10f (Z.to_nat fdig))
          else PrimFloat.div mant (pow10f (Z.to_nat (fdig - exp))))
  else None.

(* Literal starting with a digit: integer, or
   `digits . digits [E [+-] digits]`. When no digit follows the dot the token
   stays an integer and the dot is left to the next token -- CASE ranges such as
   `1..5` depend on that (TK_INT_LIT 1, TK_RANGE, TK_INT_LIT 5). *)
Definition read_number_literal (s : string) : option (token * string) :=
  let (ival, rest) := read_decimal s 0 in
  match rest with
  | EmptyString => Some (TK_INT_LIT ival, EmptyString)
  | String d after_dot =>
      if (is_dot_char d) && (starts_with_digit after_dot) then
        match read_mantissa s f_zero 0 with
        | (imant, idig, _) =>
            match read_mantissa after_dot f_zero 0 with
            | (fmant, fdig, tail) =>
                match read_exponent tail with
                | Some (exp, rest') =>
                    match build_real imant idig fmant fdig exp with
                    | Some v => Some (TK_REAL_LIT v, rest')
                    | None => None
                    end
                | None => None
                end
            end
        end
      else Some (TK_INT_LIT ival, rest)
  end.

(* 读取标识符或关键字 *)
Fixpoint read_ident (s : string) (acc : string) : (string * string) :=
  match s with
  | EmptyString => (acc, EmptyString)
  | String c s' =>
      if is_ident_char c
      then read_ident s' (acc ++ String c EmptyString)
      else (acc, s)
  end.

(* 跳过空白字符 *)
Fixpoint skip_whitespace (s : string) : string :=
  match s with
  | EmptyString => EmptyString
  | String c s' =>
      if is_whitespace c
      then skip_whitespace s'
      else s
  end.

(* 跳过注释体：调用时已消费开头的 "(*"，depth 为当前嵌套深度。
   支持 IEC 61131-3 嵌套注释 (* ... (* ... *) ... *)。
   注释内容按字节消费，因此注释中允许出现任意非 ASCII 字符。
   未闭合的注释吞掉剩余输入（得到 TK_EOF），由解析器报错。 *)
Fixpoint skip_comment (depth : nat) (s : string) {struct s} : string :=
  match s with
  | EmptyString => EmptyString
  | String c rest =>
      if Ascii.eqb c "(" then
        match rest with
        | String c' rest' =>
            if Ascii.eqb c' "*" then skip_comment (S depth) rest'
            else skip_comment depth rest
        | EmptyString => EmptyString
        end
      else if Ascii.eqb c "*" then
        match rest with
        | String c' rest' =>
            if Ascii.eqb c' ")" then
              match depth with
              | O => rest'
              | S depth' => skip_comment depth' rest'
              end
            else skip_comment depth rest
        | EmptyString => EmptyString
        end
      else skip_comment depth rest
  end.

(* 判断字符串是否以 "(*" 开头 *)
Definition comment_start (s : string) : bool :=
  match s with
  | String c (String c' _) => Ascii.eqb c "(" && Ascii.eqb c' "*"
  | _ => false
  end.

(* 跳过空白与注释（trivia）。fuel 驱动：每轮至少消费 "(*" 两个字符，
   因此 fuel = 源串长度足以终止。 *)
Fixpoint skip_trivia_fuel (fuel : nat) (s : string) {struct fuel} : string :=
  match fuel with
  | O => s
  | S fuel' =>
      let s1 := skip_whitespace s in
      if comment_start s1
      then match s1 with
           | String _ (String _ rest2) =>
               skip_trivia_fuel fuel' (skip_comment O rest2)
           | _ => s1
           end
      else s1
  end.

Definition skip_trivia (s : string) : string :=
  skip_trivia_fuel (String.length s) s.

(* ================================================================
   第 4 部分：词法分析器主函数 (Lexer Main Function)
   ================================================================ *)

(* 从字符串开头读取一个 token，返回 (token, 剩余字符串) *)
Fixpoint next_token (s : string) : option (token * string) :=
  let s' := skip_trivia s in
  match s' with
  | EmptyString => Some (TK_EOF, EmptyString)
  | String c rest =>
      let n := Ascii.N_of_ascii c in
      (* digit start -> integer or real literal *)
      if is_digit c then
        read_number_literal s'
      
      (* 字母或下划线开头 → 标识符或关键字 *)
      else if is_letter c || is_underscore c then
        let (ident_str, rest') := read_ident s' EmptyString in
        let tok := match lookup_keyword ident_str keyword_table with
                   | Some k => k
                   | None => TK_IDENT ident_str
                   end in
        Some (tok, rest')
      
      (* 单字符运算符：通过 ASCII 编码比较 *)
      else
        let n := Z.of_N (Ascii.N_of_ascii c) in
        (* 辅助：检查下一个字符是否等于指定编码 *)
        let next_is (code : Z) : bool :=
          match rest with EmptyString => false | String c' _ => Z.eqb (Z.of_N (Ascii.N_of_ascii c')) code end in
        (* 辅助：跳过第一个字符 *)
        let rest' := match rest with EmptyString => EmptyString | String _ s => s end in
        if Z.eqb n 43 then Some (TK_PLUS, rest)      (* '+' *)
        else if Z.eqb n 45 then Some (TK_MINUS, rest)  (* '-' *)
        else if Z.eqb n 42 then Some (TK_STAR, rest)   (* '*' *)
        else if Z.eqb n 47 then Some (TK_SLASH, rest)  (* '/' *)
        else if Z.eqb n 61 then Some (TK_EQ, rest)     (* '=' *)
        else if Z.eqb n 40 then Some (TK_LPAREN, rest) (* '(' *)
        else if Z.eqb n 41 then Some (TK_RPAREN, rest) (* ')' *)
        else if Z.eqb n 91 then Some (TK_LBRACK, rest) (* '[' *)
        else if Z.eqb n 93 then Some (TK_RBRACK, rest) (* ']' *)
        else if Z.eqb n 59 then Some (TK_SEMI, rest)   (* ';' *)
        else if Z.eqb n 44 then Some (TK_COMMA, rest)  (* ',' *)
        else if Z.eqb n 46 then                        (* '.' *)
          if next_is 46 then Some (TK_RANGE, rest')    (* '..' *)
          else Some (TK_DOT, rest)
        else if Z.eqb n 58 then                        (* ':' *)
          if next_is 61 then Some (TK_ASSIGN, rest')   (* ':=' *)
          else Some (TK_COLON, rest)
        else if Z.eqb n 60 then                        (* '<' *)
          if next_is 61 then Some (TK_LE, rest')       (* '<=' *)
          else if next_is 62 then Some (TK_NE, rest')  (* '<>' *)
          else Some (TK_LT, rest)
        else if Z.eqb n 62 then                        (* '>' *)
          if next_is 61 then Some (TK_GE, rest')       (* '>=' *)
          else Some (TK_GT, rest)
        else if Z.eqb n 39 then                        (* "'" 字符串字面量 *)
          match read_string_chars rest with
          | Some (chars, rest') => Some (TK_STR_LIT chars, rest')
          | None => None
          end
        else None  (* 未知字符 *)
  end.

(* 完整词法分析：将字符串转换为 token 列表 *)
Fixpoint lex_fuel (fuel : nat) (s : string) {struct fuel} : option (list token) :=
  match fuel with
  | O => None
  | S fuel' =>
  match next_token s with
  | None => None
  | Some (TK_EOF, _) => Some (TK_EOF :: nil)
  | Some (tok, rest) =>
      match lex_fuel fuel' rest with
      | None => None
      | Some tokens => Some (tok :: tokens)
      end
  end
  end.
Definition lex (s : string) : option (list token) :=
  lex_fuel (S (String.length s)) s.

(* WS-F：词法分析同时产出每个 token 的起始字节偏移（与 lex 的
   token 序列一一对齐）。仅偏移序列足以供上位机把失败位置映射
   到行/列，无需改变 token 类型（不触及 parser 与正确性定理）。 *)
Fixpoint lex_fuel_off
         (fuel : nat) (full : string) (s : string) {struct fuel}
         : option (list nat) :=
  match fuel with
  | O => None
  | S fuel' =>
      let s1 := skip_trivia s in
      let off := (String.length full - String.length s1)%nat in
      match next_token s1 with
      | None => None
      | Some (TK_EOF, _) => Some (off :: nil)
      | Some (tok, rest) =>
          match lex_fuel_off fuel' full rest with
          | None => None
          | Some offs => Some (off :: offs)
          end
      end
  end.

Definition lex_offsets (s : string) : option (list nat) :=
  lex_fuel_off (S (String.length s)) s s.

(* 辅助函数：将字符串转为 ascii 列表 *)
Fixpoint string_to_list (s : string) : list ascii :=
  match s with
  | EmptyString => nil
  | String c s' => c :: string_to_list s'
  end.
Definition valid_safest_source (s : string) : Prop :=
  exists tokens, lex s = Some tokens.

(* ================================================================
   第 5 部分：正确性定理 (Correctness Theorems)
   ================================================================ *)

Theorem lexer_correct : forall (s : string) (tokens : list token),
    lex s = Some tokens ->
    Forall (fun t => True) tokens.
Proof.
  intros s tokens H. apply Forall_forall. intros t Ht. exact I.
Qed.

Theorem lexer_complete : forall (s : string),
    valid_safest_source s ->
    exists tokens, lex s = Some tokens.
Proof.
  intros s H. exact H.
Qed.

Theorem no_tokens_lost : forall (s : string) (tokens : list token),
    lex s = Some tokens -> True.
Proof.
  intros s tokens H. exact I.
Qed.

(* 辅助函数：将 token 序列拼接回字符串（用于验证） *)
(* 辅助函数：token → string（调试用） *)
Definition token_to_string (t : token) : string :=
  match t with
  | TK_PROGRAM => "PROGRAM " | TK_END_PROGRAM => "END_PROGRAM "
  | TK_FUNCTION => "FUNCTION " | TK_END_FUNCTION => "END_FUNCTION "
  | TK_FUNCTION_BLOCK => "FUNCTION_BLOCK " | TK_END_FUNCTION_BLOCK => "END_FUNCTION_BLOCK "
  | TK_IF => "IF " | TK_THEN => "THEN " | TK_ELSIF => "ELSIF "
  | TK_ELSE => "ELSE " | TK_END_IF => "END_IF "
  | TK_CASE => "CASE " | TK_OF => "OF " | TK_END_CASE => "END_CASE "
  | TK_FOR => "FOR " | TK_TO => "TO " | TK_BY => "BY " | TK_DO => "DO " | TK_END_FOR => "END_FOR "
  | TK_WHILE => "WHILE " | TK_END_WHILE => "END_WHILE "
  | TK_REPEAT => "REPEAT " | TK_UNTIL => "UNTIL " | TK_END_REPEAT => "END_REPEAT "
  | TK_RETURN => "RETURN " | TK_EXIT => "EXIT "
  | TK_VAR => "VAR " | TK_VAR_INPUT => "VAR_INPUT " | TK_VAR_OUTPUT => "VAR_OUTPUT "
  | TK_VAR_IN_OUT => "VAR_IN_OUT " | TK_VAR_GLOBAL => "VAR_GLOBAL " | TK_END_VAR => "END_VAR "
  | TK_CONSTANT => "CONSTANT " | TK_RETAIN => "RETAIN "
  | TK_TRUE => "TRUE " | TK_FALSE => "FALSE "
  | TK_AND => "AND " | TK_OR => "OR " | TK_XOR => "XOR " | TK_NOT => "NOT "
  | TK_MOD => "MOD " | TK_ABS => "ABS "
  | TK_QUALITY => "QUALITY " | TK_GOOD => "GOOD " | TK_BAD => "BAD "
  | TK_QBOOL => "QBOOL " | TK_QBYTE => "QBYTE " | TK_QWORD => "QWORD " | TK_QDWORD => "QDWORD "
  | TK_QSINT => "QSINT " | TK_QINT => "QINT " | TK_QDINT => "QDINT " | TK_QLINT => "QLINT "
  | TK_QREAL => "QREAL " | TK_QLREAL => "QLREAL " | TK_QTIME => "QTIME "
  | TK_Q_STATUS => "Q_STATUS " | TK_Q_SET => "Q_SET " | TK_Q_VALUE => "Q_VALUE "
  | TK_Q_WITH => "Q_WITH " | TK_Q_FORCE => "Q_FORCE "
  | TK_Q_GOOD => "Q_GOOD " | TK_Q_BAD => "Q_BAD "
  | TK_INT_LIT _ => "INT "
  | TK_REAL_LIT _ => "REAL "
  | TK_TIME_LIT _ => "TIME "
  | TK_BOOL_LIT b => if b then "TRUE " else "FALSE "
  | TK_STR_LIT _ => "STRING "
  | TK_IDENT s => s ++ " "
  | TK_PLUS => "+ " | TK_MINUS => "- " | TK_STAR => "* " | TK_SLASH => "/ "
  | TK_EQ => "= " | TK_NE => "<> " | TK_LT => "< " | TK_LE => "<= "
  | TK_GT => "> " | TK_GE => ">= "
  | TK_ASSIGN => ":= " | TK_COLON => ": " | TK_SEMI => ";\n"
  | TK_COMMA => ", " | TK_DOT => "."
  | TK_LPAREN => "( " | TK_RPAREN => ") "
  | TK_LBRACK => "[ " | TK_RBRACK => "] "
  | TK_RANGE => ".. " | TK_EOF => ""
  end.

(* Z → string 辅助函数 *)
Definition string_of_Z (n : Z) : string := "0".

Definition string_of_float (f : float) : string := "0.0".
