"""
Single-block simulation: the block page runs on the same engine as the chart.

These hit the real compiler and the real simulator, because the point of the
feature is that a value on a block's pin is a value a run frame reported -- not
a second implementation of the block's arithmetic the panel could drift from.
"""

import pytest
from fastapi.testclient import TestClient

from veri_ide.api.server import app
from veri_ide.backend.library.models import (
    AlgorithmBlock,
    BlockCategory,
    BlockPort,
    PortDirection,
)
from veri_ide.backend.library.service import get_library_service


@pytest.fixture()
def client() -> TestClient:
    return TestClient(app)


def series_by_name(payload: dict) -> dict[str, dict]:
    return {row["name"]: row for row in payload["symbols"]}


class TestRunBlockFunctionBlock:
    """A FUNCTION_BLOCK is instantiated and called; its state carries across cycles."""

    def test_a_held_input_is_injected_and_the_latch_reacts(self, client: TestClient):
        payload = client.post(
            "/sim/run-block",
            json={"block_id": "RS_v1", "cycles": 3, "forces": [{"name": "S", "value": True}]},
        ).json()
        assert payload["ok"] is True, payload
        assert payload["block"]["kind"] == "FB"
        by_name = series_by_name(payload)

        # The output is read through the instance field, the input through its point.
        assert by_name["B1#Q"]["values"] == [1, 1, 1]
        assert by_name["S"]["values"] == [1, 1, 1]
        assert by_name["S"]["forced"] == [True, True, True]
        assert by_name["B1#Q"]["forced"] == [False, False, False]

    def test_the_response_names_the_symbol_each_port_reads(self, client: TestClient):
        payload = client.post(
            "/sim/run-block", json={"block_id": "RS_v1", "cycles": 1}
        ).json()
        assert payload["ok"] is True, payload
        inputs = {row["port"]: row["symbol"] for row in payload["ports"]["inputs"]}
        outputs = {row["port"]: row["symbol"] for row in payload["ports"]["outputs"]}
        assert inputs == {"S": "S", "R": "R"}
        assert outputs == {"Q": "B1#Q"}

    def test_a_script_drives_the_latch_set_then_reset(self, client: TestClient):
        """The truth-table run shape: each combination lands on a successive cycle."""
        payload = client.post(
            "/sim/run-block",
            json={
                "block_id": "RS_v1",
                "cycles": 4,
                "script": [
                    {"cycle": 1, "name": "S", "value": True},
                    {"cycle": 3, "name": "R", "value": True},
                ],
            },
        ).json()
        assert payload["ok"] is True, payload
        by_name = series_by_name(payload)

        assert by_name["B1#Q"]["values"] == [1, 1, 0, 0], "R has priority over the held S"
        assert by_name["S"]["values"] == [1, 1, 1, 1]
        assert by_name["R"]["values"] == [0, 0, 1, 1]

    def test_a_refused_stimulus_is_answered_before_anything_runs(self, client: TestClient):
        answer = client.post(
            "/sim/run-block",
            json={"block_id": "RS_v1", "cycles": 1, "forces": [{"name": "S", "value": "1; rm -rf /"}]},
        )
        assert answer.status_code == 400
        assert "neither a number nor TRUE/FALSE" in answer.json()["detail"]

    def test_an_unknown_symbol_is_reported_as_the_run_being_refused(self, client: TestClient):
        payload = client.post(
            "/sim/run-block",
            json={"block_id": "RS_v1", "cycles": 1, "forces": [{"name": "NOPE", "value": 1}]},
        ).json()
        assert payload["ok"] is False and payload["stage"] == "simulate"
        assert "NOPE" in payload["errors"][0]

    def test_cycles_are_bounded_like_the_chart_run(self, client: TestClient):
        assert client.post("/sim/run-block", json={"block_id": "RS_v1", "cycles": 0}).status_code == 400

    def test_ports_renamed_away_from_the_body_still_call_the_body_ports(self, client: TestClient):
        """The panel may rename a port without touching the source body; the driver must
        bind by the body's real port name, or the compiler refuses the call."""
        get_library_service().add_block(
            AlgorithmBlock(
                id="DRIFT_v1",
                name="漂移块",
                category=BlockCategory.LOGIC,
                version="1.0.0",
                description="",
                block_kind="FB",
                inputs=[
                    BlockPort("IN1", PortDirection.INPUT, "BOOL"),
                    BlockPort("IN2", PortDirection.INPUT, "BOOL"),
                ],
                outputs=[BlockPort("OUT1", PortDirection.OUTPUT, "BOOL")],
                st_template=(
                    "FUNCTION_BLOCK DRIFT\n"
                    "VAR_INPUT\n"
                    "    SET : BOOL;\n"
                    "    RST : BOOL;\n"
                    "END_VAR\n"
                    "VAR_OUTPUT\n"
                    "    Q : BOOL;\n"
                    "END_VAR\n"
                    "    IF RST THEN\n"
                    "        Q := FALSE;\n"
                    "    ELSIF SET THEN\n"
                    "        Q := TRUE;\n"
                    "    END_IF;\n"
                    "END_FUNCTION_BLOCK"
                ),
            ),
            library_id="user-default",
        )
        payload = client.post(
            "/sim/run-block",
            json={"block_id": "DRIFT_v1", "cycles": 2, "forces": [{"name": "IN1", "value": True}]},
        ).json()
        assert payload["ok"] is True, payload

        # The panel keeps the display name; the call and the watch use the body's names.
        inputs = {row["port"]: row["symbol"] for row in payload["ports"]["inputs"]}
        outputs = {row["port"]: row["symbol"] for row in payload["ports"]["outputs"]}
        assert inputs == {"IN1": "IN1", "IN2": "IN2"}
        assert outputs == {"OUT1": "B1#Q"}
        assert "B1(SET := IN1, RST := IN2);" in payload["program"]

        by_name = series_by_name(payload)
        assert by_name["B1#Q"]["values"] == [1, 1]
        assert by_name["IN1"]["forced"] == [True, True]


class TestRunBlockFunction:
    """A FUNCTION is stateless: it is called positionally and its result lands in a global."""

    def test_a_function_call_returns_its_value_from_a_frame(self, client: TestClient):
        get_library_service().add_block(
            AlgorithmBlock(
                id="MASK_TEST_v1",
                name="掩码测试",
                category=BlockCategory.LOGIC,
                version="1.0.0",
                description="",
                block_kind="FUN",
                inputs=[
                    BlockPort("X", PortDirection.INPUT, "BOOL"),
                    BlockPort("EN", PortDirection.INPUT, "BOOL"),
                ],
                outputs=[BlockPort("Q", PortDirection.OUTPUT, "BOOL")],
                st_template=(
                    "FUNCTION MASK_TEST : BOOL\n"
                    "VAR_INPUT\n"
                    "    X : BOOL;\n"
                    "    EN : BOOL;\n"
                    "END_VAR\n"
                    "    MASK_TEST := X AND EN;\n"
                    "END_FUNCTION"
                ),
            ),
            library_id="user-default",
        )
        payload = client.post(
            "/sim/run-block",
            json={
                "block_id": "MASK_TEST_v1",
                "cycles": 2,
                "script": [
                    {"cycle": 1, "name": "X", "value": True},
                    {"cycle": 1, "name": "EN", "value": True},
                    {"cycle": 2, "name": "EN", "value": False},
                ],
            },
        ).json()
        assert payload["ok"] is True, payload
        assert payload["block"]["kind"] == "FUN"
        by_name = series_by_name(payload)

        # A FUNCTION recomputes every cycle; the second cycle sees EN drop.
        assert by_name["Q"]["values"] == [1, 0]
        assert "MASK_TEST(" in payload["program"], "the driver calls the function positionally"


class TestRunBlockComposition:
    """A block that cannot be driven says so, in its own words, before the run."""

    def test_an_unknown_block_is_not_found(self, client: TestClient):
        assert client.post("/sim/run-block", json={"block_id": "ghost", "cycles": 1}).status_code == 404

    def test_a_block_without_a_template_refuses_to_compose(self, client: TestClient):
        get_library_service().add_block(
            AlgorithmBlock(
                id="EMPTY_v1",
                name="空块",
                category=BlockCategory.CUSTOM,
                version="1.0.0",
                description="",
                block_kind="FB",
                inputs=[BlockPort("A", PortDirection.INPUT, "BOOL")],
                outputs=[BlockPort("Y", PortDirection.OUTPUT, "BOOL")],
                st_template="",
            ),
            library_id="user-default",
        )
        payload = client.post("/sim/run-block", json={"block_id": "EMPTY_v1", "cycles": 1}).json()
        assert payload["ok"] is False and payload["stage"] == "compose"
        assert payload["errors"]


def test_a_real_valued_block_reports_the_runner_verdict_not_a_crash(client: TestClient):
    """FBY divides by an uninitialized REAL instance field the runtime leaves at 0;
    the panel must show the runner's translated verdict, never a fabricated value."""
    payload = client.post(
        "/sim/run-block", json={"block_id": "FBY_v1", "cycles": 2, "forces": [{"name": "IN", "value": 1}]}
    ).json()
    assert payload["ok"] is False
    assert payload["stage"] in ("compile", "simulate")
    assert payload["errors"]
    if payload["stage"] == "simulate":
        verdict = payload["errors"][0]
        assert "周期执行失败" in verdict and "VM 码 -3" in verdict
        assert "plant:" not in verdict, "the raw object-table dump must not reach the panel"


def test_the_runner_dump_is_reworded_but_a_stimulus_refusal_is_kept():
    """Only an execution failure is translated; a startup rejection keeps its name."""
    from veri_ide.backend.sim.block_sim import humanize_run_errors

    raw = (
        "sim refused ['B1#OUT'] (exit 4): plant: 1 channels | ch=0 INPUT CONST | "
        "sim: cycle 1 failed: -3"
    )
    (verdict,) = humanize_run_errors([raw])
    assert verdict == "第 1 周期执行失败：运行期除以零（VM 码 -3）"

    kept = "sim refused ['NOPE'] (exit 2): unknown symbol NOPE"
    assert humanize_run_errors([kept]) == [kept]
