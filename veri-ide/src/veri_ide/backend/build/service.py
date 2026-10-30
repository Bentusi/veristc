"""Build service — compile VeriIDE projects to SafeASM."""

import json
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

from ..pre.merge import write_merged_file
from ..project.schema import validate_project


@dataclass
class Diagnostic:
    """Compiler diagnostic message."""
    severity: str  # "error" / "warning" / "info"
    message: str
    pou: Optional[str] = None
    var: Optional[str] = None
    kind: Optional[str] = None
    loc: Optional[str] = None


@dataclass
class BuildResult:
    """Build result with artifacts and diagnostics."""
    success: bool
    sasm_path: Optional[Path]
    diagnostics: list[Diagnostic]
    exit_code: int
    merged_st_path: Optional[Path] = None


def parse_ndjson_diagnostics(ndjson_output: str) -> list[Diagnostic]:
    """Parse NDJSON diagnostic output from veristc --json.

    Args:
        ndjson_output: Newline-delimited JSON string

    Returns:
        List of Diagnostic objects
    """
    diagnostics = []
    for line in ndjson_output.strip().split("\n"):
        if not line:
            continue
        try:
            data = json.loads(line)
            diag = Diagnostic(
                severity=data.get("severity", "error"),
                message=data.get("msg", ""),
                pou=data.get("pou"),
                var=data.get("var"),
                kind=data.get("kind"),
                loc=data.get("loc"),
            )
            diagnostics.append(diag)
        except json.JSONDecodeError:
            # Skip malformed lines
            continue
    return diagnostics


def find_veristc_binary() -> Path:
    """Locate the veristc compiler binary.

    Returns:
        Path to veristc executable

    Raises:
        FileNotFoundError: If veristc not found in expected locations
    """
    # Check common locations
    candidates = [
        Path("build/bin/veristc"),  # Relative to repo root
        Path("/home/wei/veristc/build/bin/veristc"),  # Absolute path
    ]

    # Also check PATH
    try:
        result = subprocess.run(
            ["which", "veristc"],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode == 0:
            candidates.insert(0, Path(result.stdout.strip()))
    except Exception:
        pass

    for candidate in candidates:
        if candidate.exists():
            return candidate

    raise FileNotFoundError(
        "veristc binary not found. Run 'make veristc' in repo root first."
    )


def build_project(project_path: Path, veristc_path: Optional[Path] = None) -> BuildResult:
    """Build a VeriIDE project to SafeASM.

    Args:
        project_path: Path to the project directory
        veristc_path: Optional path to veristc binary (auto-detected if None)

    Returns:
        BuildResult with success status, artifacts, and diagnostics
    """
    # Validate project schema
    try:
        project_data = validate_project(project_path)
    except Exception as e:
        return BuildResult(
            success=False,
            sasm_path=None,
            diagnostics=[Diagnostic(severity="error", message=f"Schema validation failed: {e}")],
            exit_code=21,
        )

    # PRE merge
    try:
        merged_path = write_merged_file(project_path, project_data["project"]["logic_files"])
    except FileNotFoundError as e:
        return BuildResult(
            success=False,
            sasm_path=None,
            diagnostics=[Diagnostic(severity="error", message=str(e))],
            exit_code=22,
        )

    # Locate veristc
    if veristc_path is None:
        try:
            veristc_path = find_veristc_binary()
        except FileNotFoundError as e:
            return BuildResult(
                success=False,
                sasm_path=None,
                diagnostics=[Diagnostic(severity="error", message=str(e))],
                exit_code=127,
            )
    elif not veristc_path.exists():
        return BuildResult(
            success=False,
            sasm_path=None,
            diagnostics=[Diagnostic(severity="error", message=f"veristc binary not found: {veristc_path}")],
            exit_code=127,
        )

    # Compile
    sasm_path = project_path / "build" / "output.sasm"
    try:
        result = subprocess.run(
            [
                str(veristc_path),
                "-c", str(merged_path),
                "-o", str(sasm_path),
                "--json",
            ],
            capture_output=True,
            text=True,
            check=False,
            cwd=project_path,
        )
    except Exception as e:
        return BuildResult(
            success=False,
            sasm_path=None,
            diagnostics=[Diagnostic(severity="error", message=f"Compilation failed: {e}")],
            exit_code=126,
            merged_st_path=merged_path,
        )

    # Parse diagnostics
    diagnostics = parse_ndjson_diagnostics(result.stdout)

    # If no diagnostics parsed but exit code is non-zero, add stderr
    if result.returncode != 0 and not diagnostics:
        diagnostics.append(Diagnostic(
            severity="error",
            message=result.stderr.strip() or "Compilation failed with no diagnostics",
        ))

    return BuildResult(
        success=(result.returncode == 0),
        sasm_path=sasm_path if result.returncode == 0 else None,
        diagnostics=diagnostics,
        exit_code=result.returncode,
        merged_st_path=merged_path,
    )
