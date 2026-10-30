"""
Stage 3 simulation pipeline: chart -> composed text -> derived .plant -> frames.

These run the real compiler and the real simulator, because the whole point of
the stage is that the number on a pin is the number the run reported.
"""

from fastapi.testclient import TestClient

import veri_ide.backend.device.service as device_service
import veri_ide.backend.graph.service as graph_service
from veri_ide.api.server import app
from veri_ide.backend.device.models import ChannelBinding, HardwareModule, IoVariable, Station
from veri_ide.backend.device.service import DeviceService
from veri_ide.backend.graph.compose import compile_unit
from veri_ide.backend.graph.service import GraphProject, new_page
from veri_ide.backend.sim.plant import plant_from_external_variables
from veri_ide.backend.sim.router import run_names
from veri_ide.backend.sim.session import SimError, run_simulation

INTERFACE = "__interface__"
RS_OUTPUT = {"RS": {"outputs": [{"name": "Q"}], "inputs": [{"name": "S"}, {"name": "R"}]}}
#: The inputs a latch holds high: the point's fault preset is what stimulates them.
HOT = (1, 5)


def sw_channel(index: int) -> int:
    """Digital inputs on DI1 (12..19) then the second module the test adds (24..31)."""
    return index + 11 if index <= 8 else index + 15


def latches(count: int) -> dict:
    """`count` latches, each fed by its own input and each writing its own page variable."""
    return {
        "version": "1.1",
        "type": "FC",
        "name": "MAIN",
        "page": {"id": "PAGE1", "label": "页 1", "index": 0, "sheet": "A3"},
        "interface": {
            "input": [
                {"name": f"SI{i}", "type": "BOOL", "scope": "external",
                 "bind": {"station": "ST1", "variable": f"SW_{i}"},
                 "position": {"x": 40, "y": 40 * i}}
                for i in range(1, count + 1)
            ],
            "output": [
                {"name": f"QM{i}", "type": "BOOL", "scope": "intermediate",
                 "position": {"x": 700, "y": 40 * i}}
                for i in range(1, count + 1)
            ],
            "in_out": [],
        },
        "constants": [
            {"id": f"k{i}", "value": False, "type": "BOOL", "position": {"x": 150, "y": 40 * i}}
            for i in range(1, count + 1)
        ],
        "blocks": [
            {"id": f"rs{i}", "type": "RS", "position": {"x": 350, "y": 40 * i}}
            for i in range(1, count + 1)
        ],
        "connections": [
            wire
            for i in range(1, count + 1)
            for wire in (
                {"from": {"block": INTERFACE, "port": f"SI{i}"},
                 "to": {"block": f"rs{i}", "port": "S"}},
                {"from": {"block": f"k{i}", "port": "OUT"}, "to": {"block": f"rs{i}", "port": "R"}},
                {"from": {"block": f"rs{i}", "port": "Q"},
                 "to": {"block": INTERFACE, "port": f"QM{i}"}},
            )
        ],
    }


def configured_station(count: int) -> DeviceService:
    """A station with `count` digital inputs, two of them held high by their preset."""
    dev = DeviceService(Station(station_id="ST1", cycle_ms=100))
    dev.add_module(HardwareModule("DI2", "DI", 24, 8))
    dev.set_variables([IoVariable(f"SW_{i}", "input", "BOOL") for i in range(1, count + 1)])
    for i in range(1, count + 1):
        dev.bind(
            ChannelBinding(
                f"SW_{i}", sw_channel(i),
                fault_hold="preset" if i in HOT else "",
                preset_value=1.0 if i in HOT else None,
            )
        )
    return dev


def chart_station(count: int) -> tuple[DeviceService, GraphProject]:
    dev = configured_station(count)
    project = GraphProject(pages=[new_page("PAGE1", label="页 1")])
    project.put_page(latches(count))
    return dev, project


def simulate(dev: DeviceService, project: GraphProject, cycles: int, **stimulus):
    return run_simulation(
        compile_unit(dev, project),
        plant_from_external_variables("ST1", dev.external_variables()).to_plant_text(),
        run_names(project, dev, RS_OUTPUT),
        cycles=cycles,
        cycle_ms=dev.station.cycle_ms,
        **stimulus,
    )


def series_of(payload: dict) -> dict[str, dict]:
    return {row["name"]: row for row in payload["symbols"]}


def test_an_unstimulated_run_marks_nothing_as_forced():
    """The eighth frame key exists for every value, so "not forced" is stated, not implied."""
    dev, project = chart_station(2)
    by_name = series_of(simulate(dev, project, 3).payload)
    assert all(row["forced"] == [False, False, False] for row in by_name.values())


def test_a_forced_input_is_injected_into_the_object_so_the_program_reacts_to_it():
    """Injection lands on the plant side: the latch really sets, the page variable really follows."""
    dev, project = chart_station(2)
    by_name = series_of(
        simulate(dev, project, 3, forces=[{"name": "SW_2", "value": "TRUE"}]).payload
    )

    assert by_name["SW_2"]["values"] == [1, 1, 1]
    assert by_name["SW_2"]["forced"] == [True, True, True]
    assert by_name["rs2#Q"]["values"] == [1, 1, 1], "the block computed that output from the injected input"
    assert by_name["QM2"]["values"] == [1, 1, 1]
    assert by_name["QM2"]["forced"] == [False, False, False]


def test_a_forced_block_field_overrides_the_slot_after_the_cycle_computed_it():
    """Protocol 5.3: a memory-bound override is written once the program is done, so the pin
    shows the override while a value assigned from it inside the same cycle does not."""
    dev, project = chart_station(2)
    by_name = series_of(simulate(dev, project, 3, forces=[{"name": "rs1#Q", "value": 0}]).payload)

    assert by_name["rs1#Q"]["values"] == [0, 0, 0]
    assert by_name["rs1#Q"]["forced"] == [True, True, True]
    assert by_name["QM1"]["values"] == [1, 1, 1], "QM1 was assigned before the override landed"
    assert by_name["QM1"]["forced"] == [False, False, False]


def test_a_script_record_holds_from_its_cycle_until_the_run_ends():
    dev, project = chart_station(2)
    by_name = series_of(
        simulate(dev, project, 3, script=[{"cycle": 2, "name": "SW_2", "value": 1}]).payload
    )

    assert by_name["SW_2"]["values"] == [0, 1, 1], "cycle 1 is before the record"
    assert by_name["SW_2"]["forced"] == [False, True, True]
    assert by_name["rs2#Q"]["values"] == [0, 1, 1]


def test_a_later_record_for_the_same_symbol_takes_the_earlier_one_over():
    dev, project = chart_station(2)
    by_name = series_of(
        simulate(
            dev,
            project,
            4,
            script=[
                {"cycle": 2, "name": "SW_2", "value": 1},
                {"cycle": 3, "name": "SW_2", "value": 0},
            ],
        ).payload
    )

    assert by_name["SW_2"]["values"] == [0, 1, 0, 0]
    assert by_name["SW_2"]["forced"] == [False, True, True, True]


def test_a_stimulated_run_is_reproducible_record_for_record():
    """Determinism (protocol 4.7) has to cover the overrides too, or a re-run cannot be
    compared against the run the engineer looked at."""
    dev, project = chart_station(2)
    stimulus = {
        "forces": [{"name": "rs1#Q", "value": 0}],
        "script": [{"cycle": 2, "name": "SW_2", "value": 1}],
    }
    first = series_of(simulate(dev, project, 3, **stimulus).payload)
    second = series_of(simulate(dev, project, 3, **stimulus).payload)
    assert first == second


def test_a_stimulus_the_runner_refuses_comes_back_as_its_own_words():
    dev, project = chart_station(2)
    payload = simulate(dev, project, 2, forces=[{"name": "no_such_symbol", "value": 1}]).payload

    assert payload["ok"] is False and payload["stage"] == "simulate"
    assert "no_such_symbol" in payload["errors"][0]


def test_an_override_beyond_a_channels_physical_range_is_refused():
    """A BOOL channel takes 0 or 1; forcing 2 into it would render as a value the real
    hardware could never have produced."""
    dev, project = chart_station(2)
    payload = simulate(dev, project, 2, forces=[{"name": "SW_2", "value": 2}]).payload

    assert payload["ok"] is False
    assert "outside its physical range" in payload["errors"][0]


def test_a_record_past_the_simulated_cycles_is_refused_before_the_run():
    dev, project = chart_station(2)
    try:
        simulate(dev, project, 2, script=[{"cycle": 5, "name": "SW_2", "value": 1}])
    except SimError as exc:
        assert "past the 2 cycles" in str(exc)
    else:
        raise AssertionError("a record that can never take effect must not be dropped quietly")


def test_a_value_that_is_not_a_number_or_a_bool_is_refused_before_the_run():
    """An equals sign or a comma would turn one record into two different ones."""
    dev, project = chart_station(2)
    for bad in ("1,2", "1=2", ""):
        try:
            simulate(dev, project, 2, forces=[{"name": "SW_2", "value": bad}])
        except SimError as exc:
            assert "neither a number nor TRUE/FALSE" in str(exc), exc
        else:
            raise AssertionError(f"{bad!r} must not reach the command line")


def test_the_same_symbol_forced_twice_is_refused_before_the_run():
    dev, project = chart_station(2)
    try:
        simulate(
            dev,
            project,
            2,
            forces=[{"name": "SW_2", "value": 1}, {"name": "SW_2", "value": 0}],
        )
    except SimError as exc:
        assert "given twice" in str(exc)
    else:
        raise AssertionError("which value wins must not be left to the order of a table")


def test_a_symbol_named_by_both_the_force_list_and_the_script_is_refused():
    """`sim` refuses this too, and its words are what comes back."""
    dev, project = chart_station(2)
    payload = simulate(
        dev,
        project,
        2,
        forces=[{"name": "SW_2", "value": 1}],
        script=[{"cycle": 2, "name": "SW_2", "value": 0}],
    ).payload
    assert payload["ok"] is False
    assert "declared by both" in payload["errors"][0]


def test_the_run_reports_a_frame_value_for_every_watched_symbol():
    dev, project = chart_station(2)
    result = simulate(dev, project, 3)
    payload = result.payload
    assert result.ok, payload
    by_name = {row["name"]: row for row in payload["symbols"]}

    assert [row["cycle"] for row in payload["timeline"]] == [1, 2, 3]
    assert by_name["SW_1"]["values"] == [1, 1, 1], "the fault preset holds the input high"
    assert by_name["rs1#Q"]["values"] == [1, 1, 1]
    assert by_name["QM1"]["values"] == [1, 1, 1], "the page variable carries it the same cycle"
    assert by_name["SW_2"]["values"] == [0, 0, 0]
    assert by_name["SW_1"]["channel"] == 12, "the frame's channel stays with the value"
    assert by_name["QM1"]["channel"] is None, "a page variable is not bound to hardware"
    assert by_name["QM1"]["type"] == "BOOL"
    assert payload["done"]["cycles"] == 3


def test_a_chart_bigger_than_the_name_table_runs_over_several_passes():
    """`sim` takes 16 names a run; determinism is what makes the passes mergeable."""
    dev, project = chart_station(12)
    names = run_names(project, dev, RS_OUTPUT)
    assert len(names) == 36, "12 inputs, 12 page variables, 12 block outputs"

    result = simulate(dev, project, 4)
    payload = result.payload
    assert result.ok, payload
    assert payload["runs"] == 3
    assert len(payload["symbols"]) == len(names), "every name came back from a frame"
    assert all(len(row["values"]) == 4 for row in payload["symbols"])
    by_name = {row["name"]: row for row in payload["symbols"]}
    assert by_name["QM5"]["values"] == [1, 1, 1, 1]
    assert by_name["QM11"]["values"] == [0, 0, 0, 0]


def test_watch_symbols_reports_only_what_the_debug_section_exports():
    """Outputs have a field symbol; instances and their input pins do not."""
    dev, project = chart_station(1)
    assert project.watch_symbols(RS_OUTPUT) == ["QM1", "rs1#Q"]
    assert run_names(project, dev, RS_OUTPUT) == ["QM1", "SW_1", "rs1#Q"]


class TestSimApi:
    def client(self, count: int = 2) -> TestClient:
        graph_service._PROJECT = None
        device_service._PROJECT = None
        client = TestClient(app)
        dev = device_service.get_device_project().station("ST1")
        dev.add_module(HardwareModule("DI2", "DI", 24, 8))
        dev.set_variables([IoVariable(f"SW_{i}", "input", "BOOL") for i in range(1, count + 1)])
        for i in range(1, count + 1):
            dev.bind(
                ChannelBinding(f"SW_{i}", sw_channel(i),
                               fault_hold="preset" if i == 1 else "",
                               preset_value=1.0 if i == 1 else None)
            )
        chart = latches(count)
        assert client.put("/graph/pages/PAGE1", json=chart).status_code == 200
        return client

    def test_run_returns_the_frames_for_the_current_chart(self):
        client = self.client(2)
        payload = client.post("/sim/run", json={"station": "ST1", "cycles": 3}).json()
        assert payload["ok"] is True, payload
        assert payload["done"]["cycles"] == 3
        assert payload["station"]["cycle_ms"] == payload["cycle_ms"]
        assert payload["plant"]["text"].startswith("# Plant model: ST1_config")
        by_name = {row["name"]: row for row in payload["symbols"]}
        assert by_name["QM1"]["values"] == [1, 1, 1]
        assert by_name["rs2#Q"]["values"] == [0, 0, 0]

    def test_the_run_answers_with_the_pin_table_the_frames_belong_to(self):
        """A pin shows the value of the symbol it names, and never a name of its own."""
        payload = self.client(2).post("/sim/run", json={"station": "ST1", "cycles": 2}).json()
        assert payload["ok"] is True, payload
        series = {row["name"] for row in payload["symbols"]}
        by_pin = {(row["element"], row["port"]): row for row in payload["pins"]}
        assert {row["symbol"] for row in payload["pins"] if row["kind"] == "symbol"} <= series
        assert by_pin[("rs1", "S")]["symbol"] == "SW_1", "an input pin reads the point behind the wire"
        assert by_pin[("rs1", "Q")]["symbol"] == "rs1#Q", "an output pin reads the exported field"
        assert by_pin[("rs1", "R")]["literal"] == "FALSE", "a constant pin shows what it was folded into"
        assert by_pin[(INTERFACE, "QM1")]["symbol"] == "QM1"
        assert payload["pins"][0]["page"] == "PAGE1", "a pin belongs to the sheet it is drawn on"

    def test_run_refuses_while_the_checker_has_errors(self):
        client = self.client(1)
        chart = latches(1)
        chart["connections"].append(
            {"from": {"block": "rs1", "port": "Q"}, "to": {"block": "rs1", "port": "S"}}
        )
        assert client.put("/graph/pages/PAGE1", json=chart).status_code == 200
        payload = client.post("/sim/run", json={"station": "ST1", "cycles": 2}).json()
        assert payload["ok"] is False and payload["stage"] == "checker"
        assert payload["errors"]

    def test_run_bounds_the_cycle_count_like_the_simulator_does(self):
        client = self.client(1)
        assert client.post("/sim/run", json={"station": "ST1", "cycles": 0}).status_code == 400

    def test_run_applies_the_stimulus_that_came_with_the_request(self):
        client = self.client(2)
        payload = client.post(
            "/sim/run",
            json={
                "station": "ST1",
                "cycles": 3,
                "forces": [{"name": "SW_2", "value": True}],
                "script": [{"cycle": 2, "name": "SW_1", "value": 0}],
            },
        ).json()
        assert payload["ok"] is True, payload
        by_name = {row["name"]: row for row in payload["symbols"]}
        assert by_name["SW_2"]["values"] == [1, 1, 1]
        assert by_name["SW_2"]["forced"] == [True, True, True]
        assert by_name["SW_1"]["values"] == [1, 0, 0], "the script record takes over from cycle 2"
        assert by_name["SW_1"]["forced"] == [False, True, True]
        assert by_name["rs1#Q"]["values"] == [1, 1, 1], "the latch holds: S went low, R stayed low"

    def test_a_refused_override_is_reported_as_the_run_being_refused(self):
        client = self.client(1)
        payload = client.post(
            "/sim/run", json={"station": "ST1", "cycles": 2, "forces": [{"name": "NOPE", "value": 1}]}
        ).json()
        assert payload["ok"] is False and payload["stage"] == "simulate"
        assert "NOPE" in payload["errors"][0]

    def test_a_malformed_stimulus_value_is_answered_before_anything_runs(self):
        client = self.client(1)
        answer = client.post(
            "/sim/run",
            json={"station": "ST1", "cycles": 2, "forces": [{"name": "SW_1", "value": "1; rm -rf /"}]},
        )
        assert answer.status_code == 400
        assert "neither a number nor TRUE/FALSE" in answer.json()["detail"]
