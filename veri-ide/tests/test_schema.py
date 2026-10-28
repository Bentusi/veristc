"""Tests for schema validation."""

import pytest
from pathlib import Path
from jsonschema import ValidationError

from veri_ide.backend.project.schema import (
    validate_project_yaml,
    validate_iomap_toml,
    validate_project,
)


FIXTURES_DIR = Path(__file__).parent / "fixtures"


def test_valid_project_yaml():
    """Test that a valid project.yaml passes schema validation."""
    project_path = FIXTURES_DIR / "valid-project"
    result = validate_project_yaml(project_path)
    
    assert result["name"] == "test_project"
    assert result["safety_level"] == "SIL2"
    assert result["svm_version"] == "1.0.0"
    assert len(result["logic_files"]) == 2


def test_invalid_project_yaml_safety_level():
    """Test that an invalid safety_level fails schema validation."""
    project_path = FIXTURES_DIR / "invalid-project"
    
    with pytest.raises(ValidationError) as exc_info:
        validate_project_yaml(project_path)
    
    assert "SIL4" in str(exc_info.value)


def test_valid_iomap_toml():
    """Test that a valid iomap TOML file passes schema validation."""
    iomap_path = FIXTURES_DIR / "valid-project" / "iomap" / "ai.toml"
    result = validate_iomap_toml(iomap_path)
    
    assert "temperature_sensor" in result
    assert result["temperature_sensor"]["channel"] == 0
    assert result["temperature_sensor"]["scale"] == 0.1


def test_validate_full_project():
    """Test that validate_project validates all files."""
    project_path = FIXTURES_DIR / "valid-project"
    result = validate_project(project_path)
    
    assert "project" in result
    assert "iomaps" in result
    assert "ai" in result["iomaps"]
    assert result["lib_lock"] is None


def test_missing_project_yaml():
    """Test that missing project.yaml raises FileNotFoundError."""
    project_path = FIXTURES_DIR / "nonexistent"
    
    with pytest.raises(FileNotFoundError):
        validate_project_yaml(project_path)
