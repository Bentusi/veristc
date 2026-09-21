(* p05: 布尔 XOR + 算术法位抽取。
   注：T_And/T_Or/T_Xor 形式规则仅接受 BOOL 操作数——WORD 位与在实编译管线
   不可用（safeasm-spec 声明支持、类型规则未放行，矛盾记录见 README）；
   工程惯用 / MOD 做位域抽取。ABS 因 LOCAL_SET 255 越界静默丢弃，另立项。 *)
PROGRAM MAIN
VAR
  tick : DINT;
  x : DINT;
  b : BOOL;     (* BOOL 域 XOR；BOOL→DINT 赋值被类型检查器拒绝 *)
  v : DINT;
  hi : DINT;
  lo : DINT;
  c : BOOL;
END_VAR
  tick := CycleCounter();
  x := tick * 3;
  b := (x > 5) XOR (12 > 8);
  v := tick * 65536 + 4096;
  hi := (v / 256) MOD 256;
  lo := v MOD 256;
  c := b AND (hi = 16);
  PRINT('p05 b=', b, ' hi=', hi, ' lo=', lo, ' c=', c, '\n');
END_PROGRAM
