(* ================================================================
   qualified_access_field.st -- IEC 点号访问 + 派生名不可书写 e2e

   验证 v1.5.1 两项改动在同一程序里共存且互不干扰：
     1) inst.field（此处 l1.Q）由 parser 就地融合为内部派生名 l1#Q，
        与 expand_instances 生成的扁平全局逐字一致 ⇒ 调用方可以按
        IEC 写法只读实例输出，无需再手写 a1_Q 这类扁平名；
     2) 分隔符 '#' 不在标识符文法（字母 (字母|数字|_)*）内 ⇒ 派生名
        不可书写：用户既写不出 l1#Q（词法即报错），也不能拿它冒充
        自己声明的名字。同名风格的扁平全局 l1_Q 因此只是一个普通变量。

   语义：
     l1 : LATCH，体内 C := C + 1（私有状态）、Q := K + 1（输出）
     tick = CycleCounter(): 1,2,3,...
     l1(K := tick)          ⇒ l1.Q  = tick + 1
     l1_Q := 100 * tick     ⇒ 用户全局，与实例字段无关
   ⇒ PRINT 输出 (tick, l1_Q, l1.Q)
        t=1 → 1, 100, 2    t=2 → 2, 200, 3    t=4 → 4, 400, 5
   两条轨迹同步而不合并 ⇒ 名字空间已分离。
   反向用例（写 l1.Q / 读 l1.C）见 negative/qualified_*.st。
   ================================================================ *)

VAR_GLOBAL
  l1 : LATCH;
  l1_Q : DINT;
END_VAR

FUNCTION_BLOCK LATCH
VAR_INPUT
  K : DINT;
END_VAR
VAR_OUTPUT
  Q : DINT;
END_VAR
VAR
  C : DINT;
END_VAR
  C := C + 1;
  Q := K + 1;
END_FUNCTION_BLOCK

PROGRAM MAIN
VAR
  tick : DINT;
END_VAR
  tick := CycleCounter();
  l1(K := tick);
  l1_Q := 100 * tick;
  PRINT('tick', tick, l1_Q, l1.Q);
END_PROGRAM
