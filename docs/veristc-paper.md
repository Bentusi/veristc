# VeriSTC: 基于形式化验证的高可信工业控制编译器——语言剪裁、质量类型与双重语义模拟

## 摘要

在安全级工业控制领域（核电站保护系统、航空发动机控制、轨道交通信号联锁），所有程序执行必须在编译期可预测,所有安全属性必须可形式化证明。然而,当前工业界广泛使用的 IEC 61131-3 Structured Text (ST) 语言包含指针、动态内存、递归和非确定性循环等构造,不具备形式化验证所需的静态可决策性基础。现有的安全子集方案(如 PLCopen Safety)依赖经验规则而非形式化语义,无法提供从源代码到字节码的可追溯保证。

本文提出 **VeriSTC** (Verified ST Compiler),一个将 IEC 61131-3 ST 安全子集编译为 SafeASM 字节码的编译器,其全部核心实现在 Coq 定理证明器中完成并附带形式化正确性证明。本文的理论贡献体现在四个方面。其一,提出语言剪裁的形式化判据 P1-P4，即安全关键适配、静态可决策性、形式化可建模与 WCET 可计算，作为从工业语言中系统性地提取安全子集的通用方法论,并证明满足这四条原则的语言是语义无空洞的。其二,针对安全级设备的关键应用需求,将 Q*类型质量位传递提升为一等类型,给出其类型规则和代数性质：质量码构成二元素全序格 $(Q, \land, \lor)$（GOOD < BAD），编译器依据信号拓扑自动选择传播策略——串行链取较差者（$\text{worst} = q_1 \land q_2$）、并行冗余取较好者（$\text{best} = q_1 \lor q_2$）——从而将运行时诊断提升为编译期类型约束，并证明两种传播函数的单调性。其三,证明固定宽度编码是 WCET 静态可计算性的充分条件,并给出从指令编码长度到最差执行时间的闭式表达式。其四,在 Coq 中构造 SafeST 小步语义到 SafeASM 小步语义的模拟关系 $\mathcal{R}$,证明 $step_{ST}$ 与 $step_{ASM}^*$ 之间的精模拟关系,为控制逻辑源代码到执行字节码之间的信任链提供数学基础。

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

第二是影子类型理论。信号质量（传感器信号是可信、可疑、无效还是未连接）在工业控制中至关重要,但长期被当作运行时的诊断信息而非语言层面的一等实体来处理。传统做法中,质量检查通过显式调用 `Q_GOOD(x)` 等函数执行,质量传播依赖程序员手动维护，这种分离导致了两个根本性问题：不完备性(程序员可能忘记在某条信号路径上检查质量)和不可组合性(质量传播逻辑与控制逻辑交织在一起,难以独立推理)。本文提出的 Q*类型体系将质量提升为一等类型:质量码构成二元素全序格 $(Q, \land, \lor)$,其中 $Q = \{\mathtt{GOOD}, \mathtt{BAD}\}$,偏序 $\mathtt{GOOD} < \mathtt{BAD}$ 构成良基全序。编译器依据信号拓扑自动选择传播策略——串行链（二元运算）使用 $\land$（取较差者，$\text{worst} = q_1 \land q_2$），并行冗余（多路选择）使用 $\lor$（取较好者，$\text{best} = q_1 \lor q_2$）——从而将质量传播从动态检查提升为编译期的静态类型推导。我们进一步证明 $\text{worst}$ 和 $\text{best}$ 均满足单调性（定理 3、定理 4），保证了质量推理的可组合性。

第三是固定宽度编码与 WCET 可计算性的理论关联。对于实时安全系统而言,最差执行时间的可计算性是一个非功能性的但关键的约束。本文证明固定宽度编码是 WCET 静态可计算性的充分条件。设指令集 $\mathcal{I}$ 上的编码函数 $\mathcal{E}: \mathcal{I} \to \{0,1\}^*$ 满足 $\forall i \in \mathcal{I}, |\mathcal{E}(i)| = c$（常数 $c$），则任意指令序列 $s = i_1 i_2 \ldots i_n$ 的执行时间满足：

$$T_{WCET}(s) = n \cdot t_{\text{fetch}}(c) + \sum_{j=1}^{n} t_{\text{exec}}(i_j)$$

其中 $t_{\text{fetch}}(c)$ 是取指时间,$t_{\text{exec}}(i_j)$ 是指令 $i_j$ 的执行时间。由于 $c$ 和 $t_{\text{exec}}(i_j)$ 均在编译期确定,$T_{WCET}(s)$ 可静态计算。这一结果不仅适用于 SafeASM,也对任何面向实时安全系统的字节码设计具有指导意义。

第四是双重语义模拟证明。编译器正确性的核心在于证明源语言和目标语言的执行语义之间存在模拟关系。我们在 Coq 中构造了 SafeST 小步语义到 SafeASM 小步语义的模拟关系 $\mathcal{R} \subseteq \Sigma_{ST} \times \Sigma_{ASM}$,并证明了 $step_{ST}$ 与 $step_{ASM}^*$ 之间的精模拟关系:

$$\forall \sigma_s, \sigma_s' \in \Sigma_{ST}, \tau_s \in \Sigma_{ASM} \cdot \big( \sigma_s \xrightarrow{ST} \sigma_s' \land \mathcal{R}(\sigma_s, \tau_s) \big) \Rightarrow \exists \tau_s' \in \Sigma_{ASM} \cdot \tau_s \xrightarrow{ASM}^* \tau_s' \land \mathcal{R}(\sigma_s', \tau_s')$$

这一证明为从控制工程师书写的控制逻辑代码到最终执行的字节码之间的整条信任链提供了数学基础。证明采用结构归纳法,对 $step_{ST}$ 的每种推导情形分别构造对应的 SafeASM 指令序列,并通过 `compile_expr_correct` 和 `compile_stmt_correct` 两个核心引理完成正确性论证。

### 1.5 论文组织

后续各节的安排如下。第 2 节形式化地定义安全级编程语言的语义要求,包括语义确定性和语义空洞的概念,并证明 WCET 可计算性的三个充分条件及其不可弥补性。第 3 节提出 P1-P4 四条剪裁判据及其形式化定义,证明剪裁完备性定理,并以指针为例展示如何在这四条原则的框架下对语言特性进行逐条判断。第 3.4 节和第 3.5 节进一步将剪裁框架系统地应用于表达式和语句层面,逐项分析被排除的 IEC 61131-3 构造并给出形式化剪裁理由。第 4 节阐述影子类型体系的理论基础,从质量传播的传统问题出发,依次建立质量全序格的代数结构、Q*类型的定义与双模(Q4-Q6)类型规则、质量传播公理化(worst+best双函数体系及单调性定理),以及影子内存的编译实现方案。第 5 节给出 SafeASM 字节码的形式化设计,重点论述固定宽度编码的逻辑动机及其与 WCET 可计算性之间的理论关联。第 6 节呈现双重语义模拟关系的构造过程，包括源语言和目标语言的小步语义定义、抽象关系的构造，以及核心定理的 Coq 证明策略。第 7 节呈现类型安全性的 Coq 证明框架，包括三阶段证明架构的设计、Progress 和 Preservation 的证明策略，以及类型安全与语义保持之间的逻辑衔接。第 8 节将本文工作与 CompCert、PLCopen Safety、现有 WCET 分析方法以及质量语义的相关研究进行系统性比较。第 9 节讨论方法的普适性与当前工作的局限性,并展望后续研究方向。

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

SafeST 类型系统 $\mathcal{T}_{ST}$ 包含以下类型构造：

$$
\tau ::= \mathtt{BOOL} \mid \mathtt{SINT} \mid \mathtt{INT} \mid \mathtt{DINT} \mid \mathtt{LINT}
       \mid \mathtt{BYTE} \mid \mathtt{WORD} \mid \mathtt{DWORD}
       \mid \mathtt{REAL} \mid \mathtt{LREAL}
$$

类型间的隐式提升由偏序 $\preceq$ 定义：

$$
\mathtt{SINT} \preceq \mathtt{INT} \preceq \mathtt{DINT} \preceq \mathtt{LINT},\quad
\mathtt{BYTE} \preceq \mathtt{WORD} \preceq \mathtt{DWORD},\quad
\mathtt{REAL} \preceq \mathtt{LREAL}
$$

类型提升函数 $\text{promote}(\tau_1, \tau_2)$ 返回 $\tau_1$ 和 $\tau_2$ 在 $\preceq$ 下的最小上界（least upper bound, join），若不存在则返回类型错误：

$$
\text{promote}(\tau_1, \tau_2) =
\begin{cases}
\text{lub}_{\preceq}(\tau_1, \tau_2), & \text{若 } \tau_1, \tau_2 \text{ 属于同一数系家族} \\
\bot, & \text{否则}
\end{cases}
$$

其中数系家族分为三组：整数族 $\{\mathtt{SINT}, \mathtt{INT}, \mathtt{DINT}, \mathtt{LINT}\}$、位族 $\{\mathtt{BYTE}, \mathtt{WORD}, \mathtt{DWORD}\}$、浮点族 $\{\mathtt{REAL}, \mathtt{LREAL}\}$。跨族提升被视为类型错误，这是安全关键系统的保守策略。

#### 保留的类型构造

类型剪裁同样遵循 P1-P4 框架。表 1 列出全部保留类型及其对四条判据的满足情况。P1 用例列给出该类型在安全级控制中的典型应用场景。

**表 1　保留的类型构造**

| 类型家族 | 保留类型 | 位宽 | P1 用例 | P2 | P3 | P4 |
|---------|---------|:----:|---------|:--:|:--:|:--:|
| 布尔 | `BOOL` | 1 bit | 联锁条件、保护系统表决结果 | 满足 | 满足 | 满足 |
| 整数 | `SINT` | 8 bit | 小型计数器、索引值 | 满足 | 满足 | 满足 |
| 整数 | `INT` | 16 bit | 通用整数运算、通道号 | 满足 | 满足 | 满足 |
| 整数 | `DINT` | 32 bit | 主计数器、累加器、PID 中间计算 | 满足 | 满足 | 满足 |
| 整数 | `LINT` | 64 bit | 高精度累加、64 位时间戳计数 | 满足 | 满足 | 满足 |
| 位串 | `BYTE` | 8 bit | 状态字低 8 位、I/O 字节操作 | 满足 | 满足 | 满足 |
| 位串 | `WORD` | 16 bit | 位掩码、设备状态字 | 满足 | 满足 | 满足 |
| 位串 | `DWORD` | 32 bit | 32 路数字量输入打包 | 满足 | 满足 | 满足 |
| 浮点 | `REAL` | 32 bit | 模拟量处理、AI/AO 换算 | 满足 | 满足 | 满足 |
| 浮点 | `LREAL` | 64 bit | 高精度模拟量、双精度中间计算 | 满足 | 满足 | 满足 |

上表所示的十种类型覆盖了安全级仪控系统所需的全部数值表示范畴。

#### 排除的类型构造

表 2 列出了被排除的 IEC 61131-3 类型构造及其形式化排除理由。

**表 2　排除的类型构造**

| 类型 | 违反判据 | 违反理由 | IEC 61131-3 示例 | 替代方案 |
|------|---------|---------|-----------------|---------|
| `STRING` / `WSTRING` 字符串 | P1、P2、P4 | 安全级控制逻辑无需字符串处理，人机交互由上层 HMI 系统独立管理。字符串长度在运行时可变，编译期不可判定。字符串操作执行时间与长度相关，WCET 上界无法确定 | `s := "Hello"` | 完全排除，安全级逻辑无需字符串 |
| `DATE` / `TOD` / `DT` 时钟时间 | P1 | 安全级控制逻辑无需绝对时钟时间。安全级系统采用固定周期扫描模型，定时和延时逻辑通过周期计数实现，与绝对时间无关 | `IF DATE > D#2026-01-01 THEN ...` | 周期计数通过 `DINT` 加周期常量表达 |
| `TIME` 时间 | P1 | 安全级仪控系统采用固定周期扫描模型，所有定时和延时逻辑通过周期计数实现（如"等待 N 个扫描周期"而非"等待 T 毫秒"）。TIME 类型基于绝对时间单位的语义与周期扫描模型不匹配，可能掩盖周期计数的真实执行语义。周期计数的延时可通过整数类型变量加编译期已知的周期常量组合表达 | `TON(IN := x, PT := T#100ms)` | `DINT` 周期计数变量，每个扫描周期递增 |
| `REF` / `REF_TO` / `POINTER` 指针 | P1、P2、P3、P4 | 同 3.4.2 节表达式排除分析，指向分析不可判定，形式化模型需要分离逻辑 | `p : REF_TO INT` | 直接变量引用 |
| 无符号整数：`USINT` / `UINT` / `UDINT` / `ULINT` | P1（安全语义冲突） | 无符号整数的核心语义——模运算回绕——与安全关键系统的故障-安全原则存在根本性冲突。当计数器从 0 递减时，无符号类型静默回绕至最大值，底层逻辑错误被掩盖；而有符号类型加编译期 RANGE_CHECK 断言在同样场景下会触发显式的边界违规，驱动系统进入已知的安全态。以通道号计数器为例：若 `ch : UINT` 在逻辑错误时从 0 减至 65535，后续数组访问可能访问越界地址；若 `ch : INT` 加 `RANGE_CHECK(ch >= 0)` 断言，同样错误在赋值处即被捕获。正计数范围方面，LINT 最大值 9.22 × 10¹⁸ 对应 1 ms 扫描周期约 292,000 年的累计计数，远超安全级系统 40–60 年的设计寿命，不存在有符号类型无法覆盖的无符号正计数场景。保留无符号类型将使类型数量从 10 种增至 14 种，并在类型提升矩阵中引入有符号-无符号混合跨族场景——需定义符号扩展、隐式转换和溢出处理规则，显著增加形式化证明的工作量 | `x : UINT := 0; x := x - 1;`（结果 x = 65535，无错误报告） | 有符号类型加编译期 `>= 0` 断言，编译器自动插入 RANGE_CHECK 指令，等价场景下触发的边界检查将阻止不安全状态传播 |
| `ENUM` 枚举 | P1（必要条件不满足） | 枚举类型是语法糖，可通过 `INT` 加常量定义替代 | `TYPE Color : (RED, GREEN, BLUE); END_TYPE` | `INT` 加 `CONSTANT` 定义 |
| `STRUCT` 结构体 | P1（必要条件不满足） | 结构体嵌套增加内存布局和类型检查的复杂度，安全级控制逻辑中所有数据均可展开为扁平变量 | `TYPE Point : STRUCT x : INT; y : INT; END_STRUCT` | 展开为多个独立变量 |

类型剪裁的总体策略是保留最小完备集：保留的类型覆盖了布尔逻辑、整数运算、位操作和浮点计算四个必需的数值范畴；被排除的类型按排除性质可分为三类。第一类是原则性排除，包括字符串和指针。这两类构造违反 P1-P4 中的两条以上，无法满足形式化验证的要求。第二类是语法糖排除，包括枚举和结构体。这些类型虽然可以在 Coq 中建模（P3 满足），但存在语义等价的替代方案，保留它们只会增加类型系统和编译器的复杂度而不增加语言在安全关键领域的实质表达能力。第三类是设计范式排除，以无符号整数、TIME 类型和时钟时间类型为代表。这些类型的排除理由并非技术上的不可实现（P2-P4 均满足），而是与安全关键系统的设计范式存在根本性不匹配——无符号整数的模运算回绕语义与故障-安全原则冲突，TIME 类型和时钟时间类型的绝对时间语义与固定周期扫描模型冲突。

### 3.4 表达式的形式化剪裁

P1—P4 框架不仅适用于数据类型和POU级别的剪裁决策，同样可以系统性地应用于IEC 61131-3表达式层面。表达式剪裁围绕建立一个最小完备的表达式集这个核心目标展开，使得该集合能够表达安全级仪控系统所需的全部计算范畴，同时集合中的每个构造都满足P1—P4的形式化要求。为此，分析工作需要从安全级工程需求出发，确认哪些表达式构造必须保留；和从IEC 61131-3标准出发，逐条审查被排除的构造是否具备形式化验证的合理性依据。

#### 3.4.1保留的表达式构造

保留的表达式按照功能分为八个范畴，每个范畴对应一到多个具体的语法构造。表 3 列出了全部保留构造及其对 P1-P4 的满足情况。其中 P1 用例列给出该构造在安全关键系统中不可替代的典型场景；P2 可判定、P3 可建模和 P4 WCET 三列分别使用"满足"或"——"标记该构造是否通过对应判据的审查。保留构造不满足某一判据的情形在该语言中不予接受，但好在以下八类构造在全部四条判据上均通过审查。

**表 3　保留的表达式构造**

| 范畴 | 保留构造 | P1 用例 | P2 可判定 | P3 可建模 | P4 WCET |
|------|---------|---------|:---------:|:---------:|:-------:|
| 字面量 | `42`、`3.14`、`TRUE`、`T#5s` | PID 参数常量、联锁阈值定义 | 满足 | 满足 | 满足 |
| 变量引用 | `x` | 传感器测量值引用 | 满足 | 满足 | 满足 |
| 数组索引 | `a[i]` | 批量通道信号选择 | 满足 | 满足 | 满足 |
| 一元运算 | `-x`、`NOT x`、`ABS(x)` | 信号取反、偏差绝对值计算 | 满足 | 满足 | 满足 |
| 二元运算 | `a + b`、`a - b`、`a * b`、`a / b`、`a MOD b` | PID 控制律计算 | 满足 | 满足 | 满足 |
| 比较运算 | `a = b`、`a <> b`、`a < b`、`a > b`、`a <= b`、`a >= b` | 联锁条件判断 | 满足 | 满足 | 满足 |
| 逻辑运算 | `a AND b`、`a OR b`、`a XOR b` | 保护系统表决逻辑 | 满足 | 满足 | 满足 |
| 函数调用 | `f(e₁, ..., eₙ)` | 标准算法库复用 | 满足 | 满足 | 满足 |

上表所示的八类表达式构造与第 3.1.2 节定义的抽象语法严格对应，构成了 SafeST 表达式系统的全部语法范畴。下面对其中两类需要特别说明的构造展开讨论。

第一类是二元运算的类型提升机制。二元运算的结果类型由 promote 函数在编译期唯一确定（第 3.3 节），该函数根据操作数类型所属的数系家族（整数族、位族、浮点族）和提升链方向（如 SINT→INT→DINT→LINT）计算出最小公共超类型。这一机制保证了 P2 的通过：类型提升路径是确定的，不存在运行时类型选择的不确定性。

第二类是逻辑运算的短路求值问题。IEC 61131-3 规定 AND 和 OR 采用短路求值策略：当左操作数已经可以确定结果时，右操作数不被求值。这一特性在安全级控制中有实际用途——例如 `IF (x <> 0) AND (y / x > 0)` 中，短路求值避免了除零错误。短路求值影响的是运行时的求值路径，但在类型层面，AND 和 OR 的返回类型始终为 `BOOL*`，不因短路与否而改变。因此 P2 的通过不受影响：类型检查在编译期即可完成，无需考虑运行时控制流。

#### 3.4.2排除的表达式构造

与保留方向相反，排除方向的工作是对 IEC 61131-3 标准中未被 SafeST 包含的表达式构造逐条审查。表 4 列出了全部被排除的构造，每行标注违反的判据、具体理由、IEC 61131-3 中的代码示例以及 SafeST 推荐的替代方案。

**表 4　排除的表达式构造**

| 构造 | 违反判据 | 违反理由 | IEC 61131-3 示例 | SafeST 替代方案 |
|------|---------|---------|-----------------|----------------|
| 取地址与间接引用：`ADR`、`REF`、`^` | P1、P2、P3、P4 | 安全级控制逻辑的所有 I/O 信号通过符号变量名直接引用，不存在必须通过地址间接访问传感器的用例。精确指向分析在最一般情况下不可判定（Landi 1992），等价于停机问题。指针的形式化模型需要偏序堆和分离逻辑（Reynolds 2002），证明复杂度远超安全级程序的实际需要。间接访存的执行时间因地址动态绑定无法在编译期确定 | `p := ADR(x); y := p^` | 直接变量引用 `y := x` |
| 直接硬件地址访问：`%IW`、`%QW`、`%IX` | P1、P2 | 硬件地址与逻辑变量名的绑定属于系统集成层的配置问题，不应出现在控制逻辑的表达式中。地址解析依赖运行时的 I/O 配置表，编译期无法确定地址值 | `x := %IW3.1` | 符号变量加 IOMap Section 配置 |
| 字符串操作：`CONCAT`、`LEFT`、`MID` | P1、P2、P4 | 安全级逻辑无需处理字符串，人机交互字符串由上层 HMI 系统独立管理。字符串操作的结果长度依赖运行时输入，无法在编译期确定。字符串操作的执行时间与操作数的实际长度相关，无确定性上界 | `s := CONCAT(a, b)` | 排除，与 `STRING` 类型一并移除 |
| 位串移位：`SHL`、`SHR`、`ROL`、`ROR` | P1（必要条件不满足） | 位串移位在安全级系统中确有应用场景，但这些操作可以通过按位 AND、OR 和 NOT 的组合来实现，因此不存在不可替代的用例。移位位数若为运行时变量则同时违反 P2；固定常量移位在编译期可完全确定，但单一常量移位的场景不足以为其设立独立的语言构造 | `x := SHL(a, b)` | 按位 AND/OR/NOT 组合（当前版本）；以内置函数形式引入（后续扩展） |
| 运行时状态查询：`__ISVALID`、`__ISOPEN`、`TYPEOF` | P1、P2、P3 | 运行时状态查询的本质是运行时诊断功能，已被 Q*类型的静态质量码体系完全覆盖，无需设立独立的表达式构造。运行时状态显然不能在编译期静态确定。反射语义在 Coq 的依赖类型理论中无法直接建模 | `IF __ISVALID(x) THEN ...` | `Q_GOOD(x)` 或 `Q_STATUS(x)` |

从表 4 可以归纳出三类不同性质的排除模式。第一类是完全违反型，以取地址与间接引用为代表，这类构造同时违反全部四条原则，在安全关键语言中没有任何保留的合理性——它们不仅不具备形式化验证所需的数学基础，甚至从工程角度看也没有不可替代的用例。第二类是核心判据违反型，以直接硬件地址访问和字符串操作为代表，它们在表面上只违反两条判据，但被违反的恰好是安全关键系统的两个核心要求：P1（领域适配性）和 P2（编译期可决策性）。这两条判据中任何一条的缺失都足以将一个构造排除在安全子集之外。第三类是扩展保留型，以位串移位为代表，其排除理由不是硬性违反某条判据，而是 P1 的必要条件不满足——存在候选替代方案。这类构造在编译器达到一定成熟度后，以内置函数而非运算符形式逐步纳入语言。
#### 3.4.3形式化结论

综合保留和排除两个方向的分析，SafeST 的表达式剪裁满足以下形式化性质：保留的八类构造在 P2、P3、P4 三条判据上全部通过审查，且每一类构造都有至少一个明确的安全关键用例用于满足 P1；被排除的五类构造中，三类违反 P1-P4 中的两条以上，一类（直接硬件地址）违反两条核心判据，一类（位串移位）虽未硬性违反但存在等价替代方案。因此 SafeST 的表达式系统在 P1-P4 框架下是完备的——不存在既满足全部四条判据又无法通过八个保留构造表达的表达式需求。

以下给出 SafeST 的完整 BNF 文法定义，作为上述剪裁结论在语法层面的正式表述。

**词法规则**

```
<literal>         ::= <integer_literal> | <real_literal> | <bool_literal> 
<integer_literal> ::= <digit>+ | "2#" <binary_digit>+ | "16#" <hex_digit>+
<real_literal>    ::= <digit>+ "." <digit>+ [ "E" [ "+" | "-" ] <digit>+ ]
<bool_literal>    ::= "TRUE" | "FALSE"
<identifier>      ::= <letter> ( <letter> | <digit> | "_" )*
<letter>          ::= "a"..."z" | "A"..."Z"
<digit>           ::= "0"..."9"
```

标识符最大长度为 32 字符，不区分大小写。关键字（第 4.2 节）不可用作标识符。

**表达式规则**

SafeST 表达式遵循 IEC 61131-3 的优先级层次，从高到低依次为一元运算、乘法类运算、加法类运算、比较运算、逻辑与、逻辑异或、逻辑或：

```
<expr>          ::= <or_expr>
<or_expr>       ::= <xor_expr> | <or_expr> "OR" <xor_expr>
<xor_expr>      ::= <and_expr> | <xor_expr> "XOR" <and_expr>
<and_expr>      ::= <compare_expr> | <and_expr> "AND" <compare_expr>
<compare_expr>  ::= <add_expr> | <add_expr> "=" <add_expr>
                  | <add_expr> "<>" <add_expr> | <add_expr> "<" <add_expr>
                  | <add_expr> "<=" <add_expr> | <add_expr> ">" <add_expr>
                  | <add_expr> ">=" <add_expr>
<add_expr>      ::= <mult_expr> | <add_expr> "+" <mult_expr>
                  | <add_expr> "-" <mult_expr>
<mult_expr>     ::= <unary_expr> | <mult_expr> "*" <unary_expr>
                  | <mult_expr> "/" <unary_expr> | <mult_expr> "MOD" <unary_expr>
<unary_expr>    ::= <primary> | "-" <unary_expr> | "NOT" <unary_expr>
                  | "ABS" <unary_expr>
<primary>       ::= <literal> | <identifier> | <identifier> "[" <expr> "]"
                  | <identifier> "(" [ <expr> { "," <expr> } ] ")"
```

**语句规则**

```
<stmt>           ::= <assign_stmt> | <if_stmt> | <case_stmt>
                   | <for_stmt> | <while_stmt> | <repeat_stmt>
                   | <fb_call_stmt> | "RETURN" ";" | "EXIT" ";"
<assign_stmt>    ::= <identifier> ":=" <expr> ";"
<if_stmt>        ::= "IF" <expr> "THEN" <stmt_list>
                     { "ELSIF" <expr> "THEN" <stmt_list> }
                     [ "ELSE" <stmt_list> ] "END_IF" ";"
<case_stmt>      ::= "CASE" <expr> "OF" <case_element>+ [ "ELSE" <stmt_list> ]
                     "END_CASE" ";"
<case_element>   ::= <case_value> { "," <case_value> } ":" <stmt_list>
<case_value>     ::= <literal> | <literal> ".." <literal>
<for_stmt>       ::= "FOR" <identifier> ":=" <expr> "TO" <expr>
                     [ "BY" <expr> ] "DO" <stmt_list> "END_FOR" ";"
<while_stmt>     ::= "WHILE" <expr> "DO" <stmt_list> "END_WHILE" ";"
<repeat_stmt>    ::= "REPEAT" <stmt_list> "UNTIL" <expr> "END_REPEAT" ";"
<fb_call_stmt>   ::= <identifier> "(" <fb_param> { "," <fb_param> } ")" ";"
<fb_param>       ::= <identifier> ":=" <expr>
<stmt_list>      ::= { <stmt> }
```

**程序结构规则**

```
<program>        ::= <program_pou> | <function_pou> | <function_block_pou>
<program_pou>    ::= "PROGRAM" <identifier>
                     { <var_decl_section> } <stmt_list> "END_PROGRAM"
<function_pou>   ::= "FUNCTION" <identifier> ":" <type>
                     { <var_decl_section> } <stmt_list> "END_FUNCTION"
<function_block_pou> ::= "FUNCTION_BLOCK" <identifier>
                         { <var_decl_section> } <stmt_list> "END_FUNCTION_BLOCK"
<var_decl_section> ::= "VAR" [ "CONSTANT" | "RETAIN" ] <var_decl>+ "END_VAR"
                     | "VAR_INPUT" <var_decl>+ "END_VAR"
                     | "VAR_OUTPUT" <var_decl>+ "END_VAR"
                     | "VAR_IN_OUT" <var_decl>+ "END_VAR"
<var_decl>       ::= <identifier> { "," <identifier> } ":" <type> [ ":=" <literal> ]
```

 
### 3.5 语句的形式化剪裁

语句剪裁遵循与表达式剪裁一致的基本原则，但面临两个额外的形式化挑战。第一个挑战是控制流的结构化完备性：保留的语句集在 Böhm-Jacopini 定理（1966）的意义下必须足以表达任意控制逻辑，不能因为追求形式化可验证性而牺牲语言的表达能力。第二个挑战是循环终止性的编译期判定：安全关键系统中不允许存在非终止计算，因此 WHILE 和 REPEAT 循环必须带有编译期可验证的终止性证明机制，而非像通用语言那样依赖运行时监控或简单地假设循环终止。SafeST 的应对策略是在接受这两个挑战的前提下，对 IEC 61131-3 的全部语句构造逐条进行 P1-P4 审查，最终得到九条保留语句和六条排除语句。


#### 3.5.1保留的语句构造

保留的语句按照功能分为九个范畴，每个范畴对应一个语法构造。表 5 列出了全部保留构造及其对 P1-P4 的满足情况。列定义与表 3 相同：P1 用例列给出该构造在安全关键系统中不可替代的应用场景；P2、P3 和 P4 三列分别标记该构造是否通过对应判据的审查。

**表 5　保留的语句构造**

| 范畴 | 保留构造 | P1 用例 | P2 可判定 | P3 可建模 | P4 WCET |
|------|---------|---------|:---------:|:---------:|:-------:|
| 赋值 | `x := e` | 控制律计算、联锁输出赋值 | 满足 | 满足 | 满足 |
| 条件分支 | `IF e THEN ... ELSIF ... ELSE ... END_IF` | 联锁条件判断、报警阈值判断 | 满足 | 满足 | 满足 |
| 多路分支 | `CASE e OF ... END_CASE` | 状态机状态转移、多模式选择 | 满足 | 满足 | 满足 |
| 有界循环 | `FOR i := e1 TO e2 BY e3 DO ... END_FOR` | 批量通道扫描、数组遍历 | 满足 | 满足 | 满足 |
| 条件循环 | `WHILE e DO ... END_WHILE` | 等待传感器条件满足、非确定步长迭代 | 满足 | 满足 | 满足 |
| 后测试循环 | `REPEAT ... UNTIL e END_REPEAT` | 至少执行一次的数据采集、握手协议 | 满足 | 满足 | 满足 |
| FB 调用 | `inst(p1 := e1, p2 := e2)` | 定时器、计数器、PID 等标准功能块复用 | 满足 | 满足 | 满足 |
| 提前返回 | `RETURN` | 异常条件提前退出函数 | 满足 | 满足 | 满足 |
| 循环中断 | `EXIT` | 循环内满足条件时提前中止 | 满足 | 满足 | 满足 |

上表所示九类语句构造覆盖了结构化编程的全部控制流模式。三种循环各有其不可替代的用例：FOR 适用于迭代次数在编译期已知的批量计算，上下界常量保证了迭代次数在编译期即可计算，满足 P2 和 P4；WHILE 适用于前置条件判断的循环，Loop Variant 注解保证终止性；REPEAT 适用于至少执行一次的后置条件循环，同样通过 Loop Variant 保证终止性。FB 调用是 IEC 61131-3 领域特有的构造，SafeST 要求所有 FB 实例在编译期静态声明，调用图完全已知。RETURN 和 EXIT 作为工程便利的扩充，分别提供提前退出和循环中断的能力，且其使用范围受编译期约束限制（RETURN 仅限 FUNCTION 体内、EXIT 仅限循环体内），因此不破坏控制流的结构化性质。

#### 3.5.2排除的语句构造

表 6 列出了全部被排除的语句构造，每行标注违反的判据、具体理由、IEC 61131-3 中的代码示例以及 SafeST 推荐的替代方案。

**表 6　排除的语句构造**

| 构造 | 违反判据 | 违反理由 | IEC 61131-3 示例 | SafeST 替代方案 |
|------|---------|---------|-----------------|----------------|
| 顺序功能图：`STEP`、`TRANSITION`、`ACTION` | P1、P2、P3、P4 | 安全级仪控的连锁保护逻辑更适合用状态机加 CASE 表达，SFC 的步进模型在多个转换条件同时满足时需要冲突解决策略，引入语义非确定性。并发步进需要交织模型，状态空间随步数指数增长。并行分支的执行路径数无法在编译期确定，WCET 分析不可行 | `STEP S1: N Action1; TRANSITION FROM S1 TO S2` | `CASE state OF ... END_CASE` 状态机 |
| 无条件跳转：`JMP`、标签 | P1、P2、P3、P4 | IEC 61508-3 第 5.2 节明确禁止安全关键系统中使用非结构化控制流。间接跳转的目标地址在编译期不可判定，即使直接跳转也会破坏结构化归纳证明中良基推导树的完整性。非结构化跳转导致控制流图包含不可达边和回边，WCET 路径分析需处理任意循环嵌套的组合 | `JMP label` | IF、CASE 或结构化循环 |
| 动态内存分配：`__NEW`、`__DELETE` | P1、P2、P3、P4 | 安全级系统中所有资源在初始化阶段静态分配，运行时不存在需要动态创建或销毁变量的场景。堆分配函数的返回值在编译期完全不可预测。带堆的运行时模型需要维护复杂的不变量，显著增加形式化证明的工作量。堆分配的执行时间取决于碎片化程度 | `p := __NEW(INT)` | VAR 块静态声明 |
| 异常处理：`TRY`、`CATCH`、`__QUERY_EXCEPTION` | P1、P2、P3、P4 | 安全关键系统采用故障-安全原则，异常应驱动系统进入已知的安全态而非被捕获后继续不可靠的执行。异常是否抛出依赖运行时数据，静态不可预测。异常的形式化语义需要异常状态和栈展开规则，证明需处理非局部控制流。异常处理的执行时间随栈展开深度变化 | `TRY x := y / z; CATCH ...` | `IF z <> 0 THEN x := y / z ELSE x := 0` |
 | 多目标赋值：`a, b := c, d` | P1 必要条件不满足 | 多目标赋值从本质上说是语法糖，不存在单一赋值无法表达的不可替代安全用例。其余三条判据均满足 | `a, b := c, d` | `a := c; b := d` |
| 内联非 ST 代码：`__codedescriptor` | P1、P2、P3、P4 | 在安全关键系统中插入未经形式化验证的非 ST 代码，从信任链的角度等同于在数学证明中引入未经证明的前提，其后果是整个验证链条的完全断裂。非 ST 代码的语义不属于 SafeST 的形式化范畴，WCET 不可由 SafeST 编译器保障 | `__codedescriptor { /* C code */ }` | 完全禁止，无替代方案 |

表 6 展示的六类排除构造可以归纳为两种不同性质的排除类型。第一种类型是原则性排除，包括 SFC、JMP、动态内存分配、异常处理和内联代码共五类构造。这五类构造均同时违反全部四条原则，在 P1-P4 框架下没有任何保留的合理性。它们的排除不是工程经验的权宜之策，而是形式化推理的必然结论——这些构造的语义模型在数学上无法同时满足语义确定性、编译期可判定性和 WCET 可计算性这三个安全关键系统的根本要求。

第二种类型是语法糖排除，对应多目标赋值这一构造。多目标赋值在形式化上不存在问题：其余三条判据均满足，Coq 中可以建模为多个单赋值语句的语法糖展开。但 P1 的必要条件不满足——不存在单目标赋值无法表达的安全关键用例。保留此类构造只会增加编译器的复杂度而不增加表达能力，因此被排除以保持语言的最小性和证明框架的简洁性。

#### 3.5.3形式化结论

保留的九条语句构造在 Böhm-Jacopini 意义下构成结构化控制流的最小完备集：赋值提供顺序执行的能力，IF 和 CASE 提供条件分支的能力，FOR、WHILE 和 REPEAT 提供三种不同模式的循环能力，FB 调用、RETURN 和 EXIT 作为领域特定和工程便利的扩充但均可约简为基本控制结构。被排除的六类构造中，五类属于原则性排除（违反全部四条判据），一类属于语法糖排除（P1 必要条件不满足）。对于原则性排除的构造，不存在任何在安全关键系统中安全使用的前提条件；对于语法糖排除的构造，存在结构化语义等价的替代方案。

## 4 影子类型理论:Q*质量体系
在安全级工业控制系统中，传感器信号的可靠性信息（即信号质量）与信号数值本身同等重要。一个来自故障传感器的"正常"读数比一个来自健康传感器的"异常"读数更加危险。然而，IEC 61131-3 标准以及现有的安全子集方案均未将信号质量作为语言层面的一等概念加以处理，质量检查被留给程序员的显式函数调用，质量传播则依赖手工程序维护。本节提出影子类型理论，将质量维度嵌入类型系统，使得质量传播成为编译期自动推导的过程而非运行时可遗漏的检查。本节从质量码的代数结构出发，建立双模质量传播体系——串行链取较差者(worst)、并行冗余取较好者(best)，给出 Q*类型的定义与类型规则，证明两种传播函数的单调性，并设计影子内存布局作为其编译实现基础。

### 4.1 问题的形式化

工业控制系统中，传感器信号 $x$ 除了数值 $\text{val}(x) \in \mathbb{R}$ 外，还附带一个**质量状态** $\text{qual}(x) \in Q$。传统做法中，$\text{qual}$ 与 $\text{val}$ 是分离的：质量检查在代码中通过显式调用 $\text{Q\_GOOD}(x)$ 等函数执行，质量传播依赖程序员手动维护。这种分离导致两个根本性问题。

其一是**不完备性**：程序员可能忘记在某条信号路径上检查或传播质量，导致下游决策基于不可靠数据。考虑一个典型的三选二表决逻辑：

$$
\text{out} := (a \land b) \lor (b \land c) \lor (c \land a)
$$

如果程序员只检查了 $a$ 的质量而忽略了 $b$ 和 $c$，则当 $a$ 为 GOOD 但 $b$ 为 BAD 时，表决结果仍然可能被输出为 TRUE（若 $b \land c$ 分支因 $b$ 质量不可信而产生错误 TRUE）。这种错误在传统做法中无法被编译器捕获。

其二是**不可组合性**：质量传播逻辑与控制逻辑交织在一起，难以独立推理和验证。例如，PID 控制器的输出质量取决于三个输入（设定值、过程值、比例增益）的质量，但在传统做法中这种依赖关系被分散在 PID 算法实现的各个条件分支中，无法被统一分析和验证。

为解决这些问题，我们提出**影子类型理论**，将质量作为类型的"影子"维度，与数值维度并列为语言的一等公民。质量传播不再是程序员的责任，而是编译器通过类型检查自动推导的过程。

### 4.2 质量域与双模传播

#### 4.2.1 质量域定义

质量码集合 $Q$ 定义为一个二元素全序格，以满足安全关键系统对质量判断的绝对确定性要求——在任何时刻，一个信号要么可信（GOOD），要么不可信（BAD），不存在中间状态。

**定义 3（质量格）**。质量码构成一个二元素良基全序格 $(Q, \land, \lor)$:

$$
Q = \{\mathtt{GOOD}, \mathtt{BAD}\}, \quad \mathtt{GOOD} < \mathtt{BAD}
$$

质量码编码（1 字节，低 1 位有效）:

| 质量常量 | 编码 | 含义 |
|---------|------|------|
| $\mathtt{GOOD}$ | 0 (0b0) | 信号正常，完全可信 |
| $\mathtt{BAD}$ | 1 (0b1) | 信号无效，禁止用于控制 |

该偏序诱导出 meet 运算 $\land$ 和 join 运算 $\lor$:

$$
q_1 \land q_2 = \min(q_1, q_2) = \text{较差者}, \quad
q_1 \lor q_2 = \max(q_1, q_2) = \text{较好者}
$$

全序性质保证了 $\land$ 和 $\lor$ 有闭式表达式，可在 $O(1)$ 时间内计算，满足 P4（WCET 可计算）的要求。

#### 4.2.2 双模传播策略

**定义 4（串行衰减 worst）**。

$$
\text{worst}(q_1, q_2) \triangleq q_1 \land q_2
$$

即二元运算的结果质量取两个操作数质量中"较差"者。在安全关键系统中，信号链的可靠性由最薄弱的环节决定：计算结果的正确性依赖**所有**输入的正确性，因此输入中即使只有一个质量差，结果也不可信。

**定义 5（并行择优 best）**。

$$
\text{best}(q_1, q_2) \triangleq q_1 \lor q_2
$$

即多路冗余选择中输出质量取所有候选信号中"较好"者。这是 N 取 K 表决机制的数学抽象：当存在多条独立冗余的信号路径时，可以选择质量最好的一条作为输出。

双模传播策略对应于安全级系统的两个正交设计原则：

| 拓扑 | 操作 | 代数 | 工程直觉 |
|------|------|------|---------|
| 串行链（二元运算、比较、逻辑） | $\land$（取较差） | $\text{worst} = q_1 \land q_2$ | 链条强度 = 最弱一环 |
| 并行冗余（多路选择、信号表决） | $\lor$（取较好） | $\text{best} = q_1 \lor q_2$ | 冗余路径 = 择优而取 |

### 4.3 Q*类型定义与类型规则

#### 4.3.1 Q*类型定义

**定义 6（Q*类型）**。对于每个基础类型 $\tau \in \mathcal{T}_{ST}$，定义其带质量位的版本 $\tau^*$（称为 Q*类型，如 $\mathtt{QINT}$、$\mathtt{QREAL}$ 等）。Q*类型的值空间为:

$$
\mathcal{V}_{\tau^*} = \mathcal{V}_\tau \times Q
$$

即每个 Q*类型变量同时包含一个数值和一字节质量码。

#### 4.3.2 表达式类型规则

类型环境 $\Gamma$ 是一个从变量名到类型的偏函数：$\Gamma : \mathcal{V}\text{ar} \rightharpoonup \mathcal{T}_{\text{ST}}$。$\Gamma \vdash e : \tau$ 表示在类型环境 $\Gamma$ 下，表达式 $e$ 具有类型 $\tau$。以下每条规则均包含质量传播条款。

**字面量和变量（T-Lit, T-Var）**:

$$
\frac{}{\Gamma \vdash c : \mathtt{typeof}(c)^*} \quad (\text{质量} = \mathtt{GOOD}) \tag{T-Lit}
$$

$$
\frac{\Gamma(x) = \tau^*}{\Gamma \vdash x : \tau^*} \tag{T-Var}
$$

**一元运算（T-Neg, T-Not, T-Abs）**：质量透传，结果质量等于操作数质量。以取负为例:

$$
\frac{\Gamma \vdash e : \tau^* \quad \tau \in \{\mathtt{INT}, \mathtt{DINT}, \mathtt{LINT}, \mathtt{REAL}, \mathtt{LREAL}\}}{\Gamma \vdash -e : \tau^*} \quad (\text{质量} = \text{qual}(e)) \tag{T-Neg}
$$

**二元算术运算（T-Add, T-Sub, T-Mul, T-Div）**：结果质量取两个操作数中**较差**者（$\land$，串行衰减）。以加法为例:

$$
\frac{\Gamma \vdash e_1 : \tau_1^* \quad \Gamma \vdash e_2 : \tau_2^* \quad \text{promote}(\tau_1, \tau_2) = \tau}{\Gamma \vdash e_1 + e_2 : \tau^*} \quad (\text{质量} = \text{qual}(e_1) \land \text{qual}(e_2)) \tag{T-Add}
$$

**比较运算（T-Eq 等）**：结果类型为 $\mathtt{BOOL}^*$，质量传播同二元运算:

$$
\frac{\Gamma \vdash e_1 : \tau_1^* \quad \Gamma \vdash e_2 : \tau_2^* \quad \text{promote}(\tau_1, \tau_2) = \tau}{\Gamma \vdash e_1 = e_2 : \mathtt{BOOL}^*} \quad (\text{质量} = \text{qual}(e_1) \land \text{qual}(e_2)) \tag{T-Eq}
$$

**逻辑运算（T-And, T-Or, T-Xor）**：尽管短路求值可能在运行时跳过部分操作数，但静态类型规则保守地使用 $\land$ 传播质量:

$$
\frac{\Gamma \vdash e_1 : \mathtt{BOOL}^* \quad \Gamma \vdash e_2 : \mathtt{BOOL}^*}{\Gamma \vdash e_1 \;\mathtt{AND}\; e_2 : \mathtt{BOOL}^*} \quad (\text{质量} = \text{qual}(e_1) \land \text{qual}(e_2)) \tag{T-And}
$$

**隐式类型转换（T-QCast, T-QStrip）**:

$$
\frac{\Gamma \vdash e : \tau}{\Gamma \vdash e : \tau^*} \quad (\text{质量} = \mathtt{GOOD}) \tag{T-QCast}
$$

$$
\frac{\Gamma \vdash e : \tau^*}{\Gamma \vdash \mathtt{Q\_VALUE}(e) : \tau} \quad (\text{质量丢弃}) \tag{T-QStrip}
$$

规则 T-QCast 允许普通类型隐式转换为对应的 Q*类型（质量初始化为 GOOD），T-QStrip 通过内置函数 `Q_VALUE` 显式剥离质量码。

### 4.4 质量传播公理化与单调性定理

#### 4.4.1 质量传播规则表

下表系统性地给出所有语法构造的质量传播规则:

| 构造 | 质量传播规则 | 编号 |
|------|------------|------|
| 字面量 $c$ | $\text{qual}(c) = \mathtt{GOOD}$ | Q1 |
| 变量引用 $x$ | $\text{qual}(x) = x.\text{quality}$（运行时读取） | Q2 |
| 一元运算 $\mathit{op}\; e$ | $\text{qual}(\mathit{op}\; e) = \text{qual}(e)$ | Q3 |
| 二元算术 $e_1\;\mathit{op}\; e_2$ | $\text{qual} = \text{worst}(\text{qual}(e_1), \text{qual}(e_2))$ | Q4 |
| 比较运算 $e_1 \lt e_2$ | $\text{qual} = \text{worst}(\text{qual}(e_1), \text{qual}(e_2))$ | Q5 |
| 逻辑运算 | $\text{qual} = \text{worst}(\text{qual}(e_1), \text{qual}(e_2))$ | Q6 |
| 赋值 $x := e$ | $x.\text{quality} = \text{qual}(e)$ | Q7 |
| 函数/FB 调用 | $\text{qual} = \text{worst}(\text{qual}(p_1), \dots, \text{qual}(p_n))$ | Q8 |
| $T \to T^*$ 隐式转换 | $\text{qual} = \mathtt{GOOD}$ | Q9 |
| $T^* \to T$（Q_VALUE） | 质量丢弃 | Q10 |

#### 4.4.2 单调性定理

**定理 3（串行衰减的单调性）**。质量传播函数 $\text{worst}(\cdot, \cdot)$ 在良序 $(Q, >)$ 下是单调的:

$$
\forall q_1, q_1', q_2, q_2' \in Q \cdot (q_1 > q_1') \land (q_2 > q_2') \Rightarrow \text{worst}(q_1, q_2) > \text{worst}(q_1', q_2')
$$

**证明**。由 $\text{worst}(q_1, q_2) = q_1 \land q_2$，在良序 $(Q, >)$ 下 meet 运算 $\land$ 对每个参数都是单调的（因为 $\land$ 对应 $\min$，而 $\min$ 在标量序下显然是单调的）。因此 $\text{worst}(\cdot, \cdot)$ 是单调的。$\square$

**定理 4（并行择优的单调性）**。质量择优函数 $\text{best}(\cdot, \cdot)$ 在良序 $(Q, >)$ 下是单调的:

$$
\forall q_1, q_1', q_2, q_2' \in Q \cdot (q_1 > q_1') \land (q_2 > q_2') \Rightarrow \text{best}(q_1, q_2) > \text{best}(q_1', q_2')
$$

**证明**。由 $\text{best}(q_1, q_2) = q_1 \lor q_2$，join 运算 $\lor$ 对应 $\max$，在标量序下显然是单调的。因此 $\text{best}(\cdot, \cdot)$ 是单调的。$\square$

**推论 1（单调性的工程意义）**。$\text{worst}$ 的单调性确保了"输入越差、输出绝不复好"的故障降级可预测性；$\text{best}$ 的单调性确保了"冗余路径越多、择优结果绝不更差"的容错增益可组合性。单调性还保证了质量推理的可组合性，即对子表达式的质量改进不会降低整体表达式的质量——这是模块化验证的基础。

### 4.5 影子内存布局

Q*类型的编译实现采用**影子内存（shadow memory）**方案。每个 Q*类型变量的数值存储在主数据区，质量码存储在独立的 Quality 影子区中:

$$
\begin{aligned}
\text{offset}_{\text{qual}}(v_i) &= Q\_BASE + i \\
\text{offset}_{\text{val}}(v_i) &= DATA\_BASE + \text{layout}(i)
\end{aligned}
$$

质量与值的分离存储保证了三条关键性质：

1. **质量码与值宽度解耦**：质量码始终占用 1 字节，位宽与值的宽度（1–8 字节）无关，影子区总大小仅与 Q*变量个数有关。
2. **WCET 确定性**：质量传播代码在编译期插入，运行时不引入条件分支——质量传播路径是固定的指令序列，WCET 分析无需处理分支爆炸。
3. **向后兼容**：非 Q*基础类型不占用影子区，已有存量代码的内存布局完全不变。

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

## 7 类型安全性的 Coq 证明框架

类型安全是任何形式化语言设计的基石。Wright 和 Felleisen 提出的"进展 + 保持"框架要求：类型良好的程序要么是终止状态，要么可以继续执行（进展）；且类型在计算过程中保持不变（保持）。SafeST 的类型系统同样满足这两条经典性质。然而，本节的目的不仅是陈述这两个定理，而是揭示其背后的 **Coq 证明框架设计**——证明是如何组织的、采用了哪些策略、以及这种组织方式为什么是安全关键系统形式化验证的合理选择。

### 7.1 证明架构：三阶段设计

类型安全性的 Coq 证明遵循一个经典的三阶段架构，这一架构在 Software Foundations（Pierce 等）中定型，并在 CompCert 等大型项目中得到验证。其核心理念是将证明分解为三个层次，每层解决一个不同性质的问题。第一层是归纳定义的 `has_type` 关系，它作为类型推导规则的数学规范，每条规则对应一个构造子，推理友好，适合作为归纳证明的前提。第二层是可判定函数 `type_check_expr`，它是实际执行的可判定类型检查器，可在 Coq 中通过 `compute` 求值，计算友好，可在程序编译时调用。第三层是 Progress 和 Preservation 元定理，它们基于 `has_type` 的归纳结构进行证明，而非直接基于可判定检查函数的递归结构。第一层与第二层之间通过等价性证明（soundness + completeness）建立联系，而第三层则利用该等价性将 `has_type` 的归纳结论传递给 Progress 和 Preservation 的证明。

这一分离的动机在于：Progress 和 Preservation 的证明需要对类型推导树做归纳，使用关系型定义 `has_type` 才是自然的选择——它的每条规则对应一个构造子，归纳假设的结构直接对应语言构造的语法结构。而可判定类型检查函数作为可判定函数，其递归结构由实现细节（模式匹配顺序、辅助函数的调用图）决定，不适合作为归纳证明的对象。然而，要让外部读者相信"类型检查器做对了"，需要证明两者等价。

**定理 10（判定器等价性）**。可判定类型检查函数与归纳类型关系在如下意义下等价：

$$\text{type\_check\_expr}(\emptyset, \Gamma, e) = \text{Some } \tau \iff \text{has\_type}(\emptyset, \Gamma, e, \tau)$$

即可判定类型检查函数返回某个类型当且仅当存在一条以该类型为结论的 `has_type` 推导树。

**证明概要**。Soundness 方向通过对可判定检查函数的递归结构做归纳，对每个分支构造出对应的 `has_type` 推导式。Completeness 方向对 `has_type` 的推导树做结构归纳，利用类型提升函数、一元运算符有效性函数等辅助函数的完备性引理，将归纳假设转化为可判定检查函数的成功返回值。$\square$

这一等价性定理的价值在于它充当了**规范与实现之间的桥梁**：使用者可以通过执行可判定类型检查函数来获得类型检查结果，而元定理的证明则可以基于更抽象的 `has_type` 来进行，无需关心可判定检查函数的实现细节。

### 7.2 Progress 定理的证明策略

**定理 11（进展性）**。对于任意类型良好的 SafeST 程序 $P$：

$$\vdash P : \tau \Rightarrow \forall \sigma \in \Sigma_{ST} \cdot \big( \text{is\_terminal}(\sigma) \lor \exists \sigma' \in \Sigma_{ST} \cdot \sigma \xrightarrow{ST} \sigma' \big)$$

即类型良好的程序不会在非终止状态"卡住"（stuck），要么已经是终止状态，要么可以继续执行。

**证明策略**。证明的核心是对语句结构做情形分析，对每个语句类别分别构造出一个可执行的一步。关键观察是：SafeST 的语义确定性使得每条转移规则的后继状态唯一确定，因此"存在后继状态"的证明等价于"转移规则的前提条件全部满足"的证明。

对于赋值语句，类型良好性保证右端表达式在给定状态中具有良类型。由于 SafeST 的所有运算都是全函数（除零返回 0，无处可除），表达式求值总有定义，因此赋值规则的前提成立，一步可执行。对于条件分支语句，条件表达式必然为布尔类型（由类型检查保证），其求值结果要么为真要么为假，因此总可以触发 `IfT` 或 `IfF` 规则中的一条。对于 `WHILE` 循环，小步语义中将其展开为条件判断加循环体加递归的形式，无论条件真假都至少有一个可执行步。对于 `FOR` 循环，循环变量初始化为起始值后，至少可以执行循环体的第一句。对于 `CASE` 多路分支，选择表达式为整数类型，其值必然匹配某个分支或落入默认分支。对于 `EXIT` 和 `RETURN` 语句，它们在语义中对应跳转操作，跳转目标由编译期确定，始终可执行。对于循序复合语句，若前一子句可推进则复合语句可推进，若前一子句已终止则后一子句的首句可执行。

证明的关键支撑引理是表达式求值的总定义性：

**引理 1（表达式求值可推进）**。对于任意在类型环境中良类型的表达式 $e$（即 `has_type(∅, Γ, e, τ)` 成立）和任意满足该类型环境的状态 $\sigma$，表达式求值函数 $\llbracket e \rrbracket_\sigma$ 总有定义（返回某个值）。

**证明**。对表达式 $e$ 的结构做归纳。基础情形（字面量、变量引用）直接由状态定义可得。归纳情形中，每个子表达式由归纳假设保证有定义，且运算本身是全函数（二元整数运算在除零时返回 0 而非未定义，浮点运算对所有浮点输入有定义）。因此 $\llbracket e \rrbracket_\sigma$ 总是返回某个值。$\square$

此引理之所以成立，根本原因在于 SafeST 在语言设计阶段（P1-P4 剪裁框架）就已经排除了所有可能导致求值失败的特性——没有指针解引用（违反 P2）、没有动态分配（违反 P4）、没有除零陷阱（返回 0 而非异常），所有转移函数的定义域覆盖了整个状态空间。**Progress 的成立并非编译器实现的功劳，而是 SafeST 语言设计的直接推论**。

### 7.3 Preservation 定理的证明策略

**定理 12（保类型性）**。对于任意类型良好的 SafeST 程序 $P$：

$$\vdash P : \tau \land \sigma \xrightarrow{ST} \sigma' \Rightarrow \vdash_{\sigma'} P : \tau$$

即类型在计算过程中保持不变。

**证明策略**。Preservation 的论证分为两个层次。第一层是程序级保持，这是直接的：程序良类型性谓词是一个纯语法属性，仅依赖程序的抽象语法树和声明信息，不依赖任何运行时状态。由于一步执行不改变程序的抽象语法树，所有声明和类型标注维持不变，因此程序级的良类型性平凡地保持。

第二层是状态级保持，这需要更细致的论证。我们引入运行时类型一致性谓词 $\text{Consistent}$：

$$\text{Consistent}(\sigma) := \forall (x, v) \in \sigma.\text{vars} \cdot \text{typeof}(v) \leq \text{decltype}(x)$$

即每个变量的运行时值类型必须在其声明类型的子类型关系下相容。例如，若变量 $x$ 声明为 `INT`，则运行时值可以是 `SINT`、`INT` 或 `DINT`（由类型提升偏序 $\preceq$ 确定），但不能是 `BOOL` 或 `REAL`。然后证明状态保持引理：

**引理 2（状态保持）**。对于任意良类型程序 $P$，若 $\text{Consistent}(\sigma)$ 成立且 $\text{step\_st}(P, \sigma, \sigma')$，则 $\text{Consistent}(\sigma')$ 成立。

**证明**。对执行规则的每种情形做分析。对于赋值规则，程序良类型性保证类型检查器对赋值语句返回成功，这意味着左端变量声明类型与右端表达式类型相容。由 $\text{Consistent}(\sigma)$ 和引理 1，表达式求值返回的类型与静态检查时的类型一致，因此新值的类型与声明类型相容，更新后的状态保持 $\text{Consistent}$。对于条件分支规则，不修改任何变量的值，因此 $\text{Consistent}$ 平凡保持。对于循环展开规则，`WHILE` 在小步语义中展开为条件判断加循环体加递归，不改变变量值集合，$\text{Consistent}$ 保持。对于循序复合规则，由归纳假设对子语句的保持性可得。$\square$

将两个层次合并，即得 Preservation 定理的完整证明。值得强调的是，状态保持论证之所以只需简单的类型相容性检查而非更复杂的不变量推理，根本原因在于 SafeST 没有指针别名（不会出现通过一个指针修改变量而另一个指针意外指向同一位置的情况）、没有动态类型转换（运行时类型不会突变）、没有副作用函数（函数调用不会隐式修改外部变量）。这些限制同样是 P1-P4 剪裁框架的产物。

### 7.4 整体安全性：进展 + 保持的汇合

联合 Progress 和 Preservation，可以证明类型安全的最终定理：

**定理 13（类型安全性）**。对于任意类型良好的 SafeST 程序 $P$ 和任意满足 $\text{Consistent}(\sigma_0)$ 的初始状态 $\sigma_0$：

$$\text{star\_step\_st}(P, \sigma_0, \sigma) \Rightarrow \text{terminal\_state}(\sigma) \lor \exists \sigma' \cdot \text{step\_st}(P, \sigma, \sigma')$$

**证明**。对多步执行的步数 $n$ 做数学归纳。基例 $n=0$ 时，由 Progress 定理（若非终态则存在下一步）可得结论。归纳步骤中，设 $\sigma_0 \xrightarrow{ST}^n \sigma_n \xrightarrow{ST} \sigma_{n+1}$。由归纳假设，$\sigma_n$ 要么是终态（已得证），要么存在下一步。Preservation 定理保证 $\text{Consistent}(\sigma_n)$ 保持，因此 Progress 定理可再次应用，保证 $\sigma_n$ 若为非终态则存在下一步。$\square$

这一定理的含义是：**类型良好的 SafeST 程序永远不会陷入 stuck 状态**——不存在程序尚未结束但无规则可用的中间状态。这正是 Wright-Felleisen 类型安全框架所要保证的核心性质，也是安全关键系统中"程序行为完全可预测"这一要求的精确数学表述。

### 7.5 证明工程化的若干考量

上述证明框架在 Coq 中的实现遵循一组工程惯例，这些惯例对于保证证明的可维护性和可扩展性至关重要。

在自动化策略的选择方面，SafeST 类型安全性的证明主要依赖三类自动化策略：`auto` 和 `eauto` 用于处理 `has_type` 推导树的构造和执行规则的匹配；`lia`（线性整数算术）用于处理类型提升偏序 $\preceq$ 中的数值约束和数组边界计算；`inversion` 用于处理归纳类型构造子的情形拆分。未使用 Coq 的 SMT 策略，理由是 SafeST 的类型系统不包含需要复杂约束求解的子类型推导；Q*类型的 meet/join 运算在四元素集上是可穷举的，通过 `repeat match` 即可完全处理。

在归纳原则的选择方面，标准的结构归纳对 `has_type` 和执行关系都能直接适用，无需定义自定义归纳原则。这是因为 SafeST 的抽象语法树是良基树（无递归类型、无循环引用），Coq 自动生成的 `induction` 策略已经足够。这看似平凡，但正是 SafeST 剪裁框架的成就——如果在语言中保留了递归函数，则需要自定义良基归纳原则，证明复杂度将显著上升。

在证明架构的正交性方面，每新增一个语言构造（例如未来扩展中增加定时器 `TON`/`TOF` 类型），需要修改的 Coq 文件遵循固定的模式：抽象语法（`safest.v`）到类型规则和操作语义（`compiler_correctness.v`），再到类型检查器和元定理（`typechecker.v`），最后到代码生成器和语义保持证明（`codegen.v`）。这五处修改在逻辑上是正交的，可以独立验证。这种正交性继承了 CompCert 的模块化设计哲学，使得 VeriSTC 的证明框架在面对语言演进时具有良好的可扩展性。

### 7.6 类型安全与语义保持的衔接

作为本节收尾，值得阐明类型安全性（第 7 节）与双重语义模拟（第 6 节）之间的逻辑关系。两者在编译器验证中扮演不同的角色。语义保持（定理 5 和定理 6）是一个**跨层**的保证——SafeST 源程序的执行行为与 SafeASM 目标代码的执行行为在抽象关系 $\mathcal{R}$ 下一致，它回答的是"编译后的代码是否忠实地反映了源程序的意图"的问题。而类型安全（定理 11 到定理 13）是一个**单层**的保证——SafeST 语言自身的执行不会陷入不可预测的 stuck 状态，它回答的是"源语言本身是否具有良基的运行时行为"的问题。

两者的关系可以表述为：语义保持定理保证编译后的 SafeASM 代码忠实地反映了 SafeST 源程序的语义，而类型安全定理保证 SafeST 源程序的执行过程不会 stuck。两者合在一起，意味着编译后的 SafeASM 代码同样不会在执行过程中陷入不可预测的状态。这一结论可以从定理 13 和定理 5 直接推导得出：

$$\text{well\_typed}(P) \land \mathcal{R}(\sigma_0, \tau_0) \land \tau_0 \xrightarrow{ASM}^* \tau \Rightarrow \text{terminal}_{\text{ASM}}(\tau) \lor \exists \tau' \cdot \tau \xrightarrow{ASM} \tau'$$

即良类型的 SafeST 程序经编译后，其 SafeASM 代码的执行同样满足"非终态即可继续执行"的性质。这为安全关键系统中"从控制逻辑到字节码的整条信任链"提供了完整的数学保障。

## 8 相关工作

VeriSTC 的工作横跨形式化验证编译器、工业语言安全子集、WCET 分析与质量语义四个研究领域。本节将逐一与各领域的代表性工作进行对比,以定位本工作的理论贡献与边界。

### 8.1 形式化验证编译器

CompCert[1]是本工作最直接的理论先导。CompCert 证明了从 Clight 子集到多种目标架构(PowerPC、ARM、x86)的编译正确性,总证明规模超过 40,000 行 Coq。与之相比,VeriSTC 面临一组不同的挑战,可以从四个维度加以对比。从领域语义的复杂性看，IEC 61131-3 的领域特有语义（包括定时器 TON/TOF/TP、功能块 FB 实例化、CASE 多路分支）比 C 语言的对应构造更复杂，但具有更好的结构性。从目标架构的定制性看,SafeASM 是面向安全关键系统的定制字节码，而非通用处理器指令集，这简化了指令编码和 WCET 分析，但要求编译器设计者自行定义完整的指令语义。从内存模型的简化看,SafeST 禁止指针后,内存模型从 CompCert 的带别名堆简化为平坦内存映射,证明复杂度大幅降低。从领域特有的问题看,VeriSTC 引入的质量类型体系(Q*类型)是 CompCert 未处理的领域特有构造。

在工具链架构的全局视角下,VeriSTC 与以 **Lustre/SCADE→C→汇编**为代表的多阶段编译路径形成了鲜明的对比。后者(以下简称为 L2C 类工具链)将 Lustre 或 SCADE 等高阶同步语言编译为 C 代码[3]，再经由通用 C 编译器(GCC、Clang 等)生成目标架构上的汇编指令。这条路径存在三个内在的结构性问题。其一是**中间环节的信任断裂**:即便 Lustre 到 C 的编译器本身是经过形式化验证的,C 编译器作为一个未经验证的组件构成了信任链中的薄弱环节。虽然 CompCert 可以在理论上填补这一缺口——即以 CompCert 替代 GCC 作为后端——但这种"嵌套验证"的架构增加了工具链的集成复杂度和形式化证明的维护成本。其二是**语义抽象层的冗余**:C 语言的中间表示引入了大量与安全关键控制逻辑无关的语义细节——指针运算、内存分配、序列点、未定义行为——这些细节不仅对最终编译结果没有贡献,反而增加了形式化验证的负担(必须处理 C 语言语义中已知的 200 余项未定义行为)。其三是**领域信息在编译过程中的丢失**:Lustre 的同步假设、时钟约束、数据流结构等高层领域语义信息在翻译为 C 语言后即被展开为平坦的控制流和赋值序列,C 编译器无法利用这些语义信息进行深度优化或安全验证,因此 L2C 路径中的 WCET 分析只能后置于汇编代码生成阶段,作为额外的分析步骤而非编译过程的自然输出。

VeriSTC 通过直接将 SafeST 编译为 SafeASM 字节码,从根本上绕过了上述三个问题。由于不存在 C 语言中间表示,工具链中不需要引入任何未经验证的编译器组件;由于 SafeASM 的指令语义与 SafeST 的语义构造之间存在直接的对应关系(见第 6 节的模拟关系),领域语义信息在编译过程中被保持而非丢弃;由于固定宽度编码保证了取指时间的静态可计算性(定理 4),WCET 信息可以作为编译器的直接输出而非事后分析的结果。此外,与 Lustre/SCADE 要求控制工程师学习新的同步数据流语言范式不同,IEC 61131-3 ST 是工业控制领域通用的编程语言,拥有庞大的存量代码库和成熟的工程师群体。VeriSTC 兼容已有 ST 控制代码的能力,使得安全升级可以在不改变工程团队工作流程的前提下渐进式地开展,从而降低了形式化验证技术在工业实践中推广的采用壁垒。

CakeML[5]是另一个经过形式化验证的函数式语言编译器,但与 VeriSTC 不同,CakeML 面向通用函数式编程而非领域特定语言,其语义框架也缺乏对信号质量等工业控制特有关切的支持。

### 8.2 IEC 61131-3 安全子集

PLCopen Safety 规范[2]定义了 SIL 3 级的 ST 安全子集，但它采用**枚举式禁止**的方法论，即列出不可用的语言特性，而非**原则性剪裁**。PLCopen 验证依赖厂商实现的具体测试,不提供数学证明。Beckhoff TwinSAFE、Siemens S7-F/Failsafe 等商业产品部分实现了 PLCopen Safety,但无法保证从控制逻辑到可执行代码之间的语义保持。

VeriSTC 与 PLCopen Safety 的根本区别在于：SafeST 的剪裁基于 P1-P4 四条形式化判据，每条判据均可证伪；SafeST 提供了从语言语义到编译器正确性的完整 Coq 证明，而非仅依赖测试。此外，SafeST 额外增加了质量类型体系，这在 PLCopen Safety 中未被涉及。

### 8.3 WCET 分析方法

当下 WCET 分析的主流方法包括**基于抽象解释**(Wilhelm et al., 2008)[6]和**基于结构路径分析**(Puschner & Burns, 2000)[7]。这些方法的共同特征是：将 WCET 分析作为编译后的**后处理阶段**，即先编译，再分析已生成的机器码。

VeriSTC 的贡献在于证明了一个更强的论点:如果源语言和目标语言都是语义确定性的(定义 1),且编码是固定宽度的,那么 WCET 分析可以**提前到编译器设计中完成**,而非事后由分析工具推导。这意味着在 VeriSTC 框架下，WCET 信息可以作为编译器的**输出**而非分析工具的**输入**——当编译器输出 `.sasm` 文件时，WCET Section 已经包含了完整的 WCET 计算信息，虚拟机可以在加载时直接使用。

### 8.4 质量语义

IEC 61131-3 标准没有规定信号质量的统一处理方式。各厂商以私有函数库提供质量接口，如 Siemens 的 `GET_DP_DIAG`、CoDeSys 的 `__ISVALID`，但对质量传播的语义缺乏形式化定义。

VeriSTC 的 Q*类型体系与程序语言中"基于类型的状态验证"（Swamy et al., 2012）[8]在方法论上一脉相承，即将运行时检查提升为类型约束。然而,Swamy et al. (2012) 解决的是加密协议的保护问题,其状态空间是离散的安全状态;而 Q*类型解决的是信号质量的连续退化问题,其代数结构是带有全序的交换半格。前者要求计算"何时状态允许此操作",后者要求计算"基于多个输入信号的质量,输出信号的质量如何"。

## 9 可优化与可扩展的方向

前文的论述建立了形式化剪裁、影子类型、固定宽度编码与双重语义模拟四者之间的理论关联。这套框架在工业语言的形式化验证方面展现出了一条清晰的技术路径，同时也在多个方向上存在进一步优化和扩展的空间。本节从方法论的一般化推广、形式化框架的自然延伸以及若干有前景的理论深化方向三个层面展开讨论。

### 9.1 方法论的一般化推广

P1-P4 剪裁判据的设计独立于 IEC 61131-3 的具体语法特性，其核心是一组关于语言可验证性的充分条件，因此可以作为一种通用方法论应用于其他工业领域的形式化语言设计中。以 IEC 61499（功能块）为例，其组合语义天然适合操作语义建模，而事件语义的并发性则为 P1-P4 框架提供了一个自然的扩展方向——将 P4 的 WCET 可计算性要求从单线程扩展到并发场景，可以通过交织语义或偏序归约来实现，这恰好是形式化方法中已经充分研究的领域。对于 IEC 61850（变电站自动化），其抽象通信服务接口（ACSI）的语言模型中包含实时约束（如 GOOSE 报文的 4 ms 传输时限），这实际上是 P4 的一种自然推广——将 WCET 从单机范围延伸至网络范围，此时固定宽度编码的优势更为突出，因为网络传输中的确定性延迟同样受益于可预测的数据包大小。而对于 IEC 62541（OPC UA），其信息模型的类型系统可以沿用 P3 的形式化方法进行建模，高阶抽象语法（Higher-Order Abstract Syntax）领域的成熟成果为此提供了坚实的技术基础。上述推广方向表明：P1-P4 框架提供了一组灵活的判据，每个领域只需根据其特有的语义特征对判据的具体内涵进行适配即可。

### 9.2 形式化框架的自然延伸方向

当前证明框架在多个方向上可以自然地延伸和深化，这些延伸不是对框架的修正，而是将其推向更高形式化完备性的增强。

**从语义保持到全程序正确性的衔接。** 本文证明的语义保持关系构成了编译器正确性的核心。在此基础上，可以向全程序正确性（total correctness）的方向自然延伸——全程序正确性要求在语义保持的基础上，进一步在规范层面建立安全属性与程序语义之间的对应关系。VeriSTC 的证明框架可以自然地与 Hoare 逻辑或分离逻辑等程序验证方法衔接，形成"编译器正确性 + 程序逻辑"的双层验证架构：编译器保证编译后的代码忠实地反映了源程序的语义，程序逻辑则保证源程序本身满足安全规范。这一衔接层是本文框架最有价值的扩展方向之一。

**抽象函数的精细化与完备性刻画。** 模拟关系 $R$ 的定义依赖于从 SafeASM 状态空间到 SafeST 状态空间的抽象函数 $\alpha$，而抽象函数的选择本身就是一个可优化的设计空间。本文采用的四维抽象（变量值、质量码、调用栈深度、周期计数）是最小化的实用选择，在此基础上有多种精细化的可能：例如，可以增加内存访问模式维度以支持更细粒度的安全验证，也可以通过建立 Galois 连接来形式化地刻画抽象的完备性。不同的抽象层次适用于不同的验证目标，这种灵活性本身就是框架设计的一个优势。

**质量格的可扩展结构。** 本文定义的二元素质量格 $(Q, \land, \lor)$ 作为安全关键场景的最小完备集，在多数应用中已经足够。对于需要更细粒度质量区分的场景，质量格可以自然地扩展为 n 元素全序格。例如，核电站保护系统中带冗余传感器的"部分故障"（partial failure）信号可以建模为介于 GOOD 和 BAD 之间的中间状态。当扩展为多元素全序时，$\land$（meet）和 $\lor$（join）运算仍然具有封闭性和结合性，且计算复杂度保持 $O(1)$（直接比较编码值）。因此，质量格的扩展性不是限制，而是一个可以根据应用需求灵活调整的参数。

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

[3] ANSYS Inc. SCADE Suite Technical Data Sheet, 2020.

[4] W. Landi. Undecidability of static analysis. *ACM Letters on Programming Languages and Systems*, 1(4):323--337, 1992.

[5] R. Kumar, M. O. Myreen, M. Norrish, and S. Owens. CakeML: a verified implementation of ML. In *Proc. POPL*, 2014.

[6] R. Wilhelm et al. The worst-case execution-time problem. *ACM Transactions on Embedded Computing Systems*, 7(3):1--53, 2008.

[7] P. Puschner and A. Burns. A review of worst-case execution-time analysis. *Real-Time Systems*, 18(2):115--128, 2000.

[8] N. Swamy, J. Chen, C. Fournet, P.-Y. Strub, K. Bhargavan, and J. Yang. Secure distributed programming with type-directed encryption. In *Proc. ICFP*, 2012.

[9] J. C. Reynolds. Separation logic: a logic for shared mutable data structures. In *Proc. LICS*, 2002.

[10] E. W. Dijkstra. The humble programmer. *Communications of the ACM*, 15(10):859--866, 1972.
