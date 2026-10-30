"""
Logic-graph checker.

Runs over the merged view of every page in a project, because a chart split
across sheets is still one program: a wire that leaves a pin on page 2 and
re-enters a same-named intermediate port on page 5 is one connection, and a
loop that closes across those two pages is one loop.

Every finding is located by (page, block, port) so the editor can jump to it.
The checks mirror what the compiler would later refuse, but report it before
code generation: passing here does not prove the chart compiles, failing here
does prove it is not worth compiling.
"""

from dataclasses import dataclass, field
from typing import Any, Optional


#: Sentinel endpoint that addresses a page's interface port.
INTERFACE = "__interface__"

#: Quality types are their base type plus a validity bit.
_QUALIFIED = {"QBOOL": "BOOL", "QINT": "INT", "QDINT": "DINT", "QREAL": "REAL"}

#: Conversion rank: a value may move up, never down.
_RANK = {
    "BOOL": 0,
    "BYTE": 1,
    "WORD": 2,
    "DWORD": 3,
    "SINT": 4,
    "INT": 5,
    "DINT": 6,
    "LINT": 7,
    "REAL": 8,
    "LREAL": 9,
    "STRING": 10,
    "TIME": 11,
}

#: Types an integral/real value may widen through. BOOL is deliberately absent:
#: SafeST has no implicit bool <-> numeric conversion.
_NUMERIC = {"BYTE", "WORD", "DWORD", "SINT", "INT", "DINT", "LINT", "REAL", "LREAL"}

DIRECTIONS = ("input", "output", "in_out")

#: A library entry stores its pins per direction under these keys.
_PIN_KEY = {"input": "inputs", "output": "outputs", "in_out": "in_out"}


@dataclass
class Finding:
    """One checker result, addressable from the editor."""

    severity: str
    code: str
    message: str
    page: str = ""
    block: str = ""
    port: str = ""

    def to_dict(self) -> dict:
        return {
            "severity": self.severity,
            "code": self.code,
            "message": self.message,
            "page": self.page,
            "block": self.block,
            "port": self.port,
        }


def base_type(st_type: str) -> str:
    return _QUALIFIED.get(st_type, st_type)


def is_compatible(src: str, dst: str) -> bool:
    """True when a value of type `src` may be written into a pin of type `dst`."""
    s, d = base_type(src), base_type(dst)
    if s == d:
        return True
    if s in _NUMERIC and d in _NUMERIC:
        return _RANK[d] >= _RANK[s]
    return False


@dataclass
class _Graph:
    """The lookups every check needs, built once from a merged FC document."""

    fc: dict[str, Any]
    block_defs: dict[str, dict] = field(default_factory=dict)
    external_vars: dict[str, dict] = field(default_factory=dict)
    blocks: dict[str, dict] = field(default_factory=dict)
    constants: dict[str, dict] = field(default_factory=dict)
    interface: dict[str, dict] = field(default_factory=dict)

    def __post_init__(self) -> None:
        self.blocks = {b["id"]: b for b in self.fc.get("blocks", [])}
        self.constants = {c["id"]: c for c in self.fc.get("constants", [])}
        for name, port in _interface_of(self.fc).items():
            self.interface.setdefault(name, port)

    @property
    def connections(self) -> list[dict]:
        return self.fc.get("connections", [])

    def definition(self, block_id: str) -> Optional[dict]:
        """The library entry a block instance is wired against, if known."""
        block = self.blocks.get(block_id)
        if not block or not self.block_defs:
            return None
        key = block.get("library_id") or block.get("type")
        return self.block_defs.get(key)

    def pins(self, block_id: str) -> dict[str, str]:
        definition = self.definition(block_id)
        if not definition:
            return {}
        pins: dict[str, str] = {}
        for direction in DIRECTIONS:
            pins.update(port_types(definition, direction))
        return pins

    def source_type(self, endpoint: dict) -> Optional[str]:
        block, port = endpoint["block"], endpoint["port"]
        if block == INTERFACE:
            entry = self.interface.get(port)
            return entry["type"] if entry else None
        if block in self.constants:
            return self.constants[block]["type"]
        return self.pins(block).get(port) if block in self.blocks else None

    def target_type(self, endpoint: dict) -> Optional[str]:
        block, port = endpoint["block"], endpoint["port"]
        if block == INTERFACE:
            entry = self.interface.get(port)
            return entry["type"] if entry else None
        if block in self.blocks:
            return self.pins(block).get(port)
        return None


def port_types(definition: dict, direction: str) -> dict[str, str]:
    """Pin name -> type for one direction of a library entry."""
    return {p["name"]: p["type"] for p in definition.get(_PIN_KEY[direction], [])}


def _interface_of(fc: dict) -> dict[str, dict]:
    """Interface ports keyed by name; the merged form carries `pages`."""
    out: dict[str, dict] = {}
    interface = fc.get("interface") or {}
    for direction in DIRECTIONS:
        for port in interface.get(direction, []):
            raw = list(port.get("pages", [])) or [port.get("page", "")]
            out[port["name"]] = {
                "name": port["name"],
                "type": port["type"],
                "direction": direction,
                "scope": port.get("scope", "external"),
                "bind": port.get("bind") or {},
                "pages": sorted({p for p in raw if p}),
                "occurrences": len(raw),
                "declared_types": dict(port.get("declared_types", {})),
            }
    return out


def check_graph(
    fc: dict[str, Any],
    block_defs: Optional[dict[str, dict]] = None,
    external_vars: Optional[dict[str, dict]] = None,
) -> list[Finding]:
    """
    Check one graph (a page, or a merged project).

    Args:
        fc: FC document, normally the merged view from `GraphProject.merged_fc`
        block_defs: library port tables keyed by block type name; when omitted
            the unknown-block, pin-existence and unconnected-pin checks are skipped
        external_vars: station configuration variables keyed by name
    """
    graph = _Graph(fc=fc, block_defs=block_defs or {}, external_vars=external_vars or {})
    findings: list[Finding] = []
    for check in (
        _check_identifiers,
        _check_endpoints,
        _check_drivers,
        _check_pin_types,
        _check_cycles,
        _check_port_declarations,
        _check_bindings,
        _check_interfaces,
        _check_dead_blocks,
    ):
        findings.extend(check(graph))
    return findings


def summarize(findings: list[Finding]) -> dict:
    """The response shape the editor's checker panel consumes."""
    return {
        "ok": not any(f.severity == "error" for f in findings),
        "errors": [f.to_dict() for f in findings if f.severity == "error"],
        "warnings": [f.to_dict() for f in findings if f.severity == "warning"],
        "infos": [f.to_dict() for f in findings if f.severity == "info"],
    }


def _check_identifiers(g: _Graph) -> list[Finding]:
    findings = []
    seen: set[str] = set()
    for block in g.fc.get("blocks", []):
        if block["id"] in seen:
            findings.append(
                Finding(
                    "error",
                    "DUPLICATE_ID",
                    f"Block instance '{block['id']}' is used more than once in the project",
                    page=block.get("page", ""),
                    block=block["id"],
                )
            )
        seen.add(block["id"])
    for name in sorted(set(g.blocks) & set(g.constants)):
        findings.append(
            Finding(
                "error",
                "DUPLICATE_ID",
                f"'{name}' is both a block instance and a constant",
                page=g.blocks[name].get("page", ""),
                block=name,
            )
        )
    return findings


def _check_endpoints(g: _Graph) -> list[Finding]:
    findings = []
    for conn in g.connections:
        page = conn.get("page", "")
        for side in ("from", "to"):
            endpoint = conn[side]
            block, port = endpoint["block"], endpoint["port"]
            if block == INTERFACE:
                if port not in g.interface:
                    findings.append(
                        Finding(
                            "error",
                            "UNKNOWN_PORT",
                            f"A wire references page port '{port}', which no page declares",
                            page=page,
                            block=INTERFACE,
                            port=port,
                        )
                    )
                continue
            if block not in g.blocks and block not in g.constants:
                findings.append(
                    Finding(
                        "error",
                        "UNKNOWN_BLOCK",
                        f"A wire references '{block}', which is not a block instance or a constant",
                        page=page,
                        block=block,
                        port=port,
                    )
                )
                continue
            if block in g.constants:
                if side == "to":
                    findings.append(
                        Finding(
                            "error",
                            "CONSTANT_SINK",
                            f"Constant '{block}' cannot be written to",
                            page=page,
                            block=block,
                            port=port,
                        )
                    )
                continue
            pins = g.pins(block)
            if pins and port not in pins:
                findings.append(
                    Finding(
                        "error",
                        "UNKNOWN_PORT",
                        f"Pin '{port}' does not exist on '{block}'",
                        page=page,
                        block=block,
                        port=port,
                    )
                )
    return findings


def _drivers(g: _Graph) -> dict[tuple[str, str], list[dict]]:
    table: dict[tuple[str, str], list[dict]] = {}
    for conn in g.connections:
        table.setdefault((conn["to"]["block"], conn["to"]["port"]), []).append(conn)
    return table


def _check_drivers(g: _Graph) -> list[Finding]:
    findings = []
    drivers = _drivers(g)

    for (block, port), conns in sorted(drivers.items()):
        if len(conns) < 2:
            continue
        sources = ", ".join(sorted(f"{c['from']['block']}.{c['from']['port']}" for c in conns))
        pages = ", ".join(sorted({c.get("page", "") for c in conns if c.get("page")}))
        findings.append(
            Finding(
                "error",
                "MULTI_DRIVER",
                f"Input {block}.{port} is driven by {len(conns)} sources ({sources})"
                + (f" on pages {pages}" if pages else ""),
                page=conns[0].get("page", ""),
                block=block,
                port=port,
            )
        )

    if not g.block_defs:
        return findings

    for block in g.fc.get("blocks", []):
        definition = g.definition(block["id"])
        if not definition:
            continue
        parameters = block.get("parameters") or {}
        for pin in definition.get("inputs", []):
            if (block["id"], pin["name"]) in drivers:
                continue
            if pin["name"] in parameters or pin.get("default_value") is not None:
                continue
            findings.append(
                Finding(
                    "error",
                    "PIN_UNCONNECTED",
                    f"Input {block['id']}.{pin['name']} ({pin['type']}) has no wire, "
                    "no constant and no default value",
                    page=block.get("page", ""),
                    block=block["id"],
                    port=pin["name"],
                )
            )
    return findings


def _check_pin_types(g: _Graph) -> list[Finding]:
    findings = []
    for conn in g.connections:
        src = g.source_type(conn["from"])
        dst = g.target_type(conn["to"])
        if src is None or dst is None:
            continue
        if is_compatible(src, dst):
            if src != dst:
                findings.append(
                    Finding(
                        "warning",
                        "QUALITY_DROPPED",
                        f"{src} -> {dst} at {conn['to']['block']}.{conn['to']['port']}: "
                        "the validity bit is not carried across the wire",
                        page=conn.get("page", ""),
                        block=conn["to"]["block"],
                        port=conn["to"]["port"],
                    )
                )
            continue
        findings.append(
            Finding(
                "error",
                "PIN_TYPE_MISMATCH",
                f"Pin type mismatch: {conn['from']['block']}.{conn['from']['port']} is {src}, "
                f"{conn['to']['block']}.{conn['to']['port']} is {dst}",
                page=conn.get("page", ""),
                block=conn["to"]["block"],
                port=conn["to"]["port"],
            )
        )
    return findings


def _check_cycles(g: _Graph) -> list[Finding]:
    """
    Report each feedback loop once, with the pages and pins it crosses.

    A loop is only legal when it passes through a block whose output this cycle
    does not depend on this cycle's input -- the delay elements (`time_based` in
    the library, e.g. FBY). Those read last cycle's stored value, so the
    dependency graph stays acyclic and an execution order exists.
    """
    adjacency: dict[str, list[tuple[str, dict]]] = {}
    for conn in g.connections:
        src, dst = conn["from"]["block"], conn["to"]["block"]
        if src in g.blocks and dst in g.blocks:
            adjacency.setdefault(src, []).append((dst, conn))

    # A wire that passes through a page port is still a dependency: the block
    # that writes the port feeds every block that reads it, on any page. Without
    # this a loop drawn across two sheets would go unnoticed.
    produced: dict[str, list[tuple[str, dict]]] = {}
    consumed: dict[str, list[tuple[str, dict]]] = {}
    for conn in g.connections:
        if conn["to"]["block"] == INTERFACE and conn["from"]["block"] in g.blocks:
            produced.setdefault(conn["to"]["port"], []).append((conn["from"]["block"], conn))
        if conn["from"]["block"] == INTERFACE and conn["to"]["block"] in g.blocks:
            consumed.setdefault(conn["from"]["port"], []).append((conn["to"]["block"], conn))
    for name, writers in produced.items():
        for reader, read_conn in consumed.get(name, []):
            for writer, write_conn in writers:
                if writer != reader:
                    adjacency.setdefault(writer, []).append((reader, read_conn))

    findings: list[Finding] = []
    reported: set[frozenset] = set()
    state: dict[str, int] = {}
    stack: list[str] = []

    def delayed(nodes: set[str]) -> bool:
        return any(
            bool((g.definition(node) or {}).get("time_based")) for node in nodes
        )

    def visit(node: str) -> None:
        state[node] = 1
        stack.append(node)
        for nxt, conn in adjacency.get(node, []):
            if state.get(nxt, 0) == 0:
                visit(nxt)
            elif state.get(nxt) == 1:
                ring = stack[stack.index(nxt):]
                members = frozenset(ring)
                if members in reported:
                    continue
                reported.add(members)
                # Rotate to the alphabetically first member so the same loop
                # reads the same whatever order the walk happened to reach it.
                start = ring.index(min(ring))
                closed = ring[start:] + ring[:start]
                chain = " -> ".join(closed + [closed[0]])
                ring_pages = {g.blocks.get(name, {}).get("page", "") for name in ring}
                pages = sorted({p for p in (ring_pages | {conn.get("page", "")}) if p})
                where = conn.get("page", "") or (pages[0] if pages else "")
                if delayed(members):
                    findings.append(
                        Finding(
                            "info",
                            "DELAYED_LOOP",
                            f"Loop {chain} is closed through a time-based block, "
                            "so it reads the previous cycle",
                            page=where,
                            block=nxt,
                            port=conn["to"]["port"],
                        )
                    )
                    continue
                findings.append(
                    Finding(
                        "error",
                        "CYCLE",
                        f"Feedback loop with no delay block: {chain}"
                        + (f" (pages {', '.join(pages)})" if pages else ""),
                        page=where,
                        block=nxt,
                        port=conn["to"]["port"],
                    )
                )
        stack.pop()
        state[node] = 2

    for node in sorted(g.blocks):
        if state.get(node, 0) == 0:
            visit(node)
    return findings


def _check_port_declarations(g: _Graph) -> list[Finding]:
    """What the pages agree (or refuse to agree) about a shared variable."""
    findings = []
    for name, entry in sorted(g.interface.items()):
        page = entry["pages"][0] if entry["pages"] else ""
        types = sorted(set(entry["declared_types"].values()))
        if len(types) > 1:
            where = ", ".join(
                f"{declared} on {p}" for p, declared in sorted(entry["declared_types"].items())
            )
            findings.append(
                Finding(
                    "error",
                    "PORT_TYPE_CONFLICT",
                    f"Variable '{name}' is declared with different types across pages: {where}",
                    page=page,
                    block=INTERFACE,
                    port=name,
                )
            )
        if entry["occurrences"] > len(entry["pages"]):
            findings.append(
                Finding(
                    "warning",
                    "DUAL_PORT",
                    f"Variable '{name}' is declared more than once on the same page",
                    page=page,
                    block=INTERFACE,
                    port=name,
                )
            )
    return findings


def _check_bindings(g: _Graph) -> list[Finding]:
    """Cross-check the declared station bindings against the external table."""
    findings = []
    if not g.external_vars:
        return findings

    for name, entry in sorted(g.interface.items()):
        bind = entry["bind"]
        if not bind:
            continue
        page = entry["pages"][0] if entry["pages"] else ""
        variable = bind.get("variable", "")
        row = g.external_vars.get(variable)
        if row is None:
            findings.append(
                Finding(
                    "error",
                    "BAD_BIND",
                    f"Page port '{name}' is bound to configuration variable '{variable}', "
                    "which is not in the station external variable table",
                    page=page,
                    block=INTERFACE,
                    port=name,
                )
            )
            continue
        if row.get("direction") == "input" and entry["direction"] == "output":
            findings.append(
                Finding(
                    "error",
                    "BAD_BIND",
                    f"'{variable}' is a station input; page port '{name}' may not write it",
                    page=page,
                    block=INTERFACE,
                    port=name,
                )
            )
        station_type = row.get("st_type", "")
        if not is_compatible(station_type, entry["type"]) and not is_compatible(
            entry["type"], station_type
        ):
            findings.append(
                Finding(
                    "error",
                    "BAD_BIND",
                    f"'{variable}' is {station_type} on station {bind.get('station', '-')}, "
                    f"page port '{name}' is {entry['type']}",
                    page=page,
                    block=INTERFACE,
                    port=name,
                )
            )
    return findings


def _check_interfaces(g: _Graph) -> list[Finding]:
    """
    Associate every page port with something that supplies or consumes it.

    An input port needs a source: either a station configuration variable it is
    bound to, or a block writing into it. A port with neither is a variable the
    chart references but nothing associates -- the case the inspector is asked
    to catch. An output port needs a consumer on some page.
    """
    findings = []
    read: set[str] = set()
    written: set[str] = set()
    for conn in g.connections:
        if conn["from"]["block"] == INTERFACE:
            read.add(conn["from"]["port"])
        if conn["to"]["block"] == INTERFACE:
            written.add(conn["to"]["port"])

    for name, entry in sorted(g.interface.items()):
        page = entry["pages"][0] if entry["pages"] else ""
        pages = ", ".join(entry["pages"]) or "?"

        if len(entry["pages"]) > 1:
            findings.append(
                Finding(
                    "info",
                    "CROSS_PAGE",
                    f"Variable '{name}' joins pages {pages}",
                    page=page,
                    block=INTERFACE,
                    port=name,
                )
            )

        if entry["scope"] == "intermediate":
            if len(entry["pages"]) < 2:
                findings.append(
                    Finding(
                        "warning",
                        "DEAD_INTERMEDIATE",
                        f"Intermediate variable '{name}' appears on one page only ({pages})",
                        page=page,
                        block=INTERFACE,
                        port=name,
                    )
                )
            if name not in written:
                findings.append(
                    Finding(
                        "error",
                        "VARIABLE_UNBOUND",
                        f"Intermediate variable '{name}' is read on page(s) {pages} "
                        "but no page writes it",
                        page=page,
                        block=INTERFACE,
                        port=name,
                    )
                )
            continue

        if entry["bind"]:
            continue

        if entry["direction"] in ("input", "in_out") and name not in written:
            findings.append(
                Finding(
                    "error",
                    "VARIABLE_UNBOUND",
                    f"Variable '{name}' is used by the chart but is neither bound to a "
                    "station point nor written by a block",
                    page=page,
                    block=INTERFACE,
                    port=name,
                )
            )
        elif entry["direction"] == "output" and name not in read:
            findings.append(
                Finding(
                    "warning",
                    "UNUSED_PORT",
                    f"Output variable '{name}' is declared but no page reads it",
                    page=page,
                    block=INTERFACE,
                    port=name,
                )
            )
    return findings


def _check_dead_blocks(g: _Graph) -> list[Finding]:
    if not g.blocks:
        return []
    feeds = {c["from"]["block"] for c in g.connections}
    findings = []
    for block_id, block in sorted(g.blocks.items()):
        if block_id in feeds:
            continue
        if not g.pins(block_id):
            findings.append(
                Finding(
                    "info",
                    "UNRESOLVED_BLOCK",
                    f"Block '{block_id}' of type '{block.get('type')}' is not in the "
                    "loaded algorithm library, so its pins cannot be checked",
                    page=block.get("page", ""),
                    block=block_id,
                )
            )
            continue
        findings.append(
            Finding(
                "warning",
                "UNUSED_BLOCK",
                f"Block '{block_id}' computes a value nothing consumes",
                page=block.get("page", ""),
                block=block_id,
            )
        )
    return findings
