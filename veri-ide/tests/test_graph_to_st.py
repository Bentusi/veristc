"""Tests for graph-to-ST generator."""
import pytest
from veri_ide.backend.gen.graph_to_st import generate_st_from_fc


@pytest.fixture
def simple_fc():
    """Simple FC with one block."""
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
                "id": "pid1",
                "type": "PID",
                "position": {"x": 100, "y": 100},
                "parameters": {"kp": 10},
            }
        ],
        "connections": [
            {
                "from": {"block": "__interface__", "port": "in1"},
                "to": {"block": "pid1", "port": "SP"},
            },
            {
                "from": {"block": "pid1", "port": "OUT"},
                "to": {"block": "__interface__", "port": "out1"},
            },
        ],
    }


def test_generate_st_simple(simple_fc):
    """Generate ST from simple FC."""
    st = generate_st_from_fc(simple_fc)
    assert "PROGRAM TEST_PROG" in st
    assert "pid1 : PID;" in st
    assert "VAR_INPUT" in st
    assert "in1 : DINT;" in st
    assert "VAR_OUTPUT" in st
    assert "out1 : DINT;" in st
    assert "pid1(SP := in1, kp := 10);" in st
    assert "out1 := pid1.OUT;" in st
    assert "END_PROGRAM" in st


def test_generate_st_no_interface():
    """Generate ST with no interface."""
    data = {
        "version": "1.0",
        "type": "FC",
        "name": "NO_IFACE",
        "blocks": [
            {"id": "b1", "type": "RS", "position": {"x": 0, "y": 0}}
        ],
        "connections": [],
    }
    st = generate_st_from_fc(data)
    assert "PROGRAM NO_IFACE" in st
    assert "b1 : RS;" in st
    assert "VAR_INPUT" not in st
    assert "VAR_OUTPUT" not in st


def test_generate_st_no_blocks():
    """Generate ST with no blocks."""
    data = {
        "version": "1.0",
        "type": "FC",
        "name": "NO_BLOCKS",
        "interface": {
            "input": [{"name": "in1", "type": "DINT"}],
            "output": [{"name": "out1", "type": "DINT"}],
        },
        "blocks": [],
        "connections": [],
    }
    st = generate_st_from_fc(data)
    assert "PROGRAM NO_BLOCKS" in st
    assert "\nVAR\n" not in st
    assert "in1 : DINT;" in st


def test_generate_st_chain():
    """Generate ST with chain of blocks."""
    data = {
        "version": "1.0",
        "type": "FC",
        "name": "CHAIN",
        "blocks": [
            {"id": "a", "type": "PID", "position": {"x": 0, "y": 0}},
            {"id": "b", "type": "LIMITER", "position": {"x": 100, "y": 0}},
        ],
        "connections": [
            {"from": {"block": "a", "port": "OUT"}, "to": {"block": "b", "port": "IN"}},
        ],
    }
    st = generate_st_from_fc(data)
    assert "a : PID;" in st
    assert "b : LIMITER;" in st
    lines = st.split("\n")
    a_idx = next(i for i, line in enumerate(lines) if "a();" in line or "a(" in line)
    b_idx = next(i for i, line in enumerate(lines) if "b(" in line)
    assert a_idx < b_idx


def test_generate_st_parameters():
    """Generate ST with block parameters."""
    data = {
        "version": "1.0",
        "type": "FC",
        "name": "PARAMS",
        "blocks": [
            {
                "id": "pid1",
                "type": "PID",
                "position": {"x": 0, "y": 0},
                "parameters": {"kp": 10, "ki": 1, "kd": 0.5},
            }
        ],
        "connections": [],
    }
    st = generate_st_from_fc(data)
    assert "kp := 10" in st
    assert "ki := 1" in st
    assert "kd := 0.5" in st


def test_generate_st_string_parameter():
    """Generate ST with string parameter."""
    data = {
        "version": "1.0",
        "type": "FC",
        "name": "STR_PARAM",
        "blocks": [
            {
                "id": "b1",
                "type": "CUSTOM",
                "position": {"x": 0, "y": 0},
                "parameters": {"mode": "auto"},
            }
        ],
        "connections": [],
    }
    st = generate_st_from_fc(data)
    assert "mode := 'auto'" in st


def test_generate_st_multiple_inputs():
    """Generate ST with multiple inputs to one block."""
    data = {
        "version": "1.0",
        "type": "FC",
        "name": "MULTI_IN",
        "interface": {
            "input": [
                {"name": "sp", "type": "DINT"},
                {"name": "pv", "type": "DINT"},
            ],
        },
        "blocks": [
            {"id": "pid1", "type": "PID", "position": {"x": 0, "y": 0}}
        ],
        "connections": [
            {"from": {"block": "__interface__", "port": "sp"}, "to": {"block": "pid1", "port": "SP"}},
            {"from": {"block": "__interface__", "port": "pv"}, "to": {"block": "pid1", "port": "PV"}},
        ],
    }
    st = generate_st_from_fc(data)
    assert "SP := sp" in st
    assert "PV := pv" in st


def test_generate_st_multiple_outputs():
    """Generate ST with multiple outputs."""
    data = {
        "version": "1.0",
        "type": "FC",
        "name": "MULTI_OUT",
        "interface": {
            "output": [
                {"name": "out1", "type": "DINT"},
                {"name": "out2", "type": "DINT"},
            ],
        },
        "blocks": [
            {"id": "b1", "type": "SPLITTER", "position": {"x": 0, "y": 0}}
        ],
        "connections": [
            {"from": {"block": "b1", "port": "OUT1"}, "to": {"block": "__interface__", "port": "out1"}},
            {"from": {"block": "b1", "port": "OUT2"}, "to": {"block": "__interface__", "port": "out2"}},
        ],
    }
    st = generate_st_from_fc(data)
    assert "out1 := b1.OUT1;" in st
    assert "out2 := b1.OUT2;" in st


def test_generate_st_in_out():
    """Generate ST with VAR_IN_OUT."""
    data = {
        "version": "1.0",
        "type": "FC",
        "name": "IN_OUT_TEST",
        "interface": {
            "in_out": [{"name": "data", "type": "DINT"}],
        },
        "blocks": [
            {"id": "b1", "type": "PROCESSOR", "position": {"x": 0, "y": 0}}
        ],
        "connections": [
            {"from": {"block": "__interface__", "port": "data"}, "to": {"block": "b1", "port": "IN"}},
        ],
    }
    st = generate_st_from_fc(data)
    assert "VAR_IN_OUT" in st
    assert "data : DINT;" in st


def test_generate_st_cycle_error():
    """Cycle raises error."""
    data = {
        "version": "1.0",
        "type": "FC",
        "name": "CYCLE",
        "blocks": [
            {"id": "a", "type": "PID", "position": {"x": 0, "y": 0}},
            {"id": "b", "type": "PID", "position": {"x": 100, "y": 0}},
        ],
        "connections": [
            {"from": {"block": "a", "port": "OUT"}, "to": {"block": "b", "port": "IN"}},
            {"from": {"block": "b", "port": "OUT"}, "to": {"block": "a", "port": "IN"}},
        ],
    }
    with pytest.raises(ValueError, match="[Cc]ycle"):
        generate_st_from_fc(data)


def test_generate_st_direct_passthrough():
    """Direct passthrough from input to output."""
    data = {
        "version": "1.0",
        "type": "FC",
        "name": "PASSTHROUGH",
        "interface": {
            "input": [{"name": "in1", "type": "DINT"}],
            "output": [{"name": "out1", "type": "DINT"}],
        },
        "blocks": [],
        "connections": [
            {
                "from": {"block": "__interface__", "port": "in1"},
                "to": {"block": "__interface__", "port": "out1"},
            }
        ],
    }
    st = generate_st_from_fc(data)
    assert "out1 := in1;" in st
