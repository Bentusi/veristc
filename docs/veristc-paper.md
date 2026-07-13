---
title: "VeriSTC: 基于形式化验证的高可信工业控制编译器——语言剪裁、影子类型与双重语义模拟"
author: "蒋伟"
date: "2026-07"
---

# VeriSTC: 基于形式化验证的高可信工业控制编译器——语言剪裁、影子类型与双重语义模拟

## 摘要

在安全级工业控制领域（核电站保护系统、航空发动机控制、轨道交通信号联锁），所有程序执行必须在编译期可预测,所有安全属性必须可形式化证明。然而,当前工业界广泛使用的 IEC 61131-3 Structured Text (ST) 语言包含指针、动态内存、递归和非确定性循环等构造,不具备形式化验证所需的静态可决策性基础。现有的安全子集方案(如 PLCopen Safety)依赖经验规则而非形式化语义,无法提供从源代码到字节码的可追溯保证。

本文提出 **VeriSTC** (Verified ST Compiler),一个将 IEC 61131-3 ST 安全子集编译为 SafeASM 字节码的编译器,其全部核心实现在 Coq 定理证明器中完成并附带形式化正确性证明。本文的理论贡献体现在四个方面。其一,提出语言剪裁的形式化判据 P1-P4，即安全关键适配、静态可决策性、形式化可建模与 WCET 可计算，作为从工业语言中系统性地提取安全子集的通用方法论,并证明满足这四条原则的语言是语义无空洞的。其二,针对安全级设备的关键应用需求,将 Q*类型质量位传递提升为一等类型,给出其类型规则和代数性质：质量码构成交换半格 $(Q, \sqcap, \sqcup)$,编译器自动推导质量传播,从而将运行时诊断提升为编译期类型约束。其三,证明固定宽度编码是 WCET 静态可计算性的充分条件,并给出从指令编码长度到最差执行时间的闭式表达式。其四,在 Coq 中构造 SafeST 小步语义到 SafeASM 小步语义的模拟关系 $\mathcal{R}$,证明 $step_{ST}$ 与 $step_{ASM}^*$ 之间的精模拟关系,为控制逻辑源代码到执行字节码之间的信任链提供数学基础。

**关键词**:形式化验证;编译器正确性;IEC 61131-3;安全关键系统;Coq;WCET

## 1 引言:安全关键软件的信任基础

### 1.1 信任的演进

安全级仪控系统（核电站的反应堆保护系统、航空发动机的全权限数字控制器、轨道交通的信号联锁系统）共同面临一个根本性问题:**我们凭什么信任一段代码在运行时会做出正确的决策?** 对这个问题的回答,工程实践经历了三个阶段的演进。最早的回答是测试:通过构造尽可能多的输入场景来观察输出是否符合预期。但测试只能证明错误的存在,无法证明错误的不存在(Dijkstra, 1972)。对于安全关键系统而言,输入空间通常是连续的或是组合爆炸的,测试覆盖率永远无法达到百分之百。于是有了第二阶段的回答：静态分析，通过工具扫描代码,检查数组越界、除零、空指针等常见缺陷。这比测试前进了一步,但静态分析工具本身依赖一组经验规则，这些规则是否完备、是否与语言的语义精确对应，通常缺乏数学上的保证。更根本地,Rice 定理指出,对于任何非平凡的程序属性,不存在通用的算法可以在所有程序上判定该属性，这意味着任何静态分析工具要么是不完备的（漏报）,要么是不可判定的(不终止),要么是过度近似的(误报)。第三阶段的回答是形式化验证。Coq、Isabelle/HOL 等定理证明器允许将"程序的行为符合规范"这一命题写成数学定理,并用机器检查的证明来确认它。CompCert 编译器[1]的成功证明了一条清晰的路径:如果能够证明编译器的每一步变换都保持源程序的语义,那么从源代码到机器码的整条信任链就得到了数学上的保障。

### 1.2 CompCert 范式的前提条件与工业困境

然而，CompCert 的成功隐含了一个关键的前提条件：**源语言本身必须是可形式化的**。C 语言虽然被广泛使用,但其标准（ISO/IEC 9899）中仍然存在大量**未定义行为**（undefined behavior）——带符号整数溢出、指针别名（pointer aliasing）、序列点违规（sequence point violation）——这些语义空洞（semantic holes）使得程序的行为在编译期无法被唯一确定。CompCert 证明的是"如果源程序没有未定义行为,那么编译后的代码等价于源程序",但"谁来判断源程序有没有未定义行为"本身就是一个信任问题，因为这需要额外的静态分析工具，而这些工具的完备性又是一个新的信任链条断裂点。

这个困境在高安全等级工业控制领域变得更加尖锐。IEC 61131-3 Structured Text (ST) 是工业控制领域唯一的国际标准编程语言,但它继承了通用编程语言的所有复杂性（指针、递归、动态内存、函数重载、面向对象），此外还增加了领域特有的复杂性（SFC 的步进语义、直接地址访问、多任务配置）。这些构造中的每一个都在语言的形式化语义中留下了一个空洞。一个编译器可以正确地编译一段包含指针别名的 ST 程序,但那段程序运行时可能因竞态条件产生非确定性的行为：编译器正确，程序仍然不安全。

### 1.3 核心论点:安全是设计出来的

由此引出本文的核心论点:**安全不是加出来的,而是设计出来的(Safety by Design)。** 不能在语言设计阶段保留非确定性构造,然后期望通过编译器或运行时检查来弥补。必须在语言层面就消除语义空洞，保留工程必需的表达能力，剪裁一切破坏形式化可建模性的特性,使得每一条程序的执行轨迹在编译期就是唯一确定的路径。

这一论点有一个直接的数学推论:语言的形式化可验证性(formal verifiability)是编译器形式化验证的**前置条件**而非**后置结果**。用逻辑蕴涵的语言表述:

$$\text{CompilerCorrect}(C) \land \text{LanguageSound}(\mathcal{L}) \not\Rightarrow \text{ProgramSafe}(P_C)$$

其中 $P_C$ 是由编译器 $C$ 编译 $P$ 得到的代码。这个蕴涵之所以不成立,是因为 $\text{LanguageSound}(\mathcal{L})$ 只保证了编译器行为的一致性和可推断性,但并未保证源语言本身不存在语义空洞：它不能排除从 $P$ 可以产生多个合法运行时行为 $\{b_1, b_2, \ldots, b_k\}$ 的可能性,其中某些行为 $b_i$ 是不安全的。只有在源语言 $\mathcal{L}$ 本身满足**语义确定性**(定义 1,第 2 节)的条件下,才能建立完整的信任链。

这个系统性的剪裁过程,就是 **SafeST** 语言的设计本质。在这个方向上,PLCopen Safety 规范[2]已经做了有益的尝试：它定义了一个 IEC 61131-3 的安全关键子集,禁止了指针、递归、动态内存等特性。但它的禁止方式是基于经验规则,而非形式化语义。它告诉我们"不要使用指针",却没有回答"为什么指针是不安全的",以及"排除指针之后,语言的形式化性质是什么"。因此,PLCopen 的安全认证依赖于厂商实现的具体测试,而非数学证明。

**VeriSTC 项目的出发点正是填补这一空白。** 我们不满足于"禁止不安全特性",而是提出一套系统的形式化剪裁方法论,从 IEC 61131-3 的完整语言中提取出一个语义无空洞的子集 SafeST,并在 Coq 中为这个子集构造了完整的小步操作语义。更进一步,VeriSTC 设计了配套的 SafeASM 字节码格式,采用固定宽度编码以保证 WCET 的静态可计算性,并在 Coq 中证明了 SafeST 到 SafeASM 的编译器正确性，即双重语义模拟。

### 1.4 本文的理论贡献

本文的理论贡献涵盖四个层面。第一是语言剪裁的形式化判据。传统的安全子集定义方式（以 PLCopen Safety 为代表）采用的是枚举式禁止，即逐条列出不可用的特性。这种方法虽然实用,但缺乏数学上的完备性保证：它告诉工程师"不要用指针"，却没有回答"指针破坏了语言的什么形式化性质"。本文提出四条原则 P1-P4,分别对应安全关键适配、静态可决策性、形式化可建模与 WCET 可计算,并证明满足这四条原则的语言是语义无空洞的(定理 2)。更重要的是,这四条原则构成了一个通用的方法论框架:每条原则均可形式化地证伪，对于任一违反原则的语言特性都可以构造反例来说明其不可接受性，因此不仅适用于 IEC 61131-3,也适用于 IEC 61499 功能块、IEC 61850 变电站自动化等其他工业语言的安全子集提取。

第二是影子类型理论。信号质量（传感器信号是可信、可疑、无效还是未连接）在工业控制中至关重要,但长期被当作运行时的诊断信息而非语言层面的一等实体来处理。传统做法中,质量检查通过显式调用 `Q_GOOD(x)` 等函数执行,质量传播依赖程序员手动维护，这种分离导致了两个根本性问题：不完备性(程序员可能忘记在某条信号路径上检查质量)和不可组合性(质量传播逻辑与控制逻辑交织在一起,难以独立推理)。本文提出的 Q*类型体系将质量提升为一等类型:质量码构成交换半格 $(Q, \sqcap, \sqcup)$,其中 $Q = \{GOOD, UNCERTAIN, BAD, NOT\_CONNECTED\}$,偏序 $\sqsubseteq$ 构成良基全序。编译器自动为半格上的每对元素推导 meet 和 join 运算,从而将质量传播从动态检查提升为编译期的静态类型推导。我们进一步证明质量传播函数 $\text{worst}$ 在偏序 $\sqsubseteq$ 下是单调的(定理 3),这保证了质量推理的可组合性，即对子表达式的质量改进不会降低整体表达式的质量。

第三是固定宽度编码与 WCET 可计算性的理论关联。对于实时安全系统而言,最差执行时间的可计算性是一个非功能性的但关键的约束。本文证明固定宽度编码是 WCET 静态可计算性的充分条件。设指令集 $\mathcal{I}$ 上的编码函数 $\mathcal{E}: \mathcal{I} \to \{0,1\}^*$ 满足 $\forall i \in \mathcal{I}, |\mathcal{E}(i)| = c$（常数 $c$），则任意指令序列 $s = i_1 i_2 \ldots i_n$ 的执行时间满足：

$$T_{WCET}(s) = n \cdot t_{\text{fetch}}(c) + \sum_{j=1}^{n} t_{\text{exec}}(i_j)$$

其中 $t_{\text{fetch}}(c)$ 是取指时间,$t_{\text{exec}}(i_j)$ 是指令 $i_j$ 的执行时间。由于 $c$ 和 $t_{\text{exec}}(i_j)$ 均在编译期确定,$T_{WCET}(s)$ 可静态计算。这一结果不仅适用于 SafeASM,也对任何面向实时安全系统的字节码设计具有指导意义。

第四是双重语义模拟证明。编译器正确性的核心在于证明源语言和目标语言的执行语义之间存在模拟关系。我们在 Coq 中构造了 SafeST 小步语义到 SafeASM 小步语义的模拟关系 $\mathcal{R} \subseteq \Sigma_{ST} \times \Sigma_{ASM}$,并证明了 $step_{ST}$ 与 $step_{ASM}^*$ 之间的精模拟关系:

$$\forall \sigma_s, \sigma_s' \in \Sigma_{ST}, \tau_s \in \Sigma_{ASM} \cdot \big( \sigma_s \xrightarrow{ST} \sigma_s' \land \mathcal{R}(\sigma_s, \tau_s) \big) \Rightarrow \exists \tau_s' \in \Sigma_{ASM} \cdot \tau_s \xrightarrow{ASM}^* \tau_s' \land \mathcal{R}(\sigma_s', \tau_s')$$

这一证明为从控制工程师书写的控制逻辑代码到最终执行的字节码之间的整条信任链提供了数学基础。证明采用结构归纳法,对 $step_{ST}$ 的每种推导情形分别构造对应的 SafeASM 指令序列,并通过 `compile_expr_correct` 和 `compile_stmt_correct` 两个核心引理完成正确性论证。

### 1.5 论文组织

后续各节的安排如下。第 2 节形式化地定义安全级编程语言的语义要求,包括语义确定性和语义空洞的概念,并证明 WCET 可计算性的三个充分条件及其不可弥补性。第 3 节提出 P1-P4 四条剪裁判据及其形式化定义,证明剪裁完备性定理,并以指针为例展示如何在这四条原则的框架下对语言特性进行逐条判断。第 4 节阐述影子类型体系的理论基础,从质量传播的传统问题出发,依次建立质量半格的代数结构、Q*类型的定义与类型规则,以及影子内存的编译实现方案。第 5 节给出 SafeASM 字节码的形式化设计,重点论述固定宽度编码的逻辑动机及其与 WCET 可计算性之间的理论关联。第 6 节呈现双重语义模拟关系的构造过程，包括源语言和目标语言的小步语义定义、抽象关系的构造，以及核心定理的 Coq 证明策略。第 7 节讨论类型安全定理的进展与保持性质。第 8 节将本文工作与 CompCert、PLCopen Safety、现有 WCET 分析方法以及质量语义的相关研究进行系统性比较。第 9 节讨论方法的普适性与当前工作的局限性,并展望后续研究方向。

## 2 安全级编程语言的语义要求

在展开 SafeST 语言的具体设计之前,有必要首先建立安全级编程语言所必须满足的语义基础。与传统通用编程语言不同,安全关键系统中的程序执行必须具有数学可证明的确定性：执行轨迹必须是唯一的，语义必须是无空洞的，最差执行时间必须是可计算的。这三条性质并非正交的,它们之间存在内在的逻辑依赖关系:语义确定性是 WCET 可计算性的充分条件,而语义无空洞性又是语义确定性的具体体现。本节将形式化地定义这三条性质,并以此作为后续各节中语言剪裁、类型设计和字节码编码的理论依据。

### 2.1 执行轨迹的确定性

安全级程序 $P$ 的执行可模型化为状态空间上的轨迹序列:

$$\Pi(P) = \langle s_0, s_1, \ldots, s_n \rangle, \quad s_i \in \mathcal{S}$$

其中 $\mathcal{S}$ 是程序状态空间,$s_0$ 是初始状态,$s_{i+1} = \delta(s_i, P)$ 是转移函数。安全关键系统要求 $\Pi(P)$ 是确定性的，即对于给定的 $s_0$ 和 $P$，$\Pi(P)$ 被唯一确定。

**定义 1(语义确定性)。**语言 $\mathcal{L}$ 是语义确定性的,当且仅当对于任意程序 $P \in \mathcal{L}$ 和任意初始状态 $s_0$,转移函数 $\delta_{\mathcal{L}}$ 是一个函数:

$$\forall s \in \mathcal{S} \cdot |\{\delta_{\mathcal{L}}(s, P)\}| \leq 1$$

语义确定性是安全验证可计算性的前提。若 $\delta_{\mathcal{L}}$ 不是函数(即存在 $s$ 使得从 $s$ 出发有多于一个后继状态),则 $\Pi(P)$ 不是单一轨迹而是一棵树,导致状态空间爆炸：在数学上表现为时序逻辑模型检测的复杂度从 $\mathsf{P}$ 上升为 $\mathsf{PSPACE}$-complete，在工程上表现为 WCET 分析从可计算退化为不可判定问题。

### 2.2 语义空洞:形式化描述

语言的形式化语义通常通过一组规则 $\mathcal{R} = \{r_1, \ldots, r_m\}$ 定义。如果存在一个程序状态 $s$ 使得没有规则 $r \in \mathcal{R}$ 可以确定唯一的后继状态,则称该语言在状态 $s$ 处存在**语义空洞**。

**定义 2(语义空洞)。**设语言 $\mathcal{L}$ 的操作语义由关系 $\xrightarrow{\mathcal{L}} \subseteq \mathcal{S} \times \mathcal{S}$ 定义。对于状态 $s \in \mathcal{S}$,若:

$$\nexists s' \in \mathcal{S} \cdot s \xrightarrow{\mathcal{L}} s' \quad \lor \quad |\{s' | s \xrightarrow{\mathcal{L}} s'\}| > 1$$

则称 $s$ 是语义空洞。语言 $\mathcal{L}$ 的语义空洞率定义为:

$$\Phi(\mathcal{L}) = \frac{|\{s \in \mathcal{S} | s \text{ 是语义空洞}\}|}{|\mathcal{S}|}$$

在安全关键系统中,要求 $\Phi(\mathcal{L}) = 0$。

IEC 61131-3 ST 语言的语义空洞主要来源于四类构造。指针与别名是最典型的情形。设 $p$ 为指针变量,$\text{Al}(\sigma, p)$ 为状态 $\sigma$ 下 $p$ 的可能指向集合,则转移 $\delta_{\text{ST}}(s, *p := v)$ 在 $|\text{Al}(\sigma, p)| > 1$ 时产生 $|\text{Al}(\sigma, p)|$ 个可能的后继状态,因为 $*p$ 的更新位置在编译期无法唯一确定;当 $\text{Al}(\sigma, p) = \emptyset$ 时,$\delta_{\text{ST}}$ 甚至无定义。动态分配则是另一类语义空洞：$\delta_{\text{ST}}(s, \text{new}(T))$ 的结果依赖运行时堆状态（堆管理器的分配策略、当前碎片化程度、垃圾回收时机），均在编译期不可预测,即使假定确定性分配算法,空闲链表的布局本身也是执行历史敏感的,无法在单条转移规则中确定后继。非终止循环则构成第三类语义空洞:$\delta_{\text{ST}}(s, \text{WHILE TRUE DO } B)$ 在任意有限步后均无终止状态,即使循环体 $B$ 本身是语义确定性的,循环的不可终止性使得 $\Pi(P)$ 无限长，$T_{WCET}(P)$ 无定义，这在数学上等价于停机问题的否命题。第四类是多任务竞态:设 $\text{TASK}_1$ 和 $\text{TASK}_2$ 共享变量 $v$,在交织语义下,$\delta_{\text{ST}}(s, \text{TASK}_1 \parallel \text{TASK}_2)$ 后继状态的数量等于两个任务指令序列的交织数 $\binom{|\text{TASK}_1| + |\text{TASK}_2|}{|\text{TASK}_1|}$,随程序长度指数增长。

### 2.3 WCET 可计算性的充分条件

**定理 1(WCET 可计算性)**。如果语言 $\mathcal{L}$ 同时满足三个条件：$\mathcal{L}$ 是语义确定性的（定义 1），所有循环的终止性在编译期可判定，且所有指令的执行时间在编译期可界定，则 $\mathcal{L}$ 中任意程序 $P$ 的最差执行时间 $T_{WCET}(P)$ 是可计算的。

**证明(概要)**。语义确定性保证执行轨迹 $\Pi(P) = \langle s_0, s_1, \ldots, s_n \rangle$ 是唯一的线性序列而非树状分支结构;循环终止性的可判定性保证轨迹长度 $|\Pi(P)| = n$ 有上界;每条指令执行时间的可界定性保证每一步的时间上界 $t_{\max}(s_i)$ 存在。因此 $T_{WCET}(P) = \sum_{i=0}^{n-1} t_{\max}(s_i)$ 为有限项之和的可计算表达式。$\square$

上述三个条件是 WCET 可计算性的充分条件,且不满足其中任何一条都会导致 WCET 分析从可计算退化为不可判定。这三个条件的满足无法通过验证来弥补。如果一个语言在设计上不满足它们，任何编译器或运行时系统都无法使其 WCET 可计算。这正是 SafeST 必须在语言设计阶段而非实现阶段确保这些性质的数学原因。

## 3 SafeST:安全子集的形式化剪裁

上一节建立了安全级编程语言的语义要求。然而,从工业标准的完整语言到满足这些要求的安全子集,需要一套系统性的方法论来指导"保留什么、剪裁什么"的决策。本节提出基于四条形式化判据的剪裁框架 P1-P4,证明该框架的完备性,并以指针、动态内存、递归等具体语言特性为例展示如何在这一框架下进行剪裁决策。最后给出 SafeST 保留的类型系统及其提升规则。

### 3.1 剪裁判据

SafeST 的形式化剪裁基于四条原则,每条原则对应一个可证伪的形式化条件。第一条原则 P1(安全关键适配)要求:语言特性 $f$ 被包含当且仅当存在至少一个安全关键应用的用例 $U_f$,使得 $U_f$ 无法在不引入额外运行时开销(如运行时检查、动态绑定、二阶段执行)的条件下用现有特性表达。形式化地,令 $\mathcal{F}$ 为语言特性全集,$\text{Expr}(\mathcal{F}_0)$ 为特性子集 $\mathcal{F}_0 \subseteq \mathcal{F}$ 的表达能力,则 $\text{Include}(f)$ 当且仅当 $U_f \notin \text{Expr}(\mathcal{F} \setminus \{f\})$ 且不存在运行时开销更小的替代特性。

第二条原则 P2(静态可决策性)要求:语言特性 $f$ 的所有属性（包括类型、边界、终止性）必须在编译期可判定。形式化地,对于任意关于 $f$ 的判定问题 $P_f: \text{Program} \to \{\top, \bot\}$,$P_f$ 必须是可计算的，即存在图灵机 $M_f$，使得对于任意程序 $P$，$M_f(P)$ 在有限步内停机并输出正确结果。

第三条原则 P3(形式化可建模)要求:语言特性 $f$ 必须存在一个 Coq 归纳类型 $T_f$ 和一组 Coq 函数 $F_f$,使得 $T_f$ 精确对应 $f$ 的抽象语法,$F_f$ 精确对应 $f$ 的操作语义。形式化地,必须存在语义保持的双射对 $\text{Syntax}_f \xleftrightarrow{b_f} T_f$ 和 $\text{Semantics}_f \xleftrightarrow{s_f} F_f$,其中 $b_f$ 是语法构造到 Coq 归纳类型的双射,$s_f$ 是操作语义到 Coq 函数的满射。

第四条原则 P4(WCET 可计算)要求:包含特性 $f$ 的任意程序 $P$ 的 WCET 必须在编译期可计算。形式化地,存在算法 $A_f$ 使得对于任意 $P$ 中出现的 $f$,$A_f(P)$ 在有限步内输出 $T_{WCET}(P) \in \mathbb{N}$。

**定理 2(剪裁完备性)**。如果语言 $\mathcal{L}$ 的所有特性都满足 P1-P4,则 $\Phi(\mathcal{L}) = 0$,即 $\mathcal{L}$ 是语义无空洞的。

**证明**。假设 $\mathcal{L}$ 的所有特性满足 P1-P4,但存在状态 $s \in \mathcal{S}$ 使得 $|\{ s' \mid s \xrightarrow{\mathcal{L}} s' \}| > 1$(非确定性)或 $\nexists s' \cdot s \xrightarrow{\mathcal{L}} s'$(未定义)。前者意味着存在某个特性 $f$ 的操作语义规则导致非确定性分支，但 P2 和 P4 联合排除了这种可能性，因为非确定性导致循环终止性不可判定（违反 P2）,且 WCET 不可计算(违反 P4)。后者意味着存在某个特性 $f$ 在某些输入下没有定义后继状态，但 P3 要求 $f$ 在 Coq 中有全函数（Coq 中所有函数是全的）的操作语义模型，因此不存在未定义状态。$\square$

### 3.2 剪裁决策的形式化依据

以指针特性为例,可以展示 P1-P4 框架下的形式化推理过程。从 P1(安全关键适配)的角度看,安全关键用例中不存在必须使用别名的场景。考察核电站保护系统的典型控制逻辑，如反应堆停堆逻辑 $S = \overline{(A \land B)} \lor C$ 中 $A, B, C$ 均为直接传感器变量,所有控制逻辑的输入输出均可通过符号变量名直接引用,完全不需要间接寻址。从 P2(静态可决策性)的角度看,指向分析（alias analysis）在最一般情况下是不可判定的。Landi (1992) 证明，即使对于过程间流敏感且上下文敏感的指向分析，其精确版本等价于停机问题,即不存在算法可以在有限步内判定任意两个指针变量是否可能指向同一内存位置。从 P3(形式化可建模)的角度看,指针的形式化模型需要一个偏序堆存储 $\text{Heap} = \text{Addr} \rightharpoonup \text{Value}$ 和分离逻辑(separation logic, Reynolds, 2002),其归纳定义和推理规则的复杂度远高于安全级程序的实际必要性。

类似地，动态内存、递归和 SFC 的排除均可在 P1-P4 框架下给出严格的形式化理由：动态内存违反 P2（运行时分配地址不可预测）和 P4（分配时间依赖堆状态），递归违反 P4（调用深度无静态上界），SFC 的步进语义违反 P3（状态转换的并发语义难以在 Coq 中建模为全函数）。

### 3.3 SafeST 的类型系统

SafeST 类型系统 $\mathcal{T}_{ST}$ 包含以下类型构造:

$$\tau ::= \text{BOOL} \mid \text{SINT} \mid \text{INT} \mid \text{DINT} \mid \text{LINT} \mid \text{BYTE} \mid \text{WORD} \mid \text{DWORD} \mid \text{REAL} \mid \text{LREAL} \mid \text{TIME}$$

类型间的隐式提升由偏序 $\preceq$ 定义:

$$\text{SINT} \preceq \text{INT} \preceq \text{DINT} \preceq \text{LINT}, \quad \text{BYTE} \preceq \text{WORD} \preceq \text{DWORD}, \quad \text{REAL} \preceq \text{LREAL}$$

类型提升函数 $\text{promote}(\tau_1, \tau_2)$ 返回 $\tau_1$ 和 $\tau_2$ 在 $\preceq$ 下的最小上界(least upper bound, join),若不存在则返回类型错误:

$$\text{promote}(\tau_1, \tau_2) = 
\begin{cases}
\text{lub}_{\preceq}(\tau_1, \tau_2), & \text{若 } \tau_1, \tau_2 \text{ 属于同一数系家族} \\
\bot, & \text{否则}
\end{cases}$$

其中数系家族分为三组:整数族 $\{\text{SINT}, \text{INT}, \text{DINT}, \text{LINT}\}$、位族 $\{\text{BYTE}, \text{WORD}, \text{DWORD}\}$、浮点族 $\{\text{REAL}, \text{LREAL}\}$。跨族提升被视为类型错误，这是安全关键系统的保守策略。

## 4 影子类型理论:Q*质量体系

在安全级工业控制系统中，传感器信号的可靠性信息（即信号质量）与信号数值本身同等重要。一个来自故障传感器的"正常"读数比一个来自健康传感器的"异常"读数更加危险。然而,IEC 61131-3 标准以及现有的安全子集方案均未将信号质量作为语言层面的一等概念加以处理,质量检查被留给程序员的显式函数调用,质量传播则依赖手工程序维护。本节提出影子类型理论,将质量维度嵌入类型系统,使得质量传播成为编译期自动推导的过程而非运行时可遗漏的检查。我们从质量码的代数结构出发,定义 Q*类型,给出质量传播的公理化规则,并设计影子内存布局作为其编译实现基础。

### 4.1 问题的形式化

工业控制系统中,传感器信号 $x$ 除了数值 $\text{val}(x) \in \mathbb{R}$ 外,还附带一个**质量状态** $\text{qual}(x) \in Q$。传统做法中,$\text{qual}$ 与 $\text{val}$ 是分离的:质量检查在代码中通过显式调用 $\text{Q\_GOOD}(x)$ 等函数执行,质量传播依赖程序员手动维护。这种分离导致两个根本性问题。其一是不完备性，即程序员可能忘记在某个信号路径上检查或传播质量，导致下游决策基于不可靠数据。其二是不可组合性，即质量传播逻辑与控制逻辑交织在一起，难以独立推理和验证。为解决这些问题,我们提出**影子类型理论**,将质量作为类型的"影子"维度,与数值维度并列为语言的一等公民。

### 4.2 质量半格结构

**定义 3(质量半格)**。质量码构成一个四元素良基偏序集 $(Q, \sqsubseteq)$,其中:

$$Q = \{GOOD, UNCERTAIN, BAD, NOT\_CONNECTED\}$$

偏序关系 $\sqsubseteq$ 满足:

$$GOOD \sqsubseteq UNCERTAIN \sqsubseteq BAD \sqsubseteq NOT\_CONNECTED$$

且满足自反性(即对任意 $q \in Q$,有 $q \sqsubseteq q$)。

该偏序诱导出 meet 运算 $\sqcap$ 和 join 运算 $\sqcup$:

$$q_1 \sqcap q_2 = \min_{\sqsubseteq}(q_1, q_2), \quad q_1 \sqcup q_2 = \max_{\sqsubseteq}(q_1, q_2)$$

**性质 1(半格性质)**。$(Q, \sqsubseteq)$ 是全序集,因此 $(Q, \sqcap)$ 和 $(Q, \sqcup)$ 都是交换半格(commutative semilattice)。它们满足幂等性($q \sqcap q = q$, $q \sqcup q = q$),交换性($q_1 \sqcap q_2 = q_2 \sqcap q_1$, $q_1 \sqcup q_2 = q_2 \sqcup q_1$),以及结合性($(q_1 \sqcap q_2) \sqcap q_3 = q_1 \sqcap (q_2 \sqcap q_3)$, $(q_1 \sqcup q_2) \sqcup q_3 = q_1 \sqcup (q_2 \sqcup q_3)$)。

**证明**。由 $\sqsubseteq$ 是全序直接可得。$\square$

全序性质保证了 $\sqcap$ 和 $\sqcup$ 有闭式表达式：对于任意 $q_1, q_2 \in Q$，$\min_{\sqsubseteq}$ 和 $\max_{\sqsubseteq}$ 可在 $O(1)$ 时间内计算。这意味着质量传播不会引入运行时的性能不确定性,满足了 P4(WCET 可计算)的要求。

### 4.3 Q*类型定义

**定义 4(Q*类型)**。对于每个基础类型 $\tau \in \mathcal{T}_{ST}$,定义其带质量的版本 $\tau^*$(称为 Q*类型)。Q*类型的值空间为:

$$\mathcal{V}_{\tau^*} = \mathcal{V}_\tau \times Q$$

即每个 Q*类型变量同时包含一个数值和一字节质量码。

类型检查规则将质量作为一等公民。以加法为例:

$$\frac{\Gamma \vdash e_1 : \tau_1^*, \quad \Gamma \vdash e_2 : \tau_2^*, \quad \text{promote}(\tau_1, \tau_2) = \tau}{\Gamma \vdash e_1 + e_2 : \tau^*} \quad (\text{其中结果质量} = \text{qual}(e_1) \sqcap \text{qual}(e_2))$$

注意此处使用 $\sqcap$（取较好者）而非 $\sqcup$（取较差者）：二元运算的结果质量取两个操作数质量中"较好"者,因为在安全级系统中,只有当两个信号都足够好时,基于它们的计算结果才能被信任。然而,对于**质量汇聚**（quality merge）场景（如从多个信号路径中选择输出），则使用 $\sqcup$（取较差者），取最坏情况以保证安全性。

### 4.4 质量传播的公理化

质量传播由 $\text{worst}$ 函数实现。

**公理 1(质量传播规则)**。

$$\text{worst}(q_1, q_2) = q_1 \sqcup q_2$$

即二元运算的结果质量取两个操作数质量中"较差"者。这个函数的语义含义是:在安全关键系统中,信号链的可靠性由最薄弱的环节决定。

**定理 3(质量传播的单调性)**。质量传播函数 $\text{worst}$ 在偏序 $\sqsubseteq$ 下是单调的:

$$\forall q_1, q_1', q_2, q_2' \in Q \cdot (q_1 \sqsubseteq q_1') \land (q_2 \sqsubseteq q_2') \Rightarrow \text{worst}(q_1, q_2) \sqsubseteq \text{worst}(q_1', q_2')$$

**证明**。由 $\text{worst}(q_1, q_2) = q_1 \sqcup q_2$ 和 $\sqcup$ 在偏序 $\sqsubseteq$ 下对两个参数都是单调的(由半格性质可得),因此 $\text{worst}(q_1, q_2)$ 是单调的。$\square$

单调性保证了质量推理的**可组合性**:对子表达式的质量改进不会降低整体表达式的质量。这是模块化验证的基础。

### 4.5 影子内存布局

Q*类型的编译实现采用**影子内存**(shadow memory)方案。每个 Q*类型变量的数值存储在 Main 数据区,质量码存储在独立的 Quality 影子区中:

$$\text{offset}_{\text{qual}}(v_i) = \text{Q\_BASE} + i$$

$$\text{offset}_{\text{val}}(v_i) = \text{DATA\_BASE} + \text{layout}(i)$$

质量与值的分离存储保证了三条关键性质。即质量码始终占用 1 字节，位宽与值的宽度（1 至 8 字节）无关；质量传播代码在编译期插入，运行时不引入条件分支，从而满足 WCET 确定性；非 Q 基础类型不占用影子区，保证了向后兼容性。

## 5 SafeASM:可验证的字节码形式化设计

SafeASM 是 VeriSTC 编译器的目标语言，一种面向安全关键系统的定制字节码格式。与通用处理器指令集不同，SafeASM 的设计目标不是计算效率最大化，而是形式化可验证性：使得每条指令的语义在 Coq 中精确建模，使得加载器的验证逻辑在编译期即可完成，更使得最差执行时间可以在编译器输出字节码时直接计算而非事后分析。本节介绍 SafeASM 的固定宽度编码方案,并证明这一方案与 WCET 可计算性之间的形式化关联。

### 5.1 指令编码与固定宽度形式

SafeASM 指令集 $\mathcal{I}$ 包含 66 条指令,每条指令的编码采用**固定宽度格式**。编码函数 $\mathcal{E}: \mathcal{I} \to \{0,1\}^*$ 满足:

$$\forall i \in \mathcal{I} \cdot |\mathcal{E}(i)| = 
\begin{cases}
8, & \text{无立即数指令} \\
8 + 32, & \text{32 位立即数指令} \\
8 + 64, & \text{64 位立即数指令} \\
8 + 32 + 16, & \text{内存操作指令}
\end{cases}$$

关键设计决策是**固定宽度编码**(fixed-width encoding),而非 WASM 采用的 LEB128 变长编码。这一选择的动机是 WCET 可计算性：变长编码下，指令的取指时间 $t_{\text{fetch}}(i)$ 依赖于指令编码长度 $|\mathcal{E}(i)|$，而后者在存在数据依赖分支时无法静态确定。

### 5.2 WCET 闭式表达式

**定理 4(WCET 静态可计算性)**。对于任意 SafeASM 程序 $M$,其最差执行时间 $T_{WCET}(M)$ 可表示为:

$$T_{WCET}(M) = \sum_{f \in \text{Func}(M)} \left( I_f \cdot t_{\text{fetch}} + \sum_{j=1}^{|I_f|} t_{\text{exec}}(i_j) \right)$$

其中 $I_f$ 是函数 $f$ 的指令数,$t_{\text{fetch}}$ 是固定的取指时间,$t_{\text{exec}}(i_j)$ 是指令 $i_j$ 的执行时间。

**证明**。由固定宽度编码可知,每条指令的取指时间 $t_{\text{fetch}}$ 为常数(与编码长度无关)。由于所有循环有编译期可验证的上界(SafeST 类型系统的要求),且不存在递归调用(P2),所有指令的执行时间 $t_{\text{exec}}(i_j)$ 在微架构层面有上界。因此 $I_f$ 对每个函数 $f$ 可在编译期计算,$T_{WCET}(M)$ 为有限项之和的可计算表达式。$\square$

从定理 4 可以得出两个重要推论。第一，固定宽度编码是 WCET 静态可计算性的充分条件：若指令编码满足 $\forall i \in \mathcal{I} \cdot |\mathcal{E}(i)| \in \{c_1, \ldots, c_k\}$ 其中 $c_1, \ldots, c_k$ 为已知常数，且每条指令的取指时间可静态确定，则 WCET 可计算。第二，变长编码（如 LEB128）不保证 WCET 静态可计算性：设 $\mathcal{E}_{\text{LEB128}}(n)$ 对 $n \in \mathbb{N}$ 的编码长度为 $\lceil \log_{128} (n+1) \rceil$ 字节，若 $n$ 的值在运行时才能确定（如输入依赖的立即数），则取指时间在编译期不可预测，导致 WCET 分析退化为不可判定问题。

## 6 双重语义模拟证明

编译器正确性的核心命题可以表述为：源语言中的每一条执行轨迹，在目标语言中都存在一条对应的执行轨迹，且这两条轨迹在某个适当的抽象层面上"看起来一样"。这一命题的数学形式就是精模拟关系（forward simulation）。本节给出这一模拟关系的完整构造过程：首先分别定义 SafeST 和 SafeASM 的小步操作语义，然后建立两个状态空间之间的抽象关系 $\mathcal{R}$，最后证明 $\mathcal{R}$ 是 $step_{ST}$ 和 $step_{ASM}^*$ 之间的精模拟关系。这一定理的确立，意味着控制工程师在 SafeST 中编写的每一段控制逻辑，其编译后的 SafeASM 代码的行为都忠实地保持了源程序的语义，整条信任链由此得到了数学上的保障。

### 6.1 源语言语义:小步语义

SafeST 的小步操作语义定义为关系 $\xrightarrow{ST} \subseteq \Sigma_{ST} \times \Sigma_{ST}$,其中 $\Sigma_{ST}$ 是 ST 程序状态空间。我们给出核心规则的形式化定义:

赋值规则:
$$\frac{\llbracket e \rrbracket_\sigma = v}{\sigma \xrightarrow{ST} \sigma[x \mapsto v]} [\text{Ass}]$$

条件分支(真):
$$\frac{\llbracket e \rrbracket_\sigma = \text{true}}{\sigma \xrightarrow{ST} \text{execute}(\text{then\_block})} [\text{IfT}]$$

条件分支(假):
$$\frac{\llbracket e \rrbracket_\sigma = \text{false}}{\sigma \xrightarrow{ST} \text{execute}(\text{else\_block})} [\text{IfF}]$$

循序复合:
$$\frac{\sigma \xrightarrow{ST} \sigma'}{\langle s_1; s_2, \sigma \rangle \xrightarrow{ST} \langle s_1'; s_2, \sigma' \rangle} [\text{Seq}]$$

其中 $\llbracket e \rrbracket_\sigma$ 是表达式 $e$ 在状态 $\sigma$ 下的求值函数。由于 SafeST 的语义确定性，$\llbracket \cdot \rrbracket_\sigma$ 是一个全函数。

### 6.2 目标语言语义:小步语义

SafeASM 的语义定义为关系 $\xrightarrow{ASM} \subseteq \Sigma_{ASM} \times \Sigma_{ASM}$,其中:

$$\Sigma_{ASM} = \text{ValueStack} \times \text{FrameStack} \times \text{Memory} \times \mathbb{N}$$

即 $\Sigma_{ASM}$ 为值栈、帧栈、内存和程序计数器的四元组。

核心规则——值栈操作:
$$\frac{}{\langle v :: S, F, M, pc \rangle \xrightarrow{ASM} \langle S, F, M, pc + 1 \rangle} [\text{DROP}]$$

条件分支:
$$\frac{c \neq 0}{\langle c :: S, F, M, pc \rangle \xrightarrow{ASM} \langle S, F, M, \text{target} \rangle} [\text{BR\_IF\_T}]$$

$$\frac{c = 0}{\langle c :: S, F, M, pc \rangle \xrightarrow{ASM} \langle S, F, M, pc + 1 \rangle} [\text{BR\_IF\_F}]$$

### 6.3 模拟关系的构造

**定义 5(抽象关系)**。抽象关系 $\mathcal{R} \subseteq \Sigma_{ST} \times \Sigma_{ASM}$ 定义为满足以下四条一致性条件的最小二元关系。第一是变量一致性——ST 状态中每个变量 $x_i$ 的值等于 SafeASM 状态中对应内存位置的值,即 $\forall (x_i, v_i) \in \sigma_{\text{vars}} \cdot M[\text{offset}(x_i)] = \text{st\_val\_to\_sasm}(v_i)$。第二是质量一致性——ST 状态中每个 Q 类型变量 $x_i$ 的质量码等于 SafeASM 影子内存中的对应字节,即 $\forall (x_i, q_i) \in \sigma_{\text{qual}} \cdot M[\text{Q\_BASE} + \text{idx}(x_i)] = q_i$。第三是调用栈一致性——ST 调用栈深度等于 SafeASM 帧栈深度。第四是周期计数器一致性——ST 和 SafeASM 的周期计数器相等。抽象关系 $\mathcal{R}$ 构成了 ST 语义状态 $\Sigma_{ST}$ 到 ASM 语义状态 $\Sigma_{ASM}$ 的一个抽象函数(abstraction function) $\alpha: \Sigma_{ASM} \to \Sigma_{ST}$ 的逆:

$$\mathcal{R}(\sigma_s, \tau_s) \iff \alpha(\tau_s) = \sigma_s$$

### 6.4 核心定理

**定理 5(语义保持——单步推进)**。对于任意 ST 程序 $P$,若 $P$ 编译成功得到 SafeASM 模块 $M$($\text{compile\_success}(P, M)$),则 $\mathcal{R}$ 是 $step_{ST}$ 和 $step_{ASM}^*$ 之间的**精模拟关系**(forward simulation):

$$\forall \sigma_s, \sigma_s' \in \Sigma_{ST}, \tau_s \in \Sigma_{ASM} \cdot \big( \sigma_s \xrightarrow{ST} \sigma_s' \land \mathcal{R}(\sigma_s, \tau_s) \big) \Rightarrow \exists \tau_s' \in \Sigma_{ASM} \cdot \tau_s \xrightarrow{ASM}^* \tau_s' \land \mathcal{R}(\sigma_s', \tau_s')$$

**证明(结构归纳)**。对 $step_{ST}$ 的每种推导情形进行情形分析(case analysis),对于每个推导规则构造对应的 SafeASM 指令序列并证明最终状态满足 $\mathcal{R}$。以赋值规则 $[\text{Ass}]$ 为例,赋值语句编译后的代码为 $\text{compile\_expr}(e) \;;\; \text{LOCAL\_SET}(x)$。由 $\text{compile\_expr\_correct}$ 引理,$\text{compile\_expr}(e)$ 的执行将 $e$ 的值推入值栈;随后 $\text{LOCAL\_SET}(x)$ 将栈顶值写入 $x$ 对应的内存位置。由 $\mathcal{R}$ 的变量一致性条件即可得出最终状态一致。对于条件分支 $[\text{IfT}]$ 和 $[\text{IfF}]$,编译后的代码为 $\text{compile\_expr}(e) \;;\; \text{BR\_IF}(\text{else\_target})$。若 $e$ 求值为真,$\text{BR\_IF}$ 不跳转,顺序执行 then 分支的编译代码;若为假,跳至 else 目标地址,执行 else 分支的编译代码。$\square$

**定理 6(整体语义保持)**。定理 5 的传递闭包版本:

$$\forall \sigma_{\text{init}}, \sigma_{\text{final}} \in \Sigma_{ST}, \tau_{\text{init}} \in \Sigma_{ASM} \cdot \big( \sigma_{\text{init}} \xrightarrow{ST}^* \sigma_{\text{final}} \land \mathcal{R}(\sigma_{\text{init}}, \tau_{\text{init}}) \big) \Rightarrow \exists \tau_{\text{final}} \in \Sigma_{ASM} \cdot \tau_{\text{init}} \xrightarrow{ASM}^* \tau_{\text{final}} \land \mathcal{R}(\sigma_{\text{final}}, \tau_{\text{final}})$$

**证明**。对 $\xrightarrow{ST}^*$ 的步数 $n$ 进行数学归纳。在基例 $n = 0$ 的情况下,$\sigma_{\text{init}} = \sigma_{\text{final}}$,取 $\tau_{\text{final}} = \tau_{\text{init}}$,由 $\mathcal{R}(\sigma_{\text{init}}, \tau_{\text{init}})$ 直接得证。假设定理对 $n$ 步成立,考虑 $n+1$ 步的情形:设 $\sigma_{\text{init}} \xrightarrow{ST}^n \sigma_{\text{mid}} \xrightarrow{ST} \sigma_{\text{final}}$。由归纳假设,存在 $\tau_{\text{mid}}$ 使得 $\tau_{\text{init}} \xrightarrow{ASM}^* \tau_{\text{mid}}$ 且 $\mathcal{R}(\sigma_{\text{mid}}, \tau_{\text{mid}})$。对 $\sigma_{\text{mid}} \xrightarrow{ST} \sigma_{\text{final}}$ 应用定理 5,即存在 $\tau_{\text{final}}$ 使得 $\tau_{\text{mid}} \xrightarrow{ASM}^* \tau_{\text{final}}$ 且 $\mathcal{R}(\sigma_{\text{final}}, \tau_{\text{final}})$。$\square$

**定理 7(安全保持)**。对于任意 ST 程序 $P$,若 $P$ 通过了类型检查,则编译产生的 SafeASM 模块 $M$ 满足所有安全约束:

$$\text{well\_typed}(P) \Rightarrow \text{safety\_ok}(M) \land \text{loops\_bounded}(M) \land \text{bounds\_safe}(M)$$

**证明**。编译器的类型检查器在输出代码前已将类型信息转化为 SafeASM 的 Safety Section。Safety Section 中的断言（包括边界约束、循环变体和安全不变量）在 VM 加载时被静态验证。由类型检查的可靠性（soundness），即 $\text{well\_typed}(P)$ 意味着所有运行时安全约束的编译期满足，可得上述结论。$\square$

## 7 类型安全定理

类型安全是任何形式化语言设计的基石。Wright 和 Felleisen 提出的"进展 + 保持"框架要求:类型良好的程序要么是终止状态,要么可以继续执行(进展);且类型在计算过程中保持不变(保持)。SafeST 的类型系统同样满足这两条经典性质。本节以定理的形式给出它们的陈述,完整的 Coq 证明实现见 `veristc/src/typechecker.v`。

**定理 8(进展,Progress)**。对于任意类型良好的 SafeST 程序 $P$:

$$\vdash P : \tau \Rightarrow \forall \sigma \in \Sigma_{ST} \cdot \big( \text{is\_terminal}(\sigma) \lor \exists \sigma' \in \Sigma_{ST} \cdot \sigma \xrightarrow{ST} \sigma' \big)$$

即类型良好的程序不会在非终止状态"卡住"（stuck），要么已经是终止状态，要么可以继续执行。

**定理 9(保持,Preservation)**。对于任意类型良好的 SafeST 程序 $P$:

$$\vdash P : \tau \land \sigma \xrightarrow{ST} \sigma' \Rightarrow \vdash_{\sigma'} P : \tau$$

即类型在计算过程中保持不变。

类型安全(进展 + 保持)的 Coq 形式化证明见 `veristc/src/typechecker.v`。

## 8 相关工作

VeriSTC 的工作横跨形式化验证编译器、工业语言安全子集、WCET 分析与质量语义四个研究领域。本节将逐一与各领域的代表性工作进行对比,以定位本工作的理论贡献与边界。

### 8.1 形式化验证编译器

CompCert[1]是本工作最直接的理论先导。CompCert 证明了从 Clight 子集到多种目标架构(PowerPC、ARM、x86)的编译正确性,总证明规模超过 40,000 行 Coq。与之相比,VeriSTC 面临一组不同的挑战,可以从四个维度加以对比。从领域语义的复杂性看，IEC 61131-3 的领域特有语义（包括定时器 TON/TOF/TP、功能块 FB 实例化、CASE 多路分支）比 C 语言的对应构造更复杂，但具有更好的结构性。从目标架构的定制性看,SafeASM 是面向安全关键系统的定制字节码，而非通用处理器指令集，这简化了指令编码和 WCET 分析，但要求编译器设计者自行定义完整的指令语义。从内存模型的简化看,SafeST 禁止指针后,内存模型从 CompCert 的带别名堆简化为平坦内存映射,证明复杂度大幅降低。从领域特有的问题看,VeriSTC 引入的质量类型体系(Q*类型)是 CompCert 未处理的领域特有构造。CakeML[4]是另一个经过形式化验证的函数式语言编译器,但与 VeriSTC 不同,CakeML 面向通用函数式编程而非领域特定语言,其语义框架也缺乏对信号质量等工业控制特有关切的支持。

### 8.2 IEC 61131-3 安全子集

PLCopen Safety 规范[2]定义了 SIL 3 级的 ST 安全子集，但它采用**枚举式禁止**的方法论，即列出不可用的语言特性，而非**原则性剪裁**。PLCopen 验证依赖厂商实现的具体测试,不提供数学证明。Beckhoff TwinSAFE、Siemens S7-F/Failsafe 等商业产品部分实现了 PLCopen Safety,但无法保证从控制逻辑到可执行代码之间的语义保持。

VeriSTC 与 PLCopen Safety 的根本区别在于：SafeST 的剪裁基于 P1-P4 四条形式化判据，每条判据均可证伪；SafeST 提供了从语言语义到编译器正确性的完整 Coq 证明，而非仅依赖测试。此外，SafeST 额外增加了质量类型体系，这在 PLCopen Safety 中未被涉及。

### 8.3 WCET 分析方法

当下 WCET 分析的主流方法包括**基于抽象解释**(Wilhelm et al., 2008)[5]和**基于结构路径分析**(Puschner & Burns, 2000)[6]。这些方法的共同特征是：将 WCET 分析作为编译后的**后处理阶段**，即先编译，再分析已生成的机器码。

VeriSTC 的贡献在于证明了一个更强的论点:如果源语言和目标语言都是语义确定性的(定义 1),且编码是固定宽度的,那么 WCET 分析可以**提前到编译器设计中完成**,而非事后由分析工具推导。这意味着在 VeriSTC 框架下，WCET 信息可以作为编译器的**输出**而非分析工具的**输入**——当编译器输出 `.sasm` 文件时，WCET Section 已经包含了完整的 WCET 计算信息，虚拟机可以在加载时直接使用。

### 8.4 质量语义

IEC 61131-3 标准没有规定信号质量的统一处理方式。各厂商以私有函数库提供质量接口，如 Siemens 的 `GET_DP_DIAG`、CoDeSys 的 `__ISVALID`，但对质量传播的语义缺乏形式化定义。

VeriSTC 的 Q*类型体系与程序语言中"基于类型的状态验证"（Swamy et al., 2012）[7]在方法论上一脉相承，即将运行时检查提升为类型约束。然而,Swamy et al. (2012) 解决的是加密协议的保护问题,其状态空间是离散的安全状态;而 Q*类型解决的是信号质量的连续退化问题,其代数结构是带有全序的交换半格。前者要求计算"何时状态允许此操作",后者要求计算"基于多个输入信号的质量,输出信号的质量如何"。

## 9 可优化与可扩展的方向

前文的论述建立了形式化剪裁、影子类型、固定宽度编码与双重语义模拟四者之间的理论关联。这套框架在工业语言的形式化验证方面展现出了一条清晰的技术路径，同时也在多个方向上存在进一步优化和扩展的空间。本节从方法论的一般化推广、形式化框架的自然延伸以及若干有前景的理论深化方向三个层面展开讨论。

### 9.1 方法论的一般化推广

P1-P4 剪裁判据的设计独立于 IEC 61131-3 的具体语法特性，其核心是一组关于语言可验证性的充分条件，因此可以作为一种通用方法论应用于其他工业领域的形式化语言设计中。以 IEC 61499（功能块）为例，其组合语义天然适合操作语义建模，而事件语义的并发性则为 P1-P4 框架提供了一个自然的扩展方向——将 P4 的 WCET 可计算性要求从单线程扩展到并发场景，可以通过交织语义或偏序归约来实现，这恰好是形式化方法中已经充分研究的领域。对于 IEC 61850（变电站自动化），其抽象通信服务接口（ACSI）的语言模型中包含实时约束（如 GOOSE 报文的 4 ms 传输时限），这实际上是 P4 的一种自然推广——将 WCET 从单机范围延伸至网络范围，此时固定宽度编码的优势更为突出，因为网络传输中的确定性延迟同样受益于可预测的数据包大小。而对于 IEC 62541（OPC UA），其信息模型的类型系统可以沿用 P3 的形式化方法进行建模，高阶抽象语法（Higher-Order Abstract Syntax）领域的成熟成果为此提供了坚实的技术基础。上述推广方向表明：P1-P4 框架提供了一组灵活的判据，每个领域只需根据其特有的语义特征对判据的具体内涵进行适配即可。

### 9.2 形式化框架的自然延伸方向

当前证明框架在多个方向上可以自然地延伸和深化，这些延伸不是对框架的修正，而是将其推向更高形式化完备性的增强。

**从语义保持到全程序正确性的衔接。** 本文证明的语义保持关系构成了编译器正确性的核心。在此基础上，可以向全程序正确性（total correctness）的方向自然延伸——全程序正确性要求在语义保持的基础上，进一步在规范层面建立安全属性与程序语义之间的对应关系。VeriSTC 的证明框架可以自然地与 Hoare 逻辑或分离逻辑等程序验证方法衔接，形成"编译器正确性 + 程序逻辑"的双层验证架构：编译器保证编译后的代码忠实地反映了源程序的语义，程序逻辑则保证源程序本身满足安全规范。这一衔接层是本文框架最有价值的扩展方向之一。

**抽象函数的精细化与完备性刻画。** 模拟关系 $R$ 的定义依赖于从 SafeASM 状态空间到 SafeST 状态空间的抽象函数 $\alpha$，而抽象函数的选择本身就是一个可优化的设计空间。本文采用的四维抽象（变量值、质量码、调用栈深度、周期计数）是最小化的实用选择，在此基础上有多种精细化的可能：例如，可以增加内存访问模式维度以支持更细粒度的安全验证，也可以通过建立 Galois 连接来形式化地刻画抽象的完备性。不同的抽象层次适用于不同的验证目标，这种灵活性本身就是框架设计的一个优势。

**质量半格的可扩展结构。** 本文定义的四元素质量半格 $(Q, \sqcap, \sqcup)$ 作为最小完备集，在多数安全关键场景中已经足够。对于需要更细粒度质量区分的场景，质量半格可以自然地扩展。例如，核电站保护系统中带冗余传感器的"部分故障"（partial failure）信号——两个冗余传感器中一个故障、一个正常——可以建模为第五个质量状态。扩展后的偏序不再是全序，但可以构造为格（lattice）而非全序集，此时 meet 和 join 运算仍然具有封闭性和结合性，只是计算复杂度从 $O(1)$ 变为 $O(\log n)$（可通过预计算查找表优化）。因此，质量半格的扩展性不是限制，而是一个可以根据应用需求灵活调整的参数。

**时序语义维度的嵌入。** SafeST 当前的语义模型覆盖了单周期数据流，而安全关键系统中的部分安全属性涉及跨周期的时序约束——例如"在停堆信号触发后的 50 ms 内完成控制棒插入"或"同一传感器在连续三个扫描周期内均输出超限值才能触发报警"。这类时序安全属性的形式化验证可以通过将实时逻辑（如 MTL、TCTL）或时间自动机的语义嵌入到 SafeST 的语义框架中来实现。本文的小步语义为这种嵌入提供了良好的基础：只需在状态空间中增加时间戳维度，并在转移规则中引入时间约束，即可将框架从纯数据流扩展为数据-时间混合语义。这一扩展方向在理论上是直接的，在工程上则对应 SafeASM 中 WCET Section 的丰富化。

### 9.3 有前景的理论深化方向

在上述延伸方向之外，还有若干更深层的理论问题值得探索，这些问题将进一步提升本文框架的形式化完备性和普适性。

**剪裁框架的进一步完备化。** 定理 2 已经证明了 P1-P4 是语义无空洞性的充分条件。在此基础上可以进一步探索：P1-P4 是否也是必要条件？如果能够建立 P1-P4 的必要性定理，则剪裁框架实现了完全的形式化刻画；即使存在反例，发现反例的过程也将加深对语言安全性与形式化可验证性之间关系的理解。无论结果如何，这一探索都将推动剪裁方法论从充分条件向充要条件的理论完备化。

**影子类型体系的范畴论统一。** Q*类型体系呈现出一个优美的代数结构：每个基础类型 $\tau$ 对应提升类型 $\tau^* = \tau \times Q$，质量传播操作 $\text{worst}$ 构成该提升上的一个自然变换。这一观察提示影子类型体系可能具有范畴论层面的统一诠释——即存在一个从基础类型范畴到影子类型范畴的函子，且该函子与质量传播之间满足交换图条件。建立这一范畴论框架可以将质量类型体系推广到任意具有预序结构的质量域上，而不仅限于四元素半格，从而实现影子类型理论的完全一般化。

**编码方案空间的系统探索。** 定理 4 证明了固定宽度编码是 WCET 静态可计算性的充分条件，但固定宽度并非唯一的选择。在固定宽度与完全变长编码之间，存在一个丰富的编码方案空间等待系统探索。例如，稀疏编码（sparse encoding）——大多数指令使用固定短码、少数指令使用长码——可能在实践中同时满足编码紧凑性和 WCET 可计算性。刻画这一编码方案空间的结构，确定 WCET 可计算性在该空间中的精确边界，是编译器形式化设计中的一个既有理论趣味又有实践价值的问题。

**模拟关系的强化与互模拟的建立。** 本文建立的前向精模拟关系保证了 SafeST 语义到 SafeASM 语义的忠实翻译。在此基础上可以进一步考虑：如果 SafeASM 的指令集设计中不存在"多余行为"（即每条 SafeASM 指令都可以映射回 SafeST 的某个语义构造），则精模拟可以强化为互模拟（bisimulation）关系。互模拟的建立将提供更强形式的正确性保证——不仅源语言的每条轨迹能在目标语言中找到对应，目标语言的每条轨迹也能在源语言中找到来源。判定 SafeASM 指令集是否满足这一性质本身就是一个有意义的理论问题，其答案将为指令集的形式化设计提供指导原则。

## 参考文献

[1] X. Leroy. Formal verification of a realistic compiler. *Communications of the ACM*, 52(7):107--115, 2009.

[2] PLCopen. Safety Software --- Technical Specification, Version 1.0, 2006.

[3] W. Landi. Undecidability of static analysis. *ACM Letters on Programming Languages and Systems*, 1(4):323--337, 1992.

[4] R. Kumar, M. O. Myreen, M. Norrish, and S. Owens. CakeML: a verified implementation of ML. In *Proc. POPL*, 2014.

[5] R. Wilhelm et al. The worst-case execution-time problem. *ACM Transactions on Embedded Computing Systems*, 7(3):1--53, 2008.

[6] P. Puschner and A. Burns. A review of worst-case execution-time analysis. *Real-Time Systems*, 18(2):115--128, 2000.

[7] N. Swamy, J. Chen, C. Fournet, P.-Y. Strub, K. Bhargavan, and J. Yang. Secure distributed programming with type-directed encryption. In *Proc. ICFP*, 2012.

[8] J. C. Reynolds. Separation logic: a logic for shared mutable data structures. In *Proc. LICS*, 2002.

[9] E. W. Dijkstra. The humble programmer. *Communications of the ACM*, 15(10):859--866, 1972.
