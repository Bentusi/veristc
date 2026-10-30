"""
Multi-page logic graph container.

A project is one program drawn on several sheets. Each page is an FC document
(`schema/fc.schema.json`); the project keeps them ordered, merges them into the
single graph the checker and the ST generator work on, and persists them as
`graph/<page>.fc.json` plus `graph/project.json`.

Merging is where the cross-page semantics live: a variable that carries the
same name on two pages is one variable, not two, which is what makes an
A3-sized sheet practical at all. Names are unique per page for blocks and
constants, and shared per project for interface ports.
"""

import json
from pathlib import Path
from typing import Any, Optional

from ..gen.graph_to_st import generate_st_from_fc
from ..gen.graph_to_st import global_declarations as chart_globals
from ..gen.graph_to_st import pin_symbols as chart_pin_symbols
from ..gen.validator import validate_fc_json
from .checker import DIRECTIONS, Finding, check_graph, summarize


GRAPH_DIR = "graph"
INDEX_FILE = "project.json"


class GraphError(ValueError):
    """Raised when a page cannot be accepted into the project."""


def new_page(page_id: str, label: str = "", name: str = "MAIN", index: int = 0,
             sheet: str = "A3") -> dict:
    """An empty page, ready to draw on."""
    return {
        "version": "1.1",
        "type": "FC",
        "name": name,
        "page": {"id": page_id, "label": label or page_id, "index": index, "sheet": sheet},
        "interface": {"input": [], "output": [], "in_out": []},
        "constants": [],
        "blocks": [],
        "connections": [],
    }


class GraphProject:
    """Ordered set of FC pages forming one program."""

    def __init__(self, name: str = "MAIN", pages: Optional[list[dict]] = None) -> None:
        self.name = name
        self._pages: dict[str, dict] = {}
        self._order: list[str] = []
        for page in pages or []:
            self.put_page(page)

    # ---------- pages ----------

    def pages(self) -> list[dict]:
        """Page summaries in draw order."""
        rows = []
        for index, page_id in enumerate(self._order):
            page = self._pages[page_id]
            meta = page.get("page", {})
            rows.append(
                {
                    "id": page_id,
                    "index": index,
                    "label": meta.get("label", page_id),
                    "sheet": meta.get("sheet", "A3"),
                    "name": page.get("name", self.name),
                    "blocks": len(page.get("blocks", [])),
                    "constants": len(page.get("constants", [])),
                    "connections": len(page.get("connections", [])),
                    "ports": self._page_ports(page),
                }
            )
        return rows

    def get_page(self, page_id: str) -> dict:
        try:
            return self._pages[page_id]
        except KeyError:
            raise KeyError(f"Page not found: {page_id}") from None

    def add_page(self, label: str = "", page_id: Optional[str] = None,
                 sheet: str = "A3") -> dict:
        page_id = page_id or f"PAGE{len(self._order) + 1}"
        if page_id in self._pages:
            raise GraphError(f"Page already exists: {page_id}")
        page = new_page(page_id, label=label, name=self.name, index=len(self._order), sheet=sheet)
        return self.put_page(page)

    def put_page(self, page: dict) -> dict:
        """Validate and store one page, keeping its slot in the draw order."""
        errors = validate_fc_json(page)
        if errors:
            raise GraphError("Page rejected: " + "; ".join(errors))

        meta = page.get("page") or {}
        page_id = meta.get("id")
        if not page_id:
            raise GraphError("Page carries no page.id")
        program = page.get("name", self.name)
        stored = dict(page)
        stored["page"] = {
            **meta,
            "id": page_id,
            "index": self._pages[page_id]["page"].get("index", 0) if page_id in self._pages else len(self._order),
        }
        if not self._pages:
            self.name = program
        elif program != self.name:
            raise GraphError(
                f"All pages draw the same program: this page says {program!r}, "
                f"the project is {self.name!r}"
            )
        stored["name"] = self.name
        self._pages[page_id] = stored
        if page_id not in self._order:
            self._order.append(page_id)
        self._reindex()
        return stored

    def delete_page(self, page_id: str) -> None:
        self.get_page(page_id)
        if len(self._order) <= 1:
            raise GraphError("Cannot remove the last page")
        self._order.remove(page_id)
        self._pages.pop(page_id, None)
        self._reindex()

    def move_page(self, page_id: str, index: int) -> None:
        self.get_page(page_id)
        self._order.remove(page_id)
        self._order.insert(max(0, min(index, len(self._order))), page_id)
        self._reindex()

    def set_name(self, name: str) -> None:
        """Rename the program; every page follows."""
        self.name = name
        for page_id, page in self._pages.items():
            page["name"] = name

    def _reindex(self) -> None:
        for index, page_id in enumerate(self._order):
            self._pages[page_id].setdefault("page", {})["index"] = index

    @staticmethod
    def _page_ports(page: dict) -> list[str]:
        interface = page.get("interface") or {}
        return sorted({port["name"] for d in DIRECTIONS for port in interface.get(d, [])})

    # ---------- merging ----------

    def merged_fc(self) -> dict:
        """
        The whole project as one FC document.

        Every element carries the `page` it came from so a checker finding or a
        generated line can be traced back to a sheet. Interface ports with the
        same name on several pages become one port whose `pages` list says where
        it is drawn and whose `direction` says whether it is read, written or
        both -- that union is the cross-page jump.
        """
        blocks: list[dict] = []
        constants: list[dict] = []
        connections: list[dict] = []
        ports: dict[str, dict] = {}

        for page_id in self._order:
            page = self._pages[page_id]
            for block in page.get("blocks", []):
                blocks.append({**block, "page": block.get("page", page_id)})
            for constant in page.get("constants", []):
                constants.append({**constant, "page": constant.get("page", page_id)})
            for conn in page.get("connections", []):
                connections.append({**conn, "page": conn.get("page", page_id)})
            interface = page.get("interface") or {}
            for direction in DIRECTIONS:
                for port in interface.get(direction, []):
                    entry = ports.setdefault(
                        port["name"],
                        {
                            "name": port["name"],
                            "type": port["type"],
                            "scope": port.get("scope", "external"),
                            "bind": port.get("bind") or {},
                            "unit": port.get("unit", ""),
                            "directions": set(),
                            "pages": [],
                            "declared_types": {},
                        },
                    )
                    entry["directions"].add(direction)
                    entry["pages"].append(page_id)
                    entry["declared_types"][page_id] = port["type"]
                    if port.get("bind"):
                        entry["bind"] = port["bind"]
                    if port.get("scope") and port["scope"] != "external":
                        entry["scope"] = port["scope"]

        interface = {"input": [], "output": [], "in_out": []}
        for entry in ports.values():
            directions = entry.pop("directions")
            entry["pages"] = sorted(set(entry["pages"]))
            if len(entry["pages"]) > 1 and not entry["bind"] and entry["scope"] == "external":
                # A name drawn on more than one sheet is the connector between
                # them, whatever the pages happened to label it.
                entry["scope"] = "intermediate"
            if {"input", "output"} <= directions:
                entry["direction"] = "in_out"
                interface["in_out"].append(entry)
            elif "output" in directions:
                entry["direction"] = "output"
                interface["output"].append(entry)
            else:
                entry["direction"] = "input"
                interface["input"].append(entry)

        return {
            "version": "1.1",
            "type": "FC",
            "name": self.name,
            "page": {"id": self._order[0] if self._order else "", "index": 0, "sheet": "A3"},
            "interface": interface,
            "constants": constants,
            "blocks": blocks,
            "connections": connections,
        }

    def cross_page_index(self) -> list[dict]:
        """Variables that join two or more pages -- what the page tabs link."""
        rows = []
        for entry in self._merged_ports():
            if len(entry["pages"]) > 1:
                rows.append(
                    {
                        "name": entry["name"],
                        "type": entry["type"],
                        "scope": entry["scope"],
                        "direction": entry["direction"],
                        "pages": entry["pages"],
                    }
                )
        return sorted(rows, key=lambda row: row["name"])

    def _merged_ports(self) -> list[dict]:
        interface = self.merged_fc()["interface"]
        return [port for direction in DIRECTIONS for port in interface[direction]]

    # ---------- checking and generation ----------

    def check(
        self,
        block_defs: Optional[dict[str, dict]] = None,
        external_vars: Optional[dict[str, dict]] = None,
    ) -> list[Finding]:
        """Run the checker over the merged graph of every page."""
        return check_graph(self.merged_fc(), block_defs=block_defs, external_vars=external_vars)

    def report(
        self,
        block_defs: Optional[dict[str, dict]] = None,
        external_vars: Optional[dict[str, dict]] = None,
    ) -> dict:
        findings = self.check(block_defs=block_defs, external_vars=external_vars)
        payload = summarize(findings)
        payload["pages"] = self.pages()
        payload["cross_page"] = self.cross_page_index()
        return payload

    def generate_st(self, *, instances_global: bool = False) -> str:
        """Text ST for the whole project; the compiler stays the only reader of it."""
        return generate_st_from_fc(self.merged_fc(), instances_global=instances_global)

    def global_declarations(self) -> list[tuple[str, str]]:
        """`(name, type)` pairs the compile unit must declare as globals.

        Block instances and page variables: the compiler only accepts an instance
        as a global, and the debug section that a simulator or a monitor reads
        lists globals only.
        """
        return chart_globals(self.merged_fc())

    def watch_symbols(self, block_defs: dict[str, dict]) -> list[str]:
        """
        The symbols of this chart that a simulation run can read.

        Section 7 exports scalars and `instance#FIELD`, so neither half of a block
        instance works as a watch name: the base name is an `FB` type, which the
        protocol refuses, and a `VAR_INPUT` pin is not exported at all. Outputs
        are, so a pin shows the value the block produced.
        """
        names: list[str] = []
        for name, type_name in self.global_declarations():
            definition = block_defs.get(type_name)
            if definition is None:
                names.append(name)
            else:
                names.extend(f"{name}#{pin['name']}" for pin in definition["outputs"])
        return sorted(names)

    def pin_symbols(self, block_defs: dict[str, dict]) -> list[dict]:
        """Each pin of each page, and the symbol whose frame carries its value.

        The names come from the generator, not from a second implementation of
        them: the number a pin shows is the number of the slot the statement
        written for that very pin reads.
        """
        return chart_pin_symbols(self.merged_fc(), block_defs)

    # ---------- persistence ----------

    def to_json(self) -> dict:
        return {"name": self.name, "pages": [self._pages[p] for p in self._order]}

    def save_project(self, project_path: Path) -> list[str]:
        project_path = Path(project_path)
        graph_dir = project_path / GRAPH_DIR
        graph_dir.mkdir(parents=True, exist_ok=True)
        written = []
        for page_id in self._order:
            target = graph_dir / f"{page_id}.fc.json"
            target.write_text(_dump(self._pages[page_id]), encoding="utf-8")
            written.append(str(target))
        index = graph_dir / INDEX_FILE
        index.write_text(_dump({"name": self.name, "pages": list(self._order)}), encoding="utf-8")
        written.append(str(index))
        return written

    def load_project(self, project_path: Path) -> None:
        """Replace the page set with what is stored under `graph/`."""
        project_path = Path(project_path)
        graph_dir = project_path / GRAPH_DIR
        index_file = graph_dir / INDEX_FILE
        if not index_file.is_file():
            raise FileNotFoundError(f"No graph project index under {graph_dir}")

        index = json.loads(index_file.read_text(encoding="utf-8"))
        pages: list[dict] = []
        for page_id in index.get("pages", []):
            source = graph_dir / f"{page_id}.fc.json"
            if not source.is_file():
                raise FileNotFoundError(f"Graph page file is missing: {source}")
            pages.append(json.loads(source.read_text(encoding="utf-8")))
        if not pages:
            raise FileNotFoundError(f"Graph project {index_file} lists no pages")

        self.__init__(name=index.get("name", pages[0].get("name", "MAIN")), pages=pages)


def _dump(data: Any) -> str:
    """Byte-deterministic JSON: stage 4 compares these files to diff a download."""
    return json.dumps(data, indent=2, ensure_ascii=False, sort_keys=True) + "\n"


_PROJECT: Optional[GraphProject] = None


def get_graph_project() -> GraphProject:
    global _PROJECT
    if _PROJECT is None:
        _PROJECT = GraphProject(pages=[new_page("PAGE1", label="页 1")])
    return _PROJECT
