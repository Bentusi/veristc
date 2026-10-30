"""Tests for the multi-page logic graph: protocol, merging, checker, ST text, API."""

import json

import pytest
from fastapi.testclient import TestClient

import veri_ide.backend.graph.service as graph_service
from veri_ide.backend.graph.checker import check_graph, is_compatible
from veri_ide.backend.graph.service import GraphError, GraphProject, new_page


LIBRARY = {
    "PID": {
        "id": "PID_v1",
        "name": "PID控制器",
        "type": "PID",
        "time_based": False,
        "inputs": [
            {"name": "SP", "type": "REAL", "default_value": None},
            {"name": "PV", "type": "REAL", "default_value": None},
        ],
        "outputs": [{"name": "OUT", "type": "REAL", "default_value": None}],
        "in_out": [],
        "parameters": [{"name": "Kp", "data_type": "REAL"}],
    },
    "LIMITER": {
        "id": "LIMITER_v1",
        "name": "限幅器",
        "type": "LIMITER",
        "time_based": False,
        "inputs": [
            {"name": "IN", "type": "REAL", "default_value": None},
            {"name": "MN", "type": "REAL", "default_value": 0.0},
            {"name": "MX", "type": "REAL", "default_value": 100.0},
        ],
        "outputs": [{"name": "OUT", "type": "REAL", "default_value": None}],
        "in_out": [],
        "parameters": [],
    },
    "FBY": {
        "id": "FBY_v1",
        "name": "FBY延迟单元",
        "type": "FBY",
        "time_based": True,
        "inputs": [{"name": "IN", "type": "REAL", "default_value": None}],
        "outputs": [{"name": "OUT", "type": "REAL", "default_value": None}],
        "in_out": [],
        "parameters": [],
    },
    "RS": {
        "id": "RS_v1",
        "name": "RS触发器",
        "type": "RS",
        "time_based": False,
        "inputs": [
            {"name": "S", "type": "BOOL", "default_value": None},
            {"name": "R", "type": "BOOL", "default_value": None},
        ],
        "outputs": [{"name": "Q", "type": "BOOL", "default_value": None}],
        "in_out": [],
        "parameters": [],
    },
}

EXTERNAL = {
    "SP": {"name": "SP", "direction": "input", "st_type": "REAL"},
    "PV": {"name": "PV", "direction": "input", "st_type": "REAL"},
    "OUT": {"name": "OUT", "direction": "output", "st_type": "REAL"},
    "LS_LOW": {"name": "LS_LOW", "direction": "input", "st_type": "BOOL"},
}


def page(page_id, index=0, blocks=None, constants=None, connections=None,
         interface=None, name="MAIN", label=""):
    doc = new_page(page_id, label=label or page_id, name=name, index=index)
    doc["blocks"] = blocks or []
    doc["constants"] = constants or []
    doc["connections"] = connections or []
    if interface:
        for direction, ports in interface.items():
            doc["interface"][direction] = [
                p if isinstance(p, dict) else {"name": p, "type": "REAL"} for p in ports
            ]
    return doc


def block(bid, btype, x=0, y=0, **extra):
    return {"id": bid, "type": btype, "position": {"x": x, "y": y}, **extra}


def wire(src_block, src_port, dst_block, dst_port):
    return {"from": {"block": src_block, "port": src_port},
            "to": {"block": dst_block, "port": dst_port}}


def codes(findings):
    return sorted(f.code for f in findings)


def find(findings, code):
    return [f for f in findings if f.code == code]


# ---------- protocol ----------


def test_new_page_passes_schema():
    from veri_ide.backend.gen.validator import validate_fc_json

    assert validate_fc_json(new_page("PAGE1")) == []


def test_page_with_constants_and_bindings_passes_schema():
    from veri_ide.backend.gen.validator import validate_fc_json

    doc = page(
        "PAGE1",
        blocks=[block("pid1", "PID")],
        constants=[{"id": "K1", "type": "REAL", "value": 1.5, "position": {"x": 10, "y": 10}}],
        connections=[wire("K1", "OUT", "pid1", "SP")],
        interface={"input": [{"name": "PV", "type": "REAL", "scope": "external",
                             "bind": {"station": "ST1", "variable": "PV"}}]},
    )
    assert validate_fc_json(doc) == []


def test_bind_rejects_unknown_keys():
    from veri_ide.backend.gen.validator import validate_fc_json

    doc = page("PAGE1", interface={"input": [{"name": "PV", "type": "REAL",
                                            "bind": {"variable": "PV", "channel": 3}}]})
    assert validate_fc_json(doc)


# ---------- pages ----------


def test_put_page_rejects_invalid_document():
    project = GraphProject()
    with pytest.raises(GraphError, match="Page rejected"):
        project.put_page({"version": "1.1", "type": "FC", "name": "lower"})


def test_add_move_and_delete_keeps_order():
    project = GraphProject(pages=[new_page("PAGE1")])
    project.add_page(label="second", page_id="PAGE2")
    project.add_page(page_id="PAGE3")
    assert [p["id"] for p in project.pages()] == ["PAGE1", "PAGE2", "PAGE3"]
    assert [p["index"] for p in project.pages()] == [0, 1, 2]

    project.move_page("PAGE3", 0)
    assert [p["id"] for p in project.pages()] == ["PAGE3", "PAGE1", "PAGE2"]

    project.delete_page("PAGE1")
    assert [p["id"] for p in project.pages()] == ["PAGE3", "PAGE2"]


def test_cannot_delete_last_page():
    project = GraphProject(pages=[new_page("PAGE1")])
    with pytest.raises(GraphError, match="last page"):
        project.delete_page("PAGE1")


def test_duplicate_page_id_rejected():
    project = GraphProject(pages=[new_page("PAGE1")])
    with pytest.raises(GraphError, match="already exists"):
        project.add_page(page_id="PAGE1")


def test_all_pages_draw_one_program():
    project = GraphProject(pages=[new_page("PAGE1", name="MAIN")])
    with pytest.raises(GraphError, match="same program"):
        project.put_page(new_page("PAGE2", name="OTHER"))


def test_rename_reaches_every_page():
    project = GraphProject(pages=[new_page("PAGE1")])
    project.add_page(page_id="PAGE2")
    project.set_name("RPS")
    assert project.name == "RPS"
    assert {p["name"] for p in project.pages()} == {"RPS"}
    assert project.merged_fc()["name"] == "RPS"


# ---------- merging ----------


def test_same_name_on_two_pages_becomes_one_intermediate():
    project = GraphProject(
        pages=[
            page("P1", interface={"output": [{"name": "MID", "type": "REAL"}]},
                 blocks=[block("fb1", "FBY")],
                 connections=[wire("fb1", "OUT", "__interface__", "MID")]),
            page("P2", index=1, interface={"input": ["MID"]},
                 blocks=[block("pid1", "PID")],
                 connections=[wire("__interface__", "MID", "pid1", "SP"),
                              wire("__interface__", "MID", "pid1", "PV")]),
        ]
    )
    merged = project.merged_fc()
    entry = [p for p in merged["interface"]["in_out"] if p["name"] == "MID"]
    assert len(entry) == 1
    assert entry[0]["pages"] == ["P1", "P2"]
    assert entry[0]["scope"] == "intermediate"
    assert entry[0]["direction"] == "in_out"
    assert project.cross_page_index() == [
        {"name": "MID", "type": "REAL", "scope": "intermediate",
         "direction": "in_out", "pages": ["P1", "P2"]}
    ]


def test_merge_tags_provenance_on_every_element():
    project = GraphProject(
        pages=[
            page("P1", blocks=[block("a1", "RS")],
                 constants=[{"id": "C1", "type": "BOOL", "value": True,
                             "position": {"x": 0, "y": 0}}],
                 connections=[wire("C1", "OUT", "a1", "S"), wire("C1", "OUT", "a1", "R")]),
            page("P2", index=1, blocks=[block("b1", "FBY")]),
        ]
    )
    merged = project.merged_fc()
    assert [b["page"] for b in merged["blocks"]] == ["P1", "P2"]
    assert merged["constants"][0]["page"] == "P1"
    assert {c["page"] for c in merged["connections"]} == {"P1"}


# ---------- ST generation ----------


def test_constant_is_inlined_into_the_pin():
    project = GraphProject(
        pages=[
            page(
                "P1",
                blocks=[block("lim1", "LIMITER", parameters={"MX": 100.0})],
                constants=[{"id": "SET", "type": "REAL", "value": 1.5,
                            "position": {"x": 0, "y": 0}},
                           {"id": "ZERO", "type": "REAL", "value": 0.0,
                            "position": {"x": 0, "y": 0}}],
                connections=[wire("SET", "OUT", "lim1", "IN"),
                             wire("ZERO", "OUT", "lim1", "MN")],
            )
        ]
    )
    st = project.generate_st()
    assert "lim1(IN := 1.5, MN := 0.0, MX := 100.0);" in st
    assert "SET(" not in st


def test_bound_port_is_not_redeclared():
    project = GraphProject(
        pages=[
            page(
                "P1",
                blocks=[block("pid1", "PID")],
                interface={
                    "input": [{"name": "PV", "type": "REAL", "bind": {"station": "ST1",
                                                                     "variable": "PV"}}],
                    "output": ["OUT"],
                },
                connections=[wire("__interface__", "PV", "pid1", "PV"),
                             wire("pid1", "OUT", "__interface__", "OUT")],
            )
        ]
    )
    st = project.generate_st()
    assert "PV : REAL;" not in st
    assert "VAR_INPUT\n    OUT : REAL;" not in st
    assert "pid1(PV := PV" in st
    assert "OUT := pid1.OUT;" in st
    assert "station configuration variables" in st


def test_intermediate_variable_is_a_program_local():
    project = GraphProject(
        pages=[
            page("P1", interface={"output": ["MID"]}, blocks=[block("f1", "FBY")],
                 connections=[wire("f1", "OUT", "__interface__", "MID")]),
            page("P2", index=1, interface={"input": ["MID"]}, blocks=[block("p1", "PID")],
                 connections=[wire("__interface__", "MID", "p1", "SP"),
                              wire("__interface__", "MID", "p1", "PV")]),
        ]
    )
    st = project.generate_st()
    assert "    MID : REAL;" in st
    assert "VAR_IN_OUT" not in st


# ---------- checker: types ----------


@pytest.mark.parametrize(
    "src,dst,ok",
    [
        ("REAL", "REAL", True),
        ("DINT", "REAL", True),
        ("REAL", "DINT", False),
        ("INT", "DINT", True),
        ("DINT", "INT", False),
        ("BOOL", "REAL", False),
        ("QREAL", "REAL", True),
        ("REAL", "QREAL", True),
        ("QBOOL", "BOOL", True),
        ("STRING", "REAL", False),
        ("TIME", "DINT", False),
    ],
)
def test_compatibility(src, dst, ok):
    assert is_compatible(src, dst) is ok


def test_clean_graph_has_no_findings():
    fc = page(
        "P1",
        blocks=[block("pid1", "PID", parameters={"Kp": 2.0})],
        interface={
            "input": [
                {"name": "SP", "type": "REAL", "bind": {"station": "ST1", "variable": "SP"}},
                {"name": "PV", "type": "REAL", "bind": {"station": "ST1", "variable": "PV"}},
            ],
            "output": [{"name": "OUT", "type": "REAL",
                        "bind": {"station": "ST1", "variable": "OUT"}}],
        },
        connections=[
            wire("__interface__", "SP", "pid1", "SP"),
            wire("__interface__", "PV", "pid1", "PV"),
            wire("pid1", "OUT", "__interface__", "OUT"),
        ],
    )
    findings = check_graph(GraphProject(pages=[fc]).merged_fc(), LIBRARY, EXTERNAL)
    assert findings == []


def test_pin_type_mismatch_is_located():
    fc = page(
        "P1",
        blocks=[block("rs1", "RS"), block("pid1", "PID", parameters={"Kp": 1.0})],
        interface={
            "input": [
                {"name": "PV", "type": "REAL", "bind": {"station": "ST1", "variable": "PV"}},
                {"name": "LS", "type": "BOOL", "scope": "local"},
            ]
        },
        connections=[
            wire("__interface__", "LS", "rs1", "S"),
            wire("__interface__", "LS", "rs1", "R"),
            wire("__interface__", "PV", "pid1", "PV"),
            wire("rs1", "Q", "pid1", "SP"),
        ],
    )
    findings = check_graph(GraphProject(pages=[fc]).merged_fc(), LIBRARY, EXTERNAL)
    mismatch = find(findings, "PIN_TYPE_MISMATCH")
    assert len(mismatch) == 1
    assert mismatch[0].page == "P1"
    assert mismatch[0].block == "pid1"
    assert mismatch[0].port == "SP"
    assert "BOOL" in mismatch[0].message and "REAL" in mismatch[0].message


def test_quality_bit_drop_is_a_warning():
    fc = page(
        "P1",
        blocks=[block("pid1", "PID", parameters={"Kp": 1.0})],
        interface={"input": [{"name": "PV", "type": "QREAL", "scope": "local"}]},
        connections=[
            wire("__interface__", "PV", "pid1", "PV"),
            wire("__interface__", "PV", "pid1", "SP"),
        ],
    )
    findings = check_graph(GraphProject(pages=[fc]).merged_fc(), LIBRARY, {})
    drops = find(findings, "QUALITY_DROPPED")
    assert len(drops) == 2
    assert {f.severity for f in drops} == {"warning"}
    assert {f.port for f in drops} == {"SP", "PV"}


def test_unknown_block_and_unknown_port():
    fc = page(
        "P1",
        blocks=[block("x1", "Mystery")],
        connections=[wire("ghost", "OUT", "x1", "NOPE")],
    )
    findings = check_graph(GraphProject(pages=[fc]).merged_fc(), LIBRARY, {})
    assert "UNKNOWN_BLOCK" in codes(findings)
    assert "UNRESOLVED_BLOCK" in codes(findings)


def test_port_that_the_library_does_not_have():
    fc = page("P1", blocks=[block("pid1", "PID")],
              connections=[wire("pid1", "NOPE", "pid1", "SP")])
    findings = check_graph(GraphProject(pages=[fc]).merged_fc(), LIBRARY, {})
    assert find(findings, "UNKNOWN_PORT")


# ---------- checker: connectivity ----------


def test_unconnected_input_pin_is_reported():
    fc = page("P1", blocks=[block("pid1", "PID", parameters={"Kp": 1.0})])
    findings = check_graph(GraphProject(pages=[fc]).merged_fc(), LIBRARY, {})
    unconnected = find(findings, "PIN_UNCONNECTED")
    assert {f.port for f in unconnected} == {"SP", "PV"}
    assert unconnected[0].block == "pid1"


def test_default_from_the_library_satisfies_a_pin():
    fc = page("P1", blocks=[block("lim1", "LIMITER")])
    findings = check_graph(GraphProject(pages=[fc]).merged_fc(), LIBRARY, {})
    # MN and MX carry library defaults, IN does not.
    assert {f.port for f in find(findings, "PIN_UNCONNECTED")} == {"IN"}


def test_multi_driver_across_pages():
    project = GraphProject(
        pages=[
            page("P1", blocks=[block("a1", "FBY")], interface={"output": ["MID"]},
                 connections=[wire("a1", "OUT", "__interface__", "MID")]),
            page("P2", index=1, blocks=[block("b1", "FBY")], interface={"output": ["MID"]},
                 connections=[wire("b1", "OUT", "__interface__", "MID")]),
        ]
    )
    findings = check_graph(project.merged_fc(), LIBRARY, {})
    multi = find(findings, "MULTI_DRIVER")
    assert len(multi) == 1
    assert "P1, P2" in multi[0].message


def test_duplicate_block_id_across_pages():
    project = GraphProject(
        pages=[page("P1", blocks=[block("pid1", "PID")]),
               page("P2", index=1, blocks=[block("pid1", "PID")])]
    )
    findings = check_graph(project.merged_fc(), LIBRARY, {})
    dup = find(findings, "DUPLICATE_ID")
    assert len(dup) == 1 and dup[0].page == "P2"


def test_constant_cannot_be_written():
    fc = page(
        "P1",
        blocks=[block("f1", "FBY")],
        constants=[{"id": "K1", "type": "REAL", "value": 1.0, "position": {"x": 0, "y": 0}}],
        connections=[wire("K1", "OUT", "f1", "IN"), wire("f1", "OUT", "K1", "IN")],
    )
    findings = check_graph(GraphProject(pages=[fc]).merged_fc(), LIBRARY, {})
    assert find(findings, "CONSTANT_SINK")


# ---------- checker: loops ----------


def test_loop_without_delay_is_an_error_on_the_page_that_closes_it():
    project = GraphProject(
        pages=[
            page("P1", blocks=[block("p1", "PID", parameters={"Kp": 1.0}),
                               block("l1", "LIMITER")],
                 interface={"input": [{"name": "SP", "type": "REAL", "scope": "local"}]},
                 connections=[
                     wire("__interface__", "SP", "p1", "SP"),
                     wire("l1", "OUT", "p1", "PV"),
                     wire("p1", "OUT", "l1", "IN"),
                 ]),
        ]
    )
    findings = check_graph(project.merged_fc(), LIBRARY, {})
    cycles = find(findings, "CYCLE")
    assert len(cycles) == 1
    assert cycles[0].page == "P1"
    assert "l1 -> p1 -> l1" in cycles[0].message


def test_loop_through_a_time_based_block_is_only_informational():
    project = GraphProject(
        pages=[
            page("P1", blocks=[block("p1", "PID", parameters={"Kp": 1.0}),
                               block("d1", "FBY")],
                 interface={"input": [{"name": "SP", "type": "REAL", "scope": "local"}]},
                 connections=[
                     wire("__interface__", "SP", "p1", "SP"),
                     wire("d1", "OUT", "p1", "PV"),
                     wire("p1", "OUT", "d1", "IN"),
                 ]),
        ]
    )
    findings = check_graph(project.merged_fc(), LIBRARY, {})
    assert find(findings, "CYCLE") == []
    assert len(find(findings, "DELAYED_LOOP")) == 1


def test_loop_spanning_two_pages_is_reported_once():
    project = GraphProject(
        pages=[
            page("P1", blocks=[block("p1", "PID", parameters={"Kp": 1.0})],
                 interface={"output": ["A"], "input": ["B"]},
                 connections=[
                     wire("__interface__", "B", "p1", "SP"),
                     wire("__interface__", "B", "p1", "PV"),
                     wire("p1", "OUT", "__interface__", "A"),
                 ]),
            page("P2", index=1, blocks=[block("l1", "LIMITER")],
                 interface={"output": ["B"], "input": ["A"]},
                 connections=[
                     wire("__interface__", "A", "l1", "IN"),
                     wire("l1", "OUT", "__interface__", "B"),
                 ]),
        ]
    )
    findings = check_graph(project.merged_fc(), LIBRARY, {})
    cycles = find(findings, "CYCLE")
    assert len(cycles) == 1
    assert "pages P1, P2" in cycles[0].message


# ---------- checker: variables ----------


def test_variable_with_no_association_is_an_error():
    fc = page("P1", blocks=[block("pid1", "PID", parameters={"Kp": 1.0})],
              interface={"input": [{"name": "PV", "type": "REAL",
                                   "bind": {"station": "ST1", "variable": "NOPE"}}]},
              connections=[wire("__interface__", "PV", "pid1", "PV"),
                           wire("__interface__", "PV", "pid1", "SP")])
    findings = check_graph(GraphProject(pages=[fc]).merged_fc(), LIBRARY, EXTERNAL)
    bad = find(findings, "BAD_BIND")
    assert len(bad) == 1
    assert "NOPE" in bad[0].message


def test_binding_a_station_input_as_an_output_is_refused():
    fc = page("P1", blocks=[block("f1", "FBY")],
              interface={"output": [{"name": "SP", "type": "REAL",
                                    "bind": {"station": "ST1", "variable": "SP"}}]},
              connections=[wire("f1", "OUT", "__interface__", "SP")])
    findings = check_graph(GraphProject(pages=[fc]).merged_fc(), LIBRARY, EXTERNAL)
    assert any("station input" in f.message for f in find(findings, "BAD_BIND"))


def test_binding_type_conflicts_with_the_point():
    fc = page("P1", blocks=[block("rs1", "RS")],
              interface={"input": [{"name": "PV", "type": "REAL",
                                   "bind": {"station": "ST1", "variable": "LS_LOW"}}]},
              connections=[wire("__interface__", "PV", "rs1", "S"),
                           wire("__interface__", "PV", "rs1", "R")])
    findings = check_graph(GraphProject(pages=[fc]).merged_fc(), LIBRARY, EXTERNAL)
    assert find(findings, "BAD_BIND")


def test_unbound_interface_input_is_reported():
    fc = page("P1", blocks=[block("pid1", "PID", parameters={"Kp": 1.0})],
              interface={"input": [{"name": "PV", "type": "REAL"}]},
              connections=[wire("__interface__", "PV", "pid1", "PV"),
                           wire("__interface__", "PV", "pid1", "SP")])
    findings = check_graph(GraphProject(pages=[fc]).merged_fc(), LIBRARY, EXTERNAL)
    unbound = find(findings, "VARIABLE_UNBOUND")
    assert len(unbound) == 1 and unbound[0].port == "PV"


def test_intermediate_read_but_never_written():
    project = GraphProject(
        pages=[
            page("P1", blocks=[block("pid1", "PID", parameters={"Kp": 1.0})],
                 interface={"input": ["MID"]},
                 connections=[wire("__interface__", "MID", "pid1", "SP"),
                              wire("__interface__", "MID", "pid1", "PV")]),
            page("P2", index=1, interface={"input": ["MID"]}),
        ]
    )
    findings = check_graph(project.merged_fc(), LIBRARY, {})
    assert find(findings, "VARIABLE_UNBOUND")


def test_intermediate_that_never_jumps():
    fc = page("P1", blocks=[block("f1", "FBY")],
              interface={"output": [{"name": "MID", "type": "REAL", "scope": "intermediate"}]},
              connections=[wire("f1", "OUT", "__interface__", "MID")])
    findings = check_graph(GraphProject(pages=[fc]).merged_fc(), LIBRARY, {})
    assert find(findings, "DEAD_INTERMEDIATE")


def test_same_name_with_two_types_across_pages():
    project = GraphProject(
        pages=[
            page("P1", interface={"output": [{"name": "MID", "type": "REAL"}]}),
            page("P2", index=1, interface={"input": [{"name": "MID", "type": "BOOL"}]}),
        ]
    )
    findings = check_graph(project.merged_fc(), LIBRARY, {})
    conflict = find(findings, "PORT_TYPE_CONFLICT")
    assert len(conflict) == 1
    assert "REAL" in conflict[0].message and "BOOL" in conflict[0].message


def test_output_declared_but_never_written():
    fc = page("P1", blocks=[block("f1", "FBY")],
              interface={"input": ["X"], "output": ["Y"]},
              connections=[wire("__interface__", "X", "f1", "IN"),
                           wire("f1", "OUT", "__interface__", "X")])
    findings = check_graph(GraphProject(pages=[fc]).merged_fc(), LIBRARY, {})
    assert find(findings, "UNUSED_PORT")


# ---------- persistence ----------


def test_save_and_load_round_trip(tmp_path):
    project = GraphProject(
        pages=[
            page("P1", blocks=[block("pid1", "PID")],
                 constants=[{"id": "K1", "type": "REAL", "value": 1.5,
                             "position": {"x": 4, "y": 8}}],
                 connections=[wire("K1", "OUT", "pid1", "SP")],
                 interface={"input": [{"name": "PV", "type": "REAL",
                                      "bind": {"station": "ST1", "variable": "PV"}}]}),
            page("P2", index=1, label="second"),
        ]
    )
    written = project.save_project(tmp_path)
    assert len(written) == 3
    assert (tmp_path / "graph" / "P1.fc.json").is_file()

    loaded = GraphProject(pages=[new_page("OTHER")])
    loaded.load_project(tmp_path)
    assert [p["id"] for p in loaded.pages()] == ["P1", "P2"]
    assert loaded.pages()[1]["label"] == "second"
    assert loaded.merged_fc()["constants"][0]["value"] == 1.5

    again = tmp_path / "graph" / "P1.fc.json"
    before = again.read_text(encoding="utf-8")
    loaded.save_project(tmp_path)
    assert again.read_text(encoding="utf-8") == before


def test_load_missing_index_fails(tmp_path):
    with pytest.raises(FileNotFoundError):
        GraphProject().load_project(tmp_path)


# ---------- API ----------


@pytest.fixture
def client():
    """A fresh graph singleton, so the API tests do not leak into each other."""
    from veri_ide.api.server import app

    graph_service._PROJECT = None
    yield TestClient(app)
    graph_service._PROJECT = None


def test_api_pages_and_check(client):
    pages = client.get("/graph/pages").json()
    assert pages[0]["id"] == "PAGE1"

    r = client.put("/graph/pages/PAGE1", json=page(
        "PAGE1",
        blocks=[block("pid1", "PID", parameters={"Kp": 1.0})],
        interface={"input": [{"name": "PV", "type": "REAL",
                             "bind": {"station": "ST1", "variable": "PV"}}]},
        connections=[wire("__interface__", "PV", "pid1", "PV"),
                     wire("pid1", "OUT", "pid1", "SP")],
    ))
    assert r.status_code == 200

    r = client.post("/graph/check", json={"station": "ST1"})
    assert r.status_code == 200
    report = r.json()
    assert report["ok"] is False
    assert {f["code"] for f in report["errors"]} == {"CYCLE"}
    assert all({"page", "block", "port"} <= set(f) for f in report["errors"])

    r = client.post("/graph/pages", json={"label": "second page", "page_id": "PAGE2"})
    assert r.status_code == 200
    assert [p["id"] for p in client.get("/graph/pages").json()] == ["PAGE1", "PAGE2"]

    r = client.get("/graph/st")
    assert r.status_code == 400
    assert "cycle" in r.json()["detail"].lower()


def test_api_rejects_bad_page(client):
    r = client.put("/graph/pages/PAGE1", json={"version": "1.1", "type": "FC"})
    assert r.status_code == 400
    assert "Page rejected" in r.json()["detail"]


def test_api_page_not_found(client):
    assert client.get("/graph/pages/NOPE").status_code == 404
    assert client.delete("/graph/pages/NOPE").status_code == 404
