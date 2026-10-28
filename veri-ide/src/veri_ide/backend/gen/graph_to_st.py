"""
Graph-to-ST generator: Function Chart → Structured Text.
"""
from typing import Any


def generate_st_from_fc(data: dict[str, Any]) -> str:
    """
    Generate ST code from FC JSON.

    Args:
        data: FC JSON data (validated)

    Returns:
        ST code as string
    """
    lines = []

    program_name = data["name"]
    lines.append(f"PROGRAM {program_name}")

    blocks = data.get("blocks", [])
    if blocks:
        lines.append("VAR")
        for block in blocks:
            block_id = block["id"]
            block_type = block["type"]
            lines.append(f"    {block_id} : {block_type};")
        lines.append("END_VAR")

    interface = data.get("interface", {})
    input_ports = interface.get("input", [])
    if input_ports:
        lines.append("VAR_INPUT")
        for port in input_ports:
            lines.append(f"    {port['name']} : {port['type']};")
        lines.append("END_VAR")

    output_ports = interface.get("output", [])
    if output_ports:
        lines.append("VAR_OUTPUT")
        for port in output_ports:
            lines.append(f"    {port['name']} : {port['type']};")
        lines.append("END_VAR")

    in_out_ports = interface.get("in_out", [])
    if in_out_ports:
        lines.append("VAR_IN_OUT")
        for port in in_out_ports:
            lines.append(f"    {port['name']} : {port['type']};")
        lines.append("END_VAR")

    lines.append("")

    connections = data.get("connections", [])
    block_map = {b["id"]: b for b in blocks}

    from .validator import topological_sort
    sorted_blocks, errors = topological_sort(data)
    if errors:
        raise ValueError(errors[0])

    for block_id in sorted_blocks:
        block = block_map[block_id]
        block_type = block["type"]
        parameters = block.get("parameters", {})

        input_conns = [
            c for c in connections
            if c["to"]["block"] == block_id
        ]

        args = []
        for conn in input_conns:
            port_name = conn["to"]["port"]
            src_block = conn["from"]["block"]
            src_port = conn["from"]["port"]

            if src_block == "__interface__":
                arg_value = src_port
            else:
                arg_value = f"{src_block}.{src_port}"

            args.append(f"{port_name} := {arg_value}")

        for param_name, param_value in parameters.items():
            if isinstance(param_value, str):
                args.append(f"{param_name} := '{param_value}'")
            else:
                args.append(f"{param_name} := {param_value}")

        if args:
            args_str = ", ".join(args)
            lines.append(f"{block_id}({args_str});")
        else:
            lines.append(f"{block_id}();")

    output_assignments = [
        c for c in connections
        if c["to"]["block"] == "__interface__"
    ]
    for conn in output_assignments:
        out_port = conn["to"]["port"]
        src_block = conn["from"]["block"]
        src_port = conn["from"]["port"]
        if src_block == "__interface__":
            lines.append(f"{out_port} := {src_port};")
        else:
            lines.append(f"{out_port} := {src_block}.{src_port};")

    lines.append("END_PROGRAM")

    return "\n".join(lines)
