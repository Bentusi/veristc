"""
Simulate one algorithm block with the engine the chart runs on.

A block on the library page is simulated exactly the way the whole plant is:
the composed text is compiled to a real `.sasm`, `sim --watch` runs it against a
derived `.plant` table, and every number on the panel comes back in a frame. The
only thing unique to a single block is the driver -- one input point per port and
one ``PROGRAM`` that calls the block once -- so the stimulus, the frames and the
``forced`` flag mean here what they mean on the graph page.

``block_kind`` splits the driver, because the two POUs the compiler accepts are
called differently:

* ``FB`` -- a stateful ``FUNCTION_BLOCK`` is instantiated and called by name with
  its inputs bound by port, so the instance holds its state across cycles;
* ``FUN`` -- a stateless ``FUNCTION`` is an expression, and its formal inputs are
  passed positionally (the parser rejects named arguments on a ``FUNCTION``), so
  its result is written into a plain global the frame can read.
"""

import re

from ..device.models import ChannelBinding, IoVariable, ST_TYPES, Station
from ..device.service import DeviceService
from ..library.models import AlgorithmBlock
from .plant import plant_from_external_variables
from .session import SimError, run_simulation

#: The single instance the FB driver declares and calls.
INSTANCE = "B1"

#: `veri-runtime/core/vm.h` -- the codes a failed cycle carries, put into words so
#: the block page says what the VM hit instead of dumping a bare negative number.
VM_ERROR_TEXT = {
    -1: "栈上溢",
    -2: "栈下溢",
    -3: "运行期除以零",
    -4: "执行到不可达指令",
    -5: "超出单周期指令预算",
    -6: "内存访问越界",
    -7: "非法操作码",
    -8: "调用栈帧越界",
}
_CYCLE_FAILED = re.compile(r"sim: cycle (\d+) failed: (-?\d+)")


def humanize_run_errors(errors: list[str]) -> list[str]:
    """Turn the runner's raw refusal into the one line an engineer can act on.

    `sim` prints the whole plant and mapping table ahead of why a cycle failed,
    which buries the point on a small panel. Only an execution failure is
    reworded here; a stimulus the runner rejected at startup keeps its own words,
    because the offending name or record is exactly what that message is for.
    """
    reworded: list[str] = []
    for message in errors:
        match = _CYCLE_FAILED.search(message)
        if not match:
            reworded.append(message)
            continue
        cycle, code = match.group(1), int(match.group(2))
        reason = VM_ERROR_TEXT.get(code, f"未定义的 VM 错误码 {code}")
        reworded.append(f"第 {cycle} 周期执行失败：{reason}（VM 码 {code}）")
    return reworded


class BlockSimError(Exception):
    """The block cannot be driven -- surfaced to the panel as its own words."""


def _symbol(name: str, taken: set[str]) -> str:
    """Make a port name a writable, collision-free ST identifier."""
    cleaned = re.sub(r"[^A-Za-z0-9_]", "_", (name or "").strip())
    if not cleaned or cleaned[0].isdigit():
        cleaned = "P" + cleaned
    candidate = cleaned
    suffix = 2
    while candidate in taken:
        candidate = f"{cleaned}_{suffix}"
        suffix += 1
    taken.add(candidate)
    return candidate


class BlockProgram:
    """Everything a single-block run needs, ready for ``run_simulation``."""

    def __init__(
        self,
        block: AlgorithmBlock,
        st_text: str,
        plant_text: str,
        names: list[str],
        inputs: list[dict],
        outputs: list[dict],
    ) -> None:
        self.block = block
        self.st_text = st_text
        self.plant_text = plant_text
        self.names = names
        self.inputs = inputs
        self.outputs = outputs
        self.cycle_ms = 100

    def run(self, *, cycles: int, forces=None, script=None):
        """Hand the driver, the object table and the stimulus to the shared runner."""
        return run_simulation(
            self.st_text,
            self.plant_text,
            self.names,
            cycles=cycles,
            cycle_ms=self.cycle_ms,
            forces=forces,
            script=script,
        )

    def ports_payload(self) -> dict:
        return {"inputs": self.inputs, "outputs": self.outputs}


def _st_type(data_type: str) -> str:
    normalized = (data_type or "BOOL").upper()
    if normalized not in ST_TYPES:
        raise BlockSimError(f"端口类型 {data_type!r} 不是 SafeST 支持的类型")
    return normalized


def _body_ports(template: str) -> tuple[list[str], list[str]]:
    """The FUNCTION_BLOCK's own VAR_INPUT / VAR_OUTPUT names, in declaration order.

    A block's port list is the panel's view; these names are what the compiler
    accepts as a call's bind names and as the instance's field symbols. They are
    normally the same, but the editor can rename a port without touching the
    source body, so the driver resolves each declared port against these.
    """
    sections: dict[str, list[str]] = {"VAR_INPUT": [], "VAR_OUTPUT": []}
    for keyword in sections:
        for body in re.findall(r"\b%s\b(.*?)END_VAR" % keyword, template or "", re.S):
            for line in body.splitlines():
                declared = re.match(r"\s*([A-Za-z_][A-Za-z0-9_]*)\s*:", line)
                if declared:
                    sections[keyword].append(declared.group(1))
    return sections["VAR_INPUT"], sections["VAR_OUTPUT"]


def _resolve_port(name: str, index: int, body_ports: list[str], direction: str) -> str:
    """The body port a declared panel port drives, by name first then by position."""
    if name in body_ports:
        return name
    if index < len(body_ports):
        return body_ports[index]
    raise BlockSimError(
        f"端口 {name!r}（{direction}）与该块的 ST 源码体对不上："
        f"体内没有同名端口，位置 {index + 1} 也超出了源码体声明的端口数"
    )


def build_block_program(block: AlgorithmBlock) -> BlockProgram:
    """Compose the driver, object table and watch names for one library block."""
    template = (block.st_template or "").strip()
    if not template:
        raise BlockSimError("该算法块没有 ST 实现，无法仿真")

    block_kind = (block.block_kind or "FB").upper()
    inputs = list(block.inputs)
    outputs = list(block.outputs)
    if not outputs:
        raise BlockSimError("该算法块没有输出端口，仿真无值可读")
    if block_kind == "FUN" and len(outputs) != 1:
        raise BlockSimError("FUNCTION 只有一个返回值，该块声明了多个输出端口")

    # Each input port becomes a station INPUT point: the frame carries it, and a
    # force on it is injected into the object so the block reacts the same cycle.
    body_in: list[str] = []
    body_out: list[str] = []
    if block_kind == "FB":
        body_in, body_out = _body_ports(template)

    taken: set[str] = set()
    device = DeviceService(Station("BLK", "块仿真"), modules=[], variables=[], bindings=[])
    input_rows: list[dict] = []
    for index, port in enumerate(inputs):
        st_type = _st_type(port.data_type)
        symbol = _symbol(port.name, taken)
        device.add_variable(
            IoVariable(symbol, "input", st_type, description=port.name)
        )
        device.bind(ChannelBinding(symbol, index))
        row = {"port": port.name, "symbol": symbol, "type": st_type}
        if block_kind == "FB":
            row["bind"] = _resolve_port(port.name, index, body_in, "输入")
        input_rows.append(row)

    # Outputs: FB fields are read through the instance; a FUN result is written
    # into a plain global. Both are watchable and forceable by those names.
    extra_globals: list[tuple[str, str]] = []
    output_rows: list[dict] = []
    if block_kind == "FB":
        fb_type = _pou_name(template, "FUNCTION_BLOCK", block.name)
        extra_globals.append((INSTANCE, fb_type))
        for index, port in enumerate(outputs):
            st_type = _st_type(port.data_type)
            field = _resolve_port(port.name, index, body_out, "输出")
            output_rows.append(
                {"port": port.name, "symbol": f"{INSTANCE}#{field}", "type": st_type}
            )
    else:
        for port in outputs:
            st_type = _st_type(port.data_type)
            symbol = _symbol(port.name, taken)
            extra_globals.append((symbol, st_type))
            output_rows.append({"port": port.name, "symbol": symbol, "type": st_type})

    body = _program_body(block_kind, template, block.name, input_rows, output_rows, outputs)

    parts = (
        device.render_st(extra_globals),
        template,
        body,
    )
    st_text = "\n".join(part for part in parts if part.strip())

    plant = plant_from_external_variables("BLK", device.external_variables())

    names = sorted(
        {row["symbol"] for row in input_rows}
        | {row["symbol"] for row in output_rows}
    )
    return BlockProgram(block, st_text, plant.to_plant_text(), names, input_rows, output_rows)


def _pou_name(template: str, keyword: str, fallback: str) -> str:
    match = re.search(r"\b%s\s+([A-Za-z_][A-Za-z0-9_]*)" % keyword, template)
    return match.group(1) if match else fallback


def _program_body(
    block_kind: str,
    template: str,
    display_name: str,
    input_rows: list[dict],
    output_rows: list[dict],
    outputs: list,
) -> str:
    """The one ``PROGRAM`` that calls the block once, in the right calling form."""
    if block_kind == "FB":
        args = ", ".join(f"{row['bind']} := {row['symbol']}" for row in input_rows)
        call = f"{INSTANCE}({args});" if args else f"{INSTANCE}();"
        return f"PROGRAM MAIN\n  {call}\nEND_PROGRAM"
    fun_name = _pou_name(template, "FUNCTION", display_name)
    # A FUNCTION takes its formals positionally, in declared input order.
    args = ", ".join(row["symbol"] for row in input_rows)
    target = output_rows[0]["symbol"]
    return f"PROGRAM MAIN\n  {target} := {fun_name}({args});\nEND_PROGRAM"
