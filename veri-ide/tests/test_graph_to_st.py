"""Tests for graph-to-ST generator."""
import pytest
from veri_ide.backend.gen.graph_to_st import (
    generate_st_from_fc,
    global_declarations,
    pin_symbols,
)


RS_DEF = {
    "RS": {
        "block_kind": "FB",
        "inputs": [{"name": "S", "type": "BOOL"}, {"name": "R", "type": "BOOL"}],
        "outputs": [{"name": "Q", "type": "BOOL"}],
    }
}


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


def test_generate_st_writes_an_associated_port_as_its_station_variable():
    """A bound port is compiled as the configuration variable, not the label."""
    data = {
        "version": "1.1",
        "type": "FC",
        "name": "BOUND",
        "interface": {
            "input": [
                {
                    "name": "IN",
                    "type": "REAL",
                    "scope": "external",
                    "bind": {"station": "ST1", "variable": "PV"},
                }
            ],
            "output": [
                {
                    "name": "OUT",
                    "type": "REAL",
                    "scope": "external",
                    "bind": {"station": "ST1", "variable": "ACT"},
                }
            ],
        },
        "blocks": [{"id": "lim1", "type": "LIMITER", "position": {"x": 0, "y": 0}}],
        "connections": [
            {
                "from": {"block": "__interface__", "port": "IN"},
                "to": {"block": "lim1", "port": "IN"},
            },
            {
                "from": {"block": "lim1", "port": "OUT"},
                "to": {"block": "__interface__", "port": "OUT"},
            },
        ],
    }
    st = generate_st_from_fc(data)
    assert "lim1(IN := PV);" in st
    assert "ACT := lim1.OUT;" in st
    assert "declared by the device stage: ACT, PV" in st


def test_generate_st_instances_global_holds_the_block_back_for_the_caller():
    """The analysis hand-off declares the instances in the global section."""
    data = {
        "version": "1.0",
        "type": "FC",
        "name": "GLOBAL_INST",
        "blocks": [{"id": "rs1", "type": "RS", "position": {"x": 0, "y": 0}}],
        "connections": [],
    }
    assert "rs1 : RS;" in generate_st_from_fc(data)
    held = generate_st_from_fc(data, instances_global=True)
    assert "rs1 : RS;" not in held
    assert "rs1();" in held


PAGE_VAR_CHART = {
    "version": "1.1",
    "type": "FC",
    "name": "THROUGH_PAGE",
    "interface": {
        "input": [{"name": "S", "type": "BOOL", "scope": "external",
                         "bind": {"station": "ST1", "variable": "SW_A"}}],
        "output": [{"name": "QMID", "type": "BOOL", "scope": "intermediate"}],
        "in_out": [],
    },
    "constants": [],
    "blocks": [
        {"id": "rs1", "type": "RS", "position": {"x": 0, "y": 0}},
        {"id": "rs2", "type": "RS", "position": {"x": 0, "y": 1}},
    ],
    "connections": [
        {"from": {"block": "__interface__", "port": "S"}, "to": {"block": "rs1", "port": "S"}},
        {"from": {"block": "rs1", "port": "Q"}, "to": {"block": "__interface__", "port": "QMID"}},
        {"from": {"block": "__interface__", "port": "QMID"}, "to": {"block": "rs2", "port": "R"}},
    ],
}


def test_a_page_variable_is_written_before_the_block_that_reads_it():
    """A page variable carries data in this cycle, so it orders like a block."""
    st = generate_st_from_fc(PAGE_VAR_CHART, instances_global=True)
    body = [line for line in st.splitlines() if ":=" in line]
    assert body == ["rs1(S := SW_A);", "QMID := rs1.Q;", "rs2(R := QMID);"]
    assert "QMID : BOOL;" not in st


def test_page_variables_are_declared_as_globals_for_the_simulator():
    """Section 7 lists globals only, so a page local could never be watched."""
    assert ("QMID", "BOOL") in global_declarations(PAGE_VAR_CHART)


def _pins_of(rows, element):
    return {row["port"]: row for row in rows if row["element"] == element}


def test_a_pin_shows_the_slot_the_generated_statement_reads():
    """Each name comes from the same rule that wrote the assignment for it."""
    rows = pin_symbols(PAGE_VAR_CHART, RS_DEF)
    rs1 = _pins_of(rows, "rs1")
    assert rs1["S"]["symbol"] == "SW_A", "the driver is a port associated with a station point"
    assert rs1["Q"]["symbol"] == "rs1#Q", "an output pin reads the field the compiler exported"
    assert rs1["R"]["kind"] == "unconnected", "a pin with no wire has nothing to show"
    assert _pins_of(rows, "rs2")["R"]["symbol"] == "QMID", "a page variable is a global slot"

    ports = _pins_of(rows, "__interface__")
    assert ports["S"]["symbol"] == "SW_A"
    assert ports["QMID"]["symbol"] == "QMID"


def test_a_pin_driven_by_a_graph_constant_shows_the_literal_it_was_folded_into():
    """A constant owns no slot: the value on the pin is the value in the statement."""
    data = {
        "version": "1.1",
        "type": "FC",
        "name": "CONSTANT_IN",
        "page": {"id": "PAGE1"},
        "interface": {"input": [], "output": [], "in_out": []},
        "constants": [{"id": "k1", "value": False, "type": "BOOL"}],
        "blocks": [{"id": "rs1", "type": "RS", "position": {"x": 0, "y": 0}}],
        "connections": [
            {"from": {"block": "k1", "port": "OUT"}, "to": {"block": "rs1", "port": "R"}}
        ],
    }
    row = _pins_of(pin_symbols(data, RS_DEF), "rs1")["R"]
    assert row["kind"] == "constant"
    assert row["literal"] == "FALSE"
    assert row["page"] == "PAGE1"


def test_an_unassociated_page_port_has_no_address_to_read():
    """A bare VAR_INPUT of the program is not in the debug section, so it cannot be watched."""
    data = {
        "version": "1.1",
        "type": "FC",
        "name": "UNBOUND",
        "page": {"id": "PAGE1"},
        "interface": {
            "input": [{"name": "RAW", "type": "BOOL", "scope": "external"}],
            "output": [],
            "in_out": [],
        },
        "constants": [],
        "blocks": [],
        "connections": [],
    }
    row = _pins_of(pin_symbols(data, RS_DEF), "__interface__")["RAW"]
    assert row["kind"] == "unwatchable"
    assert row["symbol"] is None
