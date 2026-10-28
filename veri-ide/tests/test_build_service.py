"""Tests for build service."""

import pytest
from pathlib import Path
import tempfile
import shutil

from veri_ide.backend.build.service import (
    build_project,
    parse_ndjson_diagnostics,
    find_veristc_binary,
    Diagnostic,
    BuildResult,
)
from veri_ide.backend.project.service import create_project


@pytest.fixture
def temp_dir():
    """Create a temporary directory for tests."""
    tmp = tempfile.mkdtemp(prefix="veride_build_test_")
    yield Path(tmp)
    shutil.rmtree(tmp, ignore_errors=True)


@pytest.fixture
def valid_project(temp_dir):
    """Create a valid project for testing."""
    project_path = temp_dir / "valid_project"
    create_project("valid_project", project_path)

    # Add a simple ST program
    (project_path / "logic" / "main.st").write_text(
        "PROGRAM main\n"
        "VAR\n"
        "    counter : DINT;\n"
        "END_VAR\n"
        "counter := counter + 1;\n"
        "END_PROGRAM\n"
    )

    # Update project.yaml to include the file
    import yaml
    with open(project_path / "project.yaml", "r") as f:
        project_data = yaml.safe_load(f)
    project_data["logic_files"] = ["main.st"]
    with open(project_path / "project.yaml", "w") as f:
        yaml.dump(project_data, f)

    return project_path


def test_parse_ndjson_diagnostics_empty():
    """Test parsing empty NDJSON output."""
    diagnostics = parse_ndjson_diagnostics("")
    assert diagnostics == []


def test_parse_ndjson_diagnostics_single():
    """Test parsing single diagnostic."""
    ndjson = '{"severity": "error", "msg": "Syntax error", "pou": "main", "kind": "type"}\n'
    diagnostics = parse_ndjson_diagnostics(ndjson)

    assert len(diagnostics) == 1
    assert diagnostics[0].severity == "error"
    assert diagnostics[0].message == "Syntax error"
    assert diagnostics[0].pou == "main"
    assert diagnostics[0].kind == "type"


def test_parse_ndjson_diagnostics_multiple():
    """Test parsing multiple diagnostics."""
    ndjson = (
        '{"severity": "error", "msg": "Error 1"}\n'
        '{"severity": "warning", "msg": "Warning 1"}\n'
        '{"severity": "info", "msg": "Info 1"}\n'
    )
    diagnostics = parse_ndjson_diagnostics(ndjson)

    assert len(diagnostics) == 3
    assert diagnostics[0].severity == "error"
    assert diagnostics[1].severity == "warning"
    assert diagnostics[2].severity == "info"


def test_parse_ndjson_diagnostics_malformed():
    """Test that malformed lines are skipped."""
    ndjson = (
        '{"severity": "error", "msg": "Valid"}\n'
        'not valid json\n'
        '{"severity": "warning", "msg": "Also valid"}\n'
    )
    diagnostics = parse_ndjson_diagnostics(ndjson)

    assert len(diagnostics) == 2


def test_find_veristc_binary():
    """Test finding veristc binary."""
    try:
        path = find_veristc_binary()
        assert path.exists()
        assert path.name == "veristc"
    except FileNotFoundError:
        # veristc not built yet, skip test
        pytest.skip("veristc binary not found")


def test_build_project_no_veristc(temp_dir):
    """Test building with non-existent veristc path."""
    project_path = temp_dir / "test_project"
    create_project("test_project", project_path)

    fake_veristc = Path("/nonexistent/veristc")
    result = build_project(project_path, veristc_path=fake_veristc)

    assert not result.success
    assert result.exit_code == 127
    assert len(result.diagnostics) > 0
    assert "not found" in result.diagnostics[0].message.lower()


def test_build_project_schema_validation_failure(temp_dir):
    """Test building with invalid project schema."""
    project_path = temp_dir / "invalid_project"
    project_path.mkdir()

    # Create invalid project.yaml (missing required fields)
    (project_path / "project.yaml").write_text("name: test\n")

    result = build_project(project_path)

    assert not result.success
    assert result.exit_code == 21
    assert "Schema validation failed" in result.diagnostics[0].message


def test_build_project_missing_logic_file(temp_dir):
    """Test building with missing logic file."""
    project_path = temp_dir / "test_project"
    create_project("test_project", project_path)

    # Update project.yaml to reference non-existent file
    import yaml
    with open(project_path / "project.yaml", "r") as f:
        project_data = yaml.safe_load(f)
    project_data["logic_files"] = ["nonexistent.st"]
    with open(project_path / "project.yaml", "w") as f:
        yaml.dump(project_data, f)

    result = build_project(project_path)

    assert not result.success
    assert result.exit_code == 22
    assert "not found" in result.diagnostics[0].message.lower()


def test_build_project_integration(valid_project):
    """Integration test: build a valid project end-to-end."""
    try:
        veristc_path = find_veristc_binary()
    except FileNotFoundError:
        pytest.skip("veristc binary not found")

    result = build_project(valid_project, veristc_path=veristc_path)

    # Check that build succeeded
    assert result.success, f"Build failed: {[d.message for d in result.diagnostics]}"
    assert result.exit_code == 0
    assert result.sasm_path is not None
    assert result.sasm_path.exists()
    assert result.merged_st_path is not None
    assert result.merged_st_path.exists()

    # Check that .sasm file is valid (has correct magic number)
    with open(result.sasm_path, "rb") as f:
        magic = f.read(4)
    assert magic == b"SASM", "Invalid .sasm magic number"


def test_build_project_syntax_error(temp_dir):
    """Test building with ST syntax error."""
    project_path = temp_dir / "syntax_error"
    create_project("syntax_error", project_path)

    # Add invalid ST program
    (project_path / "logic" / "bad.st").write_text(
        "PROGRAM bad\n"
        "VAR\n"
        "    x : DINT\n"  # Missing semicolon
        "END_VAR\n"
        "END_PROGRAM\n"
    )

    # Update project.yaml
    import yaml
    with open(project_path / "project.yaml", "r") as f:
        project_data = yaml.safe_load(f)
    project_data["logic_files"] = ["bad.st"]
    with open(project_path / "project.yaml", "w") as f:
        yaml.dump(project_data, f)

    try:
        veristc_path = find_veristc_binary()
    except FileNotFoundError:
        pytest.skip("veristc binary not found")

    result = build_project(project_path, veristc_path=veristc_path)

    # Build should fail
    assert not result.success
    assert result.exit_code != 0
    assert len(result.diagnostics) > 0

    # Should have error diagnostic
    error_diags = [d for d in result.diagnostics if d.severity == "error"]
    assert len(error_diags) > 0
