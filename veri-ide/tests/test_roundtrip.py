"""Tests for round-trip graph → ST → graph equivalence."""
import pytest
from veri_ide.backend.gen.graph_to_st import generate_st_from_fc
from veri_ide.backend.gen.st_to_graph import parse_st_to_graph, normalize_graph_for_comparison


def roundtrip(graph: dict) -> tuple[dict, dict]:
    """Perform round-trip: graph → ST → graph'."""
    st = generate_st_from_fc(graph)
    graph2 = parse_st_to_graph(st)
    return normalize_graph_for_comparison(graph), normalize_graph_for_comparison(graph2)


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


def test_roundtrip_simple(simple_fc):
    """Simple round-trip preserves structure."""
    g1, g2 = roundtrip(simple_fc)
    assert g1["name"] == g2["name"]
    assert g1["blocks"] == g2["blocks"]
    assert g1["connections"] == g2["connections"]
    assert g1["interface"]["input"] == g2["interface"]["input"]
    assert g1["interface"]["output"] == g2["interface"]["output"]


def test_roundtrip_no_interface():
    """Round-trip with no interface."""
    graph = {
        "version": "1.0",
        "type": "FC",
        "name": "NO_IFACE",
        "interface": {},
        "blocks": [
            {"id": "b1", "type": "RS", "position": {"x": 0, "y": 0}, "parameters": {}}
        ],
        "connections": [],
    }
    g1, g2 = roundtrip(graph)
    assert g1["name"] == g2["name"]
    assert g1["blocks"] == g2["blocks"]
    assert g1["connections"] == g2["connections"]


def test_roundtrip_chain():
    """Round-trip with chain of blocks."""
    graph = {
        "version": "1.0",
        "type": "FC",
        "name": "CHAIN",
        "interface": {},
        "blocks": [
            {"id": "a", "type": "PID", "position": {"x": 0, "y": 0}, "parameters": {}},
            {"id": "b", "type": "LIMITER", "position": {"x": 100, "y": 0}, "parameters": {}},
        ],
        "connections": [
            {"from": {"block": "a", "port": "OUT"}, "to": {"block": "b", "port": "IN"}},
        ],
    }
    g1, g2 = roundtrip(graph)
    assert g1["blocks"] == g2["blocks"]
    assert g1["connections"] == g2["connections"]


def test_roundtrip_parameters():
    """Round-trip preserves parameters."""
    graph = {
        "version": "1.0",
        "type": "FC",
        "name": "PARAMS",
        "interface": {},
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
    g1, g2 = roundtrip(graph)
    assert g1["blocks"][0]["parameters"] == g2["blocks"][0]["parameters"]


def test_roundtrip_multiple_inputs():
    """Round-trip with multiple inputs."""
    graph = {
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
            {"id": "pid1", "type": "PID", "position": {"x": 0, "y": 0}, "parameters": {}}
        ],
        "connections": [
            {"from": {"block": "__interface__", "port": "sp"}, "to": {"block": "pid1", "port": "SP"}},
            {"from": {"block": "__interface__", "port": "pv"}, "to": {"block": "pid1", "port": "PV"}},
        ],
    }
    g1, g2 = roundtrip(graph)
    assert g1["interface"]["input"] == g2["interface"]["input"]
    assert len(g1["connections"]) == len(g2["connections"])


def test_roundtrip_multiple_outputs():
    """Round-trip with multiple outputs."""
    graph = {
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
            {"id": "b1", "type": "SPLITTER", "position": {"x": 0, "y": 0}, "parameters": {}}
        ],
        "connections": [
            {"from": {"block": "b1", "port": "OUT1"}, "to": {"block": "__interface__", "port": "out1"}},
            {"from": {"block": "b1", "port": "OUT2"}, "to": {"block": "__interface__", "port": "out2"}},
        ],
    }
    g1, g2 = roundtrip(graph)
    assert g1["interface"]["output"] == g2["interface"]["output"]
    assert len(g1["connections"]) == len(g2["connections"])


def test_roundtrip_in_out():
    """Round-trip with VAR_IN_OUT."""
    graph = {
        "version": "1.0",
        "type": "FC",
        "name": "IN_OUT_TEST",
        "interface": {
            "in_out": [{"name": "data", "type": "DINT"}],
        },
        "blocks": [
            {"id": "b1", "type": "PROCESSOR", "position": {"x": 0, "y": 0}, "parameters": {}}
        ],
        "connections": [
            {"from": {"block": "__interface__", "port": "data"}, "to": {"block": "b1", "port": "IN"}},
        ],
    }
    g1, g2 = roundtrip(graph)
    assert g1["interface"]["in_out"] == g2["interface"]["in_out"]


def test_roundtrip_direct_passthrough():
    """Round-trip with direct passthrough."""
    graph = {
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
    g1, g2 = roundtrip(graph)
    assert g1["connections"] == g2["connections"]


def test_roundtrip_position_lost():
    """Round-trip loses position information (expected)."""
    graph = {
        "version": "1.0",
        "type": "FC",
        "name": "POS_TEST",
        "interface": {},
        "blocks": [
            {"id": "b1", "type": "PID", "position": {"x": 999, "y": 888}, "parameters": {}}
        ],
        "connections": [],
    }
    st = generate_st_from_fc(graph)
    graph2 = parse_st_to_graph(st)

    assert graph["blocks"][0]["position"] == {"x": 999, "y": 888}
    assert graph2["blocks"][0]["position"] == {"x": 0, "y": 0}

    g1_norm = normalize_graph_for_comparison(graph)
    g2_norm = normalize_graph_for_comparison(graph2)
    assert g1_norm["blocks"] == g2_norm["blocks"]
