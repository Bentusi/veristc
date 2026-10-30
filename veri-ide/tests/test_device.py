"""Tests for the device configuration backend (hardware I/O <-> algorithm ports)."""

import math
import shutil
import subprocess
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from jsonschema import ValidationError

from veri_ide.api.server import app
from veri_ide.backend.device.models import (
    ChannelBinding,
    HardwareModule,
    IoVariable,
    Station,
    derive_io_kind,
)
from veri_ide.backend.device.service import DeviceProject, DeviceService
from veri_ide.backend.project.schema import validate_iomap_toml


@pytest.fixture
def client() -> TestClient:
    """API client over a freshly seeded single-station device project."""
    import veri_ide.backend.device.service as device_service

    device_service._PROJECT = DeviceProject([DeviceService()])
    return TestClient(app)


@pytest.fixture
def service() -> DeviceService:
    return DeviceService()


# ---------- module kind derivation (mirrors veri-stc/src/codegen.v) ----------

@pytest.mark.parametrize(
    "direction,st_type,expected",
    [
        ("input", "REAL", "AI"),
        ("input", "DINT", "AI"),
        ("input", "INT", "AI"),
        ("input", "BOOL", "DI"),
        ("input", "SINT", "DI"),  # only INT/DINT/REAL are analogue in codegen
        ("input", "LREAL", "DI"),
        ("output", "REAL", "AO"),
        ("output", "DINT", "AO"),
        ("output", "BOOL", "DO"),
        ("output", "WORD", "DO"),
    ],
)
def test_derive_io_kind_matches_codegen(direction, st_type, expected):
    assert derive_io_kind(direction, st_type) == expected


def test_derive_io_kind_rejects_bad_direction():
    with pytest.raises(ValueError):
        derive_io_kind("inout", "REAL")


# ---------- default configuration ----------

def test_default_configuration_is_valid(service):
    assert service.has_errors() is False
    assert len(service.modules()) == 4
    assert len(service.bindings()) == 5


def test_default_bindings_land_on_matching_modules(service):
    for row in service.mapping_rows():
        assert row["kind_match"] is True, row
        assert row["derived_kind"] == row["module_kind"]


def test_hardware_view_marks_bound_and_free_channels(service):
    view = service.hardware_view()
    ai1 = next(m for m in view if m["module_id"] == "AI1")
    bound = {c["channel"]: c["var_name"] for c in ai1["channel_list"] if c["bound"]}
    assert bound == {0: "PV", 2: "SP"}
    assert 1 not in bound
    assert service.free_channels("AI") == [1, 3, 4, 5, 6, 7]


# ---------- validation ----------

def test_kind_mismatch_is_rejected(service):
    # OUT is `output REAL` -> AO, channel 12 sits on the DI module
    service.bind(ChannelBinding("OUT", 12))
    codes = [i.code for i in service.validate()]
    assert "kind_mismatch" in codes


def test_duplicate_channel_is_rejected(service):
    service.bind(ChannelBinding("SP", 0))  # PV already owns channel 0
    codes = [i.code for i in service.validate()]
    assert "duplicate_channel" in codes


def test_channel_outside_the_64_channel_space_is_rejected(service):
    service.bind(ChannelBinding("SP", 64))
    issues = {i.code: i for i in service.validate()}
    assert "channel_out_of_range" in issues


def test_channel_with_no_hardware_module_is_rejected(service):
    service.bind(ChannelBinding("SP", 60))  # past the last declared module
    codes = [i.code for i in service.validate()]
    assert "no_hardware" in codes


def test_unbound_name_is_flagged_as_gate7_risk(service):
    # bind() requires a declared variable, so inject the orphan directly
    service._bindings["GHOST"] = ChannelBinding("GHOST", 3)
    issues = {i.code: i for i in service.validate()}
    assert "unknown_var" in issues
    assert "GATE-7" in issues["unknown_var"].message


def test_non_finite_calibration_is_rejected(service):
    service.bind(ChannelBinding("SP", 2, scale=math.nan))
    codes = [i.code for i in service.validate()]
    assert "non_finite_cal" in codes


def test_inverted_safety_limit_is_rejected(service):
    service.bind(ChannelBinding("PV", 0, safety_min=1000, safety_max=10))
    codes = [i.code for i in service.validate()]
    assert "bad_safety_limit" in codes


def test_unmapped_variable_is_a_warning_not_an_error(service):
    service.add_variable(IoVariable("EXTRA", "input", "REAL"))
    issues = [i for i in service.validate() if i.code == "unmapped_variable"]
    assert len(issues) == 1
    assert issues[0].severity == "warning"
    assert service.has_errors() is False


def test_bind_rejects_unknown_variable(service):
    with pytest.raises(KeyError):
        service.bind(ChannelBinding("NOPE", 1))


# ---------- hardware inventory ----------

def test_overlapping_module_is_rejected(service):
    with pytest.raises(ValueError):
        service.add_module(HardwareModule("AI2", "AI", 4, 8))  # overlaps AI1 (0..7)


def test_module_beyond_the_channel_space_is_rejected(service):
    with pytest.raises(ValueError):
        service.add_module(HardwareModule("AI2", "AI", 60, 8))


def test_removing_a_module_drops_its_bindings(service):
    service.remove_module("AI1")
    assert service.binding_for("PV") is None
    assert service.binding_for("SP") is None
    assert service.binding_for("OUT") is not None


def test_invalid_module_kind_is_rejected():
    with pytest.raises(ValueError):
        HardwareModule("X1", "PI", 30, 4)


# ---------- ST emission ----------

def test_rendered_st_is_sorted_and_complete(service):
    st = service.render_st()
    assert st.startswith("VAR_GLOBAL\n")
    assert "END_VAR\nIOMAP\n" in st
    assert st.endswith("END_IOMAP\n")
    assert st.count(",") == 3 * len(service.bindings())
    io_lines = [line for line in st.splitlines() if line.startswith("    ") and ";" in line and "," in line]
    assert io_lines == [
        "    LS_LOW, 12, INPUT, BOOL;",
        "    OUT, 8, OUTPUT, REAL;",
        "    PUMP_ON, 20, OUTPUT, BOOL;",
        "    PV, 0, INPUT, REAL;",
        "    SP, 2, INPUT, REAL;",
    ]


def test_rendered_st_is_empty_without_bindings():
    svc = DeviceService(bindings=[])
    assert svc.render_st() == ""


def test_rendered_st_is_deterministic(service):
    assert service.render_st() == service.render_st()


def test_rendered_iomap_compiles_with_veristc(tmp_path, service):
    """The emitted block must be accepted by the real compiler, not just by us."""
    binary = Path(__file__).resolve().parents[2] / "build" / "bin" / "veristc"
    if not binary.is_file():
        pytest.skip("veristc binary not built")

    st = service.render_st() + "\nPROGRAM MAIN\n    OUT := SP;\n    PUMP_ON := LS_LOW;\nEND_PROGRAM\n"
    source = tmp_path / "device.st"
    target = tmp_path / "device.sasm"
    source.write_text(st, encoding="utf-8")

    result = subprocess.run(
        [str(binary), "-c", str(source), "-o", str(target)],
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert target.is_file()

    svm = binary.parent / "svm"
    if not svm.is_file():
        pytest.skip("svm binary not built")
    mapping = subprocess.run([str(svm), "-m", str(target)], capture_output=True, text=True)
    assert mapping.returncode == 0, mapping.stdout + mapping.stderr
    for channel in (0, 2, 8, 12, 20):
        assert f"ch={channel} " in mapping.stdout


# ---------- persistence ----------

def test_saved_toml_passes_the_project_schema(service, tmp_path):
    target = service.save_project(tmp_path)
    data = validate_iomap_toml(target)
    assert data["PV"]["channel"] == 0
    assert data["PV"]["safety_limit"] == {"min": 0, "max": 1000}
    assert data["SP"]["st_type"] == "REAL"


def test_toml_rejects_a_non_numeric_channel(service, tmp_path):
    service.bind(ChannelBinding("OUT", 8))
    target = service.save_project(tmp_path)
    broken = target.read_text(encoding="utf-8").replace("channel = 8", 'channel = "8"')
    target.write_text(broken, encoding="utf-8")
    with pytest.raises(ValidationError):
        validate_iomap_toml(target)


def test_toml_round_trip_restores_bindings(service, tmp_path):
    service.save_project(tmp_path)
    reloaded = DeviceService(modules=service.modules(), bindings=[])
    reloaded.load_project(tmp_path)
    assert [b.to_dict() for b in reloaded.bindings()] == [b.to_dict() for b in service.bindings()]
    assert reloaded.has_errors() is False


# ---------- API ----------

def test_api_hardware_endpoint(client):
    response = client.get("/device/stations/ST1/hardware")
    assert response.status_code == 200
    kinds = {m["kind"] for m in response.json()["modules"]}
    assert kinds == {"AI", "AO", "DI", "DO"}


def test_api_validate_endpoint_reports_ok(client):
    response = client.post("/device/stations/ST1/validate")
    assert response.status_code == 200
    assert response.json()["ok"] is True


def test_api_mapping_crud_and_st_endpoint(client):
    created = client.get("/device/stations/ST1/mappings")
    assert created.status_code == 200
    assert len(created.json()) == 5

    moved = client.put("/device/stations/ST1/mapping", json={"var_name": "SP", "channel": 3})
    assert moved.status_code == 200
    after = client.get("/device/stations/ST1/mappings").json()
    assert next(r for r in after if r["var_name"] == "SP")["channel"] == 3

    check = client.post("/device/stations/ST1/validate").json()
    assert check["ok"] is True

    st = client.get("/device/stations/ST1/iomap.st")
    assert st.status_code == 200
    assert "SP, 3, INPUT, REAL;" in st.text

    removed = client.delete("/device/stations/ST1/mapping/SP")
    assert removed.status_code == 200
    assert client.delete("/device/stations/ST1/mapping/SP").status_code == 404


def test_api_rejects_binding_to_unknown_variable(client):
    response = client.put("/device/stations/ST1/mapping", json={"var_name": "NOPE", "channel": 1})
    assert response.status_code == 404


def test_api_rejects_overlapping_module(client):
    response = client.post(
        "/device/stations/ST1/modules",
        json={"module_id": "AI9", "kind": "AI", "first_channel": 5, "channel_count": 4},
    )
    assert response.status_code == 400


def test_api_replace_variables_drops_stale_bindings(client):
    before = client.get("/device/stations/ST1/mappings").json()
    assert any(r["var_name"] == "SP" for r in before)

    replaced = client.put(
        "/device/stations/ST1/variables",
        json={"variables": [{"name": "TIT", "direction": "input", "st_type": "REAL"}]},
    )
    assert replaced.status_code == 200
    assert [v["name"] for v in replaced.json()] == ["TIT"]
    # SP had a binding and no longer exists as a variable, so it is gone
    assert client.get("/device/stations/ST1/mappings").json() == []

    unmapped = client.post("/device/stations/ST1/validate").json()
    assert [w["var_name"] for w in unmapped["warnings"]] == ["TIT"]


# ---------- station model ----------

def test_station_requires_a_valid_identifier():
    with pytest.raises(ValueError):
        Station("2 ST")


@pytest.mark.parametrize("cycle_ms", [0, -10, 60001])
def test_station_rejects_out_of_range_cycle(cycle_ms):
    with pytest.raises(ValueError):
        Station("ST1", cycle_ms=cycle_ms)


def test_station_accepts_documented_cycle_bounds():
    assert Station("ST1", cycle_ms=1).cycle_ms == 1
    assert Station("ST1", cycle_ms=60000).cycle_ms == 60000


def test_new_station_starts_empty_with_its_own_channel_space():
    project = DeviceProject()
    service = project.add_station(Station("ST2", "副控站", device_type="RPS", cycle_ms=50))
    assert service.variables() == []
    assert service.bindings() == []
    assert service.free_channels("AI") == [0, 1, 2, 3, 4, 5, 6, 7]

    # the same channel number on two stations is two pieces of hardware
    project.station("ST1").bind(ChannelBinding("SP", 2))
    service.add_variable(IoVariable("SP", "input", "REAL"))
    service.bind(ChannelBinding("SP", 2))
    assert service.has_errors() is False


def test_cannot_remove_the_last_station():
    project = DeviceProject()
    with pytest.raises(ValueError):
        project.remove_station("ST1")


def test_duplicate_station_id_is_rejected():
    project = DeviceProject()
    with pytest.raises(ValueError):
        project.add_station(Station("ST1"))


def test_rename_station_rekeys_it_in_the_project():
    project = DeviceProject()
    project.update_station("ST1", Station("ST9", label="主控站", cycle_ms=200))
    assert [s["station_id"] for s in project.stations()] == ["ST9"]
    assert project.station("ST9").station.cycle_ms == 200
    with pytest.raises(KeyError):
        project.station("ST1")


def test_station_summary_reports_error_count():
    project = DeviceProject()
    project.station("ST1").bind(ChannelBinding("SP", 0))  # steals PV's channel
    row = next(s for s in project.stations() if s["station_id"] == "ST1")
    assert row["errors"] >= 1
    assert row["mapped"] == 5


# ---------- point configuration ----------

def test_preset_hold_needs_a_preset_value(service):
    service.bind(ChannelBinding("SP", 2, fault_hold="preset"))
    issues = {i.code for i in service.validate()}
    assert "preset_missing" in issues


def test_unknown_hold_mode_is_rejected(service):
    service.bind(ChannelBinding("SP", 2, fault_hold="freeze"))
    issues = {i.code for i in service.validate()}
    assert "bad_hold_mode" in issues


def test_hold_and_quality_are_configured_but_not_in_the_artifact(service):
    service.bind(ChannelBinding("SP", 2, has_quality=True, fault_hold="last_value"))
    issues = {i.code: i for i in service.validate()}
    assert issues["quality_not_in_artifact"].severity == "warning"
    assert issues["hold_not_in_artifact"].severity == "warning"
    # warnings never block the compile path
    assert service.has_errors() is False


def test_duplicate_point_name_is_rejected(service):
    service.bind(ChannelBinding("SP", 2, point_name="PV-001"))
    issues = {i.code: i for i in service.validate()}
    assert "duplicate_point" in issues
    assert "PV" in issues["duplicate_point"].message


def test_quality_type_on_analogue_channel_is_explained(service):
    service.add_variable(IoVariable("PT", "input", "QREAL"))
    service.bind(ChannelBinding("PT", 3))
    issues = {i.code: i for i in service.validate()}
    assert "kind_mismatch" in issues
    assert "st_type_to_io_type" in issues["kind_mismatch"].message


def test_hold_mode_defaults_to_unconfigured(service):
    assert ChannelBinding("X", 0).fault_hold == ""


# ---------- external variable table ----------

def test_external_variable_table_covers_unmapped_variables(service):
    service.add_variable(IoVariable("EXTRA", "input", "DINT", "未映射"))
    rows = {r["name"]: r for r in service.external_variables()}
    assert rows["EXTRA"]["mapped"] is False
    assert rows["EXTRA"]["channel"] is None
    assert rows["EXTRA"]["io_kind"] == "AI"
    assert rows["PV"]["has_quality"] is True
    assert rows["PV"]["fault_hold"] == "last_value"
    assert rows["OUT"]["preset_value"] == 0.0


def test_external_variable_table_is_sorted_and_stable(service):
    first = service.external_variables()
    assert [r["name"] for r in first] == sorted(r["name"] for r in first)
    assert first == service.external_variables()


def test_external_table_names_are_all_emitted_as_globals(service):
    st = service.render_st()
    for row in service.external_variables():
        if row["mapped"]:
            assert f"{row['name']} : {row['st_type']};" in st


# ---------- multi-station persistence ----------

def test_project_persists_stations_and_per_station_iomap(service, tmp_path):
    project = DeviceProject([service])
    project.add_station(Station("ST2", "副控站", device_type="ESFAS", cycle_ms=50))
    project.station("ST2").add_variable(IoVariable("TS", "input", "DINT"))
    project.station("ST2").bind(ChannelBinding("TS", 0, unit="ms", fault_hold="last_value"))

    written = project.save_project(tmp_path)
    assert Path(written["stations"]).is_file()
    assert len(written["iomap"]) == 2
    assert (tmp_path / "iomap" / "ST2.toml").is_file()
    for path in written["iomap"]:
        validate_iomap_toml(Path(path))

    reloaded = DeviceProject()
    reloaded.load_project(tmp_path)
    assert [s["station_id"] for s in reloaded.stations()] == ["ST1", "ST2"]
    assert reloaded.station("ST2").station.cycle_ms == 50
    assert reloaded.station("ST2").station.device_type == "ESFAS"
    assert reloaded.station("ST2").bindings()[0].unit == "ms"
    sp = next(b for b in reloaded.station("ST1").bindings() if b.var_name == "SP")
    assert sp.point_name == "SP-001" and sp.unit == "%"


def test_point_attributes_round_trip(service, tmp_path):
    service.bind(
        ChannelBinding("PV", 0, unit="%", point_name="PV-001", has_quality=True,
                       fault_hold="preset", preset_value=42.5,
                       safety_min=0, safety_max=1000)
    )
    target = service.save_project(tmp_path)
    assert validate_iomap_toml(target)["PV"]["preset_value"] == 42.5

    reloaded = DeviceService(modules=service.modules(), bindings=[])
    reloaded.load_project(tmp_path)
    assert reloaded.bindings() == service.bindings()


def test_load_project_without_configuration_fails(tmp_path):
    with pytest.raises(FileNotFoundError):
        DeviceProject().load_project(tmp_path)


# ---------- station-scoped API ----------

def test_api_station_crud(client):
    assert [s["station_id"] for s in client.get("/device/stations").json()] == ["ST1"]

    created = client.post("/device/stations", json={"station_id": "ST2", "cycle_ms": 50})
    assert created.status_code == 200
    assert client.post("/device/stations", json={"station_id": "ST2"}).status_code == 400

    updated = client.put(
        "/device/stations/ST2",
        json={"station_id": "ST2", "label": "副控站", "device_type": "RPS",
              "cycle_ms": 20, "comm_interface": "modbus_tcp", "comm_address": "10.0.0.2"},
    )
    assert updated.status_code == 200
    row = next(s for s in client.get("/device/stations").json() if s["station_id"] == "ST2")
    assert row["cycle_ms"] == 20 and row["comm_interface"] == "modbus_tcp"

    assert client.delete("/device/stations/ST2").status_code == 200
    assert client.delete("/device/stations/ST2").status_code == 404


def test_api_rejects_bad_station_parameters(client):
    assert client.post("/device/stations", json={"station_id": "ST2", "cycle_ms": 0}).status_code == 400
    assert client.post("/device/stations", json={"station_id": "bad id"}).status_code == 400


def test_api_unknown_station_is_404(client):
    assert client.get("/device/stations/STX/hardware").status_code == 404


def test_api_channels_are_independent_per_station(client):
    client.post("/device/stations", json={"station_id": "ST2"})
    assert client.put("/device/stations/ST1/mapping",
                      json={"var_name": "SP", "channel": 2}).status_code == 200
    # ST2 has the same inventory; channel 2 is free there
    assert 2 in client.get("/device/stations/ST2/free-channels", params={"kind": "AI"}).json()["channels"]


def test_api_external_variables_endpoint(client):
    rows = client.get("/device/stations/ST1/external-variables").json()
    assert [r["name"] for r in rows] == ["LS_LOW", "OUT", "PUMP_ON", "PV", "SP"]
    assert rows[3]["has_quality"] is True and rows[3]["io_kind"] == "AI"


def test_api_binding_carries_point_attributes(client):
    response = client.put(
        "/device/stations/ST1/mapping",
        json={"var_name": "PV", "channel": 0, "unit": "%", "point_name": "PV-001",
              "has_quality": True, "fault_hold": "preset", "preset_value": 50.0},
    )
    assert response.status_code == 200
    row = next(r for r in client.get("/device/stations/ST1/mappings").json() if r["var_name"] == "PV")
    assert row["fault_hold"] == "preset" and row["preset_value"] == 50.0

    warnings = {w["code"] for w in client.post("/device/stations/ST1/validate").json()["warnings"]}
    assert {"quality_not_in_artifact", "hold_not_in_artifact"} <= warnings


def test_api_save_and_load_multi_station_project(client, tmp_path):
    client.post("/device/stations", json={"station_id": "ST2", "cycle_ms": 250})
    saved = client.post("/device/save", json={"project_path": str(tmp_path)}).json()
    assert Path(saved["stations"]).is_file()
    assert len(saved["iomap"]) == 2

    import veri_ide.backend.device.service as device_service

    device_service._PROJECT = DeviceProject()
    loaded = client.post("/device/load", json={"project_path": str(tmp_path)})
    assert loaded.status_code == 200
    assert [s["station_id"] for s in loaded.json()] == ["ST1", "ST2"]
    assert next(s for s in loaded.json() if s["station_id"] == "ST2")["cycle_ms"] == 250


def test_rendered_st_can_carry_the_chart_instances_as_globals(service):
    """SafeST allows one global section, so a chart's blocks fold into it."""
    st = service.render_st([("lim1", "LIMITER")])
    globals_ = st.split("END_VAR")[0]
    assert "    lim1 : LIMITER;" in globals_
    assert "    lim1, " not in st.split("IOMAP")[1], "an instance is not an I/O channel"


def test_api_plant_table_is_derived_from_the_point_configuration(client):
    """One station's `.plant` comes out of its own point table, not a demo file."""
    body = client.get("/device/stations/ST1/plant").text
    rows = [line.split() for line in body.splitlines() if line and not line.startswith("#")]
    by_channel = {int(row[0]): row for row in rows}

    external = {row["channel"]: row for row in client.get("/device/stations/ST1/external-variables").json()}
    assert set(by_channel) == set(external), "every bound channel gets a row, nothing else"
    for channel, row in by_channel.items():
        point = external[channel]
        assert row[1] == point["direction"].upper()
        assert row[2] == "ACTUATOR" if point["direction"] == "output" else "CONST"
        assert int(row[5]) <= int(row[7]) <= int(row[6]), "init sits inside the point's range"

    assert client.get("/device/stations/NOPE/plant").status_code == 404
