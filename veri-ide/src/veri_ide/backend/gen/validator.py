"""
Function Chart (FC) JSON validation.
"""
import json
from pathlib import Path
from typing import Any

from jsonschema import Draft7Validator, ValidationError

_SCHEMA_DIR = Path(__file__).parent.parent.parent / "schema"


def load_fc_schema() -> dict:
    """Load FC JSON Schema."""
    schema_path = _SCHEMA_DIR / "fc.schema.json"
    with open(schema_path, "r", encoding="utf-8") as f:
        return json.load(f)


def validate_fc_json(data: dict[str, Any]) -> list[str]:
    """
    Validate FC JSON against schema.

    Returns:
        List of validation error messages (empty if valid)
    """
    schema = load_fc_schema()
    validator = Draft7Validator(schema)
    errors = []
    for error in validator.iter_errors(data):
        path = ".".join(str(p) for p in error.path) if error.path else "<root>"
        errors.append(f"{path}: {error.message}")
    return errors


def validate_fc_file(file_path: str | Path) -> tuple[dict | None, list[str]]:
    """
    Validate FC JSON file.

    Returns:
        (data, errors) tuple. data is None if file cannot be read/parsed.
    """
    path = Path(file_path)
    if not path.exists():
        return None, [f"File not found: {path}"]

    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except json.JSONDecodeError as e:
        return None, [f"Invalid JSON: {e}"]

    errors = validate_fc_json(data)
    if errors:
        return data, errors
    return data, []


def check_no_cycles(data: dict[str, Any]) -> list[str]:
    """
    Check for cycles in block connections.

    Returns:
        List of error messages (empty if no cycles)
    """
    blocks = {b["id"] for b in data.get("blocks", [])}

    adj: dict[str, set[str]] = {b: set() for b in blocks}
    for conn in data.get("connections", []):
        src = conn["from"]["block"]
        dst = conn["to"]["block"]
        if src not in blocks or dst not in blocks:
            continue
        adj[src].add(dst)

    visited = set()
    rec_stack = set()

    def dfs(node: str) -> bool:
        visited.add(node)
        rec_stack.add(node)
        for neighbor in adj[node]:
            if neighbor not in visited:
                if dfs(neighbor):
                    return True
            elif neighbor in rec_stack:
                return True
        rec_stack.remove(node)
        return False

    for block in blocks:
        if block not in visited:
            if dfs(block):
                return ["Cycle detected in block connections"]

    return []


def topological_sort(data: dict[str, Any]) -> tuple[list[str], list[str]]:
    """
    Topological sort of blocks based on connections.

    Returns:
        (sorted_blocks, errors) tuple. sorted_blocks is empty if cycle detected.
    """
    blocks = [b["id"] for b in data.get("blocks", [])]
    block_set = set(blocks)
    block_set.add("__interface__")

    in_degree = {b: 0 for b in block_set}
    adj: dict[str, list[str]] = {b: [] for b in block_set}

    for conn in data.get("connections", []):
        src = conn["from"]["block"]
        dst = conn["to"]["block"]
        if src not in block_set or dst not in block_set:
            continue
        if src == "__interface__":
            continue
        if dst == "__interface__":
            continue
        adj[src].append(dst)
        in_degree[dst] += 1

    queue = [b for b in block_set if in_degree[b] == 0 and b != "__interface__"]
    result = []

    while queue:
        queue.sort()
        node = queue.pop(0)
        result.append(node)
        for neighbor in adj[node]:
            in_degree[neighbor] -= 1
            if in_degree[neighbor] == 0:
                queue.append(neighbor)

    if len(result) != len(blocks):
        return [], ["Cycle detected: cannot topologically sort blocks"]

    return result, []
