"""
Compiler analysis hand-off.

The graphical stage produces text ST; this module is the only place that turns
that text into the numbers a control engineer needs before simulation is
allowed: worst-case execution time, memory and variable footprint, and the size
of the region hot standby has to copy every cycle. Every number is read back
from the compiler or from the image the compiler emitted -- nothing here is
estimated a second time.
"""

import re
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

from .sasm_reader import Image, SasmError, read_file
from .service import Diagnostic, find_veristc_binary, parse_ndjson_diagnostics

# Hot standby copies memory by page (veri-runtime/hotstandby/hotstandby.h).
HS_PAGE_SIZE = 4096
HS_MAX_PAGES = 256
# The target initialises the VM over the whole static region (agent_main.c).
VM_MEMORY_BYTES = 1048576
# SnapshotHeader, packed: 10 u32 + 256 u32 page indices + 2 u32 (hotstandby.h).
SNAPSHOT_HEADER_BYTES = 1172

_ANALYSIS_FIELDS = {
    "stack depth": ("stack_depth", int),
    "recursive calls": ("recursive_calls", lambda v: v == "true"),
    "estimated wcet": ("estimated_wcet", int),
    "loops bounded": ("loops_bounded", lambda v: v == "true"),
}


class AnalysisError(ValueError):
    """The compiler could not be run, or its output could not be read."""


@dataclass
class AnalysisReport:
    ok: bool
    payload: dict
    diagnostics: list[Diagnostic]

    def to_dict(self) -> dict:
        return self.payload


def run_analysis(
    st_text: str,
    *,
    station: Optional[dict] = None,
    veristc_path: Optional[Path] = None,
    timeout_s: int = 60,
) -> AnalysisReport:
    """Compile `st_text` with the verified compiler and report what it measured.

    `station` is the device-stage row (`cycle_ms`), used only to express WCET as
    a share of the cycle budget.
    """
    if veristc_path is None:
        try:
            veristc_path = find_veristc_binary()
        except FileNotFoundError as exc:
            raise AnalysisError(str(exc)) from None

    work = Path(tempfile.mkdtemp(prefix="veride_analysis_"))
    source = work / "graph.st"
    image_path = work / "graph.sasm"
    source.write_text(st_text, encoding="utf-8")

    try:
        static = _run(veristc_path, ["-a", str(source)], timeout_s)
        if static.returncode != 0:
            return _rejected(static)
        build = _run(
            veristc_path, ["-c", str(source), "-o", str(image_path), "--json"], timeout_s
        )
        diagnostics = parse_ndjson_diagnostics(build.stdout)
        if build.returncode != 0 or not image_path.is_file():
            if not diagnostics:
                diagnostics.append(
                    Diagnostic(severity="error", message=build.stderr.strip() or "compile failed")
                )
            return AnalysisReport(
                ok=False,
                payload={
                    "ok": False,
                    "stage": "compile",
                    "exit_code": build.returncode,
                    "analysis": _parse_static(static.stdout),
                    "diagnostics": [_diagnostic(d) for d in diagnostics],
                },
                diagnostics=diagnostics,
            )
        image = read_file(image_path)
    except SasmError as exc:
        raise AnalysisError(f"the compiler produced an unreadable image: {exc}") from exc
    finally:
        _cleanup(work)

    return AnalysisReport(
        ok=True,
        payload={
            "ok": True,
            "image_bytes": image.file_bytes,
            "analysis": _parse_static(static.stdout),
            "wcet": _wcet(image, station),
            "memory": _memory(image),
            "sync_region": _sync_region(image),
            "safety": {
                "level": image.safety_level,
                "cycle_limit_instructions": image.cycle_limit,
                "loop_bounds": image.loop_bounds,
            },
            "sections": image.sections,
            "station": station or None,
        },
        diagnostics=[],
    )


def _run(veristc_path: Path, arguments: list[str], timeout_s: int) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(
            [str(veristc_path), *arguments],
            capture_output=True,
            text=True,
            check=False,
            timeout=timeout_s,
        )
    except subprocess.TimeoutExpired as exc:
        raise AnalysisError(f"veristc {' '.join(arguments[:1])} timed out") from exc
    except OSError as exc:
        raise AnalysisError(f"cannot run {veristc_path}: {exc}") from exc


def _rejected(completed: subprocess.CompletedProcess) -> AnalysisReport:
    diagnostics = parse_ndjson_diagnostics(completed.stdout)
    if not diagnostics:
        diagnostics.append(
            Diagnostic(
                severity="error",
                message=completed.stderr.strip()
                or completed.stdout.strip()
                or "the compiler rejected the generated text",
            )
        )
    return AnalysisReport(
        ok=False,
        payload={
            "ok": False,
            "stage": "analysis",
            "exit_code": completed.returncode,
            "analysis": None,
            "diagnostics": [_diagnostic(d) for d in diagnostics],
        },
        diagnostics=diagnostics,
    )


def _parse_static(text: str) -> Optional[dict]:
    """`veristc -a` prints `key: value` lines; only known keys are kept."""
    rows: dict[str, object] = {}
    for line in text.splitlines():
        match = re.match(r"^\s*([A-Za-z ]+?)\s*:\s*(\S.*)$", line)
        if not match:
            continue
        field = _ANALYSIS_FIELDS.get(match.group(1).strip().lower())
        if field:
            rows[field[0]] = field[1](match.group(2).strip())
    return rows or None


def _wcet(image: Image, station: Optional[dict]) -> dict:
    cycles = sum(row.cycles for row in image.wcet)
    nanoseconds = sum(row.ns for row in image.wcet)
    report = {
        "functions": [
            {"func_idx": row.func_idx, "cycles": row.cycles, "ns": row.ns}
            for row in image.wcet
        ],
        "total_cycles": cycles,
        "total_ns": nanoseconds,
        "cycle_limit_instructions": image.cycle_limit,
    }
    cycle_ms = (station or {}).get("cycle_ms")
    if cycle_ms:
        budget_ns = int(cycle_ms) * 1_000_000
        report["station_cycle_ms"] = int(cycle_ms)
        report["budget_ns"] = budget_ns
        report["used_percent"] = round(nanoseconds * 100.0 / budget_ns, 6)
        report["fits_cycle"] = nanoseconds <= budget_ns
    if image.cycle_limit:
        report["within_instruction_limit"] = cycles <= image.cycle_limit
    return report


def _memory(image: Image) -> dict:
    by_kind: dict[str, dict] = {}
    for segment in image.segments:
        row = by_kind.setdefault(segment.kind, {"bytes": 0, "count": 0, "start": segment.start})
        row["bytes"] += segment.size
        row["count"] += 1
    return {
        "linear_memory_bytes": image.memory_total,
        "segments": [
            {"kind": s.kind, "start": s.start, "bytes": s.size} for s in image.segments
        ],
        "by_kind": by_kind,
        "io_channels": image.iomap_count,
        "symbols": len(image.symbols),
        "global_slots": sum(1 for s in image.symbols if "#" not in s["name"]),
        "fb_fields": sum(1 for s in image.symbols if "#" in s["name"]),
        "code_bytes": image.code_bytes,
        "image_bytes": image.file_bytes,
    }


def _sync_region(image: Image) -> dict:
    """Mirror `hs_snapshot_create`: the pages of SEG_GLOBAL and SEG_FB_DATA are
    copied every cycle even when no store marked them dirty."""
    page_count = min((image.memory_total + HS_PAGE_SIZE - 1) // HS_PAGE_SIZE, HS_MAX_PAGES)
    pages: set[int] = set()
    for segment in image.segments:
        if segment.kind not in ("GLOBAL", "FB_DATA") or segment.size == 0:
            continue
        first = segment.start // HS_PAGE_SIZE
        last = min((segment.start + segment.size - 1) // HS_PAGE_SIZE, page_count - 1)
        pages.update(range(first, last + 1))
    mandatory = sorted(pages)
    bytes_per_cycle = len(mandatory) * HS_PAGE_SIZE
    return {
        "page_size": HS_PAGE_SIZE,
        "tracked_pages": page_count,
        "page_limit": HS_MAX_PAGES,
        "mandatory_pages": mandatory,
        "mandatory_page_count": len(mandatory),
        "bytes_per_cycle": bytes_per_cycle,
        "snapshot_header_bytes": SNAPSHOT_HEADER_BYTES,
        "worst_case_bytes": page_count * HS_PAGE_SIZE + SNAPSHOT_HEADER_BYTES,
        "within_page_limit": len(mandatory) <= HS_MAX_PAGES,
        "note": "value stack and frame stack are added by the target snapshot model (hotstandby/snapshot.c).",
    }


def _diagnostic(diagnostic: Diagnostic) -> dict:
    return {
        "severity": diagnostic.severity,
        "message": diagnostic.message,
        "pou": diagnostic.pou,
        "var": diagnostic.var,
        "kind": diagnostic.kind,
        "loc": diagnostic.loc,
    }


def _cleanup(work: Path) -> None:
    for child in work.iterdir():
        child.unlink(missing_ok=True)
    work.rmdir()
