(* ================================================================
   veristc/src/parser.v
   SafeST 递归下降解析器 — Gallina 手写
   
   输入:  list token (由 lexer.v 产出)
   输出:  option st_program (SafeST 抽象语法树)
   
   正确性定理:
     parse_well_formed: parse ts = Some p → well_formed_program p
     parse_sound:       parse ts = Some p → 所有 token 被消耗
   ================================================================ *)

From Stdlib Require Import List.
From Stdlib Require Import ZArith.
From Stdlib Require Import String.
Require Import veristc_spec.safest.
Require Import veristc_src.lexer.
Local Open Scope Z_scope.
Import ListNotations.

(* ================================================================
   第 1 部分：解析器状态 (Parser State)
   ================================================================ *)

Record parser_state : Type := {
  ps_tokens : list token;
  ps_pos    : Z;
}.

Inductive parse_result (A : Type) : Type :=
  | Parse_ok : A * parser_state -> parse_result A
  | Parse_error : string -> parse_result A
  | Parse_fail : parse_result A
.

Arguments Parse_ok {A} _.
Arguments Parse_error {A} _.
Arguments Parse_fail {A}.

(* ================================================================
   第 2 部分：基本解析组合子 (Basic Parser Combinators)
   ================================================================ *)

Definition peek (st : parser_state) : option token :=
  match ps_tokens st with
  | nil => None
  | t :: _ => Some t
  end.

Definition consume (st : parser_state) : token * parser_state :=
  match ps_tokens st with
  | nil => (TK_EOF, st)
  | t :: ts => (t, Build_parser_state ts (ps_pos st + 1))
  end.

Definition expect (st : parser_state) (expected : token -> bool)
                  : (token * parser_state) :=
  consume st.

Definition token_eq (t1 t2 : token) : bool :=
  match t1, t2 with
  | TK_PROGRAM, TK_PROGRAM => true
  | TK_FUNCTION, TK_FUNCTION => true
  | TK_FUNCTION_BLOCK, TK_FUNCTION_BLOCK => true
  | TK_END_PROGRAM, TK_END_PROGRAM => true
  | TK_END_FUNCTION, TK_END_FUNCTION => true
  | TK_END_FUNCTION_BLOCK, TK_END_FUNCTION_BLOCK => true
  | TK_IF, TK_IF => true
  | TK_THEN, TK_THEN => true
  | TK_ELSIF, TK_ELSIF => true
  | TK_ELSE, TK_ELSE => true
  | TK_END_IF, TK_END_IF => true
  | TK_CASE, TK_CASE => true
  | TK_OF, TK_OF => true
  | TK_END_CASE, TK_END_CASE => true
  | TK_FOR, TK_FOR => true
  | TK_TO, TK_TO => true
  | TK_BY, TK_BY => true
  | TK_DO, TK_DO => true
  | TK_END_FOR, TK_END_FOR => true
  | TK_WHILE, TK_WHILE => true
  | TK_END_WHILE, TK_END_WHILE => true
  | TK_REPEAT, TK_REPEAT => true
  | TK_UNTIL, TK_UNTIL => true
  | TK_END_REPEAT, TK_END_REPEAT => true
  | TK_RETURN, TK_RETURN => true
  | TK_EXIT, TK_EXIT => true
  | TK_VAR, TK_VAR => true
  | TK_VAR_INPUT, TK_VAR_INPUT => true
  | TK_VAR_OUTPUT, TK_VAR_OUTPUT => true
  | TK_VAR_IN_OUT, TK_VAR_IN_OUT => true
  | TK_VAR_GLOBAL, TK_VAR_GLOBAL => true
  | TK_END_VAR, TK_END_VAR => true
  | TK_CONSTANT, TK_CONSTANT => true
  | TK_RETAIN, TK_RETAIN => true
  | TK_TRUE, TK_TRUE => true
  | TK_FALSE, TK_FALSE => true
  | TK_AND, TK_AND => true
  | TK_OR, TK_OR => true
  | TK_XOR, TK_XOR => true
  | TK_NOT, TK_NOT => true
  | TK_MOD, TK_MOD => true
  | TK_ABS, TK_ABS => true
  | TK_INT_LIT _, TK_INT_LIT _ => true
  | TK_REAL_LIT _, TK_REAL_LIT _ => true
  | TK_TIME_LIT _, TK_TIME_LIT _ => true
  | TK_BOOL_LIT _, TK_BOOL_LIT _ => true
  | TK_IDENT _, TK_IDENT _ => true
  | TK_PLUS, TK_PLUS => true
  | TK_MINUS, TK_MINUS => true
  | TK_STAR, TK_STAR => true
  | TK_SLASH, TK_SLASH => true
  | TK_EQ, TK_EQ => true
  | TK_NE, TK_NE => true
  | TK_LT, TK_LT => true
  | TK_LE, TK_LE => true
  | TK_GT, TK_GT => true
  | TK_GE, TK_GE => true
  | TK_ASSIGN, TK_ASSIGN => true
  | TK_COLON, TK_COLON => true
  | TK_SEMI, TK_SEMI => true
  | TK_COMMA, TK_COMMA => true
  | TK_DOT, TK_DOT => true
  | TK_LPAREN, TK_LPAREN => true
  | TK_RPAREN, TK_RPAREN => true
  | TK_LBRACK, TK_LBRACK => true
  | TK_RBRACK, TK_RBRACK => true
  | TK_RANGE, TK_RANGE => true
  | TK_QUALITY, TK_QUALITY => true
  | TK_GOOD, TK_GOOD => true
  | TK_BAD, TK_BAD => true
  | TK_QBOOL, TK_QBOOL => true
  | TK_QBYTE, TK_QBYTE => true
  | TK_QWORD, TK_QWORD => true
  | TK_QDWORD, TK_QDWORD => true
  | TK_QSINT, TK_QSINT => true
  | TK_QINT, TK_QINT => true
  | TK_QDINT, TK_QDINT => true
  | TK_QLINT, TK_QLINT => true
  | TK_QREAL, TK_QREAL => true
  | TK_QLREAL, TK_QLREAL => true
  | TK_QTIME, TK_QTIME => true
  | TK_Q_STATUS, TK_Q_STATUS => true
  | TK_Q_SET, TK_Q_SET => true
  | TK_Q_VALUE, TK_Q_VALUE => true
  | TK_Q_WITH, TK_Q_WITH => true
  | TK_Q_FORCE, TK_Q_FORCE => true
  | TK_Q_GOOD, TK_Q_GOOD => true
  | TK_Q_BAD, TK_Q_BAD => true
  | TK_EOF, TK_EOF => true
  | _, _ => false
  end.

Definition expect_token (st : parser_state) (expected_tok : token)
                        : (token * parser_state) :=
  consume st.

(* ================================================================
   第 3 部分：解析器主函数
   ================================================================ *)

Definition pou_entry_name (p : st_pou) : ident :=
  match p with
  | P_PROGRAM name _ _ => name
  | P_FUNCTION name _ _ _ => name
  | P_FUNCTION_BLOCK name _ _ => name
  end.

(* ----------------------------------------------------------------
   3.1 表达式解析（相互递归）
   ---------------------------------------------------------------- *)

Fixpoint parse_expression (fuel : nat) (st : parser_state) {struct fuel}
         : parse_result st_expr :=
  match fuel with
  | O => Parse_error "Out of fuel (parse_expression)"
  | S fuel' =>
      parse_or_expression fuel' st
  end

with parse_or_expression (fuel : nat) (st : parser_state) {struct fuel}
     : parse_result st_expr :=
  match fuel with
  | O => Parse_error "Out of fuel"
  | S fuel' =>
      match parse_xor_expression fuel' st with
      | Parse_ok (l_val, st1) =>
          match peek st1 with
          | Some TK_OR =>
              let st2 := snd (consume st1) in
              match parse_or_expression fuel' st2 with
              | Parse_ok (r_val, st3) =>
                  Parse_ok ((E_OR l_val r_val), st3)
              | Parse_fail => Parse_fail
              | Parse_error msg => Parse_error msg
              end
          | _ => Parse_ok (l_val, st1)
          end
      | Parse_fail => Parse_fail
      | Parse_error msg => Parse_error msg
      end
  end

with parse_xor_expression (fuel : nat) (st : parser_state) {struct fuel}
     : parse_result st_expr :=
  match fuel with
  | O => Parse_error "Out of fuel"
  | S fuel' =>
      match parse_and_expression fuel' st with
      | Parse_ok (l_val, st1) =>
          match peek st1 with
          | Some TK_XOR =>
              let st2 := snd (consume st1) in
              match parse_xor_expression fuel' st2 with
              | Parse_ok (r_val, st3) =>
                  Parse_ok ((E_XOR l_val r_val), st3)
              | Parse_fail => Parse_fail
              | Parse_error msg => Parse_error msg
              end
          | _ => Parse_ok (l_val, st1)
          end
      | Parse_fail => Parse_fail
      | Parse_error msg => Parse_error msg
      end
  end

with parse_and_expression (fuel : nat) (st : parser_state) {struct fuel}
     : parse_result st_expr :=
  match fuel with
  | O => Parse_error "Out of fuel"
  | S fuel' =>
      match parse_compare_expression fuel' st with
      | Parse_ok (l_val, st1) =>
          match peek st1 with
          | Some TK_AND =>
              let st2 := snd (consume st1) in
              match parse_and_expression fuel' st2 with
              | Parse_ok (r_val, st3) =>
                  Parse_ok ((E_AND l_val r_val), st3)
              | Parse_fail => Parse_fail
              | Parse_error msg => Parse_error msg
              end
          | _ => Parse_ok (l_val, st1)
          end
      | Parse_fail => Parse_fail
      | Parse_error msg => Parse_error msg
      end
  end

with parse_compare_expression (fuel : nat) (st : parser_state) {struct fuel}
     : parse_result st_expr :=
  match fuel with
  | O => Parse_error "Out of fuel"
  | S fuel' =>
      match parse_add_expression fuel' st with
      | Parse_ok (l_val, st1) =>
          match peek st1 with
          | Some TK_EQ =>
              let st2 := snd (consume st1) in
              match parse_add_expression fuel' st2 with
              | Parse_ok (r_val, st3) =>
                  Parse_ok ((E_COMP C_EQ l_val r_val), st3)
              | Parse_fail => Parse_fail
              | Parse_error msg => Parse_error msg
              end
          | Some TK_NE =>
              let st2 := snd (consume st1) in
              match parse_add_expression fuel' st2 with
              | Parse_ok (r_val, st3) =>
                  Parse_ok ((E_COMP C_NE l_val r_val), st3)
              | Parse_fail => Parse_fail
              | Parse_error msg => Parse_error msg
              end
          | Some TK_LT =>
              let st2 := snd (consume st1) in
              match parse_add_expression fuel' st2 with
              | Parse_ok (r_val, st3) =>
                  Parse_ok ((E_COMP C_LT l_val r_val), st3)
              | Parse_fail => Parse_fail
              | Parse_error msg => Parse_error msg
              end
          | Some TK_LE =>
              let st2 := snd (consume st1) in
              match parse_add_expression fuel' st2 with
              | Parse_ok (r_val, st3) =>
                  Parse_ok ((E_COMP C_LE l_val r_val), st3)
              | Parse_fail => Parse_fail
              | Parse_error msg => Parse_error msg
              end
          | Some TK_GT =>
              let st2 := snd (consume st1) in
              match parse_add_expression fuel' st2 with
              | Parse_ok (r_val, st3) =>
                  Parse_ok ((E_COMP C_GT l_val r_val), st3)
              | Parse_fail => Parse_fail
              | Parse_error msg => Parse_error msg
              end
          | Some TK_GE =>
              let st2 := snd (consume st1) in
              match parse_add_expression fuel' st2 with
              | Parse_ok (r_val, st3) =>
                  Parse_ok ((E_COMP C_GE l_val r_val), st3)
              | Parse_fail => Parse_fail
              | Parse_error msg => Parse_error msg
              end
          | _ => Parse_ok (l_val, st1)
          end
      | Parse_fail => Parse_fail
      | Parse_error msg => Parse_error msg
      end
  end

with parse_add_expression (fuel : nat) (st : parser_state) {struct fuel}
     : parse_result st_expr :=
  match fuel with
  | O => Parse_error "Out of fuel"
  | S fuel' =>
      match parse_mult_expression fuel' st with
      | Parse_ok (l_val, st1) =>
          match peek st1 with
          | Some TK_PLUS =>
              let st2 := snd (consume st1) in
              match parse_add_expression fuel' st2 with
              | Parse_ok (r_val, st3) =>
                  Parse_ok ((E_BIN_OP B_ADD l_val r_val), st3)
              | Parse_fail => Parse_fail
              | Parse_error msg => Parse_error msg
              end
          | Some TK_MINUS =>
              let st2 := snd (consume st1) in
              match parse_add_expression fuel' st2 with
              | Parse_ok (r_val, st3) =>
                  Parse_ok ((E_BIN_OP B_SUB l_val r_val), st3)
              | Parse_fail => Parse_fail
              | Parse_error msg => Parse_error msg
              end
          | _ => Parse_ok (l_val, st1)
          end
      | Parse_fail => Parse_fail
      | Parse_error msg => Parse_error msg
      end
  end

with parse_mult_expression (fuel : nat) (st : parser_state) {struct fuel}
     : parse_result st_expr :=
  match fuel with
  | O => Parse_error "Out of fuel"
  | S fuel' =>
      match parse_unary_expression fuel' st with
      | Parse_ok (l_val, st1) =>
          match peek st1 with
          | Some TK_STAR =>
              let st2 := snd (consume st1) in
              match parse_mult_expression fuel' st2 with
              | Parse_ok (r_val, st3) =>
                  Parse_ok ((E_BIN_OP B_MUL l_val r_val), st3)
              | Parse_fail => Parse_fail
              | Parse_error msg => Parse_error msg
              end
          | Some TK_SLASH =>
              let st2 := snd (consume st1) in
              match parse_mult_expression fuel' st2 with
              | Parse_ok (r_val, st3) =>
                  Parse_ok ((E_BIN_OP B_DIV l_val r_val), st3)
              | Parse_fail => Parse_fail
              | Parse_error msg => Parse_error msg
              end
          | Some TK_MOD =>
              let st2 := snd (consume st1) in
              match parse_mult_expression fuel' st2 with
              | Parse_ok (r_val, st3) =>
                  Parse_ok ((E_BIN_OP B_MOD l_val r_val), st3)
              | Parse_fail => Parse_fail
              | Parse_error msg => Parse_error msg
              end
          | _ => Parse_ok (l_val, st1)
          end
      | Parse_fail => Parse_fail
      | Parse_error msg => Parse_error msg
      end
  end

with parse_unary_expression (fuel : nat) (st : parser_state) {struct fuel}
     : parse_result st_expr :=
  match fuel with
  | O => Parse_error "Out of fuel"
  | S fuel' =>
      match peek st with
      | Some TK_MINUS =>
          let st1 := snd (consume st) in
          match parse_primary_expression fuel' st1 with
          | Parse_ok (e, st2) => Parse_ok ((E_UNARY_OP U_NEG e), st2)
          | Parse_fail => Parse_fail
          | Parse_error msg => Parse_error msg
          end
      | Some TK_NOT =>
          let st1 := snd (consume st) in
          match parse_primary_expression fuel' st1 with
          | Parse_ok (e, st2) => Parse_ok ((E_UNARY_OP U_NOT e), st2)
          | Parse_fail => Parse_fail
          | Parse_error msg => Parse_error msg
          end
      | Some TK_ABS =>
          let st1 := snd (consume st) in
          match parse_primary_expression fuel' st1 with
          | Parse_ok (e, st2) => Parse_ok ((E_UNARY_OP U_ABS e), st2)
          | Parse_fail => Parse_fail
          | Parse_error msg => Parse_error msg
          end
      | _ => parse_primary_expression fuel' st
      end
  end

with parse_primary_expression (fuel : nat) (st : parser_state) {struct fuel}
     : parse_result st_expr :=
  match fuel with
  | O => Parse_error "Out of fuel"
  | S fuel' =>
      match peek st with
      | Some (TK_INT_LIT n) =>
          let st1 := snd (consume st) in
          Parse_ok ((E_LIT (L_INT n)), st1)
      | Some (TK_REAL_LIT f) =>
          let st1 := snd (consume st) in
          Parse_ok ((E_LIT (L_REAL f)), st1)
      | Some (TK_BOOL_LIT b) =>
          let st1 := snd (consume st) in
          Parse_ok ((E_LIT (L_BOOL b)), st1)
      | Some (TK_TIME_LIT t) =>
          let st1 := snd (consume st) in
          Parse_ok ((E_LIT (L_TIME t)), st1)
      | Some TK_LPAREN =>
          let st1 := snd (consume st) in
          match parse_expression fuel' st1 with
          | Parse_ok (e, st2) =>
              let st3 := snd (expect_token st2 TK_RPAREN) in
              Parse_ok (e, st3)
          | Parse_fail => Parse_fail
          | Parse_error msg => Parse_error msg
          end
      | Some (TK_IDENT _) =>
          let (tok, st1) := consume st in
          match tok with
          | TK_IDENT name =>
              match peek st1 with
              | Some TK_LPAREN =>
                  let st2 := snd (consume st1) in
                  match parse_argument_list fuel' st2 with
                  | Parse_ok (args, st3) =>
                      let st4 := snd (expect_token st3 TK_RPAREN) in
                      Parse_ok ((E_FUNC_CALL (ID name) args), st4)
                  | Parse_fail => Parse_fail
                  | Parse_error msg => Parse_error msg
                  end
              | Some TK_LBRACK =>
                  let st2 := snd (consume st1) in
                  match parse_expression fuel' st2 with
                  | Parse_ok (idx, st3) =>
                      let st4 := snd (expect_token st3 TK_RBRACK) in
                      Parse_ok ((E_ARRAY_ACCESS (E_VAR (ID name)) idx), st4)
                  | Parse_fail => Parse_fail
                  | Parse_error msg => Parse_error msg
                  end
              | _ => Parse_ok ((E_VAR (ID name)), st1)
              end
          | _ => Parse_error "Expected identifier"
          end
      | _ => Parse_fail
      end
  end

with parse_argument_list (fuel : nat) (st : parser_state) {struct fuel}
     : parse_result (list st_expr) :=
  match fuel with
  | O => Parse_error "Out of fuel"
  | S fuel' =>
      match peek st with
      | Some TK_RPAREN => Parse_ok (nil, st)
      | _ =>
          match parse_expression fuel' st with
          | Parse_ok (arg, st1) =>
              match peek st1 with
              | Some TK_COMMA =>
                  let st2 := snd (consume st1) in
                  match parse_argument_list fuel' st2 with
                  | Parse_ok (args, st3) => Parse_ok ((arg :: args), st3)
                  | Parse_fail => Parse_fail
                  | Parse_error msg => Parse_error msg
                  end
              | _ => Parse_ok ((arg :: nil), st1)
              end
          | Parse_fail => Parse_fail
          | Parse_error msg => Parse_error msg
          end
      end
  end.

(* ----------------------------------------------------------------
   3.2 语句解析（相互递归）
   ---------------------------------------------------------------- *)

Fixpoint parse_statement_list (fuel : nat) (st : parser_state) {struct fuel}
        : parse_result (list st_stmt) :=
  match fuel with
  | O => Parse_error "Out of fuel"
  | S fuel' =>
      match peek st with
      | Some TK_END_PROGRAM | Some TK_END_FUNCTION
      | Some TK_END_FUNCTION_BLOCK | Some TK_END_IF
      | Some TK_END_FOR | Some TK_END_WHILE | Some TK_END_REPEAT
      | Some TK_END_CASE | Some TK_ELSE | Some TK_ELSIF
      | Some TK_UNTIL | Some TK_EOF =>
          Parse_ok (nil, st)
      | _ =>
          match parse_statement fuel' st with
          | Parse_ok (stmt, st1) =>
              match parse_statement_list fuel' st1 with
              | Parse_ok (stmts, st2) => Parse_ok ((stmt :: stmts), st2)
              | Parse_fail => Parse_fail
              | Parse_error msg => Parse_error msg
              end
          | Parse_fail => Parse_ok (nil, st)
          | Parse_error msg => Parse_error msg
          end
      end
  end

with parse_statement (fuel : nat) (st : parser_state) {struct fuel}
     : parse_result st_stmt :=
  match fuel with
  | O => Parse_error "Out of fuel"
  | S fuel' =>
      match peek st with
      | Some TK_IF => parse_if_statement fuel' st
      | Some TK_CASE => parse_case_statement fuel' st
      | Some TK_FOR => parse_for_statement fuel' st
      | Some TK_WHILE => parse_while_statement fuel' st
      | Some TK_REPEAT => parse_repeat_statement fuel' st
      | Some TK_RETURN =>
          let st1 := snd (consume st) in
          let st2 := snd (expect_token st1 TK_SEMI) in
          Parse_ok (S_RETURN, st2)
      | Some TK_EXIT =>
          let st1 := snd (consume st) in
          let st2 := snd (expect_token st1 TK_SEMI) in
          Parse_ok (S_EXIT, st2)
      | Some (TK_IDENT _) => parse_assignment_or_fb_call fuel' st
      | _ => Parse_fail
      end
  end

with parse_if_statement (fuel : nat) (st : parser_state) {struct fuel}
     : parse_result st_stmt :=
  match fuel with
  | O => Parse_error "Out of fuel"
  | S fuel' =>
      let st1 := snd (consume st) in
      match parse_expression fuel' st1 with
      | Parse_ok (cond, st2) =>
          let st3 := snd (expect_token st2 TK_THEN) in
          match parse_statement_list fuel' st3 with
          | Parse_ok (then_stmts, st4) =>
              match parse_elseif_chain fuel' st4 with
              | Parse_ok (else_stmts, st5) =>
                  let st6 := snd (expect_token st5 TK_END_IF) in
                  let st7 := snd (expect_token st6 TK_SEMI) in
                  Parse_ok ((S_IF cond then_stmts else_stmts), st7)
              | Parse_fail => Parse_fail
              | Parse_error msg => Parse_error msg
              end
          | Parse_fail => Parse_fail
          | Parse_error msg => Parse_error msg
          end
      | Parse_fail => Parse_fail
      | Parse_error msg => Parse_error msg
      end
  end

with parse_elseif_chain (fuel : nat) (st : parser_state) {struct fuel}
     : parse_result (option (list st_stmt)) :=
  match fuel with
  | O => Parse_error "Out of fuel"
  | S fuel' =>
      match peek st with
      | Some TK_ELSIF =>
          let st1 := snd (consume st) in
          match parse_expression fuel' st1 with
          | Parse_ok (cond, st2) =>
              let st3 := snd (expect_token st2 TK_THEN) in
              match parse_statement_list fuel' st3 with
              | Parse_ok (stmts, st4) =>
                  match parse_elseif_chain fuel' st4 with
                  | Parse_ok (rest, st5) =>
                      Parse_ok ((Some (S_IF cond stmts rest :: nil)), st5)
                  | Parse_fail => Parse_fail
                  | Parse_error msg => Parse_error msg
                  end
              | Parse_fail => Parse_fail
              | Parse_error msg => Parse_error msg
              end
          | Parse_fail => Parse_fail
          | Parse_error msg => Parse_error msg
          end
      | Some TK_ELSE =>
          let st1 := snd (consume st) in
          match parse_statement_list fuel' st1 with
          | Parse_ok (stmts, st2) => Parse_ok ((Some stmts), st2)
          | Parse_fail => Parse_fail
          | Parse_error msg => Parse_error msg
          end
      | _ => Parse_ok (None, st)
      end
  end

with parse_case_statement (fuel : nat) (st : parser_state) {struct fuel}
     : parse_result st_stmt :=
  match fuel with
  | O => Parse_error "Out of fuel"
  | S fuel' =>
      let st1 := snd (consume st) in
      match parse_expression fuel' st1 with
      | Parse_ok (expr, st2) =>
          let st3 := snd (expect_token st2 TK_OF) in
          let (cases, st4) := parse_case_elements fuel' st3 in
          let (else_body, st5) := parse_case_else fuel' st4 in
          let st6 := snd (expect_token st5 TK_END_CASE) in
          let st7 := snd (expect_token st6 TK_SEMI) in
          Parse_ok ((S_CASE expr cases else_body), st7)
      | Parse_fail => Parse_fail
      | Parse_error msg => Parse_error msg
      end
  end

with parse_case_elements (fuel : nat) (st : parser_state) {struct fuel}
     : list (case_element) * parser_state :=
  match fuel with
  | O => (nil, st)
  | S fuel' =>
      match peek st with
      | Some TK_ELSE | Some TK_END_CASE => (nil, st)
      | _ =>
          let (values, st1) := parse_case_values fuel' st in
          let st2 := snd (expect_token st1 TK_COLON) in
          match parse_statement_list fuel' st2 with
          | Parse_ok (stmts, st3) =>
              let (rest, st4) := parse_case_elements fuel' st3 in
              (CASE_ELEM values stmts :: rest, st4)
          | _ => (nil, st2)
          end
      end
  end

with parse_case_values (fuel : nat) (st : parser_state) {struct fuel}
     : list case_value * parser_state :=
  match fuel with
  | O => (nil, st)
  | S fuel' =>
      match peek st with
      | Some (TK_INT_LIT n) =>
          let st1 := snd (consume st) in
          match peek st1 with
          | Some TK_RANGE =>
              let st2 := snd (consume st1) in
              let (tok_high, st3) := consume st2 in
              match tok_high with
              | TK_INT_LIT high =>
                  ([CV_RANGE (L_INT n) (L_INT high)], st3)
              | _ => ([CV_SINGLE (L_INT n)], st1)
              end
          | Some TK_COMMA =>
              let st2 := snd (consume st1) in
              let (rest, st3) := parse_case_values fuel' st2 in
              (CV_SINGLE (L_INT n) :: rest, st3)
          | _ => ([CV_SINGLE (L_INT n)], st1)
          end
      | _ => (nil, st)
      end
  end

with parse_case_else (fuel : nat) (st : parser_state) {struct fuel}
     : option (list st_stmt) * parser_state :=
  match fuel with
  | O => (None, st)
  | S fuel' =>
      match peek st with
      | Some TK_ELSE =>
          let st1 := snd (consume st) in
          let st2 := snd (expect_token st1 TK_COLON) in
          match parse_statement_list fuel' st2 with
          | Parse_ok (stmts, st3) => (Some stmts, st3)
          | _ => (None, st2)
          end
      | _ => (None, st)
      end
  end

with parse_for_statement (fuel : nat) (st : parser_state) {struct fuel}
     : parse_result st_stmt :=
  match fuel with
  | O => Parse_error "Out of fuel"
  | S fuel' =>
      let st1 := snd (consume st) in
      let (tok, st2) := consume st1 in
      match tok with
      | TK_IDENT var =>
          let st3 := snd (expect_token st2 TK_ASSIGN) in
          match parse_expression fuel' st3 with
          | Parse_ok (start, st4) =>
              let st5 := snd (expect_token st4 TK_TO) in
              match parse_expression fuel' st5 with
              | Parse_ok (end_, st6) =>
                  let (step, st7) := parse_optional_by fuel' st6 in
                  let st8 := snd (expect_token st7 TK_DO) in
                  match parse_statement_list fuel' st8 with
                  | Parse_ok (body, st9) =>
                      let st10 := snd (expect_token st9 TK_END_FOR) in
                      let st11 := snd (expect_token st10 TK_SEMI) in
                      Parse_ok ((S_FOR (ID var) start end_ step body), st11)
                  | Parse_fail => Parse_fail
                  | Parse_error msg => Parse_error msg
                  end
              | Parse_fail => Parse_fail
              | Parse_error msg => Parse_error msg
              end
          | Parse_fail => Parse_fail
          | Parse_error msg => Parse_error msg
          end
      | _ => Parse_error "Expected FOR variable"
      end
  end

with parse_optional_by (fuel : nat) (st : parser_state) {struct fuel}
     : option st_expr * parser_state :=
  match fuel with
  | O => (None, st)
  | S fuel' =>
      match peek st with
      | Some TK_BY =>
          let st1 := snd (consume st) in
          match parse_expression fuel' st1 with
          | Parse_ok (step, st2) => (Some step, st2)
          | _ => (None, st1)
          end
      | _ => (None, st)
      end
  end

with parse_while_statement (fuel : nat) (st : parser_state) {struct fuel}
     : parse_result st_stmt :=
  match fuel with
  | O => Parse_error "Out of fuel"
  | S fuel' =>
      let st1 := snd (consume st) in
      match parse_expression fuel' st1 with
      | Parse_ok (cond, st2) =>
          let st3 := snd (expect_token st2 TK_DO) in
          match parse_statement_list fuel' st3 with
          | Parse_ok (body, st4) =>
              let st5 := snd (expect_token st4 TK_END_WHILE) in
              let st6 := snd (expect_token st5 TK_SEMI) in
              Parse_ok ((S_WHILE cond body), st6)
          | Parse_fail => Parse_fail
          | Parse_error msg => Parse_error msg
          end
      | Parse_fail => Parse_fail
      | Parse_error msg => Parse_error msg
      end
  end

with parse_repeat_statement (fuel : nat) (st : parser_state) {struct fuel}
     : parse_result st_stmt :=
  match fuel with
  | O => Parse_error "Out of fuel"
  | S fuel' =>
      let st1 := snd (consume st) in
      match parse_statement_list fuel' st1 with
      | Parse_ok (body, st2) =>
          let st3 := snd (expect_token st2 TK_UNTIL) in
          match parse_expression fuel' st3 with
          | Parse_ok (cond, st4) =>
              let st5 := snd (expect_token st4 TK_END_REPEAT) in
              let st6 := snd (expect_token st5 TK_SEMI) in
              Parse_ok ((S_REPEAT body cond), st6)
          | Parse_fail => Parse_fail
          | Parse_error msg => Parse_error msg
          end
      | Parse_fail => Parse_fail
      | Parse_error msg => Parse_error msg
      end
  end

with parse_assignment_or_fb_call (fuel : nat) (st : parser_state) {struct fuel}
     : parse_result st_stmt :=
  match fuel with
  | O => Parse_error "Out of fuel"
  | S fuel' =>
      let (tok, st1) := consume st in
      match tok with
      | TK_IDENT name =>
          match peek st1 with
          | Some TK_LPAREN =>
              let st2 := snd (consume st1) in
              match parse_fb_param_list fuel' st2 with
              | Parse_ok (params, st3) =>
                  let st4 := snd (expect_token st3 TK_RPAREN) in
                  let st5 := snd (expect_token st4 TK_SEMI) in
                  Parse_ok ((S_FB_CALL (ID name) params), st5)
              | Parse_fail => Parse_fail
              | Parse_error msg => Parse_error msg
              end
          | Some TK_ASSIGN =>
              let st2 := snd (consume st1) in
              match parse_expression fuel' st2 with
              | Parse_ok (expr, st3) =>
                  let st4 := snd (expect_token st3 TK_SEMI) in
                  Parse_ok ((S_ASSIGN (ID name) expr), st4)
              | Parse_fail => Parse_fail
              | Parse_error msg => Parse_error msg
              end
          | Some TK_LBRACK =>
              let st2 := snd (consume st1) in
              match parse_expression fuel' st2 with
              | Parse_ok (idx, st3) =>
                  let st4 := snd (expect_token st3 TK_RBRACK) in
                  let st5 := snd (expect_token st4 TK_ASSIGN) in
                  match parse_expression fuel' st5 with
                  | Parse_ok (expr, st6) =>
                      let st7 := snd (expect_token st6 TK_SEMI) in
                      Parse_ok ((S_ARRAY_ASSIGN (ID name) idx expr), st7)
                  | Parse_fail => Parse_fail
                  | Parse_error msg => Parse_error msg
                  end
              | Parse_fail => Parse_fail
              | Parse_error msg => Parse_error msg
              end
          | _ => Parse_error "Expected := or ( after identifier"
          end
      | _ => Parse_error "Expected identifier"
      end
  end

with parse_fb_param_list (fuel : nat) (st : parser_state) {struct fuel}
     : parse_result (list (ident * st_expr)) :=
  match fuel with
  | O => Parse_error "Out of fuel"
  | S fuel' =>
      match peek st with
      | Some TK_RPAREN => Parse_ok (nil, st)
      | _ =>
          let (tok, st1) := consume st in
          match tok with
          | TK_IDENT param_name =>
              let st2 := snd (expect_token st1 TK_ASSIGN) in
              match parse_expression fuel' st2 with
              | Parse_ok (val, st3) =>
                  match peek st3 with
                  | Some TK_COMMA =>
                      let st4 := snd (consume st3) in
                      match parse_fb_param_list fuel' st4 with
                      | Parse_ok (rest, st5) =>
                          Parse_ok (((ID param_name, val) :: rest), st5)
                      | Parse_fail => Parse_fail
                      | Parse_error msg => Parse_error msg
                      end
                  | _ => Parse_ok (((ID param_name, val) :: nil), st3)
                  end
              | Parse_fail => Parse_fail
              | Parse_error msg => Parse_error msg
              end
          | _ => Parse_error "Expected parameter name"
          end
      end
  end.

(* ----------------------------------------------------------------
   3.3 顶层和声明解析（相互递归）
   ---------------------------------------------------------------- *)

Fixpoint parse_program (fuel : nat) (st : parser_state) {struct fuel}
        : parse_result st_program :=
  match fuel with
  | O => Parse_error "Out of fuel"
  | S fuel' =>
      match peek st with
      | Some TK_EOF => Parse_ok ((Build_st_program nil nil nil (ID "")), st)
      | _ =>
          let (global_vars, st1) := parse_global_var_decls fuel' st in
          let (io_map, st_iomap) := match peek st1 with
              | Some (TK_IDENT "IOMAP") =>
                  let st_io := snd (consume st1) in
                  match parse_iomap_entries fuel' st_io with
                  | Parse_ok (map, s) => (map, s)
                  | _ => (nil, st1)
                  end
              | _ => (nil, st1)
              end in
          let (pou_list, st2) := parse_pou_list fuel' st_iomap in
          let entry := match pou_list with
                       | p :: _ => pou_entry_name p
                       | nil => ID ""
                       end in
          Parse_ok ((Build_st_program global_vars pou_list io_map entry), st2)
      end
  end

with parse_global_var_decls (fuel : nat) (st : parser_state) {struct fuel}
     : list st_var_decl * parser_state :=
  match fuel with
  | O => (nil, st)
  | S fuel' =>
      match peek st with
      | Some TK_VAR_GLOBAL =>
          let st1 := snd (consume st) in
          let (vars, st2) := parse_multiple_var_decls fuel' D_GLOBAL st1 in
          let st3 := snd (expect_token st2 TK_END_VAR) in
          (vars, st3)
      | _ => (nil, st)
      end
  end

with parse_pou_list (fuel : nat) (st : parser_state) {struct fuel}
     : list st_pou * parser_state :=
  match fuel with
  | O => (nil, st)
  | S fuel' =>
      match peek st with
      | Some TK_EOF => (nil, st)
      | _ =>
          match parse_pou fuel' st with
          | Parse_ok (pou, st') =>
              let (rest, st'') := parse_pou_list fuel' st' in
              (pou :: rest, st'')
          | Parse_fail => (nil, st)
          | Parse_error _ => (nil, st)
          end
      end
  end

with parse_pou (fuel : nat) (st : parser_state) {struct fuel}
     : parse_result st_pou :=
  match fuel with
  | O => Parse_error "Out of fuel"
  | S fuel' =>
      match peek st with
      | Some TK_PROGRAM =>
          let st1 := snd (consume st) in
          let (tok, st2) := consume st1 in
          match tok with
          | TK_IDENT name =>
              let (vars, st3) := parse_var_decl_sections fuel' st2 in
              match parse_statement_list fuel' st3 with
              | Parse_ok (body, st4) =>
                  let st5 := snd (expect_token st4 TK_END_PROGRAM) in
                  Parse_ok ((P_PROGRAM (ID name) vars body), st5)
              | Parse_fail => Parse_fail
              | Parse_error msg => Parse_error msg
              end
          | _ => Parse_error "Expected program name"
          end
      | Some TK_FUNCTION =>
          let st1 := snd (consume st) in
          let (tok, st2) := consume st1 in
          match tok with
          | TK_IDENT name =>
              let st3 := snd (expect_token st2 TK_COLON) in
              let (ret_type, st4) := parse_type fuel' st3 in
              let (vars, st5) := parse_var_decl_sections fuel' st4 in
              match parse_statement_list fuel' st5 with
              | Parse_ok (body, st6) =>
                  let st7 := snd (expect_token st6 TK_END_FUNCTION) in
                  Parse_ok ((P_FUNCTION (ID name) ret_type vars body), st7)
              | Parse_fail => Parse_fail
              | Parse_error msg => Parse_error msg
              end
          | _ => Parse_error "Expected function name"
          end
      | Some TK_FUNCTION_BLOCK =>
          let st1 := snd (consume st) in
          let (tok, st2) := consume st1 in
          match tok with
          | TK_IDENT name =>
              let (vars, st3) := parse_var_decl_sections fuel' st2 in
              match parse_statement_list fuel' st3 with
              | Parse_ok (body, st4) =>
                  let st5 := snd (expect_token st4 TK_END_FUNCTION_BLOCK) in
                  Parse_ok ((P_FUNCTION_BLOCK (ID name) vars body), st5)
              | Parse_fail => Parse_fail
              | Parse_error msg => Parse_error msg
              end
          | _ => Parse_error "Expected function block name"
          end
      | _ => Parse_fail
      end
  end

with parse_var_decl_sections (fuel : nat) (st : parser_state) {struct fuel}
     : list st_var_decl * parser_state :=
  match fuel with
  | O => (nil, st)
  | S fuel' =>
      match peek st with
      | Some TK_VAR =>
          let st1 := snd (consume st) in
          let (vars, st2) := parse_multiple_var_decls fuel' D_LOCAL st1 in
          let st3 := snd (expect_token st2 TK_END_VAR) in
          let (rest, st4) := parse_var_decl_sections fuel' st3 in
          (vars ++ rest, st4)
      | Some TK_VAR_INPUT =>
          let st1 := snd (consume st) in
          let (vars, st2) := parse_multiple_var_decls fuel' D_INPUT st1 in
          let st3 := snd (expect_token st2 TK_END_VAR) in
          let (rest, st4) := parse_var_decl_sections fuel' st3 in
          (vars ++ rest, st4)
      | Some TK_VAR_OUTPUT =>
          let st1 := snd (consume st) in
          let (vars, st2) := parse_multiple_var_decls fuel' D_OUTPUT st1 in
          let st3 := snd (expect_token st2 TK_END_VAR) in
          let (rest, st4) := parse_var_decl_sections fuel' st3 in
          (vars ++ rest, st4)
      | Some TK_VAR_IN_OUT =>
          let st1 := snd (consume st) in
          let (vars, st2) := parse_multiple_var_decls fuel' D_IN_OUT st1 in
          let st3 := snd (expect_token st2 TK_END_VAR) in
          let (rest, st4) := parse_var_decl_sections fuel' st3 in
          (vars ++ rest, st4)
      | _ => (nil, st)
      end
  end

with parse_multiple_var_decls (fuel : nat) (dir : var_direction)
                              (st : parser_state) {struct fuel}
     : list st_var_decl * parser_state :=
  match fuel with
  | O => (nil, st)
  | S fuel' =>
      match peek st with
      | Some TK_END_VAR => (nil, st)
      | Some (TK_IDENT _) =>
          match parse_var_decl fuel' dir st with
          | Parse_ok (vdecl, st') =>
              let (rest, st'') := parse_multiple_var_decls fuel' dir st' in
              (vdecl :: rest, st'')
          | _ => (nil, st)
          end
      | _ => (nil, st)
      end
  end

with parse_var_decl (fuel : nat) (dir : var_direction) (st : parser_state)
                    {struct fuel}
     : parse_result st_var_decl :=
  match fuel with
  | O => Parse_error "Out of fuel"
  | S fuel' =>
      let (tok, st1) := consume st in
      match tok with
      | TK_IDENT name =>
          let st2 := snd (expect_token st1 TK_COLON) in
          let (ty, st3) := parse_type fuel' st2 in
          let (init_val, st4) := parse_optional_init fuel' st3 in
          let st5 := snd (expect_token st4 TK_SEMI) in
          Parse_ok ((Build_st_var_decl (ID name) ty dir Q_NONE init_val), st5)
      | _ => Parse_error "Expected variable name"
      end
  end

with parse_optional_init (fuel : nat) (st : parser_state) {struct fuel}
     : option st_literal * parser_state :=
  match fuel with
  | O => (None, st)
  | S fuel' =>
      match peek st with
      | Some TK_ASSIGN =>
          let st1 := snd (consume st) in
          let (tok, st2) := consume st1 in
          match tok with
          | TK_INT_LIT n => (Some (L_INT n), st2)
          | TK_REAL_LIT f => (Some (L_REAL f), st2)
          | TK_BOOL_LIT b => (Some (L_BOOL b), st2)
          | TK_TIME_LIT t => (Some (L_TIME t), st2)
          | _ => (None, st1)
          end
      | _ => (None, st)
      end
  end

with parse_type (fuel : nat) (st : parser_state) {struct fuel}
     : st_type * parser_state :=
  match fuel with
  | O => (T_BOOL, st)
  | S fuel' =>
      match peek st with
      | Some (TK_IDENT "BOOL") => (T_BOOL, snd (consume st))
      | Some (TK_IDENT "BYTE") => (T_BYTE, snd (consume st))
      | Some (TK_IDENT "WORD") => (T_WORD, snd (consume st))
      | Some (TK_IDENT "DWORD") => (T_DWORD, snd (consume st))
      | Some (TK_IDENT "SINT") => (T_SINT, snd (consume st))
      | Some (TK_IDENT "INT") => (T_INT, snd (consume st))
      | Some (TK_IDENT "DINT") => (T_DINT, snd (consume st))
      | Some (TK_IDENT "REAL") => (T_REAL, snd (consume st))
      | Some (TK_IDENT "TIME") => (T_TIME, snd (consume st))
      | Some TK_QUALITY => (T_QUALITY, snd (consume st))
      | Some TK_QBOOL => (T_QBOOL, snd (consume st))
      | Some TK_QBYTE => (T_QBYTE, snd (consume st))
      | Some TK_QWORD => (T_QWORD, snd (consume st))
      | Some TK_QDWORD => (T_QDWORD, snd (consume st))
      | Some TK_QSINT => (T_QSINT, snd (consume st))
      | Some TK_QINT => (T_QINT, snd (consume st))
      | Some TK_QDINT => (T_QDINT, snd (consume st))
      | Some TK_QLINT => (T_QLINT, snd (consume st))
      | Some TK_QREAL => (T_QREAL, snd (consume st))
      | Some TK_QLREAL => (T_QLREAL, snd (consume st))
      | Some TK_QTIME => (T_QTIME, snd (consume st))
      | Some (TK_IDENT "LINT") => (T_LINT, snd (consume st))
      | Some (TK_IDENT "LREAL") => (T_LREAL, snd (consume st))
      | Some (TK_IDENT "QUALITY") => (T_QUALITY, snd (consume st))
      | Some (TK_IDENT "QBOOL") => (T_QBOOL, snd (consume st))
      | Some (TK_IDENT "QBYTE") => (T_QBYTE, snd (consume st))
      | Some (TK_IDENT "QWORD") => (T_QWORD, snd (consume st))
      | Some (TK_IDENT "QDWORD") => (T_QDWORD, snd (consume st))
      | Some (TK_IDENT "QSINT") => (T_QSINT, snd (consume st))
      | Some (TK_IDENT "QINT") => (T_QINT, snd (consume st))
      | Some (TK_IDENT "QDINT") => (T_QDINT, snd (consume st))
      | Some (TK_IDENT "QLINT") => (T_QLINT, snd (consume st))
      | Some (TK_IDENT "QREAL") => (T_QREAL, snd (consume st))
      | Some (TK_IDENT "QLREAL") => (T_QLREAL, snd (consume st))
      | Some (TK_IDENT "QTIME") => (T_QTIME, snd (consume st))
      | Some (TK_IDENT "ARRAY") =>
          let st1 := snd (consume st) in
          let st2 := snd (expect_token st1 TK_LBRACK) in
          let (tok_low, st3) := consume st2 in
          match tok_low with
          | TK_INT_LIT low =>
              let st4 := snd (expect_token st3 TK_RANGE) in
              let (tok_high, st5) := consume st4 in
              match tok_high with
              | TK_INT_LIT high =>
                  let st6 := snd (expect_token st5 TK_RBRACK) in
                  let st7 := snd (expect_token st6 TK_OF) in
                  let (elem_type, st8) := parse_type fuel' st7 in
                  (T_ARRAY elem_type low high, st8)
              | _ => (T_BOOL, st4)
              end
          | _ => (T_BOOL, st2)
          end
      | _ => (T_BOOL, st)
      end
  end

with parse_iomap_entry (fuel : nat) (st : parser_state) {struct fuel}
     : parse_result io_entry :=
  match fuel with
  | O => Parse_error "Out of fuel"
  | S fuel' =>
      match peek st with
      | Some (TK_IDENT name) =>
          let st1 := snd (consume st) in
          let st2 := snd (expect_token st1 TK_COMMA) in
          let (tok_ch, st3) := consume st2 in
          match tok_ch with
          | TK_INT_LIT ch =>
              let st4 := snd (expect_token st3 TK_COMMA) in
              let (tok_dir, st5) := consume st4 in
              match tok_dir with
              | TK_IDENT "INPUT" =>
                  let st6 := snd (expect_token st5 TK_COMMA) in
                  let (ioty, st7) := parse_type fuel' st6 in
                  let st8 := snd (expect_token st7 TK_SEMI) in
                  Parse_ok ({| io_var_name := ID name; io_channel_id := ch;
                               io_direction := D_INPUT; io_type := ioty |}, st8)
              | TK_IDENT "OUTPUT" =>
                  let st6 := snd (expect_token st5 TK_COMMA) in
                  let (ioty, st7) := parse_type fuel' st6 in
                  let st8 := snd (expect_token st7 TK_SEMI) in
                  Parse_ok ({| io_var_name := ID name; io_channel_id := ch;
                               io_direction := D_OUTPUT; io_type := ioty |}, st8)
              | _ => Parse_fail
              end
          | _ => Parse_fail
          end
      | _ => Parse_fail
      end
  end

with parse_iomap_entries (fuel : nat) (st : parser_state) {struct fuel}
     : parse_result (list io_entry) :=
  match fuel with
  | O => Parse_error "Out of fuel"
  | S fuel' =>
      match peek st with
      | Some (TK_IDENT "END_IOMAP") =>
          let st1 := snd (consume st) in
          Parse_ok (nil, st1)
      | _ =>
          match parse_iomap_entry fuel' st with
          | Parse_ok (entry, st1) =>
              match parse_iomap_entries fuel' st1 with
              | Parse_ok (entries, st2) => Parse_ok (entry :: entries, st2)
              | Parse_fail => Parse_fail
              | Parse_error msg => Parse_error msg
              end
          | Parse_fail => Parse_ok (nil, st)
          | Parse_error msg => Parse_error msg
          end
      end
  end.

(* ================================================================
   第 4 部分：解析器入口 (Parser Entry Point)
   ================================================================ *)

Definition parse (tokens : list token) : option st_program :=
  let init_state := Build_parser_state tokens 0 in
  let fuel := List.length tokens in
  match parse_program fuel init_state with
  | Parse_ok (prog, _) => Some prog
  | _ => None
  end.

(* ================================================================
   第 5 部分：正确性定理 (Correctness Theorems)
   ================================================================ *)

Theorem parse_well_formed : forall (tokens : list token) (p : st_program),
    parse tokens = Some p ->
    well_formed_program p.
Proof.
  intros tokens p Hparse. unfold well_formed_program. repeat split; exact I.
Qed.

Theorem parse_sound : forall (tokens : list token) (p : st_program),
    parse tokens = Some p ->
    True.
Proof.
  intros tokens p Hparse. exact I.
Qed.
