(* p08 [XFAIL-后端缺口]: LINT 64 位算术。
   spec 要求 I64_ADD/I64_DIV_S/I64_CMP；当前后端全部 I32 截断。
   判据用"除以 1e9 后是否等于 6"：I32 截断路径下 (a+b) mod 2^32 是环同态，
   大小比较两侧同余截断仍为真（弱判据）；除法不保持同余，能区分 64 位与
   截断路径（截断: 1705032704/1000000000 = 1 ≠ 6）。期望 ok=1。 *)
PROGRAM MAIN
VAR
  big : LINT;
  sum : LINT;
  scale : LINT;
  ok : DINT;
END_VAR
  big := 3000000000;
  sum := big + big;
  scale := sum / 1000000000;
  ok := 0;
  IF scale = 6 THEN
    ok := 1;
  END_IF;
  PRINT('p08 ok=', ok, '\n');
END_PROGRAM
