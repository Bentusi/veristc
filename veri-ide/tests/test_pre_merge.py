"""Tests for PRE merge logic."""

import pytest
from pathlib import Path

from veri_ide.backend.pre.merge import pre_merge, write_merged_file


FIXTURES_DIR = Path(__file__).parent / "fixtures"


def test_pre_merge_concatenates_files():
    """Test that pre_merge concatenates logic files in order."""
    project_path = FIXTURES_DIR / "valid-project"
    logic_files = ["MAIN.st", "pid.st"]
    
    result = pre_merge(project_path, logic_files)
    
    # Check that both files are included
    assert "PROGRAM main" in result
    assert "FUNCTION_BLOCK pid" in result
    
    # Check that source comments are added
    assert "(* Source: MAIN.st *)" in result
    assert "(* Source: pid.st *)" in result


def test_pre_merge_respects_order():
    """Test that pre_merge respects the order of logic_files."""
    project_path = FIXTURES_DIR / "valid-project"
    logic_files = ["pid.st", "MAIN.st"]
    
    result = pre_merge(project_path, logic_files)
    
    # pid.st should come before MAIN.st
    pid_pos = result.find("FUNCTION_BLOCK pid")
    main_pos = result.find("PROGRAM main")
    
    assert pid_pos < main_pos


def test_pre_merge_missing_file():
    """Test that pre_merge raises FileNotFoundError for missing files."""
    project_path = FIXTURES_DIR / "valid-project"
    logic_files = ["nonexistent.st"]
    
    with pytest.raises(FileNotFoundError):
        pre_merge(project_path, logic_files)


def test_write_merged_file_creates_build_dir():
    """Test that write_merged_file creates build/ directory if needed."""
    project_path = FIXTURES_DIR / "valid-project"
    logic_files = ["MAIN.st", "pid.st"]
    
    merged_path = write_merged_file(project_path, logic_files)
    
    assert merged_path.exists()
    assert merged_path.parent.name == "build"
    assert merged_path.name == "merged.st"
    
    # Clean up
    merged_path.unlink()
    if merged_path.parent.exists():
        merged_path.parent.rmdir()


def test_write_merged_file_content():
    """Test that write_merged_file writes correct content."""
    project_path = FIXTURES_DIR / "valid-project"
    logic_files = ["MAIN.st"]
    
    merged_path = write_merged_file(project_path, logic_files)
    
    with open(merged_path, encoding="utf-8") as f:
        content = f.read()
    
    assert "PROGRAM main" in content
    assert "(* Source: MAIN.st *)" in content
    
    # Clean up
    merged_path.unlink()
    if merged_path.parent.exists():
        merged_path.parent.rmdir()
