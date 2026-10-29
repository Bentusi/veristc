"""
ST-to-Graph reverse parser (for round-trip testing only).

This module parses ST code back into FC JSON structure.
Note: Position information is lost (set to default 0,0).
"""
import re
from typing import Any


def parse_st_to_graph(st_code: str) -> dict[str, Any]:
    """
    Parse ST code back to FC JSON structure.

    Args:
        st_code: ST code as string

    Returns:
        FC JSON structure (without position info)
    """
    lines = st_code.strip().split("\n")

    program_name = None
    interface = {"input": [], "output": [], "in_out": []}
    blocks = []
    connections = []

    current_section = None
    current_block = None
    block_params = {}

    i = 0
    while i < len(lines):
        line = lines[i].strip()

        if line.startswith("PROGRAM "):
            program_name = line.split()[1]
            current_section = None

        elif line == "VAR":
            current_section = "var"

        elif line == "VAR_INPUT":
            current_section = "input"

        elif line == "VAR_OUTPUT":
            current_section = "output"

        elif line == "VAR_IN_OUT":
            current_section = "in_out"

        elif line == "END_VAR":
            current_section = None

        elif line == "END_PROGRAM":
            break

        elif current_section == "var" and ":" in line:
            match = re.match(r"(\w+)\s*:\s*(\w+);", line)
            if match:
                block_id = match.group(1)
                block_type = match.group(2)
                blocks.append({
                    "id": block_id,
                    "type": block_type,
                    "position": {"x": 0, "y": 0},
                    "parameters": {}
                })

        elif current_section in ["input", "output", "in_out"] and ":" in line:
            match = re.match(r"(\w+)\s*:\s*(\w+);", line)
            if match:
                port_name = match.group(1)
                port_type = match.group(2)
                interface[current_section].append({
                    "name": port_name,
                    "type": port_type
                })

        elif "(" in line and ");" in line and current_section is None:
            match = re.match(r"(\w+)\((.*)\);", line)
            if match:
                block_id = match.group(1)
                args_str = match.group(2)

                args = _parse_args(args_str)

                for arg_name, arg_value in args.items():
                    if _is_literal(arg_value):
                        block = next((b for b in blocks if b["id"] == block_id), None)
                        if block:
                            block["parameters"][arg_name] = _parse_literal(arg_value)
                    else:
                        src_block, src_port = _parse_reference(arg_value)
                        connections.append({
                            "from": {"block": src_block, "port": src_port},
                            "to": {"block": block_id, "port": arg_name}
                        })

        elif ":=" in line and current_section is None:
            match = re.match(r"(\w+)\s*:=\s*(.+);", line)
            if match:
                out_port = match.group(1)
                src_expr = match.group(2).strip()

                if "." in src_expr:
                    src_block, src_port = src_expr.split(".", 1)
                    connections.append({
                        "from": {"block": src_block, "port": src_port},
                        "to": {"block": "__interface__", "port": out_port}
                    })
                else:
                    connections.append({
                        "from": {"block": "__interface__", "port": src_expr},
                        "to": {"block": "__interface__", "port": out_port}
                    })

        i += 1

    return {
        "version": "1.0",
        "type": "FC",
        "name": program_name or "UNKNOWN",
        "interface": interface,
        "blocks": blocks,
        "connections": connections
    }


def _parse_args(args_str: str) -> dict[str, str]:
    """Parse function call arguments."""
    args = {}
    if not args_str.strip():
        return args

    parts = []
    current = ""
    paren_depth = 0

    for char in args_str:
        if char == "(":
            paren_depth += 1
            current += char
        elif char == ")":
            paren_depth -= 1
            current += char
        elif char == "," and paren_depth == 0:
            parts.append(current.strip())
            current = ""
        else:
            current += char

    if current.strip():
        parts.append(current.strip())

    for part in parts:
        if ":=" in part:
            name, value = part.split(":=", 1)
            args[name.strip()] = value.strip()

    return args


def _is_literal(value: str) -> bool:
    """Check if value is a literal (number/string/bool)."""
    value = value.strip()
    if value.startswith("'") and value.endswith("'"):
        return True
    if value in ["TRUE", "FALSE"]:
        return True
    try:
        float(value)
        return True
    except ValueError:
        return False


def _parse_literal(value: str) -> Any:
    """Parse literal value."""
    value = value.strip()
    if value.startswith("'") and value.endswith("'"):
        return value[1:-1]
    if value == "TRUE":
        return True
    if value == "FALSE":
        return False
    try:
        if "." in value:
            return float(value)
        return int(value)
    except ValueError:
        return value


def _parse_reference(value: str) -> tuple[str, str]:
    """Parse block.port reference."""
    value = value.strip()
    if "." in value:
        parts = value.split(".", 1)
        return parts[0], parts[1]
    return "__interface__", value


def normalize_graph_for_comparison(graph: dict[str, Any]) -> dict[str, Any]:
    """
    Normalize graph for comparison (ignore position, sort connections).

    Args:
        graph: FC JSON structure

    Returns:
        Normalized structure for comparison
    """
    normalized = {
        "version": graph.get("version", "1.0"),
        "type": graph.get("type", "FC"),
        "name": graph.get("name", ""),
        "interface": {
            "input": sorted(graph.get("interface", {}).get("input", []), key=lambda p: p["name"]),
            "output": sorted(graph.get("interface", {}).get("output", []), key=lambda p: p["name"]),
            "in_out": sorted(graph.get("interface", {}).get("in_out", []), key=lambda p: p["name"]),
        },
        "blocks": sorted(
            [
                {
                    "id": b["id"],
                    "type": b["type"],
                    "parameters": b.get("parameters", {})
                }
                for b in graph.get("blocks", [])
            ],
            key=lambda b: b["id"]
        ),
        "connections": sorted(
            [
                {
                    "from": {"block": c["from"]["block"], "port": c["from"]["port"]},
                    "to": {"block": c["to"]["block"], "port": c["to"]["port"]}
                }
                for c in graph.get("connections", [])
            ],
            key=lambda c: (c["from"]["block"], c["from"]["port"], c["to"]["block"], c["to"]["port"])
        )
    }
    return normalized
