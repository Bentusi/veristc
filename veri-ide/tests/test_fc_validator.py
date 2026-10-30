"""Tests for FC JSON validation."""
import json
import pytest
from pathlib import Path

from veri_ide.backend.gen.validator import (
    validate_fc_json,
    validate_fc_file,
    check_no_cycles,
    topological_sort,
)


@pytest.fixture
def valid_fc():
    """Valid FC JSON."""
    return {
        "version": "1.0",
        "type": "FC",
        "name": "TEST_PROG",
        "interface": {
            "input": [{"name": "in1", "type": "DINT"}],
            "output": [{"name": "out1", "type": "DINT"}],
        },
        "blocks": [
            {
                "id": "block1",
                "type": "PID",
                "position": {"x": 100, "y": 100},
                "parameters": {"kp": 10},
            }
        ],
        "connections": [
            {
                "from": {"block": "__interface__", "port": "in1"},
                "to": {"block": "block1", "port": "SP"},
            },
            {
                "from": {"block": "block1", "port": "OUT"},
                "to": {"block": "__interface__", "port": "out1"},
            },
        ],
    }


def test_validate_fc_valid(valid_fc):
    """Valid FC passes validation."""
    errors = validate_fc_json(valid_fc)
    assert errors == []


def test_validate_fc_missing_version():
    """Missing version field fails."""
    data = {
        "type": "FC",
        "name": "TEST",
        "blocks": [],
        "connections": [],
    }
    errors = validate_fc_json(data)
    assert len(errors) > 0
    assert any("version" in e for e in errors)


def test_validate_fc_wrong_version():
    """Wrong version fails."""
    data = {
        "version": "2.0",
        "type": "FC",
        "name": "TEST",
        "blocks": [],
        "connections": [],
    }
    errors = validate_fc_json(data)
    assert len(errors) > 0
    assert any("version" in e for e in errors)


def test_validate_fc_wrong_type():
    """Wrong type fails."""
    data = {
        "version": "1.0",
        "type": "SFC",
        "name": "TEST",
        "blocks": [],
        "connections": [],
    }
    errors = validate_fc_json(data)
    assert len(errors) > 0
    assert any("type" in e for e in errors)


def test_validate_fc_lowercase_name():
    """Lowercase program name fails."""
    data = {
        "version": "1.0",
        "type": "FC",
        "name": "test_prog",
        "blocks": [],
        "connections": [],
    }
    errors = validate_fc_json(data)
    assert len(errors) > 0
    assert any("name" in e for e in errors)


def test_validate_fc_invalid_block_id():
    """Invalid block ID fails."""
    data = {
        "version": "1.0",
        "type": "FC",
        "name": "TEST",
        "blocks": [
            {
                # Identifiers may start with a letter or an underscore and hold
                # letters, digits and underscores -- this has both a leading
                # digit and a hyphen.
                "id": "1bad-block",
                "type": "PID",
                "position": {"x": 0, "y": 0},
            }
        ],
        "connections": [],
    }
    errors = validate_fc_json(data)
    assert len(errors) > 0
    assert any("id" in e.lower() or "block" in e.lower() for e in errors)


def test_validate_fc_missing_position():
    """Block missing position fails."""
    data = {
        "version": "1.0",
        "type": "FC",
        "name": "TEST",
        "blocks": [{"id": "block1", "type": "PID"}],
        "connections": [],
    }
    errors = validate_fc_json(data)
    assert len(errors) > 0


def test_validate_fc_invalid_port_type():
    """Invalid port type fails."""
    data = {
        "version": "1.0",
        "type": "FC",
        "name": "TEST",
        "interface": {
            # INT is a legal SafeST type; FLOAT is not a type at all.
            "input": [{"name": "in1", "type": "FLOAT"}],
        },
        "blocks": [],
        "connections": [],
    }
    errors = validate_fc_json(data)
    assert len(errors) > 0
    assert any("type" in e for e in errors)


def test_validate_fc_file(tmp_path):
    """Validate FC from file."""
    data = {
        "version": "1.0",
        "type": "FC",
        "name": "TEST",
        "blocks": [],
        "connections": [],
    }
    file_path = tmp_path / "test.fc.json"
    with open(file_path, "w") as f:
        json.dump(data, f)

    result, errors = validate_fc_file(file_path)
    assert result is not None
    assert errors == []


def test_validate_fc_file_not_found():
    """Validate non-existent file."""
    result, errors = validate_fc_file("/nonexistent/fc.json")
    assert result is None
    assert len(errors) > 0
    assert "not found" in errors[0].lower()


def test_validate_fc_file_invalid_json(tmp_path):
    """Validate file with invalid JSON."""
    file_path = tmp_path / "bad.json"
    with open(file_path, "w") as f:
        f.write("{invalid json}")

    result, errors = validate_fc_file(file_path)
    assert result is None
    assert len(errors) > 0
    assert "json" in errors[0].lower()


def test_check_no_cycles_no_cycle(valid_fc):
    """No cycle passes."""
    errors = check_no_cycles(valid_fc)
    assert errors == []


def test_check_no_cycles_with_cycle():
    """Cycle detected."""
    data = {
        "version": "1.0",
        "type": "FC",
        "name": "TEST",
        "blocks": [
            {"id": "a", "type": "PID", "position": {"x": 0, "y": 0}},
            {"id": "b", "type": "PID", "position": {"x": 100, "y": 0}},
        ],
        "connections": [
            {"from": {"block": "a", "port": "OUT"}, "to": {"block": "b", "port": "IN"}},
            {"from": {"block": "b", "port": "OUT"}, "to": {"block": "a", "port": "IN"}},
        ],
    }
    errors = check_no_cycles(data)
    assert len(errors) > 0
    assert "cycle" in errors[0].lower()


def test_topological_sort_simple(valid_fc):
    """Simple topological sort."""
    sorted_blocks, errors = topological_sort(valid_fc)
    assert errors == []
    assert sorted_blocks == ["block1"]


def test_topological_sort_chain():
    """Chain of blocks."""
    data = {
        "version": "1.0",
        "type": "FC",
        "name": "TEST",
        "blocks": [
            {"id": "a", "type": "PID", "position": {"x": 0, "y": 0}},
            {"id": "b", "type": "PID", "position": {"x": 100, "y": 0}},
            {"id": "c", "type": "PID", "position": {"x": 200, "y": 0}},
        ],
        "connections": [
            {"from": {"block": "a", "port": "OUT"}, "to": {"block": "b", "port": "IN"}},
            {"from": {"block": "b", "port": "OUT"}, "to": {"block": "c", "port": "IN"}},
        ],
    }
    sorted_blocks, errors = topological_sort(data)
    assert errors == []
    assert sorted_blocks == ["a", "b", "c"]


def test_topological_sort_cycle():
    """Cycle prevents topological sort."""
    data = {
        "version": "1.0",
        "type": "FC",
        "name": "TEST",
        "blocks": [
            {"id": "a", "type": "PID", "position": {"x": 0, "y": 0}},
            {"id": "b", "type": "PID", "position": {"x": 100, "y": 0}},
        ],
        "connections": [
            {"from": {"block": "a", "port": "OUT"}, "to": {"block": "b", "port": "IN"}},
            {"from": {"block": "b", "port": "OUT"}, "to": {"block": "a", "port": "IN"}},
        ],
    }
    sorted_blocks, errors = topological_sort(data)
    assert len(errors) > 0
    assert sorted_blocks == []
