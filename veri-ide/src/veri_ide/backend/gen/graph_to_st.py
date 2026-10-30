"""
Graph-to-ST generator: Function Chart -> Structured Text.

The graph layer never feeds anything but text to the compiler, so this is the
only place a chart becomes a program. Two protocol decisions shape it:

* a graph-stage constant is not a statement -- it is inlined into the argument
  of the pin it is wired to, which is what the engineer drew;
* an interface port declares storage according to where its value comes from.
  A port bound to a station configuration variable is already a `VAR_GLOBAL`
  emitted by the device stage, so redeclaring it here would be a duplicate;
  an intermediate or local port is a program variable shared by the pages.
* the calling chart writes an associated port as that variable name, not as the
  port label, because the variable is what the global section actually declares.
"""
from typing import Any


INTERFACE = "__interface__"

#: Port scopes that the device stage already declares as globals.
BOUND_SCOPES = ("external",)


def _literal(value: Any, st_type: str) -> str:
    if isinstance(value, bool):
        return "TRUE" if value else "FALSE"
    if isinstance(value, str):
        return f"'{value}'"
    if st_type == "STRING":
        return f"'{value}'"
    return str(value)


def _ports(data: dict[str, Any]) -> dict[str, dict]:
    """Every interface port of a chart, keyed by name, with its direction attached."""
    return {
        port["name"]: {**port, "direction": direction}
        for direction in ("input", "output", "in_out")
        for port in data.get("interface", {}).get(direction, [])
    }


def _bound(data: dict[str, Any]) -> dict[str, str]:
    """`port -> station configuration variable`, for every associated port."""
    return {
        name: port["bind"]["variable"]
        for name, port in _ports(data).items()
        if port.get("bind") and port["bind"].get("variable")
    }


def _internal(data: dict[str, Any]) -> list[str]:
    """Page variables: intermediate or local ports that no station owns."""
    bound = _bound(data)
    return sorted(
        name
        for name, port in _ports(data).items()
        if port.get("scope") in ("intermediate", "local") and name not in bound
    )


def global_declarations(data: dict[str, Any]) -> list[tuple[str, str]]:
    """
    Names the caller must declare in its single `VAR_GLOBAL` section.

    Two kinds. Block instances, because the compiler rejects an instance held as
    a program variable as soon as a call names an argument or reads a field. And
    page variables, because the debug section lists globals only -- a program
    local has no address a simulator or a monitor could ever read.
    """
    ports = _ports(data)
    rows = [(block["id"], block["type"]) for block in data.get("blocks", [])]
    rows += [(name, ports[name]["type"]) for name in _internal(data)]
    return rows


def generate_st_from_fc(data: dict[str, Any], *, instances_global: bool = False) -> str:
    """
    Generate ST code from FC JSON.

    Args:
        data: FC JSON data (validated)
        instances_global: hold back everything `global_declarations` reports and
            let the caller declare it in its global section. The analysis and
            simulation hand-offs both set it.

    Returns:
        ST code as string
    """
    lines = []

    program_name = data["name"]
    lines.append(f"PROGRAM {program_name}")

    blocks = data.get("blocks", [])
    constants = {c["id"]: c for c in data.get("constants", [])}
    interface = data.get("interface", {})

    ports = _ports(data)
    bound = _bound(data)
    internal = set(_internal(data))

    declarations = [] if instances_global else [
        f"    {block['id']} : {block['type']};" for block in blocks
    ]
    declarations += [] if instances_global else [
        f"    {ports[name]['name']} : {ports[name]['type']};" for name in sorted(internal)
    ]
    if declarations:
        lines.append("VAR")
        lines.extend(declarations)
        lines.append("END_VAR")

    for direction, keyword in (("input", "VAR_INPUT"), ("output", "VAR_OUTPUT"), ("in_out", "VAR_IN_OUT")):
        entries = [
            port
            for port in interface.get(direction, [])
            if not port.get("bind") and port["name"] not in internal
        ]
        if entries:
            lines.append(keyword)
            lines.extend(f"    {port['name']} : {port['type']};" for port in entries)
            lines.append("END_VAR")

    if bound:
        lines.append(
            f"(* {len(bound)} port(s) read the station configuration variables "
            "declared by the device stage: " + ", ".join(sorted(set(bound.values()))) + " *)"
        )

    lines.append("")

    connections = data.get("connections", [])
    block_map = {b["id"]: b for b in blocks}

    from .validator import topological_sort
    _, errors = topological_sort(data)
    if errors:
        raise ValueError(errors[0])

    #: A page variable is a node in the same order as the blocks: the block that
    #: writes it feeds every block that reads it, so emitting its assignment after
    #: the calls would hand the reader last cycle's value.
    writes: dict[str, list[dict]] = {}
    for conn in connections:
        if conn["to"]["block"] == INTERFACE and conn["to"]["port"] in internal:
            writes.setdefault(conn["to"]["port"], []).append(conn)

    for node in _execution_order(data, block_map, internal, writes):
        kind, name = node
        if kind == "block":
            args = []
            for conn in connections:
                if conn["to"]["block"] != name:
                    continue
                args.append(
                    f"{conn['to']['port']} := {_source_text(conn['from'], constants, bound)}"
                )
            parameters = block_map[name].get("parameters", {})
            for param_name, param_value in parameters.items():
                args.append(f"{param_name} := {_parameter_text(param_value)}")
            args_str = ", ".join(args)
            lines.append(f"{name}({args_str});" if args else f"{name}();")
        else:
            for conn in writes[name]:
                lines.append(f"{name} := {_source_text(conn['from'], constants, bound)};")

    for conn in connections:
        if conn["to"]["block"] != INTERFACE or conn["to"]["port"] in internal:
            continue
        target = bound.get(conn["to"]["port"], conn["to"]["port"])
        lines.append(f"{target} := {_source_text(conn['from'], constants, bound)};")

    lines.append("END_PROGRAM")

    return "\n".join(lines)


def pin_symbols(data: dict[str, Any], block_defs: dict[str, dict]) -> list[dict]:
    """
    Which watched symbol carries the value of each pin once the chart has run.

    The names are the ones this module writes into the statements, so a pin can
    only ever show the number of the slot the generated code actually reads or
    writes: a block pin is the field symbol `instance#FIELD`, a page pin is the
    station configuration variable it is associated with or else its page
    variable, and a graph constant owns no slot at all -- it is folded into the
    argument of the pin it feeds, so it shows its literal instead.
    """
    ports = _ports(data)
    bound = _bound(data)
    internal = set(_internal(data))
    constants = {constant["id"]: constant for constant in data.get("constants", [])}
    blocks = {block["id"]: block for block in data.get("blocks", [])}
    driven: dict[tuple[str, str], dict] = {}
    for conn in data.get("connections", []):
        driven.setdefault((conn["to"]["block"], conn["to"]["port"]), conn["from"])

    rows: list[dict] = []
    default_page = data.get("page", {}).get("id", "")
    for block_id, block in blocks.items():
        definition = block_defs.get(block["type"]) or {}
        for direction, key in (("input", "inputs"), ("output", "outputs")):
            for pin in definition.get(key, []):
                row = _pin_row(
                    block.get("page") or default_page,
                    block_id,
                    pin,
                    direction,
                    definition.get("block_kind", "FB"),
                )
                if direction == "output":
                    row["kind"] = "symbol"
                    row["symbol"] = f"{block_id}#{pin['name']}"
                else:
                    source = driven.get((block_id, pin["name"]))
                    if source is not None:
                        row.update(_source_pin(source, blocks, constants, bound, internal))
                rows.append(row)

    for name, port in ports.items():
        symbol = bound.get(name) if name in bound else (name if name in internal else None)
        for page in port.get("pages") or [default_page]:
            rows.append(
                {
                    "page": page,
                    "element": INTERFACE,
                    "port": name,
                    "direction": port["direction"],
                    "type": port["type"],
                    "kind": "symbol" if symbol else "unwatchable",
                    "symbol": symbol,
                    "literal": None,
                }
            )
    return sorted(rows, key=lambda row: (row["page"], row["element"], row["port"]))


def _pin_row(page: str, element: str, pin: dict, direction: str, kind_of_block: str) -> dict:
    return {
        "page": page,
        "element": element,
        "port": pin["name"],
        "direction": direction,
        "type": pin.get("type", ""),
        "block_kind": kind_of_block,
        "kind": "unconnected",
        "symbol": None,
        "literal": None,
    }


def _source_pin(
    source: dict,
    blocks: dict[str, dict],
    constants: dict[str, dict],
    bound: dict[str, str],
    internal: set[str],
) -> dict:
    """Resolve the far end of the wire that drives a pin, as the ST sees it."""
    block, port = source["block"], source["port"]
    if block in constants:
        constant = constants[block]
        return {"kind": "constant", "literal": _literal(constant["value"], constant.get("type", ""))}
    if block in blocks:
        return {"kind": "symbol", "symbol": f"{block}#{port}"}
    if block == INTERFACE:
        symbol = bound.get(port) if port in bound else (port if port in internal else None)
        return {"kind": "symbol" if symbol else "unwatchable", "symbol": symbol}
    return {"kind": "unconnected"}


def _execution_order(
    data: dict[str, Any],
    block_map: dict[str, dict],
    internal: set[str],
    writes: dict[str, list[dict]],
) -> list:
    """Blocks and page variables in one dependency order, blocks first on ties.

    Edges come from the wires: a block or a page variable on the far end of a
    wire has to be emitted before whatever reads it. Constants and station
    configuration variables are values a statement reads, not statements, so
    they add no edge.
    """

    def node_of(endpoint: dict):
        block, port = endpoint["block"], endpoint["port"]
        if block in block_map:
            return ("block", block)
        if block == INTERFACE and port in internal:
            return ("var", port)
        return None

    edges: dict[Any, set] = {}
    indegree: dict[Any, int] = {("block", block_id): 0 for block_id in block_map}
    indegree.update({("var", name): 0 for name in writes})
    for conn in data.get("connections", []):
        src, dst = node_of(conn["from"]), node_of(conn["to"])
        if src is None or dst is None or src == dst or dst not in indegree:
            continue
        if dst not in edges.setdefault(src, set()):
            edges[src].add(dst)
            indegree[dst] += 1

    queue = [node for node in sorted(indegree) if indegree[node] == 0]
    order = []
    while queue:
        node = queue.pop(0)
        order.append(node)
        for nxt in sorted(edges.get(node, ())):
            indegree[nxt] -= 1
            if indegree[nxt] == 0:
                queue.append(nxt)
                queue.sort()

    if len(order) != len(indegree):
        stuck = sorted(str(node[1]) for node, d in indegree.items() if d > 0)
        raise ValueError(f"Cycle detected: no execution order for {stuck}")
    return order


def _source_text(
    source: dict, constants: dict[str, dict], bound: dict[str, str]
) -> str:
    """Render what a wire carries: a constant value, a port name, or a pin read.

    An associated port is written as the station configuration variable it points
    at -- that name, not the port label, is what the device stage declares.
    """
    block, port = source["block"], source["port"]
    if block == INTERFACE:
        return bound.get(port, port)
    if block in constants:
        constant = constants[block]
        return _literal(constant["value"], constant.get("type", ""))
    return f"{block}.{port}"


def _parameter_text(value: Any) -> str:
    if isinstance(value, str):
        return f"'{value}'"
    if isinstance(value, bool):
        return "TRUE" if value else "FALSE"
    return str(value)
