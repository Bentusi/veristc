"""VeriIDE graphical logic configuration: pages, merging, checking."""

from .checker import Finding, check_graph, is_compatible, summarize
from .service import GraphError, GraphProject, get_graph_project, new_page

__all__ = [
    "Finding",
    "GraphError",
    "GraphProject",
    "check_graph",
    "get_graph_project",
    "is_compatible",
    "new_page",
    "summarize",
]
