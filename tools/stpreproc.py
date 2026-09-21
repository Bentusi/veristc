#!/usr/bin/env python3
"""stpreproc — SafeST 库模板预处理器（参考实现，演示 PRE/T 契约）

用法:
    python3 tools/stpreproc.py input.st -o output.st

展开模型（spec/safest-spec.md 9.4）:
  - 算法实现一份: 每个模板的每个 STATE/OUTPUT 字段生成一个共享
    单表达式 FUNCTION 实体（inline.v 展开域内），全程序只出现一次
  - 状态数据全局: @fb 实例声明展开为 VAR_GLOBAL 上下文块（ME-2/PRE-7）
  - 调用点轻量: inst(A := e, ...) 展开为输入绑定临时量 + 逐字段赋值调用
    <inst>_f := <TPL>_f(...)；不复制算法体，控制流不进调用点
  - 加载期卫生检查: T-1 更新规则完整且仅引用声明端口 / T-2 每实例
    每周期单次调用 / 绑定合法性

授权源文件指令（注释形式，不与 SafeST 语法冲突）:
    (* @use lib-templates/rs_v1.tpl.st *)   引用模板
    (* @fb rs1 : RS_V1 *)                   声明实例

输出为确定性文本（PRE-2）。参考实现面向演示规模：每字段单表达式
更新规则、线性程序段。
"""

import re
import sys
import os
import hashlib

ST_KEYWORDS = {
    "IF", "THEN", "ELSIF", "ELSE", "END_IF", "CASE", "OF", "END_CASE",
    "FOR", "TO", "BY", "DO", "END_FOR", "WHILE", "END_WHILE", "REPEAT",
    "UNTIL", "END_REPEAT", "RETURN", "EXIT", "AND", "OR", "XOR", "NOT",
    "MOD", "ABS", "TRUE", "FALSE", "PROGRAM", "END_PROGRAM", "VAR",
    "END_VAR", "VAR_GLOBAL", "VAR_INPUT", "VAR_STATE", "VAR_OUTPUT",
    "FUNCTION_BLOCK", "END_FUNCTION_BLOCK", "FUNCTION", "END_FUNCTION",
}


class TplError(Exception):
    pass


def code_line(line, in_comment):
    """剥除块/行内注释内容，跨行保持注释状态。
    返回 (本行代码部分, 行末注释状态)。"""
    out, i, n = [], 0, len(line)
    st = in_comment
    while i < n:
        if st:
            j = line.find("*)", i)
            if j < 0:
                return "".join(out), st
            i = j + 2
            st = False
        else:
            j = line.find("(*", i)
            if j < 0:
                out.append(line[i:])
                return "".join(out), st
            out.append(line[i:j])
            i = j + 2
            st = True
    return "".join(out), st


def expr_refs(expr):
    """表达式引用的端口名（保序去重），未声明标识符即报错（T-1）"""
    seen, refs = set(), []
    for tok in re.findall(r"\b[A-Za-z_]\w*\b", expr):
        if tok.upper() in ST_KEYWORDS:
            continue
        if tok not in seen:
            seen.add(tok)
            refs.append(tok)
    return refs


def parse_template(path):
    """受限 FB 模板: @tpl 头 + 端口三分类 + 每字段一条单表达式更新规则"""
    lines = open(path, encoding="utf-8").read().splitlines()
    text = "\n".join(lines)
    m = re.search(r"\(\*\s*@tpl\s+(\w+)([^*]*)\*\)", text)
    if not m:
        raise TplError(f"{path}: 缺少 @tpl 元信息头")
    name = m.group(1)
    meta = dict(re.findall(r"(\w+)\s*=\s*([\w.]+)", m.group(2)))

    ports = {}       # field -> (INPUT/STATE/OUTPUT, type)，保持声明序
    rules = {}       # 可写字段 -> 更新表达式，保持声明序
    rule_order = []
    section = None
    in_body = False
    st = False       # 块注释状态
    for line in lines:
        code, st = code_line(line, st)
        s = code.strip()
        if not s:
            continue
        if s.startswith("FUNCTION_BLOCK"):
            continue
        if s.startswith("END_FUNCTION_BLOCK"):
            break
        dm = re.match(r"^(VAR_INPUT|VAR_STATE|VAR_OUTPUT)$", s)
        if dm:
            section = dm.group(1)[4:]
            in_body = False
            continue
        if s == "VAR":
            raise TplError(f"{path}: 模板内不允许未分类 VAR 段（T-1）")
        if s == "END_VAR":
            section = None
            in_body = True
            continue
        if section:
            pm = re.match(r"^(\w+)\s*:\s*(\w+)\s*;$", s)
            if not pm:
                raise TplError(f"{path}: 端口声明行无法解析: {s}")
            ports[pm.group(1)] = (section, pm.group(2))
            continue
        if in_body:
            am = re.match(r"^(\w+)\s*:=\s*(.+);$", s)
            if not am:
                raise TplError(f"{path}: 模板体必须是每字段一条赋值（T-1）: {s}")
            field, expr = am.group(1), am.group(2).strip()
            if field not in ports:
                raise TplError(f"{path}: 体内写未声明字段 {field}（T-1）")
            if ports[field][0] == "INPUT":
                raise TplError(f"{path}: 输入端口 {field} 不可写（T-1）")
            if field in rules:
                raise TplError(f"{path}: 字段 {field} 重复更新规则（T-1）")
            if re.search(r"\b(IF|ELSE|END_IF|FOR|WHILE|CASE)\b", expr):
                raise TplError(f"{path}: 更新规则必须为单表达式: {field}")
            for tok in expr_refs(expr):
                if tok not in ports:
                    raise TplError(f"{path}: 规则引用未声明标识符 {tok}（T-1）")
            rules[field] = expr
            rule_order.append(field)
    missing = [f for f, (d, _t) in ports.items()
               if d in ("STATE", "OUTPUT") and f not in rules]
    if missing:
        raise TplError(f"{path}: 字段缺少更新规则 {missing}（T-1）")
    if not rules:
        raise TplError(f"{path}: 无 STATE/OUTPUT 更新规则")
    return {"name": name, "meta": meta, "ports": ports,
            "rules": rules, "rule_order": rule_order, "path": path}


def split_arglist(argstr):
    args, depth, cur = [], 0, ""
    for ch in argstr:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if ch == "," and depth == 0:
            args.append(cur)
            cur = ""
        else:
            cur += ch
    if cur.strip():
        args.append(cur)
    out = []
    for a in args:
        pm = re.match(r"^(\w+)\s*:=\s*(.+)$", a.strip())
        if not pm:
            raise TplError(f"非法绑定参数: {a.strip()}")
        out.append((pm.group(1), pm.group(2).strip()))
    return out


def gen_functions(tpl):
    """共享函数实体：每可写字段一个单表达式 FUNCTION，全程序一份"""
    out = []
    for field in tpl["rule_order"]:
        fname = f"{tpl['name']}_{field}"
        expr = tpl["rules"][field]
        refs = [r for r in tpl["ports"] if r in set(expr_refs(expr))]  # 声明序
        out.append(f"FUNCTION {fname} : {tpl['ports'][field][1]}")
        out.append("VAR_INPUT")
        for r in refs:
            out.append(f"  {r} : {tpl['ports'][r][1]};")
        out.append("END_VAR")
        out.append(f"  {fname} := {expr};")
        out.append("END_FUNCTION")
        out.append("")
    return out


def expand_call(tpl, inst, argstr, indent):
    """调用点展开：输入绑定 + 逐字段赋值调用（按声明序，T-4）"""
    out, temps, bound = [], {}, set()
    for port, expr in split_arglist(argstr):
        if port not in tpl["ports"] or tpl["ports"][port][0] != "INPUT":
            raise TplError(f"{inst}: 非法输入绑定 {port}")
        tmp = f"{inst}__in_{port}"
        temps[tmp] = tpl["ports"][port][1]
        bound.add(port)
        out.append(f"{indent}{tmp} := {expr};")
    missing = [p for p, (d, _t) in tpl["ports"].items()
               if d == "INPUT" and p not in bound]
    if missing:
        raise TplError(f"{inst}: 缺少输入绑定 {missing}")
    for field in tpl["rule_order"]:
        fname = f"{tpl['name']}_{field}"
        refs = [r for r in tpl["ports"] if r in set(expr_refs(tpl["rules"][field]))]
        names = {p: (f"{inst}__in_{p}" if tpl["ports"][p][0] == "INPUT"
                     else f"{inst}_{p}") for p in tpl["ports"]}
        argl = ", ".join(names[r] for r in refs)
        out.append(f"{indent}{inst}_{field} := {fname}({argl});")
    return out, temps


def process(src_path, out_path):
    text = open(src_path, encoding="utf-8").read()
    lines = text.splitlines()
    base_dir = os.path.dirname(os.path.abspath(src_path))

    templates = {}
    for m in re.finditer(r"\(\*\s*@use\s+([\w./-]+)\s*\*\)", text):
        t = parse_template(os.path.normpath(os.path.join(base_dir, m.group(1))))
        templates[t["name"]] = t
    instances = dict(re.findall(
        r"\(\*\s*@fb\s+(\w+)\s*:\s*(\w+)\s*\*\)", text))
    for inst, tname in instances.items():
        if tname not in templates:
            raise TplError(f"实例 {inst}: 未找到 @use 模板 {tname}")

    # 1) 预扫描：每程序段的调用与临时量（T-2 检查）
    prog_idx = -1
    calls_seen = set()
    prog_temps = {}
    st = False
    for line in lines:
        code, st = code_line(line, st)
        code = code.strip()
        if code.startswith("PROGRAM"):
            prog_idx += 1
        cm = re.match(r"^(\w+)\(\s*(.*?)\s*\)\s*;$", code)
        if cm and cm.group(1) in instances:
            inst = cm.group(1)
            if inst in calls_seen:
                raise TplError(f"实例 {inst} 本周期第二次调用（T-2）")
            calls_seen.add(inst)
            tpl = templates[instances[inst]]
            temps = prog_temps.setdefault(prog_idx, {})
            for port, _e in split_arglist(cm.group(2)):
                if port not in tpl["ports"] or tpl["ports"][port][0] != "INPUT":
                    raise TplError(f"{inst}: 非法输入绑定 {port}")
                temps[f"{inst}__in_{port}"] = tpl["ports"][port][1]

    # 2) 主展开
    out = []
    cur_prog = -1
    var_injected = set()
    st = False
    for line in lines:
        code, st = code_line(line, st)
        s = code.strip()

        if re.match(r"\s*\(\*\s*@(use|fb)\b", line):
            continue
        if s.startswith("PROGRAM"):
            cur_prog += 1
        cm = re.match(r"^(\w+)\(\s*(.*?)\s*\)\s*;$", s)
        if cm and cm.group(1) in instances:
            inst = cm.group(1)
            tpl = templates[instances[inst]]
            indent = re.match(r"\s*", line).group(0)
            exp_lines, _t = expand_call(tpl, inst, cm.group(2), indent)
            out += exp_lines
            continue

        out.append(line.rstrip())
        if (s == "END_VAR" and cur_prog >= 0
                and cur_prog not in var_injected
                and cur_prog in prog_temps):
            ins = len(out) - 1
            out[ins:ins] = [f"  {tmp} : {ty};"
                            for tmp, ty in prog_temps[cur_prog].items()]
            var_injected.add(cur_prog)

    for p in prog_temps:
        if p not in var_injected:
            raise TplError("调用所在程序段缺少 VAR 段，无法声明输入临时量")

    # 3) 上下文全局块（每实例，STATE/OUTPUT 字段序 = 声明序，T-4/ME-2）
    ctx_blocks = []
    for inst, tname in instances.items():
        tpl = templates[tname]
        fields = [(f, ty) for f, (d, ty) in tpl["ports"].items()
                  if d in ("STATE", "OUTPUT")]
        ctx_blocks.append([f"VAR_GLOBAL  (* instance {inst} of {tname} *)"]
                          + [f"  {inst}_{f} : {ty};" for f, ty in fields]
                          + ["END_VAR", ""])

    # 4) 共享函数实体（每模板一份实现）
    funcs = []
    for tname in sorted(templates):
        funcs += gen_functions(templates[tname])

    # 5) 生成头（PRE-5 manifest 简化形态）
    header = ["(* ================================================================",
              "   GENERATED by tools/stpreproc.py -- DO NOT EDIT BY HAND",
              f"   source: {os.path.basename(src_path)}"]
    for tname in sorted(templates):
        t = templates[tname]
        raw = open(t["path"], "rb").read()
        header.append(f"   template: {os.path.basename(t['path'])}"
                      f" lib={t['meta'].get('lib', '?')}"
                      f" version={t['meta'].get('version', '?')}"
                      f" sha256={hashlib.sha256(raw).hexdigest()[:16]}")
    header += ["   契约: PRE-1/2/5/7, T-1..T-4（实现一份: 共享函数实体）",
               "   ================================================================ *)",
               ""]

    final = header + ctx_blocks_flat(ctx_blocks) + funcs + out
    body = "\n".join(final).rstrip() + "\n"
    open(out_path, "w", encoding="utf-8").write(body)
    return out_path


def ctx_blocks_flat(blocks):
    return [l for b in blocks for l in b]


if __name__ == "__main__":
    argv = sys.argv[1:]
    if len(argv) < 2 or "-o" not in argv:
        print(__doc__)
        sys.exit(2)
    try:
        print("preprocessed:", process(argv[0], argv[argv.index("-o") + 1]))
    except TplError as e:
        print("stpreproc error:", e, file=sys.stderr)
        sys.exit(1)
